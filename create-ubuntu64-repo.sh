#!/bin/bash
# create ubuntu jammy mirror & VCF CLI repo
set -o pipefail

# Ensure configuration is loaded
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

# Define VCF CLI Versions
VCF_CLI_VERSION="v9.0.0"
VCF_CLI_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/${VCF_CLI_VERSION}/vcf-cli.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/${VCF_CLI_VERSION}/VCF-Consumption-CLI-PluginBundle-Linux_AMD64.tar.gz"

echo "Updating apt and installing apt-mirror..."
apt update
apt install -y apt-mirror

# Backup existing mirror list
if [ -f "/etc/apt/mirror.list" ]; then
    mv /etc/apt/mirror.list /etc/apt/mirror.list-bak
fi

# Create mirror.list file - SLIM VERSION
# REMOVED: universe, multiverse, backports to save ~600GB
cat > /etc/apt/mirror.list << EOF
############# config ##################
#
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
# Force 64-bit architecture
set defaultarch amd64
#
############# end config ##############

# -- CORE REPOSITORIES (Required) --
deb http://archive.ubuntu.com/ubuntu jammy main restricted
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted

# -- OPTIONAL / BLOAT (Uncomment only if strictly needed) --
# 'Universe' contains community maintained software (HUGE SIZE)
# deb http://archive.ubuntu.com/ubuntu jammy universe multiverse
# deb http://archive.ubuntu.com/ubuntu jammy-security universe multiverse
# deb http://archive.ubuntu.com/ubuntu jammy-updates universe multiverse

# 'Backports' contains newer, less stable software
# deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse

# Clean up old packages after mirroring
set cleanscript $BASTION_REPO_DIR/var/clean.sh
EOF

echo "Starting apt-mirror..."
apt-mirror

# Run the clean script if it exists to free up space from previous runs
if [ -f "$BASTION_REPO_DIR/var/clean.sh" ]; then
    echo "Cleaning up obsolete packages..."
    /bin/bash "$BASTION_REPO_DIR/var/clean.sh"
fi

# ------------------------------------------------------------------
# Manual Fixes & Ubuntu Icons/CNF
# ------------------------------------------------------------------
echo "Running manual fixes for icons and CNF metadata..."
base_dir="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu/dists"

if [ -d "$base_dir" ]; then
    cd $base_dir
    # Only loop through core dists, skipping backports if not used above
    for dist in jammy jammy-updates jammy-security; do
      for comp in main restricted; do
        mkdir -p "$dist/$comp/dep11"
        for size in 48 64 128; do
            wget -q "http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz" -O "$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz"
        done
      done
    done
else
    echo "Warning: Mirror directory $base_dir not found. Skipping icon download."
fi

cd /var/tmp
# Download commands (AMD64 ONLY) - reduced scope
for p in "${1:-jammy}"{,-{security,updates}}/{main,restricted}; do
  >&2 echo "Processing: ${p}"
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
done

echo "Copying manual Ubuntu downloads to repo..."
cp -av archive.ubuntu.com/ubuntu/ "$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu"

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
# Handle potentially different internal folder naming in tarball
if [ -f "vcf-cli-linux-amd64" ]; then
    chmod +x vcf-cli-linux-amd64
    mv vcf-cli-linux-amd64 /usr/local/bin/vcf
elif [ -f "vcf-cli" ]; then
    chmod +x vcf-cli
    mv vcf-cli /usr/local/bin/vcf
fi

if command -v vcf &> /dev/null; then
    echo "VCF-CLI installed successfully. Installing plugins from offline bundle..."
    mkdir -p /tmp/vcf-bundle
    tar -xf vcf-plugins-bundle.tar.gz -C /tmp/vcf-bundle
    vcf plugin install all --local-source /tmp/vcf-bundle
    rm -rf /tmp/vcf-bundle
    echo "VCF-CLI plugins installed."
else
    echo "Error: VCF-CLI binary install failed or binary name changed."
fi

# ------------------------------------------------------------------
# Sync to Remote Server
# ------------------------------------------------------------------
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  echo "Syncing Ubuntu Mirror to remote server..."
  # Use --delete to remove files on the remote side that are no longer in our local mirror (crucial for size reduction)
  sshpass -p "$HTTP_PASSWORD" rsync -avz --delete "$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/debs"
  
  echo "Syncing VCF-CLI files to remote server..."
  sshpass -p "$HTTP_PASSWORD" rsync -avz "$VCF_REPO_DIR" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/tools"
fi

echo "Mirror and VCF setup complete."
