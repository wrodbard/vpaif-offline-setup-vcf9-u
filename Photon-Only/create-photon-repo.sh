#!/bin/bash
# create-photon-repo.sh
# Replaces create-ubuntu-repo.sh for Photon OS

set -e

# Configuration
REPO_ROOT="/var/www/html/photon-repo"
# If you have a source directory of RPMs to copy, define it here.
# Otherwise, we assume this script just initializes the dir.
SOURCE_RPMS_DIR="" 

echo "============================================================"
echo "Setting up Local Photon OS RPM Repository"
echo "============================================================"

# 1. Ensure createrepo is installed
if ! command -v createrepo &> /dev/null; then
    echo "createrepo_c not found. Installing..."
    tdnf install -y createrepo_c
fi

# 2. Create Repository Directory
if [ ! -d "$REPO_ROOT" ]; then
    echo "Creating repository directory at $REPO_ROOT..."
    mkdir -p "$REPO_ROOT"
fi

# 3. Copy RPMs (Optional Step)
if [ -n "$SOURCE_RPMS_DIR" ] && [ -d "$SOURCE_RPMS_DIR" ]; then
    echo "Copying RPMs from $SOURCE_RPMS_DIR..."
    cp -r "$SOURCE_RPMS_DIR"/*.rpm "$REPO_ROOT/"
fi

# 4. Initialize/Update Repository Metadata
echo "Initializing RPM repository metadata..."
createrepo "$REPO_ROOT"

# 5. Set Permissions for Apache
echo "Setting permissions for Apache user..."
# On Photon, the apache user is usually 'apache', typically group 'apache' or 'root' depending on setup
chown -R apache:apache "$REPO_ROOT"
chmod -R 755 "$REPO_ROOT"

echo "============================================================"
echo "Repository created successfully."
echo "URL: http://$(hostname -I | awk '{print $1}')/photon-repo"
echo "============================================================"
