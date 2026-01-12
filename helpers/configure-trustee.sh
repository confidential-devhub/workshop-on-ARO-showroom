#! /bin/bash
set -e

TRUSTEE_ENV=${TRUSTEE_ENV:-"rhdp"}

# force lowercase
TRUSTEE_ENV=$(echo "$TRUSTEE_ENV" | tr '[:upper:]' '[:lower:]')

# validate
case "$TRUSTEE_ENV" in
  rhdp|gen)
    export TRUSTEE_ENV
    ;;
  *)
    echo "ERROR: TRUSTEE_ENV must be one of: rhdp, gen (got '$TRUSTEE_ENV')" >&2
    exit 1
    ;;
esac

echo "################################################"
echo "Starting the script..."
echo "If this scripts completes successfully, you will"
echo "see a final message confirming installation went"
echo "well."
echo "################################################"

echo ""

echo "################# Configuring Trustee ###############################"

mkdir -p trustee
cd trustee

oc completion bash > oc_bash_completion
sudo cp oc_bash_completion /etc/bash_completion.d/
source /etc/bash_completion.d/oc_bash_completion

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

sleep 5
oc wait deployment cert-manager-webhook -n cert-manager --for=condition=Available=True --timeout=300s
while [[ $(oc get endpoints cert-manager-webhook -n cert-manager -o jsonpath='{.subsets[*].addresses[*].ip}') == "" ]]; do
  echo "Waiting for cert-manager-webhook endpoints..."
  sleep 5
done
oc wait certificate kbs-https -n trustee-operator-system --for=condition=Ready --timeout=60s
oc wait certificate kbs-token -n trustee-operator-system --for=condition=Ready --timeout=60s
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

sleep 2
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

echo "################################################"

curl -L https://raw.githubusercontent.com/confidential-devhub/workshop-on-ARO-showroom/refs/heads/showroom/helpers/cosign.pub -o cosign.pub

SIGNATURE_SECRET_NAME=conf-devhub-signature
SIGNATURE_SECRET_FILE=pub-key

oc create secret generic $SIGNATURE_SECRET_NAME \
    --from-file=$SIGNATURE_SECRET_FILE=./cosign.pub \
    -n trustee-operator-system

SECURITY_POLICY_IMAGE=quay.io/confidential-devhub/signed

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

POLICY_SECRET_NAME=conf-devhub-image-policy
POLICY_SECRET_FILE=policy

oc create secret generic $POLICY_SECRET_NAME \
  --from-file=$POLICY_SECRET_FILE=./verification-policy.json \
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
image_security_policy_uri = 'kbs:///default/$POLICY_SECRET_NAME/$POLICY_SECRET_FILE'
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
default SetPolicyRequest := false
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
default WriteStreamRequest := false

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

PODDIR=podvm
PODROOT=""

if [[ $TRUSTEE_ENV == "rhdp" ]]; then
  PODDIR="/${PODDIR}"
  PODROOT="--root $PODDIR"
fi

sudo mkdir -p $PODDIR
if [[ $TRUSTEE_ENV == "rhdp" ]]; then
  sudo chown azure:azure $PODDIR
fi

# Download the measurements
podman pull $PODROOT --authfile cluster-pull-secret.json $IMAGE

cid=$(podman create $PODROOT --entrypoint /bin/true $IMAGE)
echo "CID: ${cid}"
podman cp $PODROOT $cid:/image/measurements.json $PODDIR
podman rm $PODROOT $cid
JSON_DATA=$(cat $PODDIR/measurements.json)

# Prepare reference-values.json
REFERENCE_VALUES_JSON=$(echo "$JSON_DATA" | jq \
  --arg pcr8_val "$PCR8_HASH" '
  (
    (.measurements.sha256 | to_entries)
    +
    [{"key": "pcr08", "value": $pcr8_val}]
  )
  | map(
      # Clean the hex value
      ([ (.value | ltrimstr("0x")) ]) as $val |

      # Extract number for sorting
      (.key | ltrimstr("pcr") | tonumber) as $idx |

      # Generate both SNP and TDX entries with fixed expiration
      [
        {
          "name": ("snp_" + .key),
          "expiration": "2027-12-12T00:00:00Z",
          "value": $val,
          "sort_idx": $idx
        },
        {
          "name": ("tdx_" + .key),
          "expiration": "2027-12-12T00:00:00Z",
          "value": $val,
          "sort_idx": $idx
        }
      ]
  )
  | flatten
  | sort_by(.sort_idx, .name)
  | map(del(.sort_idx))
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

oc patch kbsconfig trusteeconfig-kbs-config \
  -n trustee-operator-system \
  --type=json \
  -p="[
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$SIGNATURE_SECRET_NAME\"},
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$POLICY_SECRET_NAME\"}
  ]"

echo "Updated Kbsconfig - kbsSecretResources:"
oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system -o json \
  | jq '.spec.kbsSecretResources'

oc rollout restart deployment/trustee-deployment -n trustee-operator-system

echo ""
echo "################################################"
echo "Trustee configured successfully!"
echo "################################################"