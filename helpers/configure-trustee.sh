#! /bin/bash
set -e

TRUSTEE_ENV=${TRUSTEE_ENV:-"gen"}

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

if ! command -v skopeo >/dev/null 2>&1; then
  echo "Please install skopeo first"
  echo "On you can install it via: sudo dnf install -y skopeo"
  exit 1
fi

INITDATA_PATH=${INITDATA_PATH:-"$HOME/trustee/initdata.toml"}
# Expand ~ to $HOME (handles ~/path)
INITDATA_PATH="${INITDATA_PATH/#\~/$HOME}"
# Resolve to absolute path
if [[ "$INITDATA_PATH" != /* ]]; then
  INITDATA_PATH="$(cd "$(dirname "$INITDATA_PATH")" && pwd)/$(basename "$INITDATA_PATH")"
fi

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

# oc completion bash > oc_bash_completion
# sudo cp oc_bash_completion /etc/bash_completion.d/
# source /etc/bash_completion.d/oc_bash_completion

DOMAIN=$(oc get ingress.config/cluster -o jsonpath='{.spec.domain}')
NS=trustee-operator-system
ROUTE_NAME=kbs-route
ROUTE="${ROUTE_NAME}-${NS}.${DOMAIN}"

CN_NAME=kbs-trustee-operator-system
ORG_NAME=RedHat

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
    encoding: PKCS8
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
    - ${ROUTE}
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

TRUSTEE_CERT=$(oc get secret trustee-tls-cert -n trustee-operator-system -o json | jq -r '.data."tls.crt"' | base64 --decode)

TRUSTEE_HOST="https://$(oc get route -n trustee-operator-system kbs-route \
  -o jsonpath={.spec.host})"

echo $TRUSTEE_HOST

echo "################################################"

curl -L https://raw.githubusercontent.com/confidential-devhub/workshop-on-ARO-showroom/refs/heads/showroom/helpers/cosign.pub -o cosign.pub

SIGNATURE_SECRET_NAME=conf-devhub-signature
SIGNATURE_SECRET_FILE=pub-key

oc create secret generic $SIGNATURE_SECRET_NAME \
    --from-file=$SIGNATURE_SECRET_FILE=./cosign.pub \
    -n trustee-operator-system

curl -L https://security.access.redhat.com/data/63405576.txt -o redhat-cosign-pub-key.pem

RH_SIGNATURE_SECRET_NAME=redhat-signature
RH_SIGNATURE_SECRET_FILE=pub-key

oc create secret generic $RH_SIGNATURE_SECRET_NAME \
    --from-file=$RH_SIGNATURE_SECRET_FILE=./redhat-cosign-pub-key.pem \
    -n trustee-operator-system

SECURITY_POLICY_IMAGE=quay.io/confidential-devhub/signed
RH_SECURITY_POLICY_IMAGE=registry.access.redhat.com
RH_SECURITY_POLICY_IMAGE2=registry.redhat.io

cat > verification-policy.json <<EOF
{
  "default": [
      {
      "type": "reject"
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
          ],
          "$RH_SECURITY_POLICY_IMAGE":
          [
              {
                  "type": "sigstoreSigned",
                  "keyPath": "kbs:///default/$RH_SIGNATURE_SECRET_NAME/$RH_SIGNATURE_SECRET_FILE"
              }
          ],
          "$RH_SECURITY_POLICY_IMAGE2":
          [
              {
                  "type": "sigstoreSigned",
                  "keyPath": "kbs:///default/$RH_SIGNATURE_SECRET_NAME/$RH_SIGNATURE_SECRET_FILE"
              }
          ]
      }
  }
}
EOF

POLICY_SECRET_NAME=trustee-image-policy
POLICY_SECRET_FILE=policy

oc create secret generic $POLICY_SECRET_NAME \
  --from-file=$POLICY_SECRET_FILE=./verification-policy.json \
  -n trustee-operator-system

####################################################################
echo "################################################"

cat > $INITDATA_PATH <<EOF
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

# Disable exec
default ExecProcessRequest := false

'''
EOF

####################################################################
echo "################################################"

initial_pcr=0000000000000000000000000000000000000000000000000000000000000000
hash=$(sha256sum $INITDATA_PATH | cut -d' ' -f1)
PCR8_HASH=$(echo -n "$initial_pcr$hash" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo ""
echo "PCR 8:" $PCR8_HASH

####################################################################
echo "################################################"

# Download the pull secret from openshift
oc get -n openshift-config secret/pull-secret -o json \
| jq -r '.data.".dockerconfigjson"' \
| base64 -d \
| jq '.' > cluster-pull-secret.json

PODDIR=podvm
PROOTF=""

if [[ $TRUSTEE_ENV == "rhdp" ]]; then
  PODDIR="/${PODDIR}"
  PROOTF="--root $PODDIR"
  sudo mkdir -p $PODDIR
  sudo chown azure:azure $PODDIR
else
  mkdir -p $PODDIR
fi

podman run \
  $PROOTF  \
  --security-opt label=disable \
  -v $PODDIR:/workdir:Z \
  -w /workdir \
  -v ./cluster-pull-secret.json:/pull-secret.json:Z \
  -v $INITDATA_PATH:/initdata.toml:Z \
  -e REGISTRY_AUTH_FILE=/pull-secret.json \
  quay.io/openshift_sandboxed_containers/coco-tools:0.5.1 \
    veritas \
    --platform azure \
    --tee snp \
    --authfile /pull-secret.json \
    --initdata /initdata.toml \
    --rekor-url rekor-server-sigstore-rekor-prod.apps.rosa.appsrep11ue1.tgem.p3.openshiftapps.com \
    --rekor-pub-key-url https://rekor-server-sigstore-rekor-prod.apps.rosa.appsrep11ue1.tgem.p3.openshiftapps.com/api/v1/log/publicKey

cat $PODDIR/rvps-reference-values.yaml
oc apply -f $PODDIR/rvps-reference-values.yaml

oc patch kbsconfig trusteeconfig-kbs-config \
  -n trustee-operator-system \
  --type=json \
  -p="[
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$SIGNATURE_SECRET_NAME\"},
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$RH_SIGNATURE_SECRET_NAME\"},
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$POLICY_SECRET_NAME\"}
  ]"

echo "Updated Kbsconfig - kbsSecretResources:"
oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system -o json \
  | jq '.spec.kbsSecretResources'

oc rollout restart deployment/trustee-deployment -n trustee-operator-system

# if [[ $TRUSTEE_ENV == "rhdp" ]]; then
# fi

echo ""
echo "################################################"
echo "Trustee configured successfully!"
echo "################################################"