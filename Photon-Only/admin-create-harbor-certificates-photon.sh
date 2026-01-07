#!/bin/bash
set -o pipefail
# Ensure config exists or handle error
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

mkdir -p "${REGISTRY_CERT_FOLDER}"

# Photon OS uses tdnf. Installing ca-certificates and openssl if missing.
sudo tdnf install -y ca-certificates openssl

cakeyfile=${REGISTRY_CERT_FOLDER}/$(hostname)-ca.key
cacrtfile=${REGISTRY_CERT_FOLDER}/$(hostname)-ca.crt

if [ ! -f "${cakeyfile}" ] || [ ! -f "${cacrtfile}" ]; then
  	echo "CA cert ${cacrtfile} and key ${cakeyfile} do not exist."
	echo "Generating them before generating the server certificate..."

	# Generate a CA Cert Private Key
	openssl genrsa -out "${cakeyfile}" 4096

	# Generate a CA Cert Certificate
	openssl req -x509 -new -nodes -sha512 -days 3650 -subj "/C=US/ST=VA/L=Ashburn/O=SE/OU=Personal/CN=$(hostname)" -key "${cakeyfile}" -out "${cacrtfile}"

    # Photon OS Specific: Copy to anchors and update trust
    echo "Installing CA certificate to Photon OS trust anchors..."
	sudo cp -p "${cacrtfile}" /etc/pki/ca-trust/source/anchors/$(hostname)-ca.crt
    
    echo "Updating system CA trust bundle..."
    sudo update-ca-trust extract

	echo 
	echo "CA Certificate created and added to trust store."
	echo "Location: /etc/pki/ca-trust/source/anchors/$(hostname)-ca.crt"
	echo
fi

if [ "$1" == "bootstrap" ]; then
	echo "Generating certificates for Bootstrap Registry"
	REGISTRY_NAME=${BOOTSTRAP_REGISTRY}
	REGISTRY_IP=${BOOTSTRAP_REGISTRY_IP}
elif [ "$1" == "platform" ]; then
	echo "Generating certificates for Platform Registry"
	REGISTRY_NAME=${PLATFORM_REGISTRY}
	REGISTRY_IP=${PLATFORM_REGISTRY_IP}
fi

# getent is part of glibc and standard on Photon
IPs=$(getent hosts "${REGISTRY_NAME}" | awk '{ print $1 }')
if [ -z "${IPs}" ]; then
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

# Generate a Server Certificate Private Key
openssl genrsa -out "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".key 4096

# Generate a Server Certificate Signing Request
openssl req -sha512 -new -subj "/C=US/ST=CA/L=PaloAlto/O=Engineering/OU=Harbor/CN=${REGISTRY_NAME}" -key "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".key -out "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".csr

# Generate a x509 v3 extension file
cat > "${REGISTRY_CERT_FOLDER}"/v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=${REGISTRY_NAME}
DNS.2=*.${REGISTRY_NAME}
IP.1=${REGISTRY_IP}
EOF

# Use the x509 v3 extension file to generate a cert for the Harbor hosts.
openssl x509 -req -sha512 -days 365 -extfile "${REGISTRY_CERT_FOLDER}"/v3.ext -CA "${cacrtfile}" -CAkey "${cakeyfile}" -CAcreateserial -in "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".csr -out "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".crt

echo "Harbor certificates generated successfully."