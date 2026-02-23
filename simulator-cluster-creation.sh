#!/bin/bash
set -e

# --- Region selection ---
REGIONS=(
  "swedencentral:Sweden Central"
  "uksouth:UK South"
  "westeurope:West Europe"
  "northeurope:North Europe"
  "francecentral:France Central"
  "germanywestcentral:Germany West Central"
  "canadacentral:Canada Central"
  "eastus:East US"
  "westus2:West US 2"
  "australiaeast:Australia East"
)

echo "Select a region for the cluster:"
echo ""
for i in "${!REGIONS[@]}"; do
  IFS=':' read -r code name <<< "${REGIONS[$i]}"
  printf "  %2d) %s (%s)\n" $((i+1)) "$name" "$code"
done
echo ""
read -p "Enter selection [1-${#REGIONS[@]}]: " REGION_CHOICE

if [[ ! "$REGION_CHOICE" =~ ^[0-9]+$ ]] || (( REGION_CHOICE < 1 || REGION_CHOICE > ${#REGIONS[@]} )); then
  echo "Invalid selection."
  exit 1
fi

IFS=':' read -r LOCATION LOCATION_DISPLAY <<< "${REGIONS[$((REGION_CHOICE-1))]}"

RESOURCE_GROUP_NAME="eac-shared-${LOCATION}"
CLUSTER_NAME="eac-${LOCATION}-aks"

echo ""
echo "Configuration:"
echo "  Region:         ${LOCATION_DISPLAY} (${LOCATION})"
echo "  Resource group: ${RESOURCE_GROUP_NAME}"
echo "  Cluster name:   ${CLUSTER_NAME}"

# --- Detect existing VNet or generate new CIDRs ---
# Uses the 2 high bits of the second octet to separate usage types:
#
#   Slot 00 (0-63):    VNet    /20 (4096 nodes, 64 random bases)
#   Slot 01 (64-127):  Pod     /14 (262k pods, 16 random bases)
#   Slot 10 (128-191): Service /16 (65k services, 64 random bases)
#   Slot 11 (192-255): reserved
#
EXISTING_VNET_CIDR=$(az network vnet show --resource-group "$RESOURCE_GROUP_NAME" --name "${CLUSTER_NAME}-vnet" --query "addressSpace.addressPrefixes[0]" -o tsv 2>/dev/null || echo "")

if [ -n "$EXISTING_VNET_CIDR" ]; then
  echo "  Existing VNet detected: ${EXISTING_VNET_CIDR} — reusing"
  VNET_CIDR="$EXISTING_VNET_CIDR"
else
  VNET_OCTET=$(( RANDOM % 64 ))
  VNET_CIDR="10.${VNET_OCTET}.0.0/20"
fi

POD_OCTET=$(( 64 + (RANDOM % 16) * 4 ))
SERVICE_OCTET=$(( 128 + (RANDOM % 64) ))
POD_CIDR="10.${POD_OCTET}.0.0/14"
SERVICE_CIDR="10.${SERVICE_OCTET}.0.0/16"
DNS_SERVICE_IP="10.${SERVICE_OCTET}.0.10"

echo "  VNet CIDR:      ${VNET_CIDR}"
echo "  Pod CIDR:       ${POD_CIDR}"
echo "  Service CIDR:   ${SERVICE_CIDR}"
echo "  DNS Service IP: ${DNS_SERVICE_IP}"
echo ""
read -p "Proceed with cluster creation? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# --- Node pool configuration ---
SYSTEM_NODE_POOL_NAME="system4core"
SYSTEM_NODE_VM_SIZE="Standard_D4ds_v5"
SYSTEM_MIN_COUNT=1
SYSTEM_MAX_COUNT=5
SYSTEM_MAX_PODS=110
USER_NODE_POOL_1_NAME="amdepic8core"
USER_NODE_POOL_1_SIZE="Standard_D8ads_v5"
USER_NODE_POOL_1_MIN_COUNT=0
USER_NODE_POOL_1_MAX_COUNT=192
USER_NODE_POOL_1_MAX_PODS=225
USER_NODE_POOL_2_NAME="simulators"
USER_NODE_POOL_2_SIZE="Standard_D8ads_v5"
USER_NODE_POOL_2_MIN_COUNT=0
USER_NODE_POOL_2_MAX_COUNT=192
USER_NODE_POOL_2_MAX_PODS=225
AUTHORIZED_IP_RANGES="80.14.117.185/32,109.190.120.175/32,12.11.149.5/32,165.225.8.194/32,194.9.100.179/32,20.224.243.121/32"
CONTAINER_REGISTRY="ptceaccr"

echo ""
echo "=== Creating resource group ==="
az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"

echo ""
if [ -n "$EXISTING_VNET_CIDR" ]; then
  echo "=== Reusing existing VNet and subnet ==="
else
  echo "=== Creating VNet and subnet ==="
  az network vnet create --resource-group "$RESOURCE_GROUP_NAME" --name "${CLUSTER_NAME}-vnet" --address-prefix "$VNET_CIDR" --subnet-name "${CLUSTER_NAME}-subnet" --subnet-prefix "$VNET_CIDR"
fi

VNET_SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP_NAME" --vnet-name "${CLUSTER_NAME}-vnet" --name "${CLUSTER_NAME}-subnet" --query "id" --output tsv)

echo ""
EGRESS_IP_NAME="${CLUSTER_NAME}-egress-ip"
EXISTING_IP=$(az network public-ip show --resource-group "$RESOURCE_GROUP_NAME" --name "$EGRESS_IP_NAME" --query "ipAddress" -o tsv 2>/dev/null || echo "")

if [ -n "$EXISTING_IP" ]; then
  echo "=== Reusing existing static public IP for cluster egress ==="
  echo "  Egress IP: ${EXISTING_IP} (${EGRESS_IP_NAME})"
else
  echo "=== Creating static public IP for cluster egress ==="
  az network public-ip create --resource-group "$RESOURCE_GROUP_NAME" --name "$EGRESS_IP_NAME" --location "$LOCATION" --allocation-method Static --sku Standard --zone 1 2 3
fi

EGRESS_IP_ID=$(az network public-ip show --resource-group "$RESOURCE_GROUP_NAME" --name "$EGRESS_IP_NAME" --query "id" -o tsv)
EGRESS_IP_ADDRESS=$(az network public-ip show --resource-group "$RESOURCE_GROUP_NAME" --name "$EGRESS_IP_NAME" --query "ipAddress" -o tsv)

echo "  Egress IP: ${EGRESS_IP_ADDRESS} (${EGRESS_IP_NAME})"

echo ""
echo "=== Creating AKS cluster ==="
az aks create --resource-group "$RESOURCE_GROUP_NAME" --name "$CLUSTER_NAME" --location "$LOCATION" --nodepool-name "$SYSTEM_NODE_POOL_NAME" --node-vm-size "$SYSTEM_NODE_VM_SIZE" --enable-cluster-autoscaler --min-count "$SYSTEM_MIN_COUNT" --max-count "$SYSTEM_MAX_COUNT" --network-plugin azure --network-plugin-mode overlay --network-policy none --pod-cidr "$POD_CIDR" --service-cidr "$SERVICE_CIDR" --dns-service-ip "$DNS_SERVICE_IP" --max-pods "$SYSTEM_MAX_PODS" --vnet-subnet-id "$VNET_SUBNET_ID" --load-balancer-outbound-ips "$EGRESS_IP_ID" --enable-managed-identity --api-server-authorized-ip-ranges "$AUTHORIZED_IP_RANGES" --attach-acr "$CONTAINER_REGISTRY" --generate-ssh-keys

echo ""
echo "=== Adding node pool: ${USER_NODE_POOL_1_NAME} ==="
az aks nodepool add --resource-group "$RESOURCE_GROUP_NAME" --cluster-name "$CLUSTER_NAME" --name "$USER_NODE_POOL_1_NAME" --node-vm-size "$USER_NODE_POOL_1_SIZE" --node-osdisk-type Ephemeral --enable-cluster-autoscaler --min-count "$USER_NODE_POOL_1_MIN_COUNT" --max-count "$USER_NODE_POOL_1_MAX_COUNT" --vnet-subnet-id "$VNET_SUBNET_ID" --max-pods "$USER_NODE_POOL_1_MAX_PODS"

echo ""
echo "=== Adding node pool: ${USER_NODE_POOL_2_NAME} (spot) ==="
az aks nodepool add --resource-group "$RESOURCE_GROUP_NAME" --cluster-name "$CLUSTER_NAME" --name "$USER_NODE_POOL_2_NAME" --node-vm-size "$USER_NODE_POOL_2_SIZE" --node-osdisk-type Ephemeral --spot-max-price -1 --priority Spot --enable-cluster-autoscaler --min-count "$USER_NODE_POOL_2_MIN_COUNT" --max-count "$USER_NODE_POOL_2_MAX_COUNT" --vnet-subnet-id "$VNET_SUBNET_ID" --max-pods "$USER_NODE_POOL_2_MAX_PODS" --eviction-policy Delete

echo ""
echo "=== Getting cluster credentials ==="
az aks get-credentials --resource-group "$RESOURCE_GROUP_NAME" --name "$CLUSTER_NAME"

echo ""
echo "=== Cluster created successfully ==="
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Region:     ${LOCATION_DISPLAY} (${LOCATION})"
echo "  Egress IP:  ${EGRESS_IP_ADDRESS} (user-managed, in ${RESOURCE_GROUP_NAME})"
echo "  VNet CIDR:  ${VNET_CIDR}"
echo "  Pod CIDR:   ${POD_CIDR}"
echo "  Svc CIDR:   ${SERVICE_CIDR}"
echo ""
echo "Verify egress IP:"
echo "  kubectl run egress-check --image=curlimages/curl --rm -it --restart=Never -- curl -s https://ifconfig.me"
echo "Expected: ${EGRESS_IP_ADDRESS}"
