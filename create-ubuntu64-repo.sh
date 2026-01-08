#!/bin/bash
# create ubuntu jammy mirror & VCF CLI repo
set -o pipefail

# 1. Load Configuration
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

# Define VCF CLI Versions
# NOTE: Verify these URLs on the Broadcom portal. They may require an auth token or specific version adjustment.
VCF_CLI_VERSION="v9.0.0"
VCF_CLI_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/${VCF_CLI_VERSION}/vcf-cli.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/${VCF_CLI_VERSION}/VCF-Consumption-CLI-PluginBundle-Linux_AMD64.tar.gz"

echo "Updating apt and installing apt-mirror..."
apt update
apt install -y apt-mirror

# 2. Aggressive Cleanup (The "Fix" for 600GB size)
echo "----------------------------------------------------------------"
echo "PRE-FLIGHT CLEANUP: Removing massive 'Universe' & 'Multiverse' repos..."
echo "This ensures we only sync the ~120GB required for Main/Restricted."
echo "----------------------------------------------------------------"

# Define the pool path (where the actual .deb files live)
UBUNTU_MIRROR_PATH="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu"

if [ -d "$UBUNTU_MIRROR_PATH/pool/universe" ]; then
    echo "Removing existing Universe (Community) packages..."
    rm -rf "$UBUNTU_MIRROR_PATH/pool/universe"
fi

if [ -d "$UBUNTU_MIRROR_PATH/pool/multiverse" ]; then
    echo "Removing existing Multiverse (Non-Free) packages..."
    rm -rf "$UBUNTU_MIRROR_PATH/pool/multiverse"
fi

# Also remove dists indices to force apt-mirror to refresh the map
rm -rf "$UBUNTU_MIRROR_PATH/dists/*universe*"
rm -rf "$UBUNTU_MIRROR_PATH/dists/*multiverse*"

echo "Cleanup complete. Configuring slim mirror..."

# 3. Create Optimized mirror.list
# We explicitly EXCLUDE universe, multiverse, and backports.
# We explicitly set defaultarch to amd64 to avoid downloading 32-bit libs.

if [ -f "/etc/apt/mirror.list" ]; then
    mv /etc/apt/mirror.list /etc/apt/mirror.list-bak
fi

cat > /etc/apt/mirror.list << EOF
############# config ##################
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
set defaultarch amd64
############# end config ##############

# -- CORE REPOSITORIES ONLY (~100-150GB total) --
deb http://archive.ubuntu.com/ubuntu jammy main restricted
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted

# Clean up rule (generates the clean.sh script)
clean http://archive.ubuntu.com/ubuntu
EOF

# 4. Start Mirroring
echo "Starting apt-mirror (Core Only)..."
apt-mirror

# 5. Execute apt-mirror's internal clean script if generated
# This deletes any orphaned files that are no longer in the list above
CLEAN_SCRIPT="$BASTION_REPO_DIR/var/clean.sh"
if [ -f "$CLEAN_SCRIPT" ]; then
    echo "Running post-mirror cleanup script..."
    /bin/bash "$CLEAN_SCRIPT"
fi

# ------------------------------------------------------------------
# Manual Fixes: Icons & CNF (AMD64 Only)
# ------------------------------------------------------------------
echo "Running manual fixes for icons and CNF metadata..."
base_dir="$UBUNTU_MIRROR_PATH/dists"

if [ -d "$base_dir" ]; then
    cd $base_dir
    # Only loop through core dists, skipping backports/universe
    for dist in jammy jammy-updates jammy-security; do
      for comp in main restricted; do
        mkdir -p "$dist/$comp/dep11"
        for size in 48 64 128; do
            wget -q -N "http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz" -O "$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz"
        done
      done
    done
else
    echo "Warning: Mirror directory $base_dir not found. Skipping icon download."
fi

cd /var/tmp
# Download 'Command Not Found' metadata (AMD64 ONLY)
for p in "${1:-jammy}"{,-{security,updates}}/{main,restricted}; do
  >&2 echo "Processing CNF: ${p}"
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
done

echo "Copying manual Ubuntu downloads to repo..."
cp -av archive.ubuntu.com/ubuntu/ "$UBUNTU_MIRROR_PATH"

# ------------------------------------------------------------------
# VCF-CLI & Bundles Download/Install
# ------------------------------------------------------------------
echo "Starting VCF-CLI and Offline Bundle download..."

VCF_REPO_DIR="$BASTION_REPO_DIR/vcf-cli"
mkdir -p "$VCF_REPO_DIR"
cd "$VCF_REPO_DIR"

echo "Downloading VCF-CLI binary..."
wget -q -c "$VCF_CLI_URL" -O vcf-cli.tar.gz

echo "Downloading VCF-CLI Plugin Bundle..."
wget -q -c "$VCF_PLUGIN_BUNDLE_URL" -O vcf-plugins-bundle.tar.gz

echo "Installing VCF-CLI locally on Bastion..."
tar -xf vcf-cli.tar.gz

# Handle variable internal folder naming in tarball
if [ -f "vcf-cli-linux-amd64" ]; then
    chmod +x vcf-cli-linux-amd64
    mv vcf-cli-linux-amd64 /usr/local/bin/vcf
elif [ -f "vcf-cli" ]; then
    chmod +x vcf-cli
    mv vcf-cli /usr/local/bin/vcf
fi

# Install Plugins
if command -v vcf &> /dev/null; then
    echo "VCF-CLI installed. Loading plugins from offline bundle..."
    mkdir -p /tmp/vcf-bundle
    tar -xf vcf-plugins-bundle.tar.gz -C /tmp/vcf-bundle
    
    # Install local source
    vcf plugin install all --local-source /tmp/vcf-bundle
    
    rm -rf /tmp/vcf-bundle
    echo "VCF-CLI plugins installed."
else
    echo "Error: VCF-CLI binary install failed."
fi

# ------------------------------------------------------------------
# Sync to Remote Server
# ------------------------------------------------------------------
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  echo "Syncing Ubuntu Mirror to remote server..."
  # The --delete flag is CRITICAL here to remove the old 600GB junk from the remote server
  sshpass -p "$HTTP_PASSWORD" rsync -avz --delete "$UBUNTU_MIRROR_PATH" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/debs"
  
  echo "Syncing VCF-CLI files to remote server..."
  sshpass -p "$HTTP_PASSWORD" rsync -avz "$VCF_REPO_DIR" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/tools"
fi

echo "Mirror and VCF setup complete."
