#!/bin/bash
# ---------------------------------------------------------------------------------
# SMART UBUNTU MIRROR & VCF SETUP SCRIPT
# ---------------------------------------------------------------------------------
# BEHAVIOR:
# 1. Fresh Run: Sets up repo, installs dependencies, downloads ~120GB Core OS.
# 2. Subsequent/Dirty Run: Detects 600GB+ bloat (Universe/Multiverse) and deletes it.
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
# PRE-FLIGHT CHECKS & INSTALLS
# ---------------------------------------------------------------------------------
echo "[1/7] Checking dependencies..."
if ! command -v apt-mirror &> /dev/null; then
    echo "  -> apt-mirror not found. Installing..."
    apt update && apt install -y apt-mirror rsync sshpass
else
    echo "  -> Dependencies okay."
fi

# ---------------------------------------------------------------------------------
# INTELLIGENT CLEANUP ("The Nuclear Option")
# ---------------------------------------------------------------------------------
echo "[2/7] Checking repository state..."
REPO_ROOT="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu"

# Check if we have bloat from a previous configuration
if [ -d "$REPO_ROOT/pool/universe" ] || [ -d "$REPO_ROOT/pool/multiverse" ]; then
    echo "  !! DETECTED OLD BLOAT (Universe/Multiverse) !!"
    echo "  !! GOING NUCLEAR: Deleting massive community repos to save space... !!"
    
    # Remove safely without failing if one doesn't exist
    rm -rf "$REPO_ROOT/pool/universe"
    rm -rf "$REPO_ROOT/pool/multiverse"
    # Force removal of dists to ensure apt-mirror rebuilds the index map
    rm -rf "$REPO_ROOT/dists/*universe*"
    rm -rf "$REPO_ROOT/dists/*multiverse*"
    
    echo "  -> Cleanup complete. Repository stripped to Core components."
else
    echo "  -> Repository looks clean (or is empty). Skipping cleanup."
fi

# ---------------------------------------------------------------------------------
# CONFIGURE APT-MIRROR (Strict 64-bit Core)
# ---------------------------------------------------------------------------------
echo "[3/7] Configuring mirror list..."
[ -f "/etc/apt/mirror.list" ] && mv /etc/apt/mirror.list /etc/apt/mirror.list-bak

cat > /etc/apt/mirror.list << EOF
############# config ##################
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
set defaultarch amd64
############# end config ##############

# -- CORE REPOSITORIES ONLY (~120GB) --
deb http://archive.ubuntu.com/ubuntu jammy main restricted
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted

# Clean rule (Generates removal script for old packages)
clean http://archive.ubuntu.com/ubuntu
EOF

# ---------------------------------------------------------------------------------
# RUN MIRROR
# ---------------------------------------------------------------------------------
echo "[4/7] syncing mirror (This may take time)..."
apt-mirror

# Run the cleaner script if apt-mirror generated one
CLEAN_SCRIPT="$BASTION_REPO_DIR/var/clean.sh"
if [ -f "$CLEAN_SCRIPT" ]; then
    echo "  -> Running post-mirror cleanup script..."
    /bin/bash "$CLEAN_SCRIPT"
fi

# ---------------------------------------------------------------------------------
# MANUAL FIXES (Icons & CNF Metadata)
# ---------------------------------------------------------------------------------
echo "[5/7] Downloading metadata (Icons & CNF)..."
base_dir="$REPO_ROOT/dists"

# Only attempt to cd if the directory was actually created by apt-mirror
if [ -d "$base_dir" ]; then
    cd "$base_dir"
    for dist in jammy jammy-updates jammy-security; do
      for comp in main restricted; do
        mkdir -p "$dist/$comp/dep11"
        for size in 48 64 128; do
            # -N only downloads if newer than local file
            wget -q -N "http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz" -O "$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz"
        done
      done
    done
else
    echo "  -> Warning: Mirror directory not found. Skipping metadata fix."
fi

# Download CNF (Command Not Found) data
cd /var/tmp
for p in "${1:-jammy}"{,-{security,updates}}/{main,restricted}; do
  # -c continues download, -N checks timestamp
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
done

if [ -d "archive.ubuntu.com/ubuntu/" ]; then
    cp -av archive.ubuntu.com/ubuntu/ "$REPO_ROOT/../../"
fi

# ---------------------------------------------------------------------------------
# VCF-CLI SETUP
# ---------------------------------------------------------------------------------
echo "[6/7] Setting up VCF-CLI..."
VCF_REPO_DIR="$BASTION_REPO_DIR/vcf-cli"
mkdir -p "$VCF_REPO_DIR"
cd "$VCF_REPO_DIR"

# Download only if file doesn't exist or is incomplete
if [ ! -f "vcf-cli.tar.gz" ]; then
    echo "  -> Downloading VCF-CLI..."
    wget -q -c "$VCF_CLI_URL" -O vcf-cli.tar.gz
fi

if [ ! -f "vcf-plugins-bundle.tar.gz" ]; then
    echo "  -> Downloading VCF Plugin Bundle..."
    wget -q -c "$VCF_PLUGIN_BUNDLE_URL" -O vcf-plugins-bundle.tar.gz
fi

# Install/Update VCF-CLI on local machine
echo "  -> Installing VCF-CLI locally..."
tar -xf vcf-cli.tar.gz

# Robust Binary Finder (Handles "vcf-cli-linux-amd64" or "vcf-cli" or other names)
BINARY_FOUND=$(find . -maxdepth 2 -type f -name "vcf-cli*" ! -name "*.tar.gz" | head -n 1)

if [ -n "$BINARY_FOUND" ]; then
    chmod +x "$BINARY_FOUND"
    cp "$BINARY_FOUND" /usr/local/bin/vcf
    
    echo "  -> Installing Plugins from Offline Bundle..."
    mkdir -p /tmp/vcf-bundle
    tar -xf vcf-plugins-bundle.tar.gz -C /tmp/vcf-bundle
    
    # Suppress output unless error
    if vcf plugin install all --local-source /tmp/vcf-bundle > /dev/null; then
         echo "  -> Plugins installed successfully."
    else
         echo "  -> Warning: Plugin installation reported issues."
    fi
    rm -rf /tmp/vcf-bundle
else
    echo "  -> ERROR: Could not locate extracted VCF binary. Check download."
fi

# ---------------------------------------------------------------------------------
# REMOTE SYNC
# ---------------------------------------------------------------------------------
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  echo "[7/7] Syncing to remote server..."
  
  # Ensure the remote parent directories exist
  # (Optional safety step, depends on remote setup)
  
  echo "  -> Syncing Ubuntu Mirror (Deleting remote bloat if present)..."
  sshpass -p "$HTTP_PASSWORD" rsync -avz --delete "$REPO_ROOT/" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/debs/ubuntu"
  
  echo "  -> Syncing VCF Tools..."
  sshpass -p "$HTTP_PASSWORD" rsync -avz "$VCF_REPO_DIR" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/tools"
fi

echo "----------------------------------------------------------------"
echo "SUCCESS: Mirror Sync & VCF Setup Completed."
echo "----------------------------------------------------------------"
