#! /bin/bash
set -e

function wait_for_deployment() {
    local deployment=$1
    local namespace=$2
    local timeout=300
    local interval=25
    local elapsed=0
    local ready=0

    while [ $elapsed -lt $timeout ]; do
        ready=$(oc get deployment -n "$namespace" "$deployment" -o jsonpath='{.status.readyReplicas}')
        if [ "$ready" == "1" ]; then
            echo "Operator $deployment is ready"
            return 0
        fi
        echo "Operator $deployment is not yet ready, waiting another $interval seconds"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    echo "Operator $deployment is not ready after $timeout seconds"
    return 1
}

echo "################################################"
echo "Starting the script. Many of the following commands"
echo "will periodically check on OCP for operations to"
echo "complete, so it's normal to see errors."
echo "If this scripts completes successfully, you will"
echo "see a final message confirming installation went"
echo "well."
echo "################################################"

echo ""
echo "############################ Install OSC ########################"
oc apply -f-<<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sandboxed-containers-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-sandboxed-containers-operator
  namespace: openshift-sandboxed-containers-operator
spec:
  targetNamespaces:
  - openshift-sandboxed-containers-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-sandboxed-containers-operator
  namespace: openshift-sandboxed-containers-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: sandboxed-containers-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "############################ Wait for OSC ########################"
wait_for_deployment controller-manager openshift-sandboxed-containers-operator || exit 1

# echo "############################ Update kata rpm ########################"
# curl -L https://raw.githubusercontent.com/confidential-devhub/workshop-on-ARO-showroom/refs/heads/main/helpers/update-kata-rpm.sh -o update-kata-rpm.sh
# chmod +x update-kata-rpm.sh
# ./update-kata-rpm.sh

# curl -L https://raw.githubusercontent.com/snir911/workshop-scripts/refs/heads/main/runtime-req-timetout.yaml -o kubelet-timeout.yaml
# oc apply -f kubelet-timeout.yaml
# sleep 5

# curl -L https://raw.githubusercontent.com/snir911/workshop-scripts/refs/heads/main/crio-setup.yaml -o crio-setup.yaml
# oc apply -f crio-setup.yaml
# sleep 5
# wait_for_mcp kata-oc || exit 1

# ostree admin unlock --hotfix
# chroot /host
# curl -L https://people.redhat.com/eesposit/kata-containers-3.21.0-3.rhaos4.17.el9.x86_64.rpm -o kata-containers-3.21.0-3.rhaos4.17.el9.x86_64.rpm
# rpm -Uvh --replacefiles kata-containers-3.21.0-3.rhaos4.17.el9.x86_64.rpm
# systemctl restart crio


echo ""
echo "################################################"
echo "OSC installed successfully!"
echo "################################################"