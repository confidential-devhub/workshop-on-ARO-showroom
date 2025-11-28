#! /bin/bash
set -e

#sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm -y
#sudo dnf install screen -y

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

echo ""

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
oc new-project cert-manager-operator

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

echo "############################ Wait for Trustee ########################"
wait_for_deployment trustee-operator-controller-manager trustee-operator-system || exit 1
wait_for_deployment cert-manager-operator-controller-manager cert-manager-operator || exit 1

echo "############################ Wait for OSC ########################"
wait_for_deployment controller-manager openshift-sandboxed-containers-operator || exit 1

####################################################################
echo "################################################"

mkdir -p trustee
cd trustee

oc completion bash > oc_bash_completion
sudo cp oc_bash_completion /etc/bash_completion.d/
source /etc/bash_completion

DOMAIN=$(oc get ingress.config/cluster -o jsonpath='{.spec.domain}')
NS=trustee-operator-system
ROUTE_NAME=kbs-service
ROUTE="${ROUTE_NAME}-${NS}.${DOMAIN}"

CN_NAME=kbs-trustee-operator-system
ORG_NAME=my_org

oc apply -f-<<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: kbs-issuer
  namespace: trustee-operator-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kbs-https
  namespace: trustee-operator-system
spec:
  commonName: ${CN_NAME}
  subject:
    organizations:
      - ${ORG_NAME}
  dnsNames:
    - ${ROUTE}
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 2048
  duration: 8760h
  renewBefore: 360h # Standard practice: renew 15 days before expiry
  secretName: trustee-tls-cert
  issuerRef:
    name: kbs-issuer
    kind: Issuer # or ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kbs-token
  namespace: trustee-operator-system
spec:
  dnsNames:
    - kbs-service
  secretName: trustee-token-cert
  issuerRef:
    name: kbs-issuer
  privateKey:
    algorithm: ECDSA
    encoding: PKCS8
    size: 256
EOF

oc get secrets -n trustee-operator-system | grep /tls
####################################################################
echo "################################################"

oc apply -f-<<EOF
apiVersion: confidentialcontainers.org/v1alpha1
kind: TrusteeConfig
metadata:
  labels:
    app.kubernetes.io/name: trusteeconfig
    app.kubernetes.io/instance: trusteeconfig
    app.kubernetes.io/part-of: trustee-operator
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/created-by: trustee-operator
  name: trusteeconfig
  namespace: trustee-operator-system
spec:
  profileType: Restricted
  kbsServiceType: ClusterIP
  httpsSpec:
    tlsSecretName: trustee-tls-cert
  attestationTokenVerificationSpec:
    tlsSecretName: trustee-token-cert
EOF

oc get secrets -n trustee-operator-system | grep trusteeconfig
oc get configmaps -n trustee-operator-system | grep trusteeconfig

echo "################################################"

oc get secret trustee-tls-cert -n trustee-operator-system -o json | jq -r '.data."tls.crt"' | base64 --decode > https.crt

TRUSTEE_CERT=$(cat https.crt)

oc create route passthrough kbs-service \
  --service=kbs-service \
  --port=kbs-port \
  -n trustee-operator-system

TRUSTEE_ROUTE="$(oc get route -n trustee-operator-system kbs-service \
  -o jsonpath={.spec.host})"

TRUSTEE_HOST=https://${TRUSTEE_ROUTE}

echo $TRUSTEE_HOST

####################################################################
echo "################################################"

curl -L https://raw.githubusercontent.com/confidential-devhub/workshop-on-ARO-showroom/refs/heads/showroom/helpers/cosign.pub -o cosign.pub

SIGNATURE_SECRET_NAME=cosign-key
SIGNATURE_SECRET_FILE=hello-pub-key

oc create secret generic $SIGNATURE_SECRET_NAME \
    --from-file=$SIGNATURE_SECRET_FILE=./cosign.pub \
    -n trustee-operator-system

SECURITY_POLICY_IMAGE=quay.io/confidential-devhub/signed-hello-openshift

cat > verification-policy.json <<EOF
{
  "default": [
      {
      "type": "insecureAcceptAnything"
      }
  ],
  "transports": {
      "docker": {
          "$SECURITY_POLICY_IMAGE":
          [
              {
                  "type": "sigstoreSigned",
                  "keyPath": "kbs:///default/$SIGNATURE_SECRET_NAME/$SIGNATURE_SECRET_FILE"
              }
          ]
      }
  }
}
EOF

POLICY_SECRET_NAME=hello-image-policy

oc create secret generic $POLICY_SECRET_NAME \
  --from-file=osc=./verification-policy.json \
  -n trustee-operator-system

####################################################################
echo "################################################"

cat > initdata.toml <<EOF
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]
url = "${TRUSTEE_HOST}"

[token_configs.kbs]
url = "${TRUSTEE_HOST}"
cert = """
${TRUSTEE_CERT}
"""
'''

"cdh.toml"  = '''
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "${TRUSTEE_HOST}"
kbs_cert = """
${TRUSTEE_CERT}
"""

[image]
image_security_policy_uri = 'kbs:///default/$SIGNATURE_SECRET_NAME/$SIGNATURE_SECRET_FILE'
'''

"policy.rego" = '''
package agent_policy

import future.keywords.in
import future.keywords.if

default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SetPolicyRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := true

# Enable logs, to see the output of curl
default ReadStreamRequest := true

# Restrict exec
default ExecProcessRequest := false

ExecProcessRequest if {
    input_command = concat(" ", input.process.Args)
    some allowed_command in policy_data.allowed_commands
    input_command == allowed_command
}

# Add allowed commands for exec
policy_data := {
  "allowed_commands": [
        "curl -s http://127.0.0.1:8006/cdh/resource/default/hellosecret/key1",
        "cat /sealed/secret-value/key2"
  ]
}

'''
EOF

####################################################################
echo "################################################"

INITDATA=$(cat initdata.toml | gzip | base64 -w0)
echo ""
echo $INITDATA

####################################################################
echo "################################################"

initial_pcr=0000000000000000000000000000000000000000000000000000000000000000
hash=$(sha256sum initdata.toml | cut -d' ' -f1)
PCR8_HASH=$(echo -n "$initial_pcr$hash" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo ""
echo "PCR 8:" $PCR8_HASH

####################################################################
echo "################################################"

# Prepare required files
sudo dnf install -y skopeo
curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
mv cosign-linux-amd64 cosign
chmod +x cosign

# Download the pull secret from openshift
oc get -n openshift-config secret/pull-secret -o json \
| jq -r '.data.".dockerconfigjson"' \
| base64 -d \
| jq '.' > cluster-pull-secret.json

# Pick the latest podvm image, as we freshly installed the cluster
OSC_VERSION=latest
# alternatively, use the operator-version tag:
# OSC_VERSION=1.11
VERITY_IMAGE=registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image

TAG=$(skopeo inspect --authfile ./cluster-pull-secret.json docker://${VERITY_IMAGE}:${OSC_VERSION} | jq -r .Digest)

IMAGE=${VERITY_IMAGE}@${TAG}

# Fetch the rekor public key
curl -L https://tuf-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com/targets/rekor.pub -o rekor.pub

# Fetch RH cosign public key
curl -L https://security.access.redhat.com/data/63405576.txt -o cosign-pub-key.pem

# Verify the image
export REGISTRY_AUTH_FILE=./cluster-pull-secret.json
export SIGSTORE_REKOR_PUBLIC_KEY=rekor.pub
./cosign verify --key cosign-pub-key.pem --output json  --rekor-url=https://rekor-server-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com $IMAGE > cosign_verify.log

sudo mkdir -p /podvm
sudo chown azure:azure /podvm

# Download the measurements
podman pull --root /podvm --authfile cluster-pull-secret.json $IMAGE

cid=$(podman create --root /podvm --entrypoint /bin/true $IMAGE)
echo "CID ${cid}"
podman unshare --root /podvm sh -c '
  mnt=$(podman mount --root /podvm '"$cid"')
  echo "MNT ${mnt}"
  cp $mnt/image/measurements.json /podvm
  podman umount --root /podvm '"$cid"'
'
podman rm --root /podvm $cid
JSON_DATA=$(cat /podvm/measurements.json)

# Prepare reference-values.json
REFERENCE_VALUES_JSON=$(echo "$JSON_DATA" | jq \
  --arg pcr8_val "$PCR8_HASH" '
  [
    {
      "name": "mr_seam",
      "expiration": "2027-12-12T00:00:00Z",
      "value": ["9790d89a10210ec6968a773cee2ca05b5aa97309f36727a968527be4606fc19e6f73acce350946c9d46a9bf7a63f8430"]
    },
    {
      "name": "tcb_svn",
      "expiration": "2027-12-12T00:00:00Z",
      "value": ["04010700000000000000000000000000"]
    },
    {
      "name": "mr_td",
      "expiration": "2027-12-12T00:00:00Z",
      "value": ["fe27b2aa3a05ec56864c308aff03dd13c189a6112d21e417ec1afe626a8cb9d91482d1379ec02fe6308972950a930d0a"]
    },
    {
      "name": "xfam",
      "expiration": "2027-12-12T00:00:00Z",
      "value": ["e718060000000000"]
    }
  ]
  +
  (
    (.measurements.sha256 | to_entries)
    +
    [{"key": "pcr08", "value": $pcr8_val}]
    | map(
      if .key == "pcr11" then
        [
          {
            "name": "snp_pcr11",
            "expiration": "2027-12-12T00:00:00Z",
            "value": [ (.value | ltrimstr("0x")) ],
            "sort_idx": 11
          },
          {
            "name": "tdx_pcr11",
            "expiration": "2027-12-12T00:00:00Z",
            "value": [ (.value | ltrimstr("0x")) ],
            "sort_idx": 11
          }
        ]
      elif .key == "pcr08" then
        [{
          "name": "pcr08",
          "expiration": "2028-12-12T00:00:00Z",
          "value": [ (.value | ltrimstr("0x")) ],
          "sort_idx": 8
        }]
      else
        [{
          "name": .key,
          "expiration": "2027-12-12T00:00:00Z",
          "value": [ (.value | ltrimstr("0x")) ],
          "sort_idx": (.key | ltrimstr("pcr") | tonumber)
        }]
      end
    )
    | flatten
    | sort_by(.sort_idx, .name)
    | map(del(.sort_idx))
  )
' | sed 's/^/    /')

# Build the final ConfigMap
cat > rvps-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: trusteeconfig-rvps-reference-values
  namespace: trustee-operator-system
data:
  reference-values.json: |
$REFERENCE_VALUES_JSON
EOF

cat rvps-configmap.yaml
oc apply -f rvps-configmap.yaml

####################################################################
echo "################################################"

####################################################################
echo "################################################"

echo "This is my super secret key!" > key.bin
# Alternatively:
# openssl rand 128 > key.bin
SECRET_NAME=hellosecret

oc create secret generic $SECRET_NAME \
  --from-literal key1=Confidential_Secret! \
  --from-file key2=key.bin \
  -n trustee-operator-system

curl -L https://people.redhat.com/eesposit/fd-workshop-key.bin -o fd.bin
FD_SECRET_NAME=fraud-detection

oc create secret generic $FD_SECRET_NAME \
  --from-file dataset_key=fd.bin \
  -n trustee-operator-system

rm -rf fd.bin key.bin

SECRET=$(podman run -it quay.io/confidential-devhub/coco-tools:0.3.0 /tools/secret seal vault --resource-uri kbs:///default/${SECRET_NAME}/key2 --provider kbs | grep -v "Warning")

oc create secret generic sealed-secret --from-literal=key2=$SECRET -n default

####################################################################
echo "################################################"

oc patch kbsconfig trusteeconfig-kbs-config \
  -n trustee-operator-system \
  --type=json \
  -p="[
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$HELLO_SECRET_NAME\"},
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$FD_SECRET_NAME\"},
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$SIGNATURE_SECRET_NAME\"},
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$POLICY_SECRET_NAME\"}
  ]"

cat kbsconfig-cr.yaml

oc get pods -n trustee-operator-system

####################################################################
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
  ROOT_VOLUME_SIZE: "10"
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

# TODO: Temporary fix
oc set image daemonset.apps/osc-caa-ds -n openshift-sandboxed-containers-operator caa-pod=quay.io/snir/cloud-api-adaptor:hddtossd-0.14.0

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

echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""

echo "################################################"
echo "Configuration complete. Enjoy testing CoCo!"
echo "################################################"