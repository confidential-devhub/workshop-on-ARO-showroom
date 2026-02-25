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

echo "############################ Install Trustee ########################"
oc apply -f-<<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: trustee-operator-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: trustee-operator-group
  namespace: trustee-operator-system
spec:
  targetNamespaces:
  - trustee-operator-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trustee-operator
  namespace: trustee-operator-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: trustee-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "############################ Install cert-manager ########################"
oc new-project cert-manager-operator || oc project cert-manager-operator

oc apply -f-<<EOF
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
    name: openshift-cert-manager-operator
    namespace: cert-manager-operator
spec:
    targetNamespaces:
    - "cert-manager-operator"
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
    name: openshift-cert-manager-operator
    namespace: cert-manager-operator
spec:
    channel: stable-v1
    name: openshift-cert-manager-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
    installPlanApproval: Automatic
EOF

oc project default

echo "############################ Wait for Trustee ########################"
wait_for_deployment trustee-operator-controller-manager trustee-operator-system || exit 1
wait_for_deployment cert-manager-operator-controller-manager cert-manager-operator || exit 1

sleep 10

echo ""
echo "################################################"
echo "Trustee and cert-manager installed successfully!"
echo "################################################"