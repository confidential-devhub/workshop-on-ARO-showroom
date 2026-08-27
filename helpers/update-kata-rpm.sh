#!/bin/bash
set -euo pipefail

RPM_URL=${RPM_URL:-""}
GDRIVE_ID=${GDRIVE_ID:-"1iX66gdZOFm5HRwZFJYfoOfNKGcRYmbQf"}
LOCAL_RPM=""

if [[ -z "$RPM_URL" && -z "$GDRIVE_ID" ]]; then
    echo "ERROR: Set RPM_URL or GDRIVE_ID" >&2
    exit 1
fi

echo "RPM_URL: $RPM_URL"
echo "GDRIVE_ID: $GDRIVE_ID"

NODE_NAME=$(oc get nodes -l workerType=kataWorker -o jsonpath='{.items[0].metadata.name}')
DEBUG_POD_NAMESPACE=default
RPM_PATH=/tmp/kata-containers.rpm

if ! oc get runtimeclass kata-remote &> /dev/null; then
    echo "ERROR: RuntimeClass 'kata-remote' not found. Did you install the KataConfig CR?" >&2
    exit 1
fi

if ! oc get node "$NODE_NAME" &> /dev/null; then
    echo "ERROR: No node labeled 'workerType=kataWorker' found in the cluster." >&2
    exit 1
fi

cleanup_debug_pods() {
    local stale
    stale=$(oc get pods -n "$DEBUG_POD_NAMESPACE" \
        --field-selector spec.nodeName="$NODE_NAME" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for p in $stale; do
        echo "###### Cleaning up stale debug pod: $p ######" >&2
        oc delete pod "$p" -n "$DEBUG_POD_NAMESPACE" --ignore-not-found=true --wait=false >&2
    done
}

create_debug_pod() {
    local max_attempts=3

    for attempt in $(seq 1 $max_attempts); do
        local pod=""
        local elapsed=0

        echo "###### Starting debug pod (attempt $attempt/$max_attempts) ######" >&2
        cleanup_debug_pods
        oc debug node/"$NODE_NAME" -n "$DEBUG_POD_NAMESPACE" -- sleep infinity &> /dev/null &

        while [[ -z "$pod" && $elapsed -lt 60 ]]; do
            pod=$(oc get pods -n "$DEBUG_POD_NAMESPACE" \
                --field-selector spec.nodeName="$NODE_NAME",status.phase!=Succeeded,status.phase!=Failed \
                --sort-by=.metadata.creationTimestamp \
                -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)
            [[ -z "$pod" ]] && sleep 2
            elapsed=$((elapsed + 2))
        done

        if [[ -z "$pod" ]]; then
            echo "WARNING: Timed out waiting for debug pod to appear (attempt $attempt/$max_attempts)." >&2
            [[ $attempt -eq $max_attempts ]] && { echo "ERROR: Failed to create debug pod after $max_attempts attempts." >&2; exit 1; }
            sleep 5
            continue
        fi

        echo "###### Found debug pod: $pod ######" >&2
        echo "###### Waiting for pod to be ready... ######" >&2
        if oc wait --for=condition=Ready "pod/$pod" -n "$DEBUG_POD_NAMESPACE" --timeout=120s >&2 2>/dev/null; then
            echo "###### Pod is ready ######" >&2
            echo "$pod"
            return 0
        fi

        echo "WARNING: Pod '$pod' never became ready (attempt $attempt/$max_attempts)." >&2
        oc logs "pod/$pod" -n "$DEBUG_POD_NAMESPACE" >&2 || true
        oc delete pod "$pod" -n "$DEBUG_POD_NAMESPACE" --ignore-not-found=true --wait=false >&2 || true
        [[ $attempt -eq $max_attempts ]] && { echo "ERROR: Failed to create debug pod after $max_attempts attempts." >&2; exit 1; }
        sleep 5
    done
}

delete_debug_pod() {
    echo "###### Deleting debug pod $1 ######"
    oc delete pod "$1" -n "$DEBUG_POD_NAMESPACE" --ignore-not-found=true --wait=false
}

if [[ -n "$RPM_URL" ]]; then
    LOCAL_RPM="$RPM_URL"
elif [[ -n "$GDRIVE_ID" ]]; then
    if ! command -v gdown &> /dev/null; then
        echo "ERROR: gdown is required to download from Google Drive. Install it with: pip install gdown" >&2
        exit 1
    fi
    LOCAL_RPM=$RPM_PATH
    echo "###### Downloading RPM from Google Drive... ######"
    gdown "$GDRIVE_ID" -O "$LOCAL_RPM"
fi

DEBUG_POD_NAME=$(create_debug_pod)

if [[ -n "$RPM_URL" ]]; then
    echo "###### Downloading RPM directly on node... ######"
    oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
        chroot /host curl -fSL "$RPM_URL" -o "$RPM_PATH"
else
    echo "###### Copying RPM to node (streaming)... ######"
    oc exec -i "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
        sh -c "cat > /host${RPM_PATH}" < "$LOCAL_RPM"
fi

echo "###### Unlocking ostree... ######"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
    chroot /host ostree admin unlock --hotfix || echo "(already unlocked, continuing)"

echo "###### Installing RPM... ######"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
    chroot /host rpm -Uvh --force "$RPM_PATH"

echo ""
echo "Kata containers RPM version installed:"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
    chroot /host rpm -q kata-containers

oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
    chroot /host rm -f "$RPM_PATH"

echo "###### Install successful ######"

echo "###### Rebooting node... ######"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host reboot || true

delete_debug_pod "$DEBUG_POD_NAME"

echo "###### Waiting for node $NODE_NAME to be ready again... ######"
sleep 30
if ! oc wait --for=condition=Ready "node/$NODE_NAME" --timeout=1200s; then
    echo "ERROR: Timed out waiting for node '$NODE_NAME' to become ready after reboot." >&2
    exit 1
fi
echo "###### Node is ready ######"

DEBUG_POD_NAME=$(create_debug_pod)

echo "Kata containers RPM version installed after reboot:"
for attempt in 1 2 3; do
    if oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- \
        chroot /host rpm -q kata-containers; then
        break
    fi
    echo "Retrying in 10s... ($attempt/3)"
    sleep 10
done

delete_debug_pod "$DEBUG_POD_NAME"

echo "###### Completed! ######"