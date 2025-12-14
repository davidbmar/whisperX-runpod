#!/bin/bash
# =============================================================================
# RunPod Create Pod - Launch a GPU Pod for WhisperX
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Creates a RunPod GPU pod using the REST API
#   2. Waits for pod to be ready
#   3. Saves pod ID to .env for other scripts
#
# PREREQUISITES:
#   - RunPod account with API key
#   - Docker image pushed to Docker Hub (110-build--push-to-dockerhub.sh)
#
# Usage: ./scripts/300-runpod--create-pod.sh [OPTIONS]
#
# Options:
#   --gpu TYPE      GPU type (default: NVIDIA RTX A4000)
#   --name NAME     Pod name (default: from .env)
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="300-runpod--create-pod"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_REST_API="https://rest.runpod.io/v1"
GPU_TYPE=""
POD_NAME=""

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu)
            GPU_TYPE="$2"
            shift 2
            ;;
        --name)
            POD_NAME="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--gpu TYPE] [--name NAME]"
            echo ""
            echo "Create a RunPod GPU pod for WhisperX."
            echo ""
            echo "Options:"
            echo "  --gpu TYPE    GPU type (default: NVIDIA RTX A4000)"
            echo "  --name NAME   Pod name"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Creating RunPod pod"

    # Load environment
    load_env_or_fail

    # Set defaults from env
    GPU_TYPE="${GPU_TYPE:-${GPU_TYPE:-NVIDIA RTX A4000}}"
    POD_NAME="${POD_NAME:-${RUNPOD_ENDPOINT_NAME:-whisperx-pod}}"

    local docker_image="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG:-latest}"

    print_status "info" "Creating RunPod GPU Pod"
    echo ""
    echo "  Name: $POD_NAME"
    echo "  GPU: $GPU_TYPE"
    echo "  Image: $docker_image"
    echo ""

    # Check if pod already exists
    if [ -n "${RUNPOD_POD_ID:-}" ] && [ "$RUNPOD_POD_ID" != "" ]; then
        print_status "warn" "Pod ID already configured: $RUNPOD_POD_ID"
        echo ""
        echo "To create a new pod, first delete the existing one:"
        echo "  ./scripts/340-runpod--stop-pod.sh"
        exit 1
    fi

    # Create pod via REST API
    print_status "info" "Calling RunPod API..."

    local response=$(curl -s -X POST "${RUNPOD_REST_API}/pods" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "'"$POD_NAME"'",
            "imageName": "'"$docker_image"'",
            "gpuTypeId": "'"$GPU_TYPE"'",
            "gpuCount": 1,
            "volumeInGb": 0,
            "containerDiskInGb": 50,
            "ports": "8000/http",
            "env": {
                "WHISPER_MODEL": "'"${WHISPER_MODEL:-small}"'",
                "WHISPER_COMPUTE_TYPE": "'"${WHISPER_COMPUTE_TYPE:-float16}"'",
                "HF_TOKEN": "'"${HF_TOKEN:-}"'",
                "ENABLE_DIARIZATION": "'"${ENABLE_DIARIZATION:-true}"'"
            }
        }')

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Failed to create pod"
        echo "$response" | jq .
        exit 1
    fi

    # Extract pod ID
    local pod_id=$(echo "$response" | jq -r '.id // .podId // empty')

    if [ -z "$pod_id" ]; then
        print_status "error" "No pod ID in response"
        echo "$response" | jq .
        exit 1
    fi

    print_status "ok" "Pod created: $pod_id"

    # Save pod ID to .env
    update_env_file "RUNPOD_POD_ID" "$pod_id"
    print_status "ok" "Saved pod ID to .env"

    # Wait for pod to be ready
    print_status "info" "Waiting for pod to start..."

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        sleep 10

        local status_response=$(curl -s "${RUNPOD_REST_API}/pods/${pod_id}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        local status=$(echo "$status_response" | jq -r '.desiredStatus // .status // "unknown"')
        local runtime=$(echo "$status_response" | jq -r '.runtime // {}')

        echo "  Attempt $attempt/$max_attempts: Status = $status"

        if [ "$status" = "RUNNING" ]; then
            # Get pod IP/URL
            local pod_ip=$(echo "$status_response" | jq -r '.runtime.ports[0].ip // empty')
            local pod_port=$(echo "$status_response" | jq -r '.runtime.ports[0].publicPort // empty')

            if [ -n "$pod_ip" ] && [ -n "$pod_port" ]; then
                echo ""
                print_status "ok" "============================================"
                print_status "ok" "RunPod pod is ready!"
                print_status "ok" "============================================"
                echo ""
                echo "Pod ID: $pod_id"
                echo "API URL: http://${pod_ip}:${pod_port}"
                echo ""
                echo "Next step: ./scripts/320-runpod--test-api.sh --host $pod_ip --port $pod_port"
                return 0
            fi
        fi

        attempt=$((attempt + 1))
    done

    print_status "warn" "Pod may still be starting. Check status with:"
    echo "  curl -s '${RUNPOD_REST_API}/pods/${pod_id}' -H 'Authorization: Bearer \$RUNPOD_API_KEY' | jq"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
