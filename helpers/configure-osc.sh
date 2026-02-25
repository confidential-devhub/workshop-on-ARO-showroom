#! /bin/bash
set -e

INITDATA_PATH=${INITDATA_PATH:-"$HOME/trustee/initdata.toml"}
# Expand ~ to $HOME (handles ~/path)
INITDATA_PATH="${INITDATA_PATH/#\~/$HOME}"
# Resolve to absolute path
if [[ "$INITDATA_PATH" != /* ]]; then
  INITDATA_PATH="$(cd "$(dirname "$INITDATA_PATH")" && pwd)/$(basename "$INITDATA_PATH")"
fi
OSC_ENV=${OSC_ENV:-"rhdp"}

if [[ ! -f "$INITDATA_PATH" ]]; then
  echo "ERROR: INITDATA file not found: $INITDATA_PATH" >&2
  echo "Please configure the INITDATA_PATH environment variable"
  echo "For example: export INITDATA_PATH=\"/path/to/initdata.toml\""
  exit 1
fi

# force lowercase
OSC_ENV=$(echo "$OSC_ENV" | tr '[:upper:]' '[:lower:]')

# validate
case "$OSC_ENV" in
  rhdp|aro|az)
    export OSC_ENV
    ;;
  *)
    echo "ERROR: OSC_ENV must be one of: rhdp, aro, az (got '$OSC_ENV')" >&2
    exit 1
    ;;
esac

function wait_for_runtimeclass() {

    local runtimeclass=$1
    local timeout=900
    local interval=60
    local elapsed=0
    local ready=0

    # oc get runtimeclass "$runtimeclass" -o jsonpath={.metadata.name} should return the runtimeclass
    echo "Runtimeclass $runtimeclass is not yet ready, waiting another $interval seconds"
    while [ $elapsed -lt $timeout ]; do
        ready=$(oc get runtimeclass "$runtimeclass" -o jsonpath='{.metadata.name}')
        if [ "$ready" == "$runtimeclass" ]; then
            echo "Runtimeclass $runtimeclass is ready"
            return 0
        fi
        echo "Runtimeclass $runtimeclass is not yet ready, waiting another $interval seconds"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo "Runtimeclass $runtimeclass is not ready after $timeout seconds"
    return 1
}

function wait_for_mcp() {
    local mcp=$1
    local timeout=900
    local interval=30
    local elapsed=0
    echo "MCP $mcp is not yet ready, waiting another $interval seconds"
    while [ $elapsed -lt $timeout ]; do
        if [ "$statusUpdated" == "True" ] && [ "$statusUpdating" == "False" ] && [ "$statusDegraded" == "False" ]; then
            echo "MCP $mcp is ready"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        statusUpdated=$(oc get mcp "$mcp" -o=jsonpath='{.status.conditions[?(@.type=="Updated")].status}')
        statusUpdating=$(oc get mcp "$mcp" -o=jsonpath='{.status.conditions[?(@.type=="Updating")].status}')
        statusDegraded=$(oc get mcp "$mcp" -o=jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')
        echo "MCP $mcp is not yet ready, waiting another $interval seconds"
    done

    echo "MCP $mcp is not ready after $timeout seconds"
    return 1
}

echo "Checking Azure login status..."
if az account show; then
  echo "User is logged into Azure."
else
  echo "User is not logged in. Please run 'az login' first."
  exit 1
fi

echo ""

REQUIRED="4.18.30"
# Extract version number (e.g., 4.18.30)
CURRENT=$(oc version 2>/dev/null | grep "Server Version" | awk '{print $3}')

echo "Current: $CURRENT"
echo "Required: $REQUIRED"

# Use sort -V to compare versions correctly
# If the lowest version in the list is NOT the required one, then Current < Required.
if [ "$(printf '%s\n' "$REQUIRED" "$CURRENT" | sort -V | head -n1)" != "$REQUIRED" ]; then
  echo "Exiting: Cluster version is below $REQUIRED"
  exit 1
fi

echo "################################################"
echo "Starting the script. Many of the following commands"
echo "will periodically check on OCP for operations to"
echo "complete, so it's normal to see errors."
echo "If this scripts completes successfully, you will"
echo "see a final message confirming installation went"
echo "well."
echo "################################################"

echo ""

echo "################################################"

mkdir -p ~/osc
cd ~/osc

cat > cc-fg.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: osc-feature-gates
  namespace: openshift-sandboxed-containers-operator
data:
  confidential: "true"
EOF

oc apply -f cc-fg.yaml

####################################################################
echo "################################################"

CLOUD_CONF=$(oc get configmap cloud-conf \
  -n openshift-cloud-controller-manager \
  -o jsonpath='{.data.cloud\.conf}')

# Parse required fields
SUBSCRIPTION_ID=$(echo "$CLOUD_CONF" | jq -r '.subscriptionId')
LOCATION=$(echo "$CLOUD_CONF" | jq -r '.location')
USER_RESOURCE_GROUP=$(echo "$CLOUD_CONF" | jq -r '.vnetResourceGroup')
VNET_NAME=$(echo "$CLOUD_CONF" | jq -r '.vnetName')
SUBNET_NAME=$(echo "$CLOUD_CONF" | jq -r '.subnetName')
CLUSTER_RESOURCE_GROUP=$(echo "$CLOUD_CONF" | jq -r '.resourceGroup')
SECURITY_GROUP_NAME=$(echo "$CLOUD_CONF" | jq -r '.securityGroupName')

# Construct resource IDs
AZURE_REGION="$LOCATION"
AZURE_SUBNET_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${USER_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${SUBNET_NAME}"
AZURE_NSG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${CLUSTER_RESOURCE_GROUP}/providers/Microsoft.Network/networkSecurityGroups/${SECURITY_GROUP_NAME}"

echo "AZURE_REGION: \"$AZURE_REGION\""
echo "CLUSTER_RESOURCE_GROUP: \"$CLUSTER_RESOURCE_GROUP\""
echo "USER_RESOURCE_GROUP: \"$USER_RESOURCE_GROUP\""
echo "ARO_SUBNET_ID: \"$AZURE_SUBNET_ID\""
echo "ARO_NSG_ID: \"$AZURE_NSG_ID\""

# Necessary otherwise the CoCo pods won't be able to connect with the OCP cluster (OSC and Trustee)
PEERPOD_NAT_GW=peerpod-nat-gw
PEERPOD_NAT_GW_IP=peerpod-nat-gw-ip

az network public-ip create -g "${USER_RESOURCE_GROUP}" \
    -n "${PEERPOD_NAT_GW_IP}" -l "${AZURE_REGION}" --sku Standard

az network nat gateway create -g "${USER_RESOURCE_GROUP}" \
    -l "${AZURE_REGION}" --public-ip-addresses "${PEERPOD_NAT_GW_IP}" \
    -n "${PEERPOD_NAT_GW}"

az network vnet subnet update --nat-gateway "${PEERPOD_NAT_GW}" \
    --ids "${AZURE_SUBNET_ID}"

AZURE_NAT_ID=$(az network vnet subnet show --ids "${AZURE_SUBNET_ID}" \
    --query "natGateway.id" -o tsv)

echo "AZURE_NAT_ID: \"$AZURE_NAT_ID\""

INITDATA=$(cat $INITDATA_PATH | gzip | base64 -w0)
echo ""
echo $INITDATA
echo ""

cat > pp-cm.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-pods-cm
  namespace: openshift-sandboxed-containers-operator
data:
  CLOUD_PROVIDER: "azure"
  VXLAN_PORT: "9000"
  AZURE_INSTANCE_SIZES: "Standard_DC2as_v5,Standard_DC2es_v5,Standard_DC4as_v5,Standard_DC4es_v5,Standard_DC8es_v5,Standard_DC8as_v5"
  AZURE_INSTANCE_SIZE: "Standard_DC4as_v5"
  AZURE_RESOURCE_GROUP: "${CLUSTER_RESOURCE_GROUP}"
  AZURE_REGION: "${AZURE_REGION}"
  AZURE_SUBNET_ID: "${AZURE_SUBNET_ID}"
  AZURE_NSG_ID: "${AZURE_NSG_ID}"
  PROXY_TIMEOUT: "5m"
  INITDATA: "${INITDATA}"
  PEERPODS_LIMIT_PER_NODE: "10"
  TAGS: "key1=value1,key2=value2"
  ROOT_VOLUME_SIZE: "20"
  AZURE_IMAGE_ID: ""
EOF

cat pp-cm.yaml
oc apply -f pp-cm.yaml

####################################################################
echo "################################################"

oc label node $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}') workerType=kataWorker

cat > kataconfig.yaml <<EOF
apiVersion: kataconfiguration.openshift.io/v1
kind: KataConfig
metadata:
 name: example-kataconfig
spec:
  enablePeerPods: true
  kataConfigPoolSelector:
    matchLabels:
      workerType: 'kataWorker'
EOF

cat kataconfig.yaml
oc apply -f kataconfig.yaml

echo "############################ Wait for Kataconfig ########################"
sleep 10

wait_for_mcp kata-oc || exit 1

# Wait for runtimeclass kata to be ready
wait_for_runtimeclass kata || exit 1

echo "############################ Wait for kata-remote + job ########################"

# Wait for runtimeclass kata-remote to be ready
wait_for_runtimeclass kata-remote || exit 1

# curl -L https://raw.githubusercontent.com/snir911/workshop-scripts/refs/heads/main/runtime-req-timetout.yaml -o kubelet-timeout.yaml
# oc apply -f kubelet-timeout.yaml
# sleep 5

# curl -L https://raw.githubusercontent.com/snir911/workshop-scripts/refs/heads/main/crio-setup.yaml -o crio-setup.yaml
# oc apply -f crio-setup.yaml
# sleep 5
# wait_for_mcp kata-oc || exit 1

echo ""
echo "################################################"
echo "OSC configured successfully!"
echo "################################################"