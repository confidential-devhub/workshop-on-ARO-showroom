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

function wait_for_phase() {
    local dsc=$1
    local objtype=$2
    local status=$3
    local timeout=900
    local interval=30
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        sleep $interval
        elapsed=$((elapsed + interval))
        statusReady=$(oc get "$objtype" "$dsc" -o=jsonpath='{.status.conditions[?(@.type=="'$status'")].status}')
        if [ "$statusReady" == "True" ]; then
            echo "$objtype $dsc is $status"
            return 0
        fi
        echo "$objtype $dsc is not yet $status, waiting another $interval seconds"
    done

	echo "$objtype $dsc is not $status after $timeout seconds"
    return 1
}

echo "################################################"
echo "Starting the script. Many of the following commands"
echo "will periodically check on OCP for operations to"
echo "complete, so it's normal to see errors."
echo "If this scripts completes successfully, you will"
echo "see a final message confirming installation went"
echo "well."

echo "This script will:"
echo " - Check the podvm root disk size to ensure enough space for the notebook"
echo " - Install Openshift AI, Servicemesh and Serverless in the cluster"
echo " - Create a new namespace and deploy CoCo fraud-detection notebook"
echo "################################################"

echo ""

echo "############################ Check root disk size #############"
NAMESPACE="openshift-sandboxed-containers-operator"
CONFIGMAP="peer-pods-cm"

# Get current value (empty if not set)
CURRENT_VALUE=$(oc get cm "${CONFIGMAP}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.ROOT_VOLUME_SIZE}' 2>/dev/null || true)

# Default to 0 if empty or non-numeric
if [[ -z "${CURRENT_VALUE}" || ! "${CURRENT_VALUE}" =~ ^[0-9]+$ ]]; then
  CURRENT_VALUE=0
fi

echo "Current ROOT_VOLUME_SIZE=${CURRENT_VALUE}"

if (( CURRENT_VALUE > 19 )); then
  echo "ROOT_VOLUME_SIZE is already >= 20."
else
  echo "You need to update ROOT_VOLUME_SIZE in peer-pods-cm to at least 20"
  echo "Remember to restart the OSC caa daemonset after this change:"
  echo '# oc set env ds/osc-caa-ds -n openshift-sandboxed-containers-operator REBOOT="$(date)"'
  exit 1

  # oc patch cm "${CONFIGMAP}" -n "${NAMESPACE}" \
  #   --type merge \
  #   -p '{"data":{"ROOT_VOLUME_SIZE":"20"}}'

  # echo "Update complete."
fi

echo "###############################################################"

echo "############################ Install OAI ########################"
oc apply -f-<<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  name: serverless-operator
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f-<<EOF
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  name: servicemeshoperator
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f-<<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  name: rhods-operator
  installPlanApproval: Automatic
  channel: stable
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "############################ Wait for Serverless ########################"
wait_for_deployment knative-openshift openshift-serverless || exit 1

echo "############################ Wait for Service Mesh ########################"
wait_for_deployment istio-operator openshift-operators || exit 1

echo "############################ Wait for OAI ########################"
wait_for_phase default-dsci DSCInitialization Available || exit 1

oc apply -f-<<EOF
---
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
  labels:
    app.kubernetes.io/created-by: rhods-operator
    app.kubernetes.io/instance: default-dsc
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: datasciencecluster
    app.kubernetes.io/part-of: rhods-operator
spec:
  components:
    codeflare:
      managementState: Managed
    kserve:
      nim:
        managementState: Managed
      rawDeploymentServiceConfig: Headless
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Managed
        name: knative-serving
      managementState: Managed
    modelregistry:
      registriesNamespace: rhoai-model-registries
      managementState: Managed
    feastoperator:
      managementState: Removed
    trustyai:
      eval:
        lmeval:
          permitCodeExecution: deny
          permitOnline: deny
      managementState: Managed
    ray:
      managementState: Managed
    kueue:
      defaultClusterQueueName: default
      defaultLocalQueueName: default
      managementState: Managed
    workbenches:
      workbenchNamespace: rhods-notebooks
      managementState: Managed
    dashboard:
      managementState: Managed
    modelmeshserving:
      managementState: Managed
    llamastackoperator:
      managementState: Removed
    datasciencepipelines:
      argoWorkflowsControllers:
        managementState: Managed
      managementState: Managed
    trainingoperator:
      managementState: Managed
EOF

echo "############################ Wait for OAI DSC ########################"
wait_for_phase default-dsc DataScienceCluster Ready || exit 1

# Disable local registry
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type=merge \
  -p '{"spec":{"managementState":"Removed"}}'

# oc adm policy add-cluster-role-to-user cluster-admin "kube:admin"

OAI_NS=fraud-detection
OAI_NAME=fraud-detection

oc get secret pull-secret -n openshift-config -o yaml \
  | sed "s/namespace: openshift-config/namespace: ${OAI_NS}/" \
  | oc apply -n "${OAI_NS}" -f -

oc secrets link default pull-secret --for=pull -n ${OAI_NS}

# oc apply -f-<<EOF
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: RoleBinding
# metadata:
#   labels:
#     opendatahub.io/dashboard: "true"
#     opendatahub.io/project-sharing: "true"
#   name: rhods-rb-${OAI_NAME}
#   namespace: ${OAI_NS}
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: ClusterRole
#   name: admin
# subjects:
# - apiGroup: rbac.authorization.k8s.io
#   kind: User
#   name: admin
# EOF



