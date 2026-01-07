#!/bin/bash
# Adapted create-ubuntu-repo.sh for PhotonOS
# This script sets up a local Ubuntu mirror on a PhotonOS server.

set -e

# 1. Install Dependencies using tdnf (PhotonOS package manager)
echo "Installing prerequisites (git, perl, wget, httpd)..."
tdnf install -y git perl wget httpd

# 2. Install apt-mirror manually (not available in PhotonOS repos)
# apt-mirror is a Perl script, so we can fetch it directly.
if [ ! -f /usr/local/bin/apt-mirror ]; then
    echo "Downloading and installing apt-mirror..."
    git clone https://github.com/apt-mirror/apt-mirror.git /tmp/apt-mirror
    cp /tmp/apt-mirror/apt-mirror /usr/local/bin/apt-mirror
    chmod +x /usr/local/bin/apt-mirror
    
    # Create necessary directories
    mkdir -p /etc/apt
    mkdir -p /var/spool/apt-mirror/var
    mkdir -p /var/spool/apt-mirror/skel
    mkdir -p /var/spool/apt-mirror/mirror
fi

# 3. Configure mirror.list
# This defines which Ubuntu files to pull.
# NOTE: Update the release (e.g., jammy) and components as per the original script if they differ.
echo "Creating /etc/apt/mirror.list configuration..."
cat <<EOF > /etc/apt/mirror.list
############# config ##################
#
set base_path    /var/spool/apt-mirror
#
# set mirror_path  \$base_path/mirror
# set skel_path    \$base_path/skel
# set var_path     \$base_path/var
# set cleanscript \$var_path/clean.sh
# set defaultarch  <running host architecture>
# set postmirror_script \$var_path/postmirror.sh
# set run_postmirror 0
set nthreads     20
set _tilde 0
#
############# end config ##############

# Ubuntu 22.04 (Jammy) Repositories - Standard VCF/VPAIF requirements
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted universe multiverse

# Clean up old packages
clean http://archive.ubuntu.com/ubuntu
EOF

# 4. Run apt-mirror to pull down the files
echo "Starting repository sync (this may take a long time)..."
/usr/local/bin/apt-mirror

# 5. Configure Web Server (httpd) to serve the repo
# Link the mirror path to the web server's document root
echo "Configuring httpd to serve the repository..."
if [ ! -d /var/www/html/ubuntu ]; then
    mkdir -p /var/www/html
    ln -s /var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu /var/www/html/ubuntu
fi

# Start and enable httpd service
systemctl enable httpd
systemctl start httpd

echo "----------------------------------------------------------------"
echo "Ubuntu repository setup complete."
echo "Repo is available at: http://$(hostname -I | awk '{print $1}')/ubuntu"
echo "----------------------------------------------------------------"