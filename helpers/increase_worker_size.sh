#! /bin/bash
set -e

echo "################################################"
echo "This script will increase Kata worker node size to ensure OAI is installed properly"
echo "################################################"

ARO_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
AZ_CID=$(oc get secrets/azure-credentials -n kube-system -o json | jq -r .data.azure_client_id | base64 -d)

AZ_CS=$(oc get secrets/azure-credentials -n kube-system -o json | jq -r .data.azure_client_secret | base64 -d)

AZ_TID=$(oc get secrets/azure-credentials -n kube-system -o json | jq -r .data.azure_tenant_id | base64 -d)

echo azure_client_id $AZ_CID
echo azure_client_secret $AZ_CS
echo azure_tenant_id $AZ_TID

az login --service-principal -u $AZ_CID -p $AZ_CS --tenant $AZ_TID

W1=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
TARGET_SIZE="Standard_D16s_v5"
MIN_TOTAL_CPU=24

echo "Calculating total CPUs across all workers..."

# 1. Get list of all worker VM sizes
# This returns a list like: Standard_D4s_v3 Standard_D8s_v3
WORKER_SIZES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}')

TOTAL_CPU=0

# 2. Loop through sizes and parse the number
for SIZE in $WORKER_SIZES; do
    # Regex to extract the number immediately following 'D', 'E', 'F', etc.
    # Standard_D4s_v3 -> 4
    # Standard_D16s_v5 -> 16
    # This works for most standard Azure naming conventions (D, E, F, L series)
    CORES=$(echo $SIZE | grep -oP '(?<=_D|E|F|L)[0-9]+' | head -n1)

    # Fallback/Safety: If regex fails (e.g., unexpected naming), treat as 0 or handle error
    if [[ -z "$CORES" ]]; then
        echo "Could not parse cores from $SIZE. Skipping."
        CORES=0
    fi

    TOTAL_CPU=$((TOTAL_CPU + CORES))
done

echo "Total Worker CPUs: $TOTAL_CPU (Threshold: $MIN_TOTAL_CPU)"

# 3. Check Condition and Upgrade
if [ "$TOTAL_CPU" -eq "0" ]; then
    echo "Total CPU calculation failed. Exiting."
    exit 1
fi

if [ "$TOTAL_CPU" -lt "$MIN_TOTAL_CPU" ]; then
    echo "Total CPU ($TOTAL_CPU) is less than $MIN_TOTAL_CPU. Upgrading $W1..."

    # Deallocate
    az vm deallocate --resource-group $ARO_RESOURCE_GROUP --name $W1

    # Resize
    az vm resize \
      --resource-group $ARO_RESOURCE_GROUP \
      --name $W1 \
      --size $TARGET_SIZE

    # Start the VM again
    az vm start --resource-group $ARO_RESOURCE_GROUP --name $W1

    echo "Upgrade complete. $W1 is now $TARGET_SIZE."
else
    echo "Total CPU ($TOTAL_CPU) is sufficient (>= $MIN_TOTAL_CPU). No action required."
fi
echo "###############################################################"
echo "Increase worker size script completed."
echo "###############################################################"