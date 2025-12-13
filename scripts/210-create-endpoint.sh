#!/bin/bash
# =============================================================================
# Create RunPod Serverless Endpoint
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Validates RunPod API key and configuration
#   2. Creates a new serverless endpoint via RunPod GraphQL API
#   3. Configures GPU type, scaling, and environment variables
#   4. Saves endpoint ID to .env for future use
#
# PREREQUISITES:
#   - Docker image pushed to registry (run 205-push-to-registry.sh first)
#   - RunPod API key configured in .env
#
# CONFIGURATION:
#   All settings read from .env file:
#   - RUNPOD_API_KEY: RunPod API key
#   - RUNPOD_ENDPOINT_NAME: Name for the endpoint
#   - GPU_TYPE: GPU type to use
#   - WHISPER_MODEL: Model configuration
#   - HF_TOKEN: HuggingFace token for diarization
#
# Usage: ./scripts/210-create-endpoint.sh [OPTIONS]
#
# Options:
#   --help       Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="210-create-endpoint"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Start logging
start_logging "$SCRIPT_NAME"

# =============================================================================
# RunPod GraphQL API
# =============================================================================

RUNPOD_GRAPHQL_URL="https://api.runpod.io/graphql"

runpod_graphql() {
    local query="$1"

    curl -s -X POST "$RUNPOD_GRAPHQL_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -d "$query"
}

# Map GPU type to RunPod GPU ID
get_gpu_id() {
    local gpu_type="$1"

    case "$gpu_type" in
        "NVIDIA RTX A4000")
            echo "NVIDIA RTX A4000"
            ;;
        "NVIDIA RTX A5000")
            echo "NVIDIA RTX A5000"
            ;;
        "NVIDIA RTX A6000")
            echo "NVIDIA RTX A6000"
            ;;
        "NVIDIA GeForce RTX 3090")
            echo "NVIDIA GeForce RTX 3090"
            ;;
        "NVIDIA L4")
            echo "NVIDIA L4"
            ;;
        *)
            echo "NVIDIA RTX A4000"
            ;;
    esac
}

# =============================================================================
# Main Create Process
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting RunPod endpoint creation"

    # =========================================================================
    # Load Environment
    # =========================================================================

    load_env_or_fail

    local docker_image="docker.io/${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG}"
    local gpu_id=$(get_gpu_id "$GPU_TYPE")

    json_log "$SCRIPT_NAME" "config" "ok" "Configuration loaded" \
        "endpoint_name=$RUNPOD_ENDPOINT_NAME" \
        "image=$docker_image" \
        "gpu=$gpu_id"

    # =========================================================================
    # Check for Existing Endpoint
    # =========================================================================

    if [ -n "${RUNPOD_ENDPOINT_ID:-}" ] && [ "$RUNPOD_ENDPOINT_ID" != "TO_BE_DISCOVERED" ]; then
        print_status "warn" "Endpoint ID already configured: $RUNPOD_ENDPOINT_ID"
        echo ""
        echo "Options:"
        echo "  1. Delete existing endpoint first: ./scripts/915-runpod-delete.sh"
        echo "  2. Or manually update RUNPOD_ENDPOINT_ID in .env"
        echo ""
        read -p "Continue anyway and create a new endpoint? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi

    # =========================================================================
    # Validate RunPod API Key
    # =========================================================================

    print_status "info" "Validating RunPod API key..."

    local validate_query='{"query":"query { myself { id email } }"}'
    local validate_response=$(runpod_graphql "$validate_query")

    if echo "$validate_response" | jq -e '.errors' &>/dev/null; then
        json_log "$SCRIPT_NAME" "api_validate" "error" "Invalid API key"
        print_status "error" "Invalid RunPod API key"
        exit 1
    fi

    local user_email=$(echo "$validate_response" | jq -r '.data.myself.email // "unknown"')
    json_log "$SCRIPT_NAME" "api_validate" "ok" "API key validated" "user=$user_email"
    print_status "ok" "API key valid for: $user_email"

    # =========================================================================
    # Create Endpoint
    # =========================================================================

    print_status "info" "Creating RunPod serverless endpoint..."
    echo ""
    echo "Configuration:"
    echo "  Name: $RUNPOD_ENDPOINT_NAME"
    echo "  Image: $docker_image"
    echo "  GPU: $gpu_id"
    echo "  Model: $WHISPER_MODEL"
    echo "  Diarization: ${ENABLE_DIARIZATION:-true}"
    echo ""

    # Build environment variables JSON
    local env_vars="["
    env_vars+="{\"key\":\"WHISPER_MODEL\",\"value\":\"$WHISPER_MODEL\"},"
    env_vars+="{\"key\":\"WHISPER_COMPUTE_TYPE\",\"value\":\"${WHISPER_COMPUTE_TYPE:-float16}\"},"
    env_vars+="{\"key\":\"WHISPER_BATCH_SIZE\",\"value\":\"${WHISPER_BATCH_SIZE:-16}\"},"
    env_vars+="{\"key\":\"ENABLE_DIARIZATION\",\"value\":\"${ENABLE_DIARIZATION:-true}\"}"

    if [ -n "${HF_TOKEN:-}" ]; then
        env_vars+=",{\"key\":\"HF_TOKEN\",\"value\":\"$HF_TOKEN\"}"
    fi

    env_vars+="]"

    # Create endpoint mutation
    local create_query=$(cat <<EOF
{
    "query": "mutation {
        saveEndpoint(input: {
            name: \"$RUNPOD_ENDPOINT_NAME\"
            templateId: null
            gpuIds: \"$gpu_id\"
            networkVolumeId: null
            locations: null
            idleTimeout: 5
            scalerType: \"QUEUE_DELAY\"
            scalerValue: 4
            workersMin: 0
            workersMax: 3
            dockerArgs: \"\"
            env: $env_vars
            imageName: \"$docker_image\"
        }) {
            id
            name
            gpuIds
        }
    }"
}
EOF
)

    # Clean up the query (remove newlines for valid JSON)
    create_query=$(echo "$create_query" | tr '\n' ' ' | sed 's/  */ /g')

    local create_response=$(runpod_graphql "$create_query")

    # Check for errors
    if echo "$create_response" | jq -e '.errors' &>/dev/null; then
        local error_msg=$(echo "$create_response" | jq -r '.errors[0].message // "Unknown error"')
        json_log "$SCRIPT_NAME" "create_endpoint" "error" "Failed to create endpoint: $error_msg"
        print_status "error" "Failed to create endpoint: $error_msg"
        echo ""
        echo "Full response:"
        echo "$create_response" | jq .
        exit 1
    fi

    # Extract endpoint ID
    local endpoint_id=$(echo "$create_response" | jq -r '.data.saveEndpoint.id // empty')

    if [ -z "$endpoint_id" ]; then
        json_log "$SCRIPT_NAME" "create_endpoint" "error" "No endpoint ID in response"
        print_status "error" "Failed to get endpoint ID from response"
        echo "$create_response" | jq .
        exit 1
    fi

    json_log "$SCRIPT_NAME" "create_endpoint" "ok" "Endpoint created" "id=$endpoint_id"

    # =========================================================================
    # Save Endpoint ID
    # =========================================================================

    update_env_file "RUNPOD_ENDPOINT_ID" "$endpoint_id"

    # Also save to artifacts
    mkdir -p "$ARTIFACTS_DIR"
    cat > "$ARTIFACTS_DIR/endpoint.json" << EOF
{
    "endpoint_id": "$endpoint_id",
    "endpoint_name": "$RUNPOD_ENDPOINT_NAME",
    "docker_image": "$docker_image",
    "gpu_type": "$gpu_id",
    "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

    json_log "$SCRIPT_NAME" "save_config" "ok" "Endpoint ID saved to .env and artifacts"

    # =========================================================================
    # Summary
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "RunPod endpoint created successfully!"
    print_status "ok" "============================================"
    echo ""
    echo "Endpoint ID: $endpoint_id"
    echo "Endpoint Name: $RUNPOD_ENDPOINT_NAME"
    echo "GPU Type: $gpu_id"
    echo ""
    echo "API URL: https://api.runpod.ai/v2/$endpoint_id/runsync"
    echo ""
    echo "View in console: https://www.runpod.io/console/serverless"
    echo ""
    echo "Note: The endpoint may take a few minutes to become ready."
    echo ""
    echo "Next step: ./scripts/215-test-endpoint.sh"
    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
