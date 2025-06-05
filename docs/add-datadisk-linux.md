# Add data disk to Linux VM

## Find the disk

```bash
lsblk -o NAME,HCTL,SIZE,MOUNTPOINT | grep -i "sd"
```

## Prepare disk

```bash
sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%
sudo mkfs.xfs /dev/sdc1
sudo partprobe /dev/sdc1
```

## Mount the disk

```bash
sudo mkdir /datadrive
sudo mount /dev/sdc1 /datadrive
```

## Add to fstab

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

## Find the UUID of the new drive, use the blkid utility:

```bash
sudo blkid
```

This command will list all block devices and their UUIDs. Look for the line that corresponds to the new disk you just created (e.g., `/dev/sdc1`). The output will look something like this:

Example output:

```bash
/dev/sda1: SEC_TYPE="msdos" UUID="DD07-BBC9" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="EFI System Partition" PARTUUID="fa5b94a0-4b25-4d22-abd5-0ef7db1c0e7f"
/dev/sda2: LABEL="boot" UUID="35690cb6-f5f7-4071-83d0-fc743aaf87e6" BLOCK_SIZE="512" TYPE="xfs" PARTLABEL="primary" PARTUUID="a42b9a46-37e2-4cf7-8154-3125c73224af"
/dev/sda5: UUID="91388218-d89b-40b0-a705-04a7eced3755" BLOCK_SIZE="512" TYPE="xfs" PARTLABEL="primary" PARTUUID="7d077c1b-86d9-47a0-9495-a8931d4a4515"
/dev/sda3: PARTLABEL="primary" PARTUUID="8d561ab7-d00b-42f4-990c-89f61119f26b"
/dev/sda4: PARTLABEL="primary" PARTUUID="68e41680-0d8c-475b-93fe-a393b357f3ee"
/dev/sdc1: UUID="a2560312-5eda-4ee7-8839-40bf3928382f" BLOCK_SIZE="4096" TYPE="xfs" PARTLABEL="xfspart" PARTUUID="e99839aa-3673-43a7-8e8f-d24b50894ddf"
```

Next, open the `/etc/fstab` file in a text editor. Add a line to the end of the file, using the UUID value for the `/dev/sdc1` device that was created in the previous steps, and the mountpoint of `/datadrive`. Using the example from this article, the new line would look like the following:

```bash
UUID=a2560312-5eda-4ee7-8839-40bf3928382f   /datadrive   xfs   defaults,nofail   1   2
```

## Verifiy the disk

```bash
lsblk -o NAME,HCTL,SIZE,MOUNTPOINT | grep -i "sd"
```

## References

- [Create and attach a data disk to a Linux VM in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/attach-disk-portal)