#!/bin/bash
# bastion-download-prerequisites.sh
# Adapted for VMware Photon OS

set -e

# Source the configuration file
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found. Please ensure you are running this from the root of the repo."
    exit 1
fi

echo "============================================================"
echo "Starting Prerequisite Download & Setup for Photon OS..."
echo "============================================================"

# ------------------------------------------------------------------
# 1. Install System Dependencies via tdnf (Tiny DNF)
# ------------------------------------------------------------------
echo "Updating package repositories..."
tdnf makecache

echo "Installing system dependencies (curl, wget, jq, git, unzip, tar, sshpass)..."
# Note: 'jq' is available in standard Photon repos. 
# We include 'ca-certificates' to ensure SSL downloads work correctly.
tdnf install -y curl wget jq git unzip tar gzip sshpass ca-certificates

# ------------------------------------------------------------------
# 2. Install yq (YAML Processor)
# ------------------------------------------------------------------
# yq is often not in minimal Photon repos, so we download the binary directly.
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.35.1" # Safe default version, or check env.config if defined
    YQ_BINARY="yq_linux_amd64"
    
    wget "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O /usr/bin/yq
    chmod +x /usr/bin/yq
    echo "yq installed successfully."
else
    echo "yq is already installed."
fi

# ------------------------------------------------------------------
# 3. Install Docker (if not present)
# ------------------------------------------------------------------
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    tdnf install -y docker
    systemctl enable --now docker
    echo "Docker installed and started."
else
    echo "Docker is already installed."
fi

# ------------------------------------------------------------------
# 4. Install Kubectl
# ------------------------------------------------------------------
# Assuming KUBERNETES_VERSION is set in env.config. If not, defaults to stable.
KUBE_VER=${KUBERNETES_VERSION:-$(curl -L -s https://dl.k8s.io/release/stable.txt)}

if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl (Version: $KUBE_VER)..."
    curl -LO "https://dl.k8s.io/release/${KUBE_VER}/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    echo "kubectl installed successfully."
else
    echo "kubectl is already installed."
fi

# ------------------------------------------------------------------
# 5. Install Carvel Tools (imgpkg, kapp, kbld, ytt)
# ------------------------------------------------------------------
# These are required for many VCF/TKG offline operations.
echo "Installing Carvel tools (imgpkg, kapp, kbld, ytt)..."
curl -L https://carvel.dev/install.sh | bash

# ------------------------------------------------------------------
# 6. Verify Installations
# ------------------------------------------------------------------
echo "============================================================"
echo "Verification:"
echo "------------------------------------------------------------"
echo "jq version:      $(jq --version)"
echo "yq version:      $(yq --version)"
echo "docker version:  $(docker --version)"
echo "kubectl version: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
echo "imgpkg version:  $(imgpkg --version | head -n 1)"
echo "============================================================"
echo "Prerequisites setup complete."
