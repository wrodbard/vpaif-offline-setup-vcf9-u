#!/bin/bash
# ---------------------------------------------------------------------------------
# DEEP CLEAN & SYNC SCRIPT (Standard ~120GB Target)
# ---------------------------------------------------------------------------------
set -o pipefail

# 1. Load Configuration
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "CRITICAL ERROR: ./config/env.config not found. Exiting."
    exit 1
fi

# Define Broadcom/VCF Versions
VCF_CLI_VERSION="v9.0.0"
VCF_CLI_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/${VCF_CLI_VERSION}/vcf-cli.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/${VCF_CLI_VERSION}/VCF-Consumption-CLI-PluginBundle-Linux_AMD64.tar.gz"

# ---------------------------------------------------------------------------------
# STEP 1: LOCATE AND DESTROY BLOAT
# ---------------------------------------------------------------------------------
REPO_ROOT="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu"

echo "====================================================================="
echo "DIAGNOSTIC: Checking storage usage..."
echo "====================================================================="

if [ -d "$REPO_ROOT/pool" ]; then
    # Calculate sizes of the specific components
    echo "Checking size of 'Universe' (Community - likely huge)..."
    du -sh "$REPO_ROOT/pool/universe" 2>/dev/null || echo "Universe not found."

    echo "Checking size of 'Multiverse' (Non-Free)..."
    du -sh "$REPO_ROOT/pool/multiverse" 2>/dev/null || echo "Multiverse not found."
    
    echo "Checking size of 'Backports'..."
    du -sh "$REPO_ROOT/pool/main/b/backports-*" 2>/dev/null || echo "Backports not found."

    echo "---------------------------------------------------------------------"
    echo "PERFORMING DEEP CLEAN..."
    
    # FORCE DELETE
    # We remove these folders entirely. apt-mirror will recreate 'main'/'restricted' 
    # but will NOT recreate these because they are removed from the config below.
    
    if [ -d "$REPO_ROOT/pool/universe" ]; then
        echo "  -> Removing Universe... (This frees the most space)"
        rm -rf "$REPO_ROOT/pool/universe"
    fi
    
    if [ -d "$REPO_ROOT/pool/multiverse" ]; then
        echo "  -> Removing Multiverse..."
        rm -rf "$REPO_ROOT/pool/multiverse"
    fi

    # Also remove the index files that list these packages
    rm -rf "$REPO_ROOT/dists/"*universe*
    rm -rf "$REPO_ROOT/dists/"*multiverse*
    
    echo "  -> Cleanup Finished."
else
    echo "Repo directory not created yet. Proceeding with fresh install."
fi

# ---------------------------------------------------------------------------------
# STEP 2: CONFIGURE APT-MIRROR (Strict Main/Restricted)
# ---------------------------------------------------------------------------------
echo "Configuring apt-mirror for 64-bit Core Only..."

# Backup existing list
[ -f "/etc/apt/mirror.list" ] && mv /etc/apt/mirror.list /etc/apt/mirror.list-bak

cat > /etc/apt/mirror.list << EOF
############# config ##################
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
set defaultarch amd64
############# end config ##############

# -- CORE REPOSITORIES ONLY --
# Only 'main' and 'restricted'. NO universe. NO multiverse.
deb http://archive.ubuntu.com/ubuntu jammy main restricted
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted

# Clean rule
clean http://archive.ubuntu.com/ubuntu
EOF

# ---------------------------------------------------------------------------------
# STEP 3: RUN SYNC
# ---------------------------------------------------------------------------------
echo "Starting Sync..."
apt-mirror

# Run the internal clean script (deletes orphaned files from 'main' if any)
CLEAN_SCRIPT="$BASTION_REPO_DIR/var/clean.sh"
if [ -f "$CLEAN_SCRIPT" ]; then
    echo "Running apt-mirror post-clean script..."
    /bin/bash "$CLEAN_SCRIPT"
fi

# ---------------------------------------------------------------------------------
# STEP 4: MANUAL FIXES (Icons & CNF)
# ---------------------------------------------------------------------------------
echo "Downloading metadata..."
base_dir="$REPO_ROOT/dists"

if [ -d "$base_dir" ]; then
    cd "$base_dir"
    for dist in jammy jammy-updates jammy-security; do
      for comp in main restricted; do
        mkdir -p "$dist/$comp/dep11"
        for size in 48 64 128; do
            wget -q -N "http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz" -O "$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz"
        done
      done
    done
fi

cd /var/tmp
for p in "${1:-jammy}"{,-{security,updates}}/{main,restricted}; do
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
done

if [ -d "archive.ubuntu.com/ubuntu/" ]; then
    cp -av archive.ubuntu.com/ubuntu/ "$REPO_ROOT/../../"
fi

# ---------------------------------------------------------------------------------
# STEP 5: VCF-CLI SETUP
# ---------------------------------------------------------------------------------
echo "Setting up VCF-CLI..."
VCF_REPO_DIR="$BASTION_REPO_DIR/vcf-cli"
mkdir -p "$VCF_REPO_DIR"
cd "$VCF_REPO_DIR"

if [ ! -f "vcf-cli.tar.gz" ]; then
    wget -q -c "$VCF_CLI_URL" -O vcf-cli.tar.gz
fi
if [ ! -f "vcf-plugins-bundle.tar.gz" ]; then
    wget -q -c "$VCF_PLUGIN_BUNDLE_URL" -O vcf-plugins-bundle.tar.gz
fi

tar -xf vcf-cli.tar.gz
BINARY_FOUND=$(find . -maxdepth 2 -type f -name "vcf-cli*" ! -name "*.tar.gz" | head -n 1)

if [ -n "$BINARY_FOUND" ]; then
    chmod +x "$BINARY_FOUND"
    cp "$BINARY_FOUND" /usr/local/bin/vcf
    mkdir -p /tmp/vcf-bundle
    tar -xf vcf-plugins-bundle.tar.gz -C /tmp/vcf-bundle
    vcf plugin install all --local-source /tmp/vcf-bundle > /dev/null 2>&1
    rm -rf /tmp/vcf-bundle
fi

# ---------------------------------------------------------------------------------
# STEP 6: REMOTE SYNC (With DELETE)
# ---------------------------------------------------------------------------------
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  echo "Syncing to remote (DELETING REMOTE BLOAT)..."
  sshpass -p "$HTTP_PASSWORD" rsync -avz --delete "$REPO_ROOT/" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/debs/ubuntu"
  sshpass -p "$HTTP_PASSWORD" rsync -avz "$VCF_REPO_DIR" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/tools"
fi

echo "====================================================================="
echo "DONE. Check size now with: du -sh $REPO_ROOT"
echo "====================================================================="
