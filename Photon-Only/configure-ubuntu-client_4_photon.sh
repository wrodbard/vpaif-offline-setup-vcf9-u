#!/bin/bash
# configure-ubuntu-client.sh
# Configures an Ubuntu 64-bit client to use a custom PhotonOS Mirror.

set -e

# --- 1. Root Check ---
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)."
  exit 1
fi

# --- 2. Get Mirror IP ---
# Check if IP was provided as an argument, otherwise prompt for it.
MIRROR_IP="$1"

if [ -z "$MIRROR_IP" ]; then
    echo "-------------------------------------------------------"
    echo "Enter the IP address or Hostname of your PhotonOS Mirror"
    echo "-------------------------------------------------------"
    read -p "Mirror IP: " MIRROR_IP
fi

if [ -z "$MIRROR_IP" ]; then
    echo "Error: IP address cannot be empty."
    exit 1
fi

echo "Configuring client to use Mirror at: $MIRROR_IP"

# --- 3. Backup Existing Config ---
SOURCE_FILE="/etc/apt/sources.list"
BACKUP_FILE="/etc/apt/sources.list.bak.$(date +%F_%H-%M-%S)"

if [ -f "$SOURCE_FILE" ]; then
    echo "Backing up existing sources.list to $BACKUP_FILE..."
    cp "$SOURCE_FILE" "$BACKUP_FILE"
else
    echo "Warning: No existing sources.list found. Creating new one."
fi

# --- 4. Write New Configuration ---
echo "Writing new source configuration..."
cat <<EOF > "$SOURCE_FILE"
# Local PhotonOS Mirror ($MIRROR_IP)
deb http://${MIRROR_IP}/ubuntu jammy main restricted universe multiverse
deb http://${MIRROR_IP}/ubuntu jammy-security main restricted universe multiverse
deb http://${MIRROR_IP}/ubuntu jammy-updates main restricted universe multiverse
deb http://${MIRROR_IP}/ubuntu jammy-backports main restricted universe multiverse
EOF

# --- 5. Update and Verify ---
echo "Updating package lists..."
apt update

echo "-------------------------------------------------------"
echo "Verification:"
# Check where 'bash' package would be pulled from
POLICY_CHECK=$(apt policy bash | grep "http://${MIRROR_IP}/ubuntu")

if [[ -n "$POLICY_CHECK" ]]; then
    echo "SUCCESS: The system is now pulling packages from $MIRROR_IP"
    echo "Output: $POLICY_CHECK"
else
    echo "WARNING: The system may not be using the mirror correctly."
    echo "Please check 'apt policy' manually."
fi
echo "-------------------------------------------------------"
