# Copy a snapshot from a community gallery image to another region


## Step 1. Identify the community gallery image

This command gets the different versions of a certain community gallery image available in the specified region. For example, Rocky Linux 8.x in East US.

```bash
# Get available versions
az sig image-definition show-community --public-gallery-name rocky-dc1c6aa6-905b-4d9c-9577-63ccc28c482a --gallery-image-definition Rocky-8-x86_64-LVM --location eastus --query uniqueId

# Example output
"/CommunityGalleries/rocky-dc1c6aa6-905b-4d9c-9577-63ccc28c482a/Images/Rocky-8-x86_64-LVM"

# Get versions of the image
az sig image-version list-community --public-gallery-name rocky-dc1c6aa6-905b-4d9c-9577-63ccc28c482a --gallery-image-definition Rocky-8-x86_64-LVM --location eastus --query [].uniqueId

# Example output
[
  "/CommunityGalleries/rocky-dc1c6aa6-905b-4d9c-9577-63ccc28c482a/Images/Rocky-8-x86_64-LVM/Versions/8.8.20230518",
  "/CommunityGalleries/rocky-dc1c6aa6-905b-4d9c-9577-63ccc28c482a/Images/Rocky-8-x86_64-LVM/Versions/8.9.20231119"
]
```

Choose the unique Id of version you want to use.


## Step 2. Create a disk from the community gallery image


## Step 3. Create a snapshot of the disk

Use the following command to create a snapshot of the disk created from the community gallery image.

```bash
# Create a snapshot of the disk
az snapshot create --name snap-rocky8-lvm-east --resource-group vm-migration --incremental true --source "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/vm-migration/providers/Microsoft.Compute/disks/MyDisk" --location eastus
```


## Step 4. Copy the snapshot to another region

```bash
# Copy snapshot to another region
resourceGroupName=vm-migration
targetSnapshotName=snap-rocky8-lvm-west
sourceSnapshotName=snap-rocky8-lvm-east
targetRegion=westeurope

# Get the original snapshot ID
sourceSnapshotId=$(az snapshot show -n $sourceSnapshotName -g $resourceGroupName --query [id] -o tsv)

# Start copy snapshot to another region
az snapshot create -g $resourceGroupName -n $targetSnapshotName -l $targetRegion --source $sourceSnapshotId --incremental --copy-start

# Check copy status
az snapshot show -n $targetSnapshotName -g $resourceGroupName --query [completionPercent] -o tsv
```


## References

- https://learn.microsoft.com/en-us/azure/virtual-machines/disks-copy-incremental-snapshot-across-regions?tabs=azure-cli