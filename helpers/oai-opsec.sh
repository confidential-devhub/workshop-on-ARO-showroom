#! /bin/bash
set -e

INITDATA_PATH=${INITDATA_PATH:-"$HOME/trustee/initdata-oai.toml"}
# Expand ~ to $HOME (handles ~/path)
INITDATA_PATH="${INITDATA_PATH/#\~/$HOME}"
# Resolve to absolute path
if [[ "$INITDATA_PATH" != /* ]]; then
  INITDATA_PATH="$(cd "$(dirname "$INITDATA_PATH")" && pwd)/$(basename "$INITDATA_PATH")"
fi


# IMAGE=registry.redhat.io/rhoai/odh-workbench-jupyter-minimal-cpu-py312-rhel9@sha256:a8cfef07ffc89d99acfde08ee879cc87aaa08e9a369e0cf7b36544b61b3ee3c7

# oc get -n openshift-config secret/pull-secret -o json \
# | jq -r '.data.".dockerconfigjson"' \
# | base64 -d \
# | jq '.' > cluster-pull-secret.json

# export REGISTRY_AUTH_FILE=./cluster-pull-secret.json
# ./cosign download signature $IMAGE \
# | jq -r 'select(.Bundle != null) | .Bundle.Payload.body' \
# | base64 -d \
# | jq -r '.spec.signature.publicKey.content' \
# | sort -u \
# | head -n1 \
# | base64 -d > redhat.pub

# RH_SIGNATURE_SECRET_NAME=registry-redhat-io-signature
# RH_SIGNATURE_SECRET_FILE=pub-key

# oc create secret generic $RH_SIGNATURE_SECRET_NAME \
#     --from-file=$RH_SIGNATURE_SECRET_FILE=./redhat.pub \
#     -n trustee-operator-system

# oc get secret trustee-image-policy -n trustee-operator-system -o jsonpath='{.data.policy}' | base64 -d | \
# jq '.transports.docker += {"registry.redhat.io": [{"type": "sigstoreSigned", "keyPath": "kbs:///default/$RH_SIGNATURE_SECRET_NAME/$RH_SIGNATURE_SECRET_FILE"}]}' | \
# oc create secret generic trustee-image-policy \
#   --from-file=policy=/dev/stdin \
#   -n trustee-operator-system \
#   --dry-run=client -o yaml | oc replace -f -

# oc patch kbsconfig trusteeconfig-kbs-config \
#   -n trustee-operator-system \
#   --type=json \
#   -p="[
#     {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$RH_SIGNATURE_SECRET_NAME\"},
#   ]"

# echo "Updated Kbsconfig - kbsSecretResources:"
# oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system -o json \
#   | jq '.spec.kbsSecretResources'

# oc rollout restart deployment/trustee-deployment -n trustee-operator-system


cat > oai-verification-policy.json <<EOF
{
  "default": [
      {
      "type": "insecureAcceptAnything"
      }
  ],
  "transports": {
  }
}
EOF

OAI_POLICY_SECRET_NAME=oai-image-policy
OAI_POLICY_SECRET_FILE=policy

oc create secret generic $OAI_POLICY_SECRET_NAME \
  --from-file=$OAI_POLICY_SECRET_FILE=./oai-verification-policy.json \
  -n trustee-operator-system

oc patch kbsconfig trusteeconfig-kbs-config \
  -n trustee-operator-system \
  --type=json \
  -p="[
    {\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$OAI_POLICY_SECRET_NAME\"},
  ]"

echo "Updated Kbsconfig - kbsSecretResources:"
oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system -o json \
  | jq '.spec.kbsSecretResources'

orig_init=$(oc get configmaps/peer-pods-cm -n openshift-sandboxed-containers-operator -o json | jq -r '.data.INITDATA' | base64 -d | gunzip)

new_init="$(printf '%s\n' "$orig_init" \
  | sed "s|^image_security_policy_uri *=.*|image_security_policy_uri = 'kbs:///default/$OAI_POLICY_SECRET_NAME/$OAI_POLICY_SECRET_FILE'|")"

echo "$new_init" > $INITDATA_PATH
echo ""
cat $INITDATA_PATH
echo ""
# NEW_INIT=$(cat $INITDATA_PATH | gzip | base64 -w0)

initial_pcr=0000000000000000000000000000000000000000000000000000000000000000
hash=$(sha256sum $INITDATA_PATH | cut -d' ' -f1)
PCR8_HASH_OAI=$(echo -n "$initial_pcr$hash" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo ""
echo "PCR 8 OAI:" $PCR8_HASH_OAI

# rm $INITDATA_PATH


oc get configmap trusteeconfig-rvps-reference-values \
  -n trustee-operator-system \
  -o jsonpath='{.data.reference-values\.json}' \
| jq --arg p1 "$PCR8_HASH_OAI" '
  map(
    if .name == "snp_pcr08" or .name == "tdx_pcr08"
    then .value += [$p1]
    else .
    end
  )
' \
| jq --indent 2 . \
| oc create configmap trusteeconfig-rvps-reference-values \
    -n trustee-operator-system \
    --from-file=reference-values.json=/dev/stdin \
    --dry-run=client -o yaml \
| oc apply -f -

echo ""

oc get configmap trusteeconfig-rvps-reference-values \
  -n trustee-operator-system \
  -o jsonpath='{.data.reference-values\.json}'

oc rollout restart deployment/trustee-deployment -n trustee-operator-system

