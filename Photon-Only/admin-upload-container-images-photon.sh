#!/bin/bash
set -o pipefail

# Check for config file
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <bootstrap|platform>"
	exit 1
fi

# Photon OS Specific: Install dependencies via tdnf
# - unzip: required for extracting vsphere-plugin.zip
# - jq: required for JSON parsing
# - gettext: required for 'envsubst'
# - nginx: required for the mirror setup at the end
echo "Checking and installing dependencies (curl, wget, unzip, jq, gettext, nginx)..."
sudo tdnf install -y curl wget unzip jq gettext nginx

if ! command -v curl >/dev/null 2>&1 ; then
	echo "Error: curl installation failed."
	exit 1
fi

if ! command -v wget >/dev/null 2>&1 ; then
	echo "Error: wget installation failed."
	exit 1
fi

# Tanzu CLI Check and Installation
if ! command -v tanzu >/dev/null 2>&1 ; then
	echo "Tanzu CLI missing. Installing from tarball..."
    if [ -f "$DOWNLOAD_DIR_BIN/tanzu-cli-linux-amd64.tar.gz" ]; then
  	    tar -xzvf "$DOWNLOAD_DIR_BIN"/tanzu-cli-linux-amd64.tar.gz -C "$DOWNLOAD_DIR_BIN"
	    sudo mv "$DOWNLOAD_DIR_BIN"/v1.1.0/tanzu* /usr/local/bin/tanzu
    else
        echo "Error: Tanzu CLI tarball not found at $DOWNLOAD_DIR_BIN/tanzu-cli-linux-amd64.tar.gz"
        exit 1
    fi
else
    if ! tanzu imgpkg --help > /dev/null 2>&1 ; then 
		mkdir -p ~/.local/share/tanzu-cli/
        if [ -f "$DOWNLOAD_DIR_BIN/tanzu-cli-plugins.tar.gz" ]; then
		    tar -xzvf "$DOWNLOAD_DIR_BIN"/tanzu-cli-plugins.tar.gz -C  ~/.local/share/tanzu-cli/
		    tanzu plugin source update default --uri "$BOOTSTRAP_REGISTRY/tanzu-plugins/plugin-inventory:latest"
		    tanzu plugin install --group vmware-vsphere/default
		    tanzu config cert add --host "$BOOTSTRAP_REGISTRY" --insecure true --skip-cert-verify true
        else
            echo "Error: Tanzu plugins tarball not found."
        fi
    fi
fi

# Kubectl CLI Check
if ! command -v kubectl >/dev/null 2>&1 ; then
	echo "Error: Kubectl CLI missing. Please install Kubectl CLI manually or via tdnf (kubernetes-cli)."
  	exit 1
else
    # vsphere-plugin Check
    if ! kubectl vsphere --help > /dev/null 2>&1 ; then 
        echo "Downloading vSphere Plugin from $K8S_SUPERVISOR_IP..."
		wget --no-check-certificate https://"${K8S_SUPERVISOR_IP}"/wcp/plugin/linux-amd64/vsphere-plugin.zip -O /tmp/vsphere-plugin.zip
		if [ $? -ne 0 ]; then
			echo "Error: Could not download the vsphere-plugin.zip. Please validate if the Supervisor is running and the IP is valid!!"
			exit 1
		fi
		unzip -o /tmp/vsphere-plugin.zip -d /tmp/vsphere-plugin
		sudo install /tmp/vsphere-plugin/bin/kubectl-vsphere /usr/local/bin/kubectl-vsphere
    fi
fi

# YQ Check
if ! command -v yq >/dev/null 2>&1 ; then
	echo "Error: yq missing. Please install yq CLI first (binary download usually required for Photon)."
	exit 1
fi

# The main code
if [ "$1" = "bootstrap" ]; then
	echo "Bootstrap Supervisor Services"
	REGISTRY_NAME=${BOOTSTRAP_REGISTRY}
	REGISTRY_IP=${BOOTSTRAP_REGISTRY_IP}
	REGISTRY_URL=${BOOTSTRAP_REGISTRY}/${BOOTSTRAP_SUPSVC_REPO}
	REGISTRY_URL1=${BOOTSTRAP_REGISTRY}/${BOOTSTRAP_TNZPKG_REPO}
	REGISTRY_USERNAME=${BOOTSTRAP_REGISTRY_USERNAME}
	REGISTRY_PASSWORD=${BOOTSTRAP_REGISTRY_PASSWORD}
elif [ "$1" = "platform" ]; then
	echo "Platform Supervisor Services"
	REGISTRY_NAME=${PLATFORM_REGISTRY}
	REGISTRY_IP=${PLATFORM_REGISTRY_IP}
	REGISTRY_URL=${PLATFORM_REGISTRY}/${PLATFROM_SUPSVC_REPO}
	REGISTRY_URL1=${PLATFORM_REGISTRY}/${PLATFROM_TNZSVC_REPO}
	REGISTRY_USERNAME=${PLATFORM_REGISTRY_USERNAME}
	REGISTRY_PASSWORD=${PLATFORM_REGISTRY_PASSWORD}
fi

IPs=$(getent hosts "${REGISTRY_NAME}" | awk '{ print $1 }')
if [[ -z "${IPs}" ]]; then
	echo "Error: Could not resolve the IP address for ${REGISTRY_NAME}. Please validate!!"
	exit 1
fi

found=false
for ip in "${IPs[@]}"; do
  	if [[ "$ip" == "${REGISTRY_IP}" ]]; then
		found=true
		break
  	fi
done

if [ "$found" = false ]; then
  	echo "Error: Could not resolve the IP address ${REGISTRY_IP} for ${REGISTRY_NAME}. Please validate!!"
  	exit 1
fi

mkdir -p ./certificates
# get certificate from harbor
openssl s_client -showcerts -servername "$REGISTRY_NAME" -connect "$REGISTRY_NAME:443" </dev/null 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ./certificates/"$REGISTRY_NAME".crt

HEADER_CONTENTTYPE="Content-Type: application/json"
################################################
# Login to VCenter and get Session ID
###############################################
SESSION_ID=$(curl -sk -X POST https://${VCENTER_HOSTNAME}/rest/com/vmware/cis/session --user ${VCENTER_USERNAME}:${VCENTER_PASSWORD} |jq -r '.value')
if [ -z "${SESSION_ID}" ] || [ "${SESSION_ID}" = "null" ]; then
	echo "Error: Could not connect to the VCenter. Please validate!!"
	exit 1
fi
echo Authenticated successfully to VC with Session ID - "${SESSION_ID}" ...
HEADER_SESSIONID="vmware-api-session-id: ${SESSION_ID}"

################################################
# Get Supervisor details from vCenter
###############################################
echo "Searching for Supervisor on Cluster ${K8S_SUP_CLUSTER} ..."
response=$(curl -ks --write-out "%{http_code}" --output /tmp/temp_cluster.json -X GET -H "${HEADER_SESSIONID}" https://"${VCENTER_HOSTNAME}"/api/vcenter/namespace-management/supervisors/summaries?config_status=RUNNING&kubernetes_status=READY)
if [[ "${response}" -ne 200 ]] ; then
  	echo "Error: Could not fetch clusters. Please validate!!"
	exit 1
fi

SUPERVISOR_ID=$(jq -r --arg K8S_SUP_CLUSTER "$K8S_SUP_CLUSTER" '.items[] | select(.info.name == $K8S_SUP_CLUSTER) | .supervisor' /tmp/temp_cluster.json)
if [ -z "${SUPERVISOR_ID}" ]; then
	echo "Error: Could not find the Supervisor Cluster ${K8S_SUP_CLUSTER}. Please validate!!"
	exit 1
fi

################################################
# Add the registry to the vCenter
###############################################
echo "Found Supervisor Cluster ${K8S_SUP_CLUSTER} with Supervisor ID - ${SUPERVISOR_ID} ..."
export REGISTRY_CACERT=$(jq -sR . "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".crt)
export REGISTRY_NAME
export REGISTRY_PASSWORD
export REGISTRY_USERNAME

if [ -f "./config/registry-spec.json" ]; then
    envsubst < ./config/registry-spec.json > temp_registry.json
    echo "Adding Registry ${REGISTRY_NAME} to ${VCENTER_HOSTNAME} ..."
    response=$(curl -ks --write-out "%{http_code}" --output /tmp/status.json  -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "@temp_registry.json" https://"${VCENTER_HOSTNAME}"/api/vcenter/namespace-management/supervisors/"${SUPERVISOR_ID}"/container-image-registries)
    echo "Response Code: $response"
else
    echo "Warning: ./config/registry-spec.json not found. Skipping registry registration."
fi

echo "Scanning YML directory: $DOWNLOAD_DIR_YML"

for file in "${DOWNLOAD_DIR_YML}"/supsvc-*.yaml; do
    # Check if file exists to handle empty glob
    [ -e "$file" ] || continue
    
	echo "Processing $file"
	full_filename=$(basename "$file")
	file_name="${full_filename%.yaml}"
	stripped=$(echo -n "$file_name" | sed 's/supsvc-//g') # strip the supsvc- from filename
    image=$(yq -P '(.|select(.kind == "Package").spec.template.spec.fetch[].imgpkgBundle.image)' "$file")
	
    if [ "$image" ]; then
		if [[ "$image" == *"${REGISTRY_URL}"* ]]; then
			echo Now uploading "${DOWNLOAD_DIR_TAR}"/"$file_name".tar ...
			tanzu imgpkg copy --tar "${DOWNLOAD_DIR_TAR}"/"$file_name".tar --to-repo "${REGISTRY_URL}"/"$stripped" --cosign-signatures --registry-ca-cert-path ./certificates/$REGISTRY_NAME.crt --registry-username "${REGISTRY_USERNAME}" --registry-password "${REGISTRY_PASSWORD}"

			echo "Processing file - ${file} ..."
			export FILE_CONTENT=$(base64 "${file}" -w0)

            if [ -f "./config/carvel-spec.json" ]; then
			    envsubst < ./config/carvel-spec.json > temp_final.json
			    echo "Adding Supervisor Service to ${VCENTER_HOSTNAME}  ..."
			    curl -ks -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "@temp_final.json" https://"${VCENTER_HOSTNAME}"/api/vcenter/namespace-management/supervisor-services
            else
                echo "Warning: ./config/carvel-spec.json not found."
            fi
		fi
	fi
done

################################################
# setup nginx
################################################
echo "Configuring Nginx..."
cat > /etc/nginx/conf.d/mirror.conf << EOF
server {
 listen 80;
 server_name $HTTP_HOST;
 root /data/debs/;

 location / {
   autoindex on;
 }
}
EOF

# Ensure the root directory exists
mkdir -p /data/debs/

# Enable and start nginx on Photon OS
sudo systemctl enable nginx
sudo systemctl restart nginx

################################################
# copy the kubernetes deployment files to the 
# nginx location to be downloaded during deployments.
################################################
if ls gpu-operator/gpu-operator* 1> /dev/null 2>&1; then
    echo "Copying GPU operator files..."
    cp gpu-operator/gpu-operator* "$REPO_LOCATION"/debs/
else
    echo "No GPU operator files found to copy."
fi

echo "Script execution completed."