#!/bin/bash

echo ""
echo "----- STEP 2. Resizing source disk partition... -----"
echo ""

# Required variables
required_vars=(
    "source_vg_name"
    "source_lv_sizes"
    "pvshrink_script_url"
)

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

# Function to calculate the new size of an existing partition based on the size of the volume group PV and resize it
resize_partition() {
    local vg_name=$1
    local partition=$2
    local partition_number=$3

    # Safety gap in sectors in a total of 4096 sectors (2x 2048 sectors * 512 bytes = 2MiB)
    # This is to ensure that the partition does not overlap with the LVM metadata area (1 MiB)
    # and to leave some space for the filesystem overhead (another 1 MiB).
    local safety_gap=4096

    # Run vgdisplay command and capture the output
    vgdisplay_output=$(sudo vgdisplay "$vg_name" --units m)

    # Extract the VG size from the output
    vg_size=$(echo "$vgdisplay_output" | grep "VG Size" | awk '{print $3}')

    # Get the start sector of the existing partition
    start_sector=$(sudo sfdisk -d "$partition" | grep "first-lba" | awk '{print $2}')

    # Calculate the new size in sectors (assuming 512 bytes per sector)
    new_size_sectors=$(echo "$vg_size * 1024 * 1024 / 512 + $start_sector + $safety_gap" | bc)

    # Resizing the partition
    echo "Resizing partition partition with a total of $new_size_sectors sectors"
    echo " ,$new_size_sectors" | sudo sfdisk --no-reread --force -N $partition_number $partition
}

####################################################################################

# Check if all required arguments have been set
check_required_arguments

#
# Install packages
#

echo ""
echo "----- STEP 2.1. Installing required packages... -----"
echo ""

# Install LVM2 tools if needed
sudo dnf install -y lvm2

# Install python 2
sudo dnf install -y python2

# Install basic calculator
sudo dnf install -y bc

#
# Collect PV and VG information
#

if ! sudo pvs --noheadings -o pv_name,vg_name | grep -q "${source_vg_name}"; then
    echo "Error: VG ${source_vg_name} not found in volume groups."
    exit 1
fi

SOURCE_PV_VG_NAMES=$(sudo pvs --noheadings -o pv_name,vg_name | grep ${source_vg_name})
read -r SOURCE_PV_NAME SOURCE_VG_NAME_TO_IGNORE <<< "$SOURCE_PV_VG_NAMES"

if [ -z "$SOURCE_PV_NAME" ]; then
    echo "Error: No physical volume found for the volume group $source_vg_name."
    exit 1
fi

# Extract the base device (e.g., /dev/sdb)
SOURCE_DEVICE_NAME=$(echo "$SOURCE_PV_NAME" | sed -E 's/[0-9]+$//')

# Extract the partition number (e.g., 6)
SOURCE_PARTITION_NUMBER=$(echo "$SOURCE_PV_NAME" | grep -oE '[0-9]+$')

echo "PV name: $SOURCE_PV_NAME"
echo "Base device: $SOURCE_DEVICE_NAME"
echo "Partition number: $SOURCE_PARTITION_NUMBER"

#
# Check the filesystem
#
echo ""
echo "----- STEP 2.2. Checking filesystem... -----"
echo ""

# Get the array of logical volumes with new sizes
IFS=',' read -r -a array <<< "$source_lv_sizes"

for lv in "${array[@]}"; do

    # Get the name and size of LV
    IFS=':' read -r -a subarray <<< "$lv"
    lv_path="/dev/${source_vg_name}/${subarray[0]}"
    new_size="${subarray[1]}"

    # Check if the logical volume exists
    if [ ! -e "$lv_path" ]; then
        echo "Logical volume $lv_path does not exist. Skipping."
        continue
    fi

    # Check the filesystem
    echo "Running filesystem check on $lv_path..."
    sudo fsck.ext4 -D -ff "$lv_path" -y
done

#
# Resize the logical volumes
#

echo ""
echo "----- STEP 2.3. Resizing logical volumes... -----"
echo ""

for lv in "${array[@]}"; do

    # Get the name and size of LV
    IFS=':' read -r -a subarray <<< "$lv"
    lv_path="/dev/${source_vg_name}/${subarray[0]}"
    new_size="${subarray[1]}"

    # Check if the logical volume exists
    if [ ! -e "$lv_path" ]; then
        echo "Logical volume $lv_path does not exist. Skipping."
        continue
    fi

    # Resize the LV
    echo "Resizing $lv_path to $new_size..."
    sudo lvresize --resizefs -L $new_size $lv_path
done

#
# Resize physical volume
#

echo ""
echo "----- STEP 2.4. Resizing physical volume... -----"
echo ""

# Install python script
curl -o pvshrink $pvshrink_script_url
chmod +x pvshrink

# Resize PV
sudo ./pvshrink -v $SOURCE_PV_NAME

#
# Resize partition
#

echo ""
echo "----- STEP 2.5. Resizing partition... -----"
echo ""

# Resize the partition
resize_partition "$source_vg_name" "$SOURCE_DEVICE_NAME" $SOURCE_PARTITION_NUMBER

echo ""
echo "----- STEP 2. Completed. -----"
echo ""
