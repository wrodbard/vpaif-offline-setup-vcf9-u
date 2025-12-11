#!/bin/bash
set -o pipefail

# Ensure config exists
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

# Photon OS Specific: Install dependencies
# - jq: used for parsing JSON config
# - docker: required for pulling/running images
echo "Checking and installing dependencies (jq, docker)..."
sudo tdnf install -y jq docker

# Ensure Docker is started
if ! systemctl is-active --quiet docker; then
    echo "Starting Docker service..."
    sudo systemctl enable docker
    sudo systemctl start docker
fi

# Install Helm if missing (Helm is often not in default Photon repos, downloading binary)
if ! command -v helm >/dev/null 2>&1 ; then
    echo "Helm not found. Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
    echo "Helm installed successfully."
fi

# Check for 'pais' CLI (Private AI Service)
# This is a specialized tool and likely needs to be manually installed or provided in the bin dir.
if ! command -v pais >/dev/null 2>&1 ; then
    echo "Warning: 'pais' CLI not found. The model push steps at the end of this script will fail."
    echo "Please ensure the 'pais' binary is in your PATH."
fi

# Verify config json exists
if [ ! -f "./config/images.json" ]; then
    echo "Error: ./config/images.json not found."
    exit 1
fi

mapfile -t container_images < <(jq -r '.containers[]' './config/images.json')
mapfile -t helm_charts < <(jq -r '.helm[]' './config/images.json')
mapfile -t llm < <(jq -c '.models.llm[]' './config/images.json')
mapfile -t embedding < <(jq -c '.models.embedding[]' './config/images.json')

# update docker to ignore harbor self-signed cert
# Note: Ensure /etc/docker exists
if [ ! -d "/etc/docker" ]; then sudo mkdir -p /etc/docker; fi
if [ ! -f "/etc/docker/daemon.json" ]; then echo "{}" | sudo tee /etc/docker/daemon.json > /dev/null; fi

echo "Configuring Docker insecure registries..."
sudo jq ". += {\"insecure-registries\":[\"${BOOTSTRAP_REGISTRY}\"]}" /etc/docker/daemon.json > /tmp/temp.json && sudo mv /tmp/temp.json /etc/docker/daemon.json
sudo systemctl restart docker

# update certificate to ignore harbor self-signed cert
mkdir -p ./certificates
echo "Fetching certificate for $BOOTSTRAP_REGISTRY..."
openssl s_client -showcerts -servername "$BOOTSTRAP_REGISTRY" -connect "$BOOTSTRAP_REGISTRY:443" </dev/null 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ./certificates/"$BOOTSTRAP_REGISTRY".crt

# Photon OS Specific: Install Cert to Trust Anchors
echo "Installing CA certificate to Photon OS trust anchors..."
sudo cp ./certificates/"$BOOTSTRAP_REGISTRY".crt /etc/pki/ca-trust/source/anchors/"$BOOTSTRAP_REGISTRY".crt
sudo update-ca-trust extract

echo "Logging into Docker registries..."
# Note: Using --password-stdin is more secure if available, but sticking to provided structure
docker login "${BOOTSTRAP_REGISTRY}" -u "$BOOTSTRAP_REGISTRY_USERNAME" -p "$BOOTSTRAP_REGISTRY_PASSWORD"
docker login nvcr.io -u '$oauthtoken' -p "$NGC_API_KEY"

# pull images using docker
for image in "${container_images[@]}"; do
    echo "==> Start to pull container image: $image"
    # Logic to replace registry prefix
    version=$(echo "$image" | sed "s/^[^/]*\//$BOOTSTRAP_REGISTRY\/$BOOTSTRAP_NVIDIA_REPO\//")
    
    docker pull "$image"
    docker tag "$image" "$version"
    
    echo "==> Start to push container image: $version"
    docker push "$version"
done

# helm gpu-operator chart
for image in "${helm_charts[@]}"; do
    filename=""
    echo "==> Pulling helm charts... $image"
    # Ensure resources dir exists
    mkdir -p ./resources
    
    helm fetch "$image" --destination "./resources" --username='$oauthtoken' --password="$NGC_API_KEY"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to download helm chart: $image"
        # Continue or exit? Original script continued but logged error
    fi
    filename=$(basename "$image")
    target=oci://"$BOOTSTRAP_REGISTRY"/charts
    echo "==> Pushing helm chart $filename to $target"
	helm push "./resources/$filename" "$target" --insecure-skip-tls-verify --username "$BOOTSTRAP_REGISTRY_USERNAME" --password "$BOOTSTRAP_REGISTRY_PASSWORD"
done

# LLM model profiles
llm_output=()
for m in "${llm[@]}"; do
    name=$(echo "$m" | jq -r '.name')
    uri=$(echo "$m" | jq -r '.uri')

    profiles=$(echo "$m" | jq -c '.profiles[]')
    for profile in $profiles; do
        profile_name=$(echo "$profile" | jq -r '.profile_name')
        profile_id=$(echo "$profile" | jq -r '.profile_id')
        llm_output+=("$name, $uri, $profile_name, $profile_id")
    done
done

# Embedding model profiles
emb_output=()
for m in "${embedding[@]}"; do
    name=$(echo "$m" | jq -r '.name')
    uri=$(echo "$m" | jq -r '.uri')

    profiles=$(echo "$m" | jq -c '.profiles[]')
    for profile in $profiles; do
        profile_name=$(echo "$profile" | jq -r '.profile_name')
        profile_id=$(echo "$profile" | jq -r '.profile_id')
        emb_output+=("$name, $uri, $profile_name, $profile_id")
    done
done

# Pull all LLM model files
for item in "${llm_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"

    # Clean whitespace that IFS might miss if comma-space is used
    image_name=$(echo "$image_name" | xargs)
    uri=$(echo "$uri" | xargs)
    profile_name=$(echo "$profile_name" | xargs)
    profile_id=$(echo "$profile_id" | xargs)

    local_model_cache_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_cache
    local_model_store_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_model
    
    mkdir -p "$local_model_cache_path"
    mkdir -p "$local_model_store_path"

    echo "==> Pulling model: $image_name profile: $profile_name to $local_model_cache_path"

    # Note: Ensure the user running this script has permissions or use sudo for docker if not in docker group
    # Added -u 0 (root) inside container if volume permissions are tricky, but strictly following original:
    docker run -it --rm --name="$image_name" \
        -v "$local_model_cache_path":/opt/nim/.cache \
        -v "$local_model_store_path":/model-repo \
        -e NGC_API_KEY="$NGC_API_KEY" \
        $( [ -n "$HTTP_PROXY" ] && [ -n "$HTTPS_PROXY" ] && echo " -e http_proxy=$HTTP_PROXY -e https_proxy=$HTTPS_PROXY -e no_proxy=$NO_PROXY" ) \
        -u "$(id -u)" \
        "$uri" \
        bash -c "create-model-store --profile $profile_id --model-store /model-repo"
        
    if [ $? -ne 0 ]; then
        echo "Error: Failed to download model profile: $profile_name"
    fi
done

# Push LLM to bootstrap harbor
working_dir=$(pwd)
for item in "${llm_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"
    
    image_name=$(echo "$image_name" | xargs)
    profile_name=$(echo "$profile_name" | xargs)

    local_model_store_path="$working_dir/$BASTION_RESOURCES_DIR/$image_name/$profile_name"_model

    if [[ ! -d "$local_model_store_path" ]]; then
        echo "File not found: $local_model_store_path"
        continue
    fi
    cd "$local_model_store_path" || exit
    
    if command -v pais >/dev/null 2>&1; then
        echo "==> Pushing model: $local_model_store_path to model store: $BOOTSTRAP_REGISTRY/model-store/$image_name/$profile_name"
        pais models push --modelName "$image_name/$profile_name" --modelStore "$BOOTSTRAP_REGISTRY/model-store" -t v1
    else
        echo "Skipping push: 'pais' CLI not installed."
    fi
done

# Pull all embedding model files
cd "$working_dir" || exit
for item in "${emb_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"
    
    image_name=$(echo "$image_name" | xargs)
    uri=$(echo "$uri" | xargs)
    profile_name=$(echo "$profile_name" | xargs)
    profile_id=$(echo "$profile_id" | xargs)

    local_model_cache_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_cache
    local_model_store_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_model

    mkdir -p "$local_model_cache_path"
    mkdir -p "$local_model_store_path"

    echo "==> Pulling model: $image_name profile: $profile_name to $local_model_cache_path"
    docker run -it --rm --name="$image_name" \
        -v "$local_model_cache_path":/opt/nim/.cache \
        -v "$local_model_store_path":/model-repo \
        -e NGC_API_KEY="$NGC_API_KEY" \
        $( [ -n "$HTTP_PROXY" ] && [ -n "$HTTPS_PROXY" ] && echo " -e http_proxy=$HTTP_PROXY -e https_proxy=$HTTPS_PROXY -e no_proxy=$NO_PROXY" ) \
        -u "$(id -u)" \
        "$uri" \
        bash -c "download-to-cache --profile $profile_id"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to download model profile: $profile_name"
    fi

    # tar all embedding model files
    path="$BASTION_RESOURCES_DIR/$profile_name.tgz"
    tar -czvf "$path" -C "$local_model_cache_path" .
    mkdir -p "$BASTION_RESOURCES_DIR/$image_name/$profile_name"
    mv "$path" "$BASTION_RESOURCES_DIR/$image_name/$profile_name"
    echo "Archived: $path"
done
	
# Push embedding tar file.
for item in "${emb_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"
    
    image_name=$(echo "$image_name" | xargs)
    profile_name=$(echo "$profile_name" | xargs)

    local_model_store_path="$working_dir/$BASTION_RESOURCES_DIR/$image_name/$profile_name"

    if [[ ! -d "$local_model_store_path" ]]; then
        echo "File not found: $local_model_store_path"
        continue
    fi
    cd "$local_model_store_path" || exit
    
    if command -v pais >/dev/null 2>&1; then
        echo "==> Pushing model: $local_model_store_path  to model store: $BOOTSTRAP_REGISTRY/model-store/$image_name/$profile_name"
        pais models push --modelName "$image_name/$profile_name" --modelStore "$BOOTSTRAP_REGISTRY/model-store" -t v1
    else
        echo "Skipping push: 'pais' CLI not installed."
    fi
done

echo "Script execution completed."