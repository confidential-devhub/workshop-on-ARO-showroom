#! /bin/bash

RPM_URL=${RPM_URL:-""}
GDRIVE_ID=${GDRIVE_ID:-"1kYV-CIAMCafxGYDVwc5z7yGrbbMbaxXq"}

if [[ -z "$RPM_URL" && -z "$GDRIVE_ID" ]]; then
    echo "RPM_URL or GDRIVE_ID is not set"
    exit 1
fi

echo "RPM_URL: $RPM_URL"
echo "GDRIVE_ID: $GDRIVE_ID"

FILE_TO_COPY=/tmp/kata-containers.rpm

if [[ -n "$RPM_URL" ]]; then
    curl -L "$RPM_URL"  -o $FILE_TO_COPY
elif [[ -n "$GDRIVE_ID" ]]; then
    pip install gdown
    gdown "$GDRIVE_ID" -O $FILE_TO_COPY
fi

NODE_NAME=$(oc get nodes -l workerType=kataWorker -o jsonpath='{.items[0].metadata.name}')
DEBUG_POD_NAMESPACE=default

if ! oc get runtimeclass kata-remote &> /dev/null; then
    echo -e "ERROR: RuntimeClass 'kata-remote' not found. Did you install the KataConfig CR?" >&2
    exit 1
fi

if ! oc get node "$NODE_NAME" &> /dev/null; then
    echo -e "ERROR: No node labeled 'workerType=kataWorker' found in the cluster." >&2
    exit 1
fi

TEMP_PATH_IN_POD="/host$FILE_TO_COPY"

function create_debug_pod() {
    local debug_pod_name=""
    local timeout=60
    local elapsed=0
    local interval=2

    echo "###### Start debug pod ######" >&2
    oc debug node/"$NODE_NAME" -n $DEBUG_POD_NAMESPACE -- sleep infinity &> /dev/null &

    while [[ -z "$debug_pod_name" && $elapsed -lt $timeout ]]; do
        debug_pod_name=$(oc get pods -n $DEBUG_POD_NAMESPACE --field-selector spec.nodeName="$NODE_NAME" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)
        [[ -z "$debug_pod_name" ]] && sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [[ -z "$debug_pod_name" ]]; then
        echo -e "ERROR: Timed out waiting for debug pod to be created on node '$NODE_NAME'." >&2
        exit 1
    fi

    echo "###### Found debug pod: $debug_pod_name in namespace $DEBUG_POD_NAMESPACE ######" >&2

    echo "###### Waiting for pod to be ready... ######" >&2
    if ! oc wait --for=condition=Ready "pod/$debug_pod_name" -n "$DEBUG_POD_NAMESPACE" --timeout=120s; then
        echo -e "ERROR: Timed out waiting for pod '$debug_pod_name' to become ready." >&2
        oc logs "pod/$debug_pod_name" -n "$DEBUG_POD_NAMESPACE" >&2
        exit 1
    fi
    echo "###### Pod is running and ready ######" >&2
    echo "$debug_pod_name"
}

DEBUG_POD_NAME=$(create_debug_pod)

echo "###### Copying rpm in debug pod ######"
oc cp "$FILE_TO_COPY" "${DEBUG_POD_NAMESPACE}/${DEBUG_POD_NAME}:${TEMP_PATH_IN_POD}"

echo "###### Installing the rpm... ######"
# oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host mount -o remount,rw /usr
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host ostree admin unlock --hotfix
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host rpm -Uvh "$FILE_TO_COPY"
echo ""

echo "Kata containers rpm version installed:"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host rpm -q kata-containers

# oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host systemctl restart crio
echo "###### Install succesful ######"

echo "###### Rebooting node... ######"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host reboot || true

echo "###### Waiting for node $NODE_NAME to be ready again... ######"
if ! oc wait --for=condition=Ready "node/$NODE_NAME" --timeout=1200s; then
    echo -e "ERROR: Timed out waiting for node '$NODE_NAME' to become ready after reboot." >&2
    exit 1
fi
echo "###### Node is ready ######"

DEBUG_POD_NAME=$(create_debug_pod)

echo "Kata containers rpm version installed:"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host rpm -q kata-containers

echo "###### Deleting debug pod and cleaning up... ######"
oc delete pod "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" --ignore-not-found=true
rm -f "$FILE_TO_COPY"

echo "###### Completed! ######"