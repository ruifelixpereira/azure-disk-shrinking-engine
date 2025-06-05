#!/bin/bash

echo ""
echo "----- STEP 4. Copy partitions: source to target... -----"
echo ""

# Required variables
required_vars=(
    "source_vg_name"
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

# Check if all required arguments have been set
check_required_arguments


# Get source device from the volume group name
SOURCE_PV_NAME=$(sudo pvs --noheadings -o pv_name --select vg_name=${source_vg_name} | awk '{print $1}')

# Extract the base device (e.g., /dev/sdb)
SOURCE_DEVICE_NAME=$(echo "$SOURCE_PV_NAME" | sed -E 's/[0-9]+$//')

# Get the target device from lun 1
TARGET_DEVICE_NAME=$(lsblk -o NAME,HCTL | grep '.*:.*:.*:1' | awk '{print "/dev/" $1}')

echo "Source device: ${SOURCE_DEVICE_NAME}"
echo "Target device: ${TARGET_DEVICE_NAME}"

echo ""
echo "----- STEP 4.1. Getting original partitions layout... -----"
echo ""

# Dump the original disk layout to a file
sfdisk -d ${SOURCE_DEVICE_NAME} > source.layout
#cat source.layout

# Customize layout file to remove 2 lines
sed -i '/device: /d' source.layout
sed -i '/last-lba: /d' source.layout

echo ""
echo "----- STEP 4.2. Creating new partions... -----"
echo ""

# Apply the layout to the new disk:
sfdisk ${TARGET_DEVICE_NAME} < source.layout

# Check the new layout
sfdisk -d ${TARGET_DEVICE_NAME}

echo ""
echo "----- STEP 4.3. Copying partitions... -----"
echo ""

# Get the number of partitions of the source device
SOURCE_PARTITIONS_COUNT=$(sudo fdisk -l ${SOURCE_DEVICE_NAME} | grep "^/dev" | wc -l)
echo "Source device ${SOURCE_DEVICE_NAME} has ${SOURCE_PARTITIONS_COUNT} partitions."

# Copy partitions from ${SOURCE_DEVICE_NAME} to ${TARGET_DEVICE_NAME}
for i in $(seq 1 $SOURCE_PARTITIONS_COUNT); do
    echo "Copying partition ${i}..."
    #dd if=${SOURCE_DEVICE_NAME}${i} of=${TARGET_DEVICE_NAME}${i} bs=2048k status=progress
    dd if=${SOURCE_DEVICE_NAME}${i} of=${TARGET_DEVICE_NAME}${i} bs=4096k status=progress
done

echo ""
echo "----- STEP 4. Completed. -----"
echo ""
