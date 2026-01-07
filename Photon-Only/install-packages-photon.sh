#!/bin/bash
# install-packages.sh
# Adapted for VMware Photon OS

set -e

echo "============================================================"
echo "Installing Packages & Services on Photon OS"
echo "============================================================"

# 1. Update Repositories
echo "Updating tdnf metadata..."
tdnf makecache

# 2. Install Required Packages
# 'httpd' is the Apache web server package on Photon/RHEL systems
# 'createrepo_c' is needed for the repo creation script later
echo "Installing Docker, Apache (httpd), and tools..."
tdnf install -y \
    docker \
    httpd \
    createrepo_c \
    wget \
    curl \
    jq \
    tar \
    git \
    sshpass \
    ca-certificates

# 3. Configure & Start Docker
echo "Enabling and starting Docker..."
systemctl enable --now docker

# 4. Configure & Start Apache
echo "Enabling and starting Apache (httpd)..."
systemctl enable --now httpd

# 5. Firewall Configuration (Optional but recommended)
# Photon OS usually defaults to iptables. We allow HTTP/HTTPS.
echo "Configuring firewall for HTTP/HTTPS..."
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
# Persist rules (if iptables-services is used, otherwise this applies to runtime only)
iptables-save > /etc/systemd/scripts/ip4save 2>/dev/null || true

echo "============================================================"
echo "Installation complete. Services are running."
