# Define the ConfigMap name
CM_NAME="trusteeconfig-attestation-policy-cpu"
FILE_NAME="attestation-policy.yaml"

echo "Step 1: Exporting ConfigMap..."
# Export the current configmap to a file
oc get configmap "$CM_NAME" -n trustee-operator-system -o yaml > "$FILE_NAME"

echo "Step 2: Adjusting the attestation policy..."
# 1. Rename input.az_snp_vtpm and use bracket notation
sed -i -E 's/input\.az_snp_vtpm/input["az-snp-vtpm"]/g' "$FILE_NAME"
# 2. Rename input.az_tdx_vtpm and use bracket notation
sed -i -E 's/input\.az_tdx_vtpm/input["az-tdx-vtpm"]/g' "$FILE_NAME"
# 3. Comment out az-snp-vtpm measurement
sed -i -E 's/^([[:space:]]+)(input\["az-snp-vtpm"\]\.measurement.*)$/\1# \2/' "$FILE_NAME"
# 4. Comment out az-snp-vtpm reported_tcb lines
sed -i -E 's/^([[:space:]]+)(input\["az-snp-vtpm"\]\.reported_tcb_.*)$/\1# \2/' "$FILE_NAME"
# 5. Comment out az-snp-vtpm configuration/policy lines
sed -i -E 's/^([[:space:]]+)(input\["az-snp-vtpm"\]\.(platform|policy)_.*)$/\1# \2/' "$FILE_NAME"
# 6. Comment out az-tdx-vtpm specific quote body lines (mr_td and xfam)
sed -i -E 's/^([[:space:]]+)(input\["az-tdx-vtpm"\]\.quote\.body\.(mr_td|xfam).*)$/\1# \2/' "$FILE_NAME"

echo "Step 3: Re-applying the ConfigMap..."
# Apply the modified file back to OpenShift
oc apply -f "$FILE_NAME"

oc rollout restart deployment/trustee-deployment -n trustee-operator-system

echo "Success: $CM_NAME has been updated."