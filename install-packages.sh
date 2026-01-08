 #!/bin/bash

# ==============================================================================
# VCF 9 & Private AI - Air Gap Preparation (Direct Artifactory Method)
# ==============================================================================
# FIXED:
# 1. Corrected VCF CLI binary detection to handle 'vcf-cli-linux_amd64' naming.
# 2. Uses direct Artifactory links (No Broadcom Portal Token required).
# ==============================================================================

set -e

# --- Configuration ---
# Direct URLs for VCF 9.0.0 (Verified from KB 415112 / User Testing)
VCF_CLI_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.0/vcf-cli.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/v9.0.0/linux/amd64/plugins.tar.gz"

DOWNLOAD_DIR="$HOME/vcf_airgap_prep"
mkdir -p "$DOWNLOAD_DIR"

echo "=== Starting VCF 9 Air-Gap Preparation ==="

# 1. Update System & Install Dependencies
echo "[1/6] Updating package list and installing base dependencies..."
sudo apt update
sudo apt install -y \
    wget curl jq git openssl openssh-server \
    nginx ca-certificates sshpass software-properties-common \
    python3 python3-pip apt-transport-https gnupg lsb-release

# 2. Install Docker Engine
echo "[2/6] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    sudo usermod -aG docker $USER
    echo "Docker installed."
else
    echo "Docker already installed."
fi

# Enable Services
sudo systemctl enable --now docker
sudo systemctl enable --now nginx

# 3. Install Kubernetes Tools (Kubectl & Helm)
echo "[3/6] Installing kubectl and Helm..."
# Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

# yq (YAML processor)
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
sudo chmod +x /usr/bin/yq

# 4. Fetch & Install VCF CLI (Direct Download)
echo "[4/6] Downloading VCF 9 CLI from Artifactory..."
# Download to a temporary filename to ensure we handle it correctly
wget -c "$VCF_CLI_URL" -O "$DOWNLOAD_DIR/vcf-cli.tar.gz"

echo "Extracting VCF CLI..."
# Create a clean extraction directory
CLI_EXTRACT_DIR="$DOWNLOAD_DIR/vcf_cli_extracted"
rm -rf "$CLI_EXTRACT_DIR"
mkdir -p "$CLI_EXTRACT_DIR"

# Extract
tar -xvf "$DOWNLOAD_DIR/vcf-cli.tar.gz" -C "$CLI_EXTRACT_DIR"

# Find the binary. It might be named 'vcf', 'vcf-cli', or 'vcf-cli-linux_amd64'
# We look for any file in the extracted folder (excluding hidden ones)
VCF_BIN=$(find "$CLI_EXTRACT_DIR" -maxdepth 2 -type f ! -name ".*" | head -n 1)

if [ -z "$VCF_BIN" ]; then
    echo "ERROR: Could not find any binary in the extracted archive."
    echo "Contents of $CLI_EXTRACT_DIR:"
    ls -R "$CLI_EXTRACT_DIR"
    exit 1
fi

echo "Found binary: $VCF_BIN"
echo "Installing to /usr/local/bin/vcf..."
sudo cp "$VCF_BIN" /usr/local/bin/vcf
sudo chmod +x /usr/local/bin/vcf

echo "Verifying VCF CLI Installation:"
vcf version

# 5. Fetch & Install Offline Plugins (Direct Download)
echo "[5/6] Downloading VCF Offline Plugin Bundle..."
PLUGIN_BUNDLE="$DOWNLOAD_DIR/plugins.tar.gz"
wget -c "$VCF_PLUGIN_BUNDLE_URL" -O "$PLUGIN_BUNDLE"

echo "Extracting Plugin Bundle for Local Install..."
BUNDLE_EXTRACT_DIR="$DOWNLOAD_DIR/vcf_plugins_extracted"
rm -rf "$BUNDLE_EXTRACT_DIR"
mkdir -p "$BUNDLE_EXTRACT_DIR"
tar -xvf "$PLUGIN_BUNDLE" -C "$BUNDLE_EXTRACT_DIR"

echo "Installing Plugins from Local Source..."
# Installs all plugins from the offline bundle
vcf plugin install all --local-source "$BUNDLE_EXTRACT_DIR"

echo "Verifying Plugin Installation..."
vcf plugin list

# 6. Prepare Private AI Artifacts (Helm & Images)
echo "[6/6] Pre-fetching Private AI Helm Charts..."

# NVIDIA GPU Operator
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm pull nvidia/gpu-operator --untar --untardir "$DOWNLOAD_DIR/charts"

echo "
==============================================================================
AIR GAP PREPARATION COMPLETE
==============================================================================
1. VCF CLI installed successfully.
2. VCF Plugins installed from offline bundle.
3. Dependencies (Docker, Helm, Kubectl) ready.

Artifacts location: $DOWNLOAD_DIR
==============================================================================
"
sudo systemctl daemon-reload
