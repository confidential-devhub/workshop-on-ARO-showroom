#!/bin/bash
set -euo pipefail

RPM_URL=${RPM_URL:-""}
GDRIVE_ID=${GDRIVE_ID:-"1iX66gdZOFm5HRwZFJYfoOfNKGcRYmbQf"}
LOCAL_RPM=""
NODE_SELECTOR=${NODE_SELECTOR:-"node-role.kubernetes.io/kata-oc="}
DS_NAMESPACE="openshift-sandboxed-containers-operator"
RPM_PATH=/tmp/kata-containers.rpm

if [[ -z "$RPM_URL" && -z "$GDRIVE_ID" ]]; then
    echo "ERROR: Set RPM_URL or GDRIVE_ID" >&2
    exit 1
fi

echo "RPM_URL: $RPM_URL"
echo "GDRIVE_ID: $GDRIVE_ID"

# Find kata nodes
NODES=$(oc get nodes -l "$NODE_SELECTOR" -o jsonpath='{.items[*].metadata.name}')
if [[ -z "$NODES" ]]; then
    echo "ERROR: No nodes found with label '$NODE_SELECTOR'" >&2
    exit 1
fi
echo "###### Kata nodes: $NODES ######"

# Download RPM locally if using Google Drive
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

# Find the daemonset pod on each node and replace the RPM
for NODE_NAME in $NODES; do
    echo ""
    echo "=============================="
    echo "###### Processing node: $NODE_NAME ######"
    echo "=============================="

    # Find the install daemonset pod on this node
    DS_POD=$(oc get pods -n "$DS_NAMESPACE" \
        --field-selector spec.nodeName="$NODE_NAME" \
        -l name=osc-rpm-install-install \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "$DS_POD" ]]; then
        echo "WARNING: No install daemonset pod found on $NODE_NAME, skipping" >&2
        continue
    fi
    echo "###### Using daemonset pod: $DS_POD ######"

    # Copy RPM to the pod and then to the host
    if [[ -n "$RPM_URL" ]]; then
        echo "###### Downloading RPM directly on node... ######"
        oc exec "$DS_POD" -n "$DS_NAMESPACE" -c kata-install -- \
            chroot /host curl -fSL "$RPM_URL" -o "$RPM_PATH"
    else
        echo "###### Copying RPM to pod... ######"
        oc cp "$LOCAL_RPM" "$DS_NAMESPACE/$DS_POD:$RPM_PATH" -c kata-install
        echo "###### Copying RPM to host filesystem... ######"
        oc exec "$DS_POD" -n "$DS_NAMESPACE" -c kata-install -- \
            cp "$RPM_PATH" "/host$RPM_PATH"
    fi

    # Replace the kata-containers RPM via rpm-ostree
    echo "###### Replacing kata-containers RPM... ######"
    oc exec "$DS_POD" -n "$DS_NAMESPACE" -c kata-install -- \
        chroot /host rpm-ostree uninstall kata-containers --install "$RPM_PATH"

    echo "###### Applying live (no reboot)... ######"
    oc exec "$DS_POD" -n "$DS_NAMESPACE" -c kata-install -- \
        chroot /host rpm-ostree apply-live --allow-replacement

    # Verify
    echo ""
    echo "Kata containers RPM version installed on $NODE_NAME:"
    oc exec "$DS_POD" -n "$DS_NAMESPACE" -c kata-install -- \
        chroot /host rpm -q kata-containers

    # Clean up
    oc exec "$DS_POD" -n "$DS_NAMESPACE" -c kata-install -- \
        chroot /host rm -f "$RPM_PATH"

    echo "###### Node $NODE_NAME done ######"
done

echo ""
echo "###### All nodes updated successfully! ######"
