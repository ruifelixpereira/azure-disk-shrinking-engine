#!/bin/bash

START_DATE=$(date +%s)

# Usage: ./shrink_disk.sh <sourceVmName>
sourceVmName=$1
if [ -z "$sourceVmName" ]; then
    echo "Usage: $0 <vm_name>"
    exit 1
fi

echo ""
echo "----- [VM: $sourceVmName] Starting disk shrink process... -----"
echo ""

# load environment variables
set -a && source .env && set +a

# Exit immediately if any command fails (returns a non-zero exit code), preventing further execution.
set -e

# Required variables
required_vars=(
    "maxStep"
    "subscriptionId"
    "prefixName"
    "resourceGroup"
    "prepVmSize"
    "prepVmSubnetId"
    "prepVmOSDiskSnapshotName"
    "vmShrinkPartsJsonFile"
    "pvshrinkScriptUrl"
)

# Set the current directory to where the script lives.
cd "$(dirname "$0")"

####################################################################################

# Function to check if all required arguments have been set
check_required_arguments() {
    # Array to store the names of the missing arguments
    local missing_arguments=()

    # Loop through the array of required argument names
    for arg_name in "${required_vars[@]}"; do
        # Check if the argument value is empty
        if [[ -z "${!arg_name}" ]]; then
            # Add the name of the missing argument to the array
            missing_arguments+=("${arg_name}")
        fi
    done

    # Check if any required argument is missing
    if [[ ${#missing_arguments[@]} -gt 0 ]]; then
        echo -e "\nError: Missing required arguments:"
        printf '  %s\n' "${missing_arguments[@]}"
        [ ! \( \( $# == 1 \) -a \( "$1" == "-c" \) \) ] && echo "  Either provide a .env file or all the arguments, but not both at the same time."
        [ ! \( $# == 22 \) ] && echo "  All arguments must be provided."
        echo ""
        exit 1
    fi
}

####################################################################################

# Function to check if a managed disk is attached and detach it
detach_managed_disk() {
    local resource_group=$1
    local disk_name=$2

    # Check if the managed disk is attached
    attached_vm=$(az disk list --resource-group "$resource_group" --query "[?name=='$disk_name'].managedBy" --output tsv)

    if [ -n "$attached_vm" ]; then
        # Extract the VM name from the managedBy property
        vm_name=$(basename "$attached_vm")

        # Detach the managed disk
        az vm disk detach --resource-group "$resource_group" --vm-name "$vm_name" --name "$disk_name"
        echo "Managed disk '$disk_name' detached from VM '$vm_name'."
    else
        echo "Managed disk '$disk_name' is not attached to any VM."
    fi
}

####################################################################################

# Check if all required arguments have been set
check_required_arguments

#
# Steps
#

# Get the max step to run from the first argument, default to 6 if not provided
MAX_STEP=${maxStep:-6}
if ! [[ "$MAX_STEP" =~ ^[0-6]$ ]]; then
    echo "[VM: $sourceVmName] Error: maxStep must be a number between 0 and 6."
    exit 1
fi

echo ""
echo "----- [VM: $sourceVmName] STEP 0. Get source VM disk shrinking configuration... -----"
echo ""

# Load source VM disk shrinking parameters from JSON file
if [ ! -f "$vmShrinkPartsJsonFile" ]; then
    echo "[VM: $sourceVmName] Error: JSON file with source VM disk shrinking parameters not found: $vmShrinkPartsJsonFile"
    exit 1
fi

source_lv_sizes=$(jq -r --arg vm "$sourceVmName" '.[] | select(.vm_name == $vm) | .new_lv_sizes' "$vmShrinkPartsJsonFile")
if [ -z "$source_lv_sizes" ]; then
    echo "[VM: $sourceVmName] No logical volumes found for VM $sourceVmName in $vmShrinkPartsJsonFile."
    exit 1
fi

source_vg_name=$(jq -r --arg vm "$sourceVmName" '.[] | select(.vm_name == $vm) | .vg_name_to_shrink' "$vmShrinkPartsJsonFile")
if [ -z "$source_vg_name" ]; then
    echo "[VM: $sourceVmName] No volume group found for VM $sourceVmName in $vmShrinkPartsJsonFile."
    exit 1
fi

target_disk_size_gb=$(jq -r --arg vm "$sourceVmName" '.[] | select(.vm_name == $vm) | .target_disk_size_gb' "$vmShrinkPartsJsonFile")
if [ -z "$target_disk_size_gb" ]; then
    echo "[VM: $sourceVmName] No target disk size found for VM $sourceVmName in $vmShrinkPartsJsonFile."
    exit 1
fi

echo "[VM: $sourceVmName] Source volume group name: $source_vg_name"
echo "[VM: $sourceVmName] Source logical volumes sizes: $source_lv_sizes"
echo "[VM: $sourceVmName] Target disk size: $target_disk_size_gb GB"

if [ "$MAX_STEP" -lt 1 ]; then exit 0; fi
echo ""
echo "----- [VM: $sourceVmName] STEP 1. Preparation VM with copy of source disk... -----"
echo ""

# Set the context to the subscription Id where Managed Disk exists and where VM will be created
az account set --subscription $subscriptionId

# Check if source vm exists
SOURCE_DISK_NAME=$(az vm show --name "$sourceVmName" --resource-group "$resourceGroup" --query "storageProfile.osDisk.name" -o tsv)

if [ -z "$SOURCE_DISK_NAME" ]; then
    echo "Source VM $sourceVmName does not exist in resource group $resourceGroup."
    exit 1
fi

#
# Create snapshot of the source disk
#
echo ""
echo "----- [VM: $sourceVmName] STEP 1.1. Creating snapshot of the source disk $SOURCE_DISK_NAME in resource group $resourceGroup... -----"
echo ""

# Get source disk ID
SOURCE_DISK_ID=$(az disk show --name "$SOURCE_DISK_NAME" --resource-group "$resourceGroup" --query id -o tsv)
if [ -z "$SOURCE_DISK_ID" ]; then
    echo "Disk $SOURCE_DISK_NAME does not exist in resource group $resourceGroup."
    exit 1
fi

# Get original disk details
Disk=$(az disk show --ids "$SOURCE_DISK_ID" --query "{sku:sku.name, hyperVGeneration:hyperVGeneration, diskSizeGB:diskSizeGB}" -o json)
#HyperVGen=$(echo "$Disk" | jq -r '.hyperVGeneration')
DISK_SIZE_GB=$(echo "$Disk" | jq -r '.diskSizeGB')
STORAGE_TYPE=$(echo "$Disk" | jq -r '.sku')

# Provide the name of the snapshot that will be created from the source VM OS disk
sourceVmOSDiskSnapshotName="$prefixName-$SOURCE_DISK_NAME-source-snapshot"

# Create snapshot from the original disk
SOURCE_SNAPSHOT_ID=$(az snapshot create --name $sourceVmOSDiskSnapshotName --resource-group $resourceGroup --incremental false --source $SOURCE_DISK_ID --query [id] -o tsv)

# Provide the name of the new managed disk that will be create from the source snapshot
sourceDiskName="$prefixName-$SOURCE_DISK_NAME-source-disk"

#
# Delete the source VM + source disk but keep the NIC
#
echo ""
echo "----- [VM: $sourceVmName] STEP 1.2. Deleting source VM + Disk after the snapshot, but keep the NIC... -----"
echo ""

# Get the NIC name attached to the VM
SOURCE_NIC_ID=$(az vm show --name "$sourceVmName" --resource-group "$resourceGroup" --query "networkProfile.networkInterfaces[0].id" -o tsv)
SOURCE_NIC_NAME=$(basename "$SOURCE_NIC_ID")

# Get location from RG
LOCATION=$(az vm show --name "$sourceVmName" --resource-group "$resourceGroup" --query location -o tsv)

# Get source vm size
SOURCE_VM_SIZE=$(az vm show --name "$sourceVmName" --resource-group "$resourceGroup" --query "hardwareProfile.vmSize" -o tsv)
if [ -z "$SOURCE_VM_SIZE" ]; then
    echo "Source VM $sourceVmName does not exist in resource group $resourceGroup."
    exit 1
fi

# Delete the VM (but keep the NIC and disks)
az vm delete --name "$sourceVmName" --resource-group "$resourceGroup" --yes

# Delete the original OS disk
az disk delete --name "$SOURCE_DISK_NAME" --resource-group "$resourceGroup" --yes

#
# Create copy of source disk from the new source disk snapshot
#
echo ""
echo "----- [VM: $sourceVmName] STEP 1.3. Creating a new copy of the source managed disk with the name $sourceDiskName in resource group $resourceGroup... -----"
echo ""

# Create a new Managed Disks using the snapshot Id
# Note that managed disk will be created in the same location as the snapshot
# If you're creating a Premium SSD v2 or an Ultra Disk, add "--zone $zone" to the end of the command
NEW_SOURCE_DISK_ID=$(az disk create --resource-group $resourceGroup --name $sourceDiskName --sku $STORAGE_TYPE --size-gb $DISK_SIZE_GB --source $SOURCE_SNAPSHOT_ID --query [id] -o tsv)

# Provide the name of the new OS Managed Disks that will be create for the new preparation virtual machine
prepVmOSDiskName="$prefixName-$sourceVmName-prep-vm-osdisk"

#
# Create a new OS disk for the preparation VM
#
echo ""
echo "----- [VM: $sourceVmName] STEP 1.4. Creating a new OS disk for the preparation VM with the name $prepVmOSDiskName in resource group $resourceGroup... -----"
echo ""

# Get the OS disk snapshot information
PREP_VM_OS_DISK_SNAPSHOT_ID=$(az snapshot show --name $prepVmOSDiskSnapshotName --resource-group $resourceGroup --query [id] -o tsv)
PREP_VM_OS_DISK_SNAPSHOT_SIZE=$(az snapshot show --name $prepVmOSDiskSnapshotName --resource-group $resourceGroup --query [diskSizeGB] -o tsv)

# Create a new Managed Disks using the snapshot Id
# Note that managed disk will be created in the same location as the snapshot
PREP_VM_OS_DISK_ID=$(az disk create --resource-group $resourceGroup --name $prepVmOSDiskName --sku "StandardSSD_LRS" --size-gb $PREP_VM_OS_DISK_SNAPSHOT_SIZE --source $PREP_VM_OS_DISK_SNAPSHOT_ID --query [id] -o tsv)

# Provide the the name for the new preparation virtual machine
prepVmName="$prefixName-$sourceVmName-prep-vm"

#
# Create copy of source disk from the new source disk snapshot
#
echo ""
echo "----- [VM: $sourceVmName] STEP 1.5. Creating a new preparation vm $prepVmName in resource group $resourceGroup... -----"
echo ""

# Create preparation VM by attaching existing managed disks as OS
az vm create \
    --name $prepVmName \
    --resource-group $resourceGroup \
    --attach-os-disk $PREP_VM_OS_DISK_ID \
    --attach-data-disks $NEW_SOURCE_DISK_ID \
    --os-type "Linux" \
    --subnet $prepVmSubnetId \
    --public-ip-address "" \
    --nsg "" \
    --size $prepVmSize \
    --tag "CreatedBy=script" \
    --os-disk-delete-option delete \
    --nic-delete-option delete \
    --data-disk-delete-option delete

# Enable boot diagnostics
az vm boot-diagnostics enable \
    --name $prepVmName \
    --resource-group $resourceGroup


echo ""
echo "----- [VM: $sourceVmName] STEP 1.6. Waiting for the VM $prepVmName to be ready... -----"
echo ""

while true; do
  az vm run-command invoke \
    --resource-group "$resourceGroup" \
    --name "$prepVmName" \
    --command-id RunShellScript \
    --scripts "echo VM is ready" &> /dev/null

  if [ $? -eq 0 ]; then
    echo "✅ VM is ready!"
    break
  else
    echo "⏳ Still waiting..."
    sleep 10
  fi
done

echo ""
echo "----- [VM: $sourceVmName] STEP 1. Completed. -----"
echo ""

if [ "$MAX_STEP" -lt 2 ]; then exit 0; fi
echo ""
echo "----- [VM: $sourceVmName] STEP 2. Resizing source disk partition... -----"
echo ""

# Run script inside the preparation VM to resize the source disk partition
az vm run-command invoke \
    --name "$prepVmName" \
    --resource-group "$resourceGroup" \
    --command-id RunShellScript \
    --scripts @step2-resize-source-disk.sh \
    --parameters "source_vg_name=$source_vg_name source_lv_sizes=$source_lv_sizes pvshrink_script_url=$pvshrinkScriptUrl"

echo ""
echo "----- [VM: $sourceVmName] STEP 2. Completed. -----"
echo ""

az account get-access-token --scope https://management.core.windows.net//.default

if [ "$MAX_STEP" -lt 3 ]; then exit 0; fi
echo ""
echo "----- [VM: $sourceVmName] STEP 3. Prepare target disk... -----"
echo ""

echo ""
echo "----- [VM: $sourceVmName] STEP 3.1. Rebooting preparation VM $prepVmName... -----"
echo ""

#
# Reboot preparation VM
#
az vm restart -g "$resourceGroup" -n "$prepVmName"

echo ""
echo "----- [VM: $sourceVmName] STEP 3.2. Waiting for the VM $prepVmName to be ready... -----"
echo ""

while true; do
  az vm run-command invoke \
    --resource-group "$resourceGroup" \
    --name "$prepVmName" \
    --command-id RunShellScript \
    --scripts "echo VM is ready" &> /dev/null

  if [ $? -eq 0 ]; then
    echo "✅ VM is ready!"
    break
  else
    echo "⏳ Still waiting..."
    sleep 10
  fi
done

# Provide the new resized disk name
targetDiskName="$prefixName-$SOURCE_DISK_NAME-target-disk"

echo ""
echo "----- [VM: $sourceVmName] STEP 3.3. Creating new target empty disk ${targetDiskName} and attaching it to preparation VM... -----"
echo ""

#
# Create new target empty disk
#

# Fixed values
#DiskType="StandardSSD_LRS"
HyperVGen="V2"

# Create empty disk
TARGET_DISK_ID=$(az disk create --resource-group "$resourceGroup" --name "$targetDiskName" --size-gb "$target_disk_size_gb" --location "$LOCATION" --sku $STORAGE_TYPE --hyper-v-generation "$HyperVGen" --query [id] -o tsv)

#
# Attach empty data disk to VM on lun 1 (lun 0 if for the source data disk)
#
az vm disk attach --vm-name "$prepVmName" --resource-group "$resourceGroup" --lun 1 --disks "$TARGET_DISK_ID"

echo ""
echo "----- [VM: $sourceVmName] STEP 3. Completed. -----"
echo ""

az account get-access-token --scope https://management.core.windows.net//.default

if [ "$MAX_STEP" -lt 4 ]; then exit 0; fi
echo ""
echo "----- [VM: $sourceVmName] STEP 4. Copy partitions: source to target... -----"
echo ""

# Run script inside the preparation VM to copy source disk partitions to target disk
az vm run-command invoke \
    --name "$prepVmName" \
    --resource-group "$resourceGroup" \
    --command-id RunShellScript \
    --scripts @step4-copy-partitions.sh \
    --parameters "source_vg_name=$source_vg_name"

echo ""
echo "----- [VM: $sourceVmName] STEP 4. Completed. -----"
echo ""

az account get-access-token --scope https://management.core.windows.net//.default


if [ "$MAX_STEP" -lt 5 ]; then exit 0; fi
echo ""
echo "----- [VM: $sourceVmName] STEP 5. Create new virtual machine with shrinked disk... -----"
echo ""

echo ""
echo "----- [VM: $sourceVmName] STEP 5.1. Detaching target disk $targetDiskName from preparation VM... -----"
echo ""

# Provide the OS type
osType=linux

# Detach disk from preparation VM if needed
detach_managed_disk "$resourceGroup" "$targetDiskName"

# Get the resource Id of the managed disk
MANAGED_DISK_ID=$(az disk show --name $targetDiskName --resource-group $resourceGroup --query [id] -o tsv)

# Provide the name of the virtual machine
#targetVmName="$prefixName-$sourceVmName-vm"
targetVmName=$sourceVmName

echo ""
echo "----- [VM: $sourceVmName] STEP 5.2. Creating target virtual machine $targetVmName... -----"
echo ""

# Create target VM by attaching existing managed disks as OS
az vm create \
    --name $targetVmName \
    --resource-group $resourceGroup \
    --attach-os-disk $MANAGED_DISK_ID \
    --os-type $osType \
    --nics "$SOURCE_NIC_NAME" \
    --public-ip-address "" \
    --nsg "" \
    --size $SOURCE_VM_SIZE \
    --tag "CreatedBy=DiskShrinkingEngine" #--subnet $targetVmSubnetId \


az account get-access-token --scope https://management.core.windows.net//.default


# Enable boot diagnostics
az vm boot-diagnostics enable \
    --name $targetVmName \
    --resource-group $resourceGroup

echo ""
echo "----- [VM: $sourceVmName] STEP 5. Completed. -----"
echo ""

if [ "$MAX_STEP" -lt 6 ]; then exit 0; fi
echo ""
echo "----- [VM: $sourceVmName] STEP 6. Cleaning up the preparation VM $prepVmName... -----"
echo ""

# Delete the preparation VM
az vm delete --name "$prepVmName" --resource-group "$resourceGroup" --yes --no-wait

# Delete the OS disk of the preparation VM
#az disk delete --name "$prepVmOSDiskName" --resource-group "$resourceGroup" --yes --no-wait

# Delete the source disk snapshot
#az snapshot delete --name $sourceVmOSDiskSnapshotName --resource-group $resourceGroup --yes --no-wait

echo ""
echo "----- [VM: $sourceVmName] STEP 6. Completed. -----"
echo ""

#
# Calculate total duration
#

END_DATE=$(date +%s)

elapsed=$((END_DATE - START_DATE))
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))

echo ""
echo "----- [VM: $sourceVmName] Elapsed time: ${minutes} minutes and ${seconds} seconds. -----"
echo ""