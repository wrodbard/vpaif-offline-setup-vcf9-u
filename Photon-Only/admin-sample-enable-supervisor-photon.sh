#!/bin/bash

###################################################
## Modify the three variables below to match your environment
###################################################
DEPLOYMENT_TYPE='NSX' # 'NSX' or 'VDS'

VCENTER_VERSION=8 # set to 7 for vCenter 7
VCENTER_HOSTNAME=chi-m03-vc02.set.lab
VCENTER_USERNAME=administrator@vsphere.local
VCENTER_PASSWORD='VMware@123!'
K8S_SUP_CLUSTER=airgapped  # Name of cluster where Supervisor is to be enabled
K8S_CONTENT_LIBRARY=local-vks # Not required for 8.0 online install
K8S_STORAGE_POLICY='vSAN Default Storage Policy'
K8S_MGMT_PORTGROUP='airgap-airgapped-vds-01-pg-mgmt'
K8S_WKD0_PORTGROUP='Workload0-VDS-PG' # Not required for NSX 
K8S_WKD1_PORTGROUP='Workload1-VDS-PG' # Not required for NSX

export DNS_SERVER='172.21.0.90'
export NTP_SERVER='172.29.0.50'
export DNS_SEARCHDOMAIN='set.lab'

export MGMT_STARTING_IP='172.29.0.35'
export MGMT_GATEWAY_IP='172.29.0.1'
export MGMT_SUBNETMASK='255.255.255.0'

#### AVI specific details. Not required for NSX.
export AVI_CLOUD='domain-c9'
export AVI_HOSTNAME=192.168.100.58
export AVI_USERNAME=admin
export AVI_PASSWORD='VMware1!'

#### NSX specifc details, Not required for VDS. 
export NSX_MANAGER='172.29.0.40'
export NSX_USERNAME='admin'
export NSX_PASSWORD='VMware@123!VMware@123!'
export NSX_EDGE_CLUSTER='vcf-w01-edge'
export NSX_T0_GATEWAY='ag-t0'
export NSX_DVS_PORTGROUP='airgap-airgapped-vds-01'
export NSX_INGRESS_CIDR='172.22.0.0/22'
export NSX_EGRESS_CIDR='172.22.10.0/23'
export NSX_NAMESPACE_NETWORK='10.244.0.0/19'

###################################################

# Photon OS Specific: Ensure dependencies are installed
# tdnf is the package manager for Photon OS
if ! command -v jq &> /dev/null || ! command -v envsubst &> /dev/null; then
    echo "Installing missing dependencies (jq, gettext)..."
    sudo tdnf install -y jq gettext curl
fi

HEADER_CONTENTTYPE="Content-Type: application/json"

content_library_json()
{
	cat <<EOF
{
	"name": "${K8S_CONTENT_LIBRARY}"
}
EOF
}

rm -f /tmp/temp_*.*

if [ "${DEPLOYMENT_TYPE}" = "VDS" ]
then
        # Ensure config files exist
        if [ ! -f "./config/sample-vds-80.json" ]; then
            echo "Error: ./config/sample-vds-80.json not found."
            exit 1
        fi
        cp ./config/sample-vds-80.json cluster.json

        ################################################
        # Get NSXALB CA CERT
        ###############################################
        echo "Getting NSX ALB CA Certificate for  ${AVI_HOSTNAME} ..."
        # Using -connect with explicit port and </dev/null is standard, but some minimal openssl versions can be picky
        openssl s_client -showcerts -connect ${AVI_HOSTNAME}:443  </dev/null 2>/dev/null|sed -ne '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > /tmp/temp_avi-ca.cert
        if [ ! -s /tmp/temp_avi-ca.cert ]
        then
                echo "Error: Could not connect to the NSX ALB endpoint. Please validate!!"
                exit 1
        fi
        export AVI_CACERT=$(jq -sR . /tmp/temp_avi-ca.cert)

else
        # Ensure config files exist
        if [ ! -f "./config/sample-nsx-80.json" ]; then
            echo "Error: ./config/sample-nsx-80.json not found."
            exit 1
        fi
        cp ./config/sample-nsx-80.json cluster.json
fi

################################################
# Login to VCenter and get Session ID
###############################################
SESSION_ID=$(curl -sk -X POST https://${VCENTER_HOSTNAME}/rest/com/vmware/cis/session --user ${VCENTER_USERNAME}:${VCENTER_PASSWORD} |jq -r '.value')
if [ -z "${SESSION_ID}" ] || [ "${SESSION_ID}" = "null" ]; then
	echo "Error: Could not connect to the VCenter. Please validate!!"
	exit 1
fi
echo Authenticated successfully to VC with Session ID - ${SESSION_ID} ...
HEADER_SESSIONID="vmware-api-session-id: ${SESSION_ID}"

################################################
# Get cluster details from vCenter
###############################################
echo "Searching for Cluster ${K8S_SUP_CLUSTER} ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/cluster --output /tmp/temp_cluster.json)
if [[ "${response}" -ne 200 ]] ; then
  echo "Error: Could not fetch clusters. Please validate!!"
  exit 1
fi

export TKGClusterID=$(jq -r --arg K8S_SUP_CLUSTER "$K8S_SUP_CLUSTER" '.[]|select(.name == $K8S_SUP_CLUSTER).cluster' /tmp/temp_cluster.json)
#export TKGClusterID=$(jq -r --arg K8S_SUP_CLUSTER "$K8S_SUP_CLUSTER" '.[]|select(.name|contains($K8S_SUP_CLUSTER)).cluster' /tmp/temp_cluster.json)
if [ -z "${TKGClusterID}" ]
then
        echo "Error: Could not fetch cluster - ${K8S_SUP_CLUSTER} . Please validate!!"
        exit 1
fi

################################################
# Get content library details from vCenter
###############################################
if [[ ${VCENTER_VERSION} -eq 7 ]] ; then

	echo "Searching for Content Library ${K8S_CONTENT_LIBRARY} ..."
	response=$(curl -ks --write-out "%{http_code}" -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "$(content_library_json)" https://${VCENTER_HOSTNAME}/api/content/library?action=find --output /tmp/temp_contentlib.json)
	if [[ "${response}" -ne 200 ]] ; then
  		echo "Error: Could not fetch content libraries. Please validate!!"
  		exit 1
	fi

	export TKGContentLibrary=$(jq -r '.[]' /tmp/temp_contentlib.json)
	if [ -z "${TKGContentLibrary}" ]
	then
        	echo "Error: Could not fetch content library - ${K8S_CONTENT_LIBRARY} . Please validate!!"
        	exit 1
	fi
	
    if [ ! -f "./config/sample-vds-70.json" ]; then
        echo "Error: ./config/sample-vds-70.json not found."
        exit 1
    fi
	cp ./config/sample-vds-70.json cluster.json
fi

################################################
# Get storage policy details from vCenter
###############################################
echo "Searching for Storage Policy ${K8S_STORAGE_POLICY} ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/storage/policies --output /tmp/temp_storagepolicies.json)
if [[ "${response}" -ne 200 ]] ; then
  echo "Error: Could not fetch storage policy. Please validate!!"
  exit 1
fi

export TKGStoragePolicy=$(jq -r --arg K8S_STORAGE_POLICY "$K8S_STORAGE_POLICY" '.[]| select(.name == $K8S_STORAGE_POLICY)|.policy' /tmp/temp_storagepolicies.json)
#export TKGStoragePolicy=$(jq -r --arg K8S_STORAGE_POLICY "$K8S_STORAGE_POLICY" '.[]| select(.name|contains($K8S_STORAGE_POLICY))|.policy' /tmp/temp_storagepolicies.json)
if [ -z "${TKGStoragePolicy}" ]
then
        echo "Error: Could not fetch storage policy - ${K8S_STORAGE_POLICY} . Please validate!!"
        exit 1
fi

################################################
# Get network details from vCenter
###############################################
echo "Searching for Network portgroups  ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/network --output /tmp/temp_networkportgroups.json)
if [[ "${response}" -ne 200 ]] ; then
  echo "Error: Could not fetch network details. Please validate!!"
  exit 1
fi

export TKGMgmtNetwork=$(jq -r --arg K8S_MGMT_PORTGROUP "$K8S_MGMT_PORTGROUP" '.[]| select(.name == $K8S_MGMT_PORTGROUP)|.network' /tmp/temp_networkportgroups.json)
export TKGWorkload0Network=$(jq -r --arg K8S_WKD0_PORTGROUP "$K8S_WKD0_PORTGROUP" '.[]| select(.name == $K8S_WKD0_PORTGROUP)|.network' /tmp/temp_networkportgroups.json)
export TKGWorkload1Network=$(jq -r --arg K8S_WKD1_PORTGROUP "$K8S_WKD1_PORTGROUP" '.[]| select(.name == $K8S_WKD1_PORTGROUP)|.network' /tmp/temp_networkportgroups.json)
if [ -z "${TKGMgmtNetwork}" ]
then
        echo "Error: Could not fetch portgroup - ${K8S_MGMT_PORTGROUP} . Please validate!!"
        exit 1
fi

if [ "${DEPLOYMENT_TYPE}" = "NSX" ]
then
        ################################################
        # Get a compatible VDS switch from vCenter
        ###############################################
        echo "Searching for NSX compatible VDS switch ..."
        response=$(curl -ks --write-out "%{http_code}" -X POST  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/namespace-management/networks/nsx/distributed-switches?action=check_compatibility --output /tmp/temp_vds.json)
        if [[ "${response}" -ne 200 ]] ; then
                echo "Error: Could not fetch VDS details. Please validate!!"
                exit 1
        fi
        export NSX_DVS=$(jq -r --arg NSX_DVS_PORTGROUP "$NSX_DVS_PORTGROUP" '.[]| select((.compatible==true) and .name == $NSX_DVS_PORTGROUP)|.distributed_switch' /tmp/temp_vds.json)
        if [ -z "${NSX_DVS}" ]
        then
                echo "Error: Could not fetch NSX compatible VDS - ${NSX_DVS_PORTGROUP} . Please validate!!"
                exit 1
        fi

        ################################################
        # Get a Edge cluster ID from NSX Manager
        ###############################################
        echo "Searching for Edge cluster in NSX Manager ..."
	response=$(curl -ks --write-out "%{http_code}" -X GET -u "${NSX_USERNAME}:${NSX_PASSWORD}" -H 'Content-Type: application/json' https://${NSX_MANAGER}/api/v1/edge-clusters --output /tmp/temp_edgeclusters.json)
        if [[ "${response}" -ne 200 ]] ; then
                echo "Error: Could not fetch Edge Cluster details. Please validate!!"
                exit 1
	fi
	export NSX_EDGE_CLUSTER_ID=$(jq -r --arg NSX_EDGE_CLUSTER "$NSX_EDGE_CLUSTER" '.results[] | select( .display_name == $NSX_EDGE_CLUSTER)|.id' /tmp/temp_edgeclusters.json)
        if [ -z "${NSX_EDGE_CLUSTER_ID}" ]
        then
                echo "Error: Could not fetch NSX Edge cluster - ${NSX_EDGE_CLUSTER} . Please validate!!"
                exit 1
        fi

        ################################################
        # Get a Tier0 ID from NSX Manager
        ###############################################
        echo "Searching for Tier0 in NSX Manager ..."
	response=$(curl -ks --write-out "%{http_code}" -X GET -u "${NSX_USERNAME}:${NSX_PASSWORD}" -H 'Content-Type: application/json' https://${NSX_MANAGER}/policy/api/v1/infra/tier-0s --output /tmp/temp_t0s.json)
        if [[ "${response}" -ne 200 ]] ; then
                echo "Error: Could not fetch Tier0 details. Please validate!!"
                exit 1
	fi
	export NSX_T0_GATEWAY_ID=$(jq -r --arg NSX_T0_GATEWAY "$NSX_T0_GATEWAY" '.results[] | select( .display_name == $NSX_T0_GATEWAY)|.id' /tmp/temp_t0s.json)
        if [ -z "${NSX_T0_GATEWAY_ID}" ]
        then
                echo "Error: Could not fetch NSX T0 - ${NSX_T0_GATEWAY} . Please validate!!"
                exit 1
        fi

	echo "Filtering Egress, Ingress and Namespace CIDR"
	export INGRESS_CIDR=$(echo "${NSX_INGRESS_CIDR}"|cut -d'/' -f1)
	export INGRESS_SIZE=$(echo "${NSX_INGRESS_CIDR}"|cut -d'/' -f2)
	export EGRESS_CIDR=$(echo "${NSX_EGRESS_CIDR}"|cut -d'/' -f1)
	export EGRESS_SIZE=$(echo "${NSX_EGRESS_CIDR}"|cut -d'/' -f2)
	export NAMESPACE_CIDR=$(echo "${NSX_NAMESPACE_NETWORK}"|cut -d'/' -f1)
	export NAMESPACE_SIZE=$(echo "${NSX_NAMESPACE_NETWORK}"|cut -d'/' -f2)
fi

################################################
# Get WORKLOAD Network for VDS
###############################################
if [ "${DEPLOYMENT_TYPE}" = "VDS" ]
then
        if [ -z "${TKGWorkload0Network}" ]
        then
                echo "Error: Could not fetch portgroup - ${K8S_WKD0_PORTGROUP} . Please validate!!"
                exit 1
        fi
        if [ -z "${TKGWorkload1Network}" ]
        then
                echo "Error: Could not fetch portgroup - ${K8S_WKD1_PORTGROUP} . Please validate!!"
                exit 1
        fi
fi

################################################
# Enable Supervisor and cleanup
###############################################
# envsubst is part of the 'gettext' package
envsubst < cluster.json > temp_final.json

echo "Enabling WCP on cluster ${TKGClusterID} ..."
curl -ks -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "@temp_final.json" https://${VCENTER_HOSTNAME}/api/vcenter/namespace-management/clusters/${TKGClusterID}?action=enable

# TODO while configuring, keep checking for the status of the Supervisor until ready

rm -f /tmp/temp_*.*
rm -f temp_final.json
rm -f cluster.json