#!/usr/bin/env bash

fetch_crd() {
    filename=${1%% *}
    kubectl get crds "$filename" -o yaml >"$TMP_CRD_DIR/$filename.yaml" 2>&1
}

# Check if python3 is installed
if ! command -v python3 &>/dev/null; then
    printf "python3 is required for this utility, and is not installed on your machine"
    printf "please visit https://www.python.org/downloads/ to install it"
    exit 1
fi
# Check if kubectl is installed
if ! command -v kubectl &>/dev/null; then
    printf "kubectl is required for this utility, and is not installed on your machine"
    printf "please visit https://kubernetes.io/docs/tasks/tools/#kubectl to install it"
    exit 1
fi
# Check if the major version is 4 or higher
if [[ ! ${BASH_VERSION%%.*} -ge 4 ]]; then
    printf "Bash version is lower than 4"
    printf "please visit https://www.gnu.org/software/bash/ to install it"
    exit 1
fi

# Check if the pyyaml module is installed
if ! echo 'import yaml' | python3 &>/dev/null; then
    printf "the python3 module 'yaml' is required, and is not installed on your machine.\n"

    while true; do
        read -p -r "Do you wish to install this program? (y/n) " yn
        case $yn in
        [Yy])
            pip3 install pyyaml
            break
            ;;
        "")
            pip3 install pyyaml
            break
            ;;
        [Nn])
            echo "Exiting..."
            exit
            ;;
        *) echo "Please answer 'y' (yes) or 'n' (no)." ;;
        esac
    done
fi

# Create temp folder for CRDs
TMP_CRD_DIR=$HOME/.datree/crds
mkdir -p "$TMP_CRD_DIR"

# Create final schemas directory
SCHEMAS_DIR=$HOME/.datree/crdSchemas
mkdir -p "$SCHEMAS_DIR"
cd "$SCHEMAS_DIR" || exit 1

# Get a list of all CRDs
printf "Fetching list of CRDs...\n"
IFS=$'\n' read -r -d '' -a CRD_LIST < <(kubectl get crds 2>&1 | sed -n '/NAME/,$p' | tail -n +2 && printf '\0')

# If no CRDs exist in the cluster, exit
if [ ${#CRD_LIST[@]} == 0 ]; then
    printf "No CRDs found in the cluster, exiting...\n"
    exit 0
fi

# Extract CRDs from cluster
FETCHED_CRDS=0
PARALLELISM=10
for crd in "${CRD_LIST[@]}"; do
    printf "Fetching CRD %s/%s...\n" $((FETCHED_CRDS + 1)) ${#CRD_LIST[@]}

    # Fetch CRD
    fetch_crd "$crd" &

    # allow to execute up to $PARALLELISM jobs in parallel
    if [[ $(jobs -r -p | wc -l) -ge $PARALLELISM ]]; then
        # now there are $PARALLELISM jobs already running, so wait here for any job
        # to be finished so there is a place to start next one.
        wait -n
    fi
    ((++FETCHED_CRDS))
done

# Download converter script
curl https://raw.githubusercontent.com/yannh/kubeconform/master/scripts/openapi2jsonschema.py --output "$TMP_CRD_DIR/openapi2jsonschema.py" 2>/dev/null

# Fetch OpenAPI v2 schema for CRD validation
kubectl get --raw /openapi/v2 > "$TMP_CRD_DIR/openapi_v2.yaml"

# Convert crds to jsonSchema
FILENAME_FORMAT="{fullgroup}_{kind}_{version}" python3 "$TMP_CRD_DIR/openapi2jsonschema.py" "$TMP_CRD_DIR"/*.yaml "$TMP_CRD_DIR/openapi_v2.yaml" &>/dev/null
conversionResult=$?

# Copy and rename files to support kubeval
rm -rf "$SCHEMAS_DIR/master-standalone"
mkdir -p "$SCHEMAS_DIR/master-standalone"
cp "$SCHEMAS_DIR"/*.json "$SCHEMAS_DIR/master-standalone" 2>/dev/null
find "$SCHEMAS_DIR/master-standalone" -name '*json' -exec bash -c ' mv -f $0 ${0/\_/-stable-}' {} \; 2>/dev/null

# Organize schemas by group
for schema in "$SCHEMAS_DIR"/*.json; do
    # Skip if no files match the pattern
    [[ -f "$schema" ]] || continue
    
    crdFileName=$(basename "$schema")
    crdGroup=$(echo "$crdFileName" | cut -d"_" -f1)
    outName=$(echo "$crdFileName" | cut -d"_" -f2-)
    mkdir -p "$SCHEMAS_DIR/$crdGroup"
    mv "$schema" "$SCHEMAS_DIR/$crdGroup/$outName"
done

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

if [ $conversionResult == 0 ]; then
    printf "${GREEN}Successfully converted $FETCHED_CRDS CRDs to JSON schema${NC}\n\n"
    
    # List schemas in organized groups
    if [ -f "$SCHEMAS_DIR/apiextensions.k8s.io/customresourcedefinition_v1.json" ]; then
        printf "CRD validation schema written to apiextensions.k8s.io/customresourcedefinition_v1.json\n\n"
    fi
    
    # List CRD schemas first (excluding master-standalone and CRD schema)
    find "$SCHEMAS_DIR" -type f -path "*/customresourcedefinition_v1.json" -prune -o -name "*.json" ! -path "*/master-standalone/*" -print | sort | while read -r schema; do
        printf "JSON schema written to %s\n" "$(basename "$(dirname "$schema")")/$(basename "$schema")"
    done
    
    printf "\nTo validate a CR using various tools, run the relevant command:\n"
    printf "\n- ${CYAN}datree:${NC}\n\$ datree test /path/to/file\n"
    printf "\n- ${CYAN}kubeconform:${NC}\n\$ kubeconform -summary -output json -schema-location default -schema-location '$HOME/.datree/crdSchemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' /path/to/file\n"
    printf "\n- ${CYAN}kubeval:${NC}\n\$ kubeval --additional-schema-locations file:\"$HOME/.datree/crdSchemas\" /path/to/file\n\n"
fi

rm -rf "$TMP_CRD_DIR"