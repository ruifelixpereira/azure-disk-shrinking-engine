#!/bin/bash

shrink_all_vms_start_date=$(date +%s)

# load environment variables
set -a && source .env && set +a

# Exit immediately if any command fails (returns a non-zero exit code), preventing further execution.
set -e

# Required variables
required_vars=(
    "vmListToShrinkJsonFile"
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

# Check if all required arguments have been set
check_required_arguments

echo ""
echo "----- Starting bulk disk shrink process for VM list: $vmListToShrinkJsonFile... -----"
echo ""

#
# Validate list of VMs to shrink
#

# Load list of source VMs to shrink parameter from JSON file
if [ ! -f "$vmListToShrinkJsonFile" ]; then
    echo "Error: JSON file with the list of source VMs to shrink parameter not found: $vmListToShrinkJsonFile"
    exit 1
fi

# Validate empty list
count=$(jq 'length' $vmListToShrinkJsonFile)
if [ "$count" -eq 0 ]; then
  echo "Error: No VMs to shrink found in the JSON file: $vmListToShrinkJsonFile"
  exit 1
else
  echo "VMs to shrink: $count"
fi

# Array to hold PIDs
PIDS=()

while read -r vm_json; do
    # Extract VM information
    VM_NAME=$(echo "$vm_json" | jq -r '.source_vm_name')

    # Launch in background and collect PID
    echo "=== Launching parallel process to shrink VM '$VM_NAME'... ==="
    ./shrink-disk.sh $VM_NAME > $VM_NAME-shrink-disk.log 2>&1 &
    PIDS+=($!)
done < <(jq -c '[.[] ][]' "$vmListToShrinkJsonFile")

# Wait for all background jobs to finish
for pid in "${PIDS[@]}"; do
    wait "$pid"
done

# Duration calculation
shrink_all_vms_end_date=$(date +%s)
shrink_all_vms_elapsed=$((shrink_all_vms_end_date - shrink_all_vms_start_date))
shrink_all_vms_minutes=$((shrink_all_vms_elapsed / 60))
shrink_all_vms_seconds=$((shrink_all_vms_elapsed % 60))

echo "----- Completed shrinking all VMs in the list in ${shrink_all_vms_minutes} minutes and ${shrink_all_vms_seconds} seconds. -----"
