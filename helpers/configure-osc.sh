#! /bin/bash
set -e


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

echo "Checking for AZURE_RESOURCE_GROUP..."
if [[ -n "$AZURE_RESOURCE_GROUP" ]]; then
  echo "AZURE_RESOURCE_GROUP is set to: '$AZURE_RESOURCE_GROUP'"
else
  echo "The AZURE_RESOURCE_GROUP environment variable is not set."
  echo "   Please set it, for example: export AZURE_RESOURCE_GROUP=\"my-rg-name\""
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

# Get the ARO created RG
ARO_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')

# If the cluster is Azure self managed, run
# AZURE_RESOURCE_GROUP=$ARO_RESOURCE_GROUP

# Get the ARO region
ARO_REGION=$(oc get secret -n kube-system azure-credentials -o jsonpath="{.data.azure_region}" | base64 -d)

# Get VNET name used by ARO. This exists in the admin created RG.
# In this ARO infrastructure, there are 2 VNETs: pick the one starting with "aro-".
# The other is used internally by this workshop
# If the cluster is Azure self managed, change
# contains(Name, 'aro')
# with
# contains(Name, '')
ARO_VNET_NAME=$(az network vnet list --resource-group $AZURE_RESOURCE_GROUP --query "[].{Name:name} | [? contains(Name, 'aro')]" --output tsv)

# Get the Openshift worker subnet ip address cidr. This exists in the admin created RG
ARO_WORKER_SUBNET_ID=$(az network vnet subnet list --resource-group $AZURE_RESOURCE_GROUP --vnet-name $ARO_VNET_NAME --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv)

ARO_NSG_ID=$(az network nsg list --resource-group $ARO_RESOURCE_GROUP --query "[].{Id:id}" --output tsv)

# Necessary otherwise the CoCo pods won't be able to connect with the OCP cluster (OSC and Trustee)
PEERPOD_NAT_GW=peerpod-nat-gw
PEERPOD_NAT_GW_IP=peerpod-nat-gw-ip

az network public-ip create -g "${AZURE_RESOURCE_GROUP}" \
    -n "${PEERPOD_NAT_GW_IP}" -l "${ARO_REGION}" --sku Standard

az network nat gateway create -g "${AZURE_RESOURCE_GROUP}" \
    -l "${ARO_REGION}" --public-ip-addresses "${PEERPOD_NAT_GW_IP}" \
    -n "${PEERPOD_NAT_GW}"

az network vnet subnet update --nat-gateway "${PEERPOD_NAT_GW}" \
    --ids "${ARO_WORKER_SUBNET_ID}"

ARO_NAT_ID=$(az network vnet subnet show --ids "${ARO_WORKER_SUBNET_ID}" \
    --query "natGateway.id" -o tsv)

echo "ARO_REGION: \"$ARO_REGION\""
echo "ARO_RESOURCE_GROUP: \"$ARO_RESOURCE_GROUP\""
echo "ARO_SUBNET_ID: \"$ARO_WORKER_SUBNET_ID\""
echo "ARO_NSG_ID: \"$ARO_NSG_ID\""
echo "ARO_NAT_ID: \"$ARO_NAT_ID\""

cat > pp-cm.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-pods-cm
  namespace: openshift-sandboxed-containers-operator
data:
  CLOUD_PROVIDER: "azure"
  VXLAN_PORT: "9000"
  AZURE_INSTANCE_SIZES: "Standard_DC4as_v5,Standard_DC4es_v5"
  AZURE_INSTANCE_SIZE: "Standard_DC4es_v5"
  AZURE_RESOURCE_GROUP: "${ARO_RESOURCE_GROUP}"
  AZURE_REGION: "${ARO_REGION}"
  AZURE_SUBNET_ID: "${ARO_WORKER_SUBNET_ID}"
  AZURE_NSG_ID: "${ARO_NSG_ID}"
  PROXY_TIMEOUT: "5m"
  DISABLECVM: "false"
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


echo ""
echo "################################################"
echo "OSC configured successfully!"
echo "################################################"