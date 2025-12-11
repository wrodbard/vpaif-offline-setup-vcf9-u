#!/bin/bash
set -xeo pipefail

# Ensure config exists
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

# Photon OS Specific: Install standard dependencies
# tdnf is the package manager for Photon OS
echo "Checking and installing system dependencies..."
sudo tdnf install -y jq wget tar gzip

# Check for govc and install if missing
if ! command -v govc >/dev/null 2>&1 ; then
  echo "govc not found. Installing govc..."
  # Downloading latest govc binary
  curl -L -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | tar -C /tmp -xzf - govc
  sudo mv /tmp/govc /usr/local/bin/govc
  sudo chmod +x /usr/local/bin/govc
  echo "govc installed successfully."
fi

export GOVC_URL=$VCENTER_HOSTNAME
export GOVC_USERNAME=$VCENTER_USERNAME
export GOVC_PASSWORD=$VCENTER_PASSWORD
export GOVC_INSECURE=true
export GOVC_DATASTORE=$CL_DATASTORE
export GOVC_CLUSTER=$K8S_SUP_CLUSTER
# export GOVC_RESOURCE_POOL= # Uncomment and set if needed

############################ WIP

# upload to content library VKS
echo "Checking Content Library '$CL_VKS'..."
if govc library.ls "$CL_VKS" >/dev/null 2>&1; then
  echo "Library '$CL_VKS' already exists."
else
  # If the library does not exist, create it
  echo "Library '$CL_VKS' does not exist. Creating it..."
  govc library.create "$CL_VKS"
fi

# Save original directory
pushd . > /dev/null

if [ -d "$DOWNLOAD_VKR_OVA" ]; then
    cd "$DOWNLOAD_VKR_OVA"
    # Find the tar.gz file
    FILE_WITH_EXTENSION=$(ls *.tar.gz 2>/dev/null | head -n 1)
    
    if [ -n "$FILE_WITH_EXTENSION" ]; then
        FILENAME=${FILE_WITH_EXTENSION%.tar.gz}
        echo "Processing $FILENAME"
        echo "Source: $FILE_WITH_EXTENSION"
        
        # Extract, strip components if needed, though usually flat for these archives
        tar xvf "$FILE_WITH_EXTENSION" --transform 's|.*/||'
        
        if [ -f "ubuntu-ova.ovf" ]; then
            mv ubuntu-ova.ovf "$FILENAME.ovf"
            # Remove manifest if present to avoid checksum errors after rename (common issue)
            rm -f ubuntu-ova.mf 
            
            echo "Importing OVF to $CL_VKS..."
            govc library.import "$CL_VKS" "$FILENAME.ovf"
        else
            echo "Error: ubuntu-ova.ovf not found in archive."
        fi

        echo "Cleaning up..."
        # Be careful with cleanup; only remove what we extracted or just the temp files
        # Original logic: find . -type f | grep -v "$FILE_WITH_EXTENSION" | xargs rm -fr
        # Safer cleanup:
        rm -f "$FILENAME.ovf" ubuntu-ova.mf
    else
        echo "Error: No .tar.gz file found in $DOWNLOAD_VKR_OVA"
    fi
else
    echo "Error: Directory $DOWNLOAD_VKR_OVA does not exist."
fi

# Go back to original directory
popd > /dev/null

# upload to content library DLVM
echo "Checking Content Library '$CL_DLVM'..."
if govc library.ls "$CL_DLVM" >/dev/null 2>&1; then
  echo "Library '$CL_DLVM' already exists."
else
  # If the library does not exist, create it
  echo "Library '$CL_DLVM' does not exist. Creating it..."
  govc library.create "$CL_DLVM"
fi

# Save original directory
pushd . > /dev/null

if [ -d "$DOWNLOAD_DLVM_OVA" ]; then
    cd "$DOWNLOAD_DLVM_OVA"
    FILE_WITH_EXTENSION=$(ls *.tar.gz 2>/dev/null | head -n 1)
    
    if [ -n "$FILE_WITH_EXTENSION" ]; then
        FILENAME=${FILE_WITH_EXTENSION%.tar.gz}
        echo "Processing $FILENAME"
        
        tar xvf "$FILE_WITH_EXTENSION" --transform 's|.*/||'
        
        # DLVM archives might name the OVF differently; assuming it matches filename or is standard
        # If the OVF inside doesn't match $FILENAME.ovf, the import command below might fail.
        # Assuming original script logic (that the OVF is named matching the tar or extracted as such)
        
        # If the tarball contains a specific named ovf, we might need to find it:
        OVF_FILE=$(ls *.ovf 2>/dev/null | head -n 1)
        
        if [ -n "$OVF_FILE" ]; then
            echo "Importing OVF ($OVF_FILE) to $CL_DLVM..."
            govc library.import "$CL_DLVM" "$OVF_FILE"
        else
             echo "Error: No .ovf file found after extraction."
        fi

        echo "Cleaning up"
        # Safer cleanup
        rm -f *.ovf *.mf *.vmdk
    else
        echo "Error: No .tar.gz file found in $DOWNLOAD_DLVM_OVA"
    fi
else
    echo "Error: Directory $DOWNLOAD_DLVM_OVA does not exist."
fi

# Go back to original directory
popd > /dev/null

echo "Upload process completed."