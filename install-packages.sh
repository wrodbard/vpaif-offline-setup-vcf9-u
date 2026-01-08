#!/bin/bash
# ==============================================================================
# VCF 9 Air-Gap "Portable Kit" Creator
# ==============================================================================
# This script installs VCF tools locally AND saves all installers to:
# $HOME/vcf_airgap_prep
# So you can copy this folder to other offline machines.
# ==============================================================================

set -e

# --- Configuration ---
VCF_CLI_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.0/vcf-cli.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/v9.0.0/linux/amd64/plugins.tar.gz"

DOWNLOAD_DIR="$HOME/vcf_airgap_prep"
mkdir -p "$DOWNLOAD_DIR"

echo "=== Starting Portable VCF 9 Kit Creation ==="

# 1. Base System Prep (Requires Internet on THIS machine)
sudo apt update
sudo apt install -y wget curl jq git openssl sshpass software-properties-common

# 2. Docker (Standard Install - Not saved as portable artifact by default)
# Note: Saving Docker offline is complex (requires deb mirroring). 
# We assume other nodes have base OS + Docker or you have a repo mirror.
if ! command -v docker &> /dev/null; then
    sudo apt install -y docker.io
    sudo usermod -aG docker $USER
fi

# 3. Download & Save KUBECTL (Portable)
echo "Downloading Kubectl..."
curl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o "$DOWNLOAD_DIR/kubectl"
chmod +x "$DOWNLOAD_DIR/kubectl"
# Install locally
sudo cp "$DOWNLOAD_DIR/kubectl" /usr/local/bin/kubectl

# 4. Download & Save HELM (Portable)
echo "Downloading Helm..."
curl -fsSL -o "$DOWNLOAD_DIR/get_helm.sh" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 "$DOWNLOAD_DIR/get_helm.sh"
# Install locally
"$DOWNLOAD_DIR/get_helm.sh"

# 5. Download & Save VCF CLI (Portable)
echo "Downloading VCF CLI..."
wget -c "$VCF_CLI_URL" -O "$DOWNLOAD_DIR/vcf-cli.tar.gz"

# Install locally
echo "Installing VCF CLI..."
CLI_EXTRACT_DIR="$DOWNLOAD_DIR/vcf_cli_extracted"
rm -rf "$CLI_EXTRACT_DIR"
mkdir -p "$CLI_EXTRACT_DIR"
tar -xvf "$DOWNLOAD_DIR/vcf-cli.tar.gz" -C "$CLI_EXTRACT_DIR"

# Dynamic Binary Find (Handles 'vcf' or 'vcf-cli-linux_amd64')
VCF_BIN=$(find "$CLI_EXTRACT_DIR" -maxdepth 2 -type f ! -name ".*" | head -n 1)
sudo cp "$VCF_BIN" /usr/local/bin/vcf
sudo chmod +x /usr/local/bin/vcf

# 6. Download & Save PLUGINS (Portable)
echo "Downloading VCF Plugins..."
wget -c "$VCF_PLUGIN_BUNDLE_URL" -O "$DOWNLOAD_DIR/plugins.tar.gz"

# Install locally
echo "Installing Plugins..."
BUNDLE_EXTRACT_DIR="$DOWNLOAD_DIR/vcf_plugins_extracted"
rm -rf "$BUNDLE_EXTRACT_DIR"
mkdir -p "$BUNDLE_EXTRACT_DIR"
tar -xvf "$DOWNLOAD_DIR/plugins.tar.gz" -C "$BUNDLE_EXTRACT_DIR"
vcf plugin install all --local-source "$BUNDLE_EXTRACT_DIR"

# 7. Download & Save Helm Charts (Portable)
echo "Fetching NVIDIA Charts..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm pull nvidia/gpu-operator --untar --untardir "$DOWNLOAD_DIR/charts"

echo "
==============================================================================
PORTABLE KIT READY
==============================================================================
You can now copy the folder: 
   $DOWNLOAD_DIR
to your other air-gapped machines.

It contains:
1. vcf-cli.tar.gz  (VCF CLI Installer)
2. plugins.tar.gz  (Offline Plugin Bundle)
3. kubectl         (Kubernetes Binary)
4. get_helm.sh     (Helm Installer Script)
5. charts/         (NVIDIA Helm Charts)
==============================================================================
"
