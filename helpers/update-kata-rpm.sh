#! /bin/bash

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

TEMP_PATH_IN_POD="/host/tmp/$FILENAME"
FILE_TO_COPY=kata-containers-3.21.0-3.rhaos4.17.el9.x86_64.rpm
curl -L https://people.redhat.com/eesposit/kata-containers-3.21.0-3.rhaos4.17.el9.x86_64.rpm  -o $FILE_TO_COPY

echo "###### Start debug pod ######"
oc debug node/"$NODE_NAME" -n $DEBUG_POD_NAMESPACE -- sleep infinity &> /dev/null &

DEBUG_POD_NAME=""
TIMEOUT=60 # seconds
ELAPSED=0
INTERVAL=2

while [[ -z "$DEBUG_POD_NAME" && $ELAPSED -lt $TIMEOUT ]]; do
    DEBUG_POD_NAME=$(oc get pods -n $DEBUG_POD_NAMESPACE --field-selector spec.nodeName="$NODE_NAME" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)
    [[ -z "$DEBUG_POD_NAME" ]] && sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ -z "$DEBUG_POD_NAME" ]]; then
    echo -e "ERROR: Timed out waiting for debug pod to be created on node '$NODE_NAME'." >&2
    exit 1
fi

echo "###### Found debug pod: $DEBUG_POD_NAME in namespace $DEBUG_POD_NAMESPACE ######"

echo "###### Waiting for pod to be ready... ######"
if ! oc wait --for=condition=Ready "pod/$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" --timeout=120s; then
    echo -e "ERROR: Timed out waiting for pod '$DEBUG_POD_NAME' to become ready." >&2
    oc logs "pod/$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" >&2
    exit 1
fi
echo "###### Pod is running and ready ######"

echo "###### Copying rpm in debug pod ######"
oc cp "$FILE_TO_COPY" "${DEBUG_POD_NAMESPACE}/${DEBUG_POD_NAME}:${TEMP_PATH_IN_POD}"

echo "###### Installing the rpm... ######"
# oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host mount -o remount,rw /usr
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host ostree admin unlock --hotfix
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host rpm -Uvh "/tmp/$FILE_TO_COPY"
echo ""

echo "Kata containers rpm version installed:"
oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host rpm -q kata-containers

oc exec "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" -- chroot /host systemctl restart crio
echo "###### Install succesful ######"

oc delete pod "$DEBUG_POD_NAME" -n "$DEBUG_POD_NAMESPACE" --ignore-not-found=true
rm -f $FILE_TO_COPY

echo "###### Completed! ######"