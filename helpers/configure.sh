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

# Admin authentication keys
openssl genpkey -algorithm ed25519 > privateKey
openssl pkey -in privateKey -pubout -out publicKey

# HTTPS keys
DOMAIN=$(oc get ingress.config/cluster -o jsonpath='{.spec.domain}')
NS=trustee-operator-system
ROUTE_NAME=kbs-service

CN_NAME=kbs-trustee-operator-system
ORG_NAME=my_org

ROUTE="${ROUTE_NAME}-${NS}.${DOMAIN}"
echo "ROUTE: $ROUTE"
echo ""

openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=${CN_NAME}/O=${ORG_NAME}$" \
  -addext "subjectAltName=DNS:${ROUTE}"

# Attestation token
openssl ecparam -name prime256v1 -genkey -noout -out token.key
openssl req -new -x509 -key token.key -out token.crt -days 365 \
	-subj "/CN=${CN_NAME}/O=${ORG_NAME}"

####################################################################
echo "################################################"

oc create secret generic kbs-https-certificate --from-file=tls.crt -n trustee-operator-system

oc create secret generic kbs-https-key --from-file=tls.key -n trustee-operator-system

TRUSTEE_CERT=$(cat tls.crt)

echo "$TRUSTEE_CERT"
echo ""
echo "ROUTE: $ROUTE"
echo ""
oc get secrets -n trustee-operator-system | grep kbs-https

####################################################################
echo "################################################"

HTTP="https://"
oc create route passthrough kbs-service \
  --service=kbs-service \
  --port=kbs-port \
  -n trustee-operator-system

TRUSTEE_ROUTE="$(oc get route -n trustee-operator-system kbs-service \
  -o jsonpath={.spec.host})"

TRUSTEE_HOST=${HTTP}${TRUSTEE_ROUTE}

echo $TRUSTEE_HOST

####################################################################
echo "################################################"

oc create secret generic kbs-auth-public-key --from-file=./publicKey -n trustee-operator-system

####################################################################
echo "################################################"

oc create secret generic attestation-token --from-file=token.crt --from-file=token.key -n trustee-operator-system

####################################################################
echo "################################################"

cat > kbs-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kbs-config-cm
  namespace: trustee-operator-system
data:
  kbs-config.toml: |
    [http_server]
    sockets = ["0.0.0.0:8080"]
    insecure_http = false
    private_key = "/etc/https-key/tls.key"
    certificate = "/etc/https-cert/tls.crt"

    [admin]
    insecure_api = false
    auth_public_key = "/etc/auth-secret/publicKey"

    [attestation_token]
    insecure_key = false
    trusted_certs_paths = ["/opt/confidential-containers/kbs/repository/default/attestation-token/token.crt"]
    attestation_token_type = "CoCo"

    [attestation_service.attestation_token_broker.signer]
    key_path = "/opt/confidential-containers/kbs/repository/default/attestation-token/token.key"
    cert_path = "/opt/confidential-containers/kbs/repository/default/attestation-token/token.crt"

    [attestation_service]
    type = "coco_as_builtin"
    work_dir = "/opt/confidential-containers/attestation-service"
    policy_engine = "opa"

    [attestation_service.attestation_token_broker]
    type = "Ear"
    policy_dir = "/opt/confidential-containers/attestation-service/policies"

    [attestation_service.attestation_token_config]
    duration_min = 5

    [attestation_service.rvps_config]
    type = "BuiltIn"

    [attestation_service.rvps_config.storage]
    type = "LocalJson"
    file_path = "/opt/confidential-containers/rvps/reference-values/reference-values.json"

    [[plugins]]
    name = "resource"
    type = "LocalFs"
    dir_path = "/opt/confidential-containers/kbs/repository"

    [policy_engine]
    policy_path = "/opt/confidential-containers/opa/policy.rego"
EOF

cat kbs-configmap.yaml
oc apply -f kbs-configmap.yaml

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
        "curl -s http://127.0.0.1:8006/cdh/resource/default/kbsres1/key1",
        "cat /sealed/secret-value/key2"
  ]
}

'''
EOF

cat initdata.toml

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

# 1. Prepare required files

# Pick the latest podvm image, as we freshly installed the cluster
IMAGE="registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image:latest"
# alternatively, use the operator-version tag:
# OSC_VERSION=1.10.3
# IMAGE="registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image:${OSC_VERSION}"

# Download the pull secret from openshig
oc get -n openshift-config secret/pull-secret -o json \
| jq -r '.data.".dockerconfigjson"' \
| base64 -d \
| jq '.' > cluster-pull-secret.json
# alternatively if you don't have access to the pull-secret:
# podman login registry.redhat.io
# Username: {REGISTRY-SERVICE-ACCOUNT-USERNAME}
# Password: {REGISTRY-SERVICE-ACCOUNT-PASSWORD}

# On the ARO workshop, we don't have enough space for podman.
# Use a different folder.
sudo mkdir -p /podvm
sudo chown azure:azure /podvm

# 2. Download the measurements
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

# 3. Prepare reference-values.json
REFERENCE_VALUES_JSON=$(echo "$JSON_DATA" | jq \
  --arg pcr8_val "$PCR8_HASH" '
  .measurements.sha256 | to_entries | map({
    "name": .key,
    "expiration": "2026-12-12T00:00:00Z",
    "hash-value": [
      {
        "alg": "sha256",
        "value": (.value | ltrimstr("0x"))
      }
    ]
  })
  +
  [
    {
      "name": "pcr08",
      "expiration": "2026-12-12T00:00:00Z",
      "hash-value": [
        {
          "alg": "sha256",
          "value": $pcr8_val
        }
      ]
    }
  ]
  | sort_by(.name | ltrimstr("pcr") | tonumber)
' | sed 's/^/    /')

# 4. Build the final ConfigMap
cat > rvps-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rvps-reference-values
  namespace: trustee-operator-system
data:
  reference-values.json: |
$REFERENCE_VALUES_JSON
EOF

cat rvps-configmap.yaml
oc apply -f rvps-configmap.yaml

####################################################################
echo "################################################"

cat > attestation-policy.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: attestation-policy
  namespace: trustee-operator-system
data:
  default.rego: |
    package policy

    import rego.v1
    default executables := 33
    default hardware := 97
    default configuration := 36

    ##### Azure vTPM SNP
    executables := 3 if {
      input.azsnpvtpm.tpm.pcr03 in data.reference.pcr03
      input.azsnpvtpm.tpm.pcr08 in data.reference.pcr08
      input.azsnpvtpm.tpm.pcr09 in data.reference.pcr09
      input.azsnpvtpm.tpm.pcr11 in data.reference.pcr11
      input.azsnpvtpm.tpm.pcr12 in data.reference.pcr12
    }

    hardware := 0 if {
      input.azsnpvtpm
    }

    configuration := 0 if {
      input.azsnpvtpm
    }

    ##### Azure vTPM TDX
    executables := 3 if {
      input.aztdxvtpm.tpm.pcr03 in data.reference.pcr03
      input.aztdxvtpm.tpm.pcr08 in data.reference.pcr08
      input.aztdxvtpm.tpm.pcr09 in data.reference.pcr09
      input.aztdxvtpm.tpm.pcr11 in data.reference.pcr11
      input.aztdxvtpm.tpm.pcr12 in data.reference.pcr12
    }

    hardware := 0 if {
      input.aztdxvtpm
    }

    configuration := 0 if {
      input.aztdxvtpm
    }
EOF

cat attestation-policy.yaml
oc apply -f attestation-policy.yaml

####################################################################
echo "################################################"

cat > tdx-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tdx-config
  namespace: trustee-operator-system
data:
  sgx_default_qcnl.conf: |
    {
      "collateral_service": "https://api.trustedservices.intel.com/sgx/certification/v4/"
    }
EOF

cat tdx-config.yaml
oc apply -f tdx-config.yaml

####################################################################
echo "################################################"

# Download the key
curl -L https://raw.githubusercontent.com/confidential-devhub/workshop-on-ARO-showroom/refs/heads/showroom/helpers/cosign.pub -o cosign.pub

SIGNATURE_SECRET_NAME=cosign-key
SIGNATURE_SECRET_FILE=hello-pub-key

oc create secret generic $SIGNATURE_SECRET_NAME \
    --from-file=$SIGNATURE_SECRET_FILE=./cosign.pub \
    -n trustee-operator-system

SECURITY_POLICY_TRANSPORT=docker
SECURITY_POLICY_IMAGE=quay.io/confidential-devhub/signed-hello-openshift

cat > security-policy-config.json <<EOF
{
  "default": [
      {
      "type": "insecureAcceptAnything"
      }
  ],
  "transports": {}
}
EOF

cat security-policy-config.json
oc create secret generic security-policy \
  --from-file=osc=./security-policy-config.json \
  -n trustee-operator-system

####################################################################
echo "################################################"

cat > resourcepolicy-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-policy
  namespace: trustee-operator-system
data:
  policy.rego: |
    package policy
    import rego.v1

    default allow = false
    allow if {
      input["submods"]["cpu"]["ear.status"] == "affirming"
    }
EOF

cat resourcepolicy-configmap.yaml
oc apply -f resourcepolicy-configmap.yaml

####################################################################
echo "################################################"

echo "This is my super secret key!" > key.bin
# Alternatively:
# openssl rand 128 > key.bin
SECRET_NAME=kbsres1

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

cat > kbsconfig-cr.yaml <<EOF
apiVersion: confidentialcontainers.org/v1alpha1
kind: KbsConfig
metadata:
  labels:
    app.kubernetes.io/name: kbsconfig
    app.kubernetes.io/instance: kbsconfig
    app.kubernetes.io/part-of: trustee-operator
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/created-by: trustee-operator
  name: kbsconfig
  namespace: trustee-operator-system
spec:
  kbsConfigMapName: kbs-config-cm
  kbsAuthSecretName: kbs-auth-public-key
  kbsDeploymentType: AllInOneDeployment
  kbsRvpsRefValuesConfigMapName: rvps-reference-values
  kbsSecretResources: ["$SECRET_NAME", "$FD_SECRET_NAME", "security-policy", "attestation-token", "$SIGNATURE_SECRET_NAME"]
  kbsResourcePolicyConfigMapName: resource-policy
  kbsAttestationPolicyConfigMapName: attestation-policy
  kbsHttpsKeySecretName: kbs-https-key
  kbsHttpsCertSecretName: kbs-https-certificate
  tdxConfigSpec:
    kbsTdxConfigMapName: tdx-config
EOF

cat kbsconfig-cr.yaml
oc apply -f kbsconfig-cr.yaml

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