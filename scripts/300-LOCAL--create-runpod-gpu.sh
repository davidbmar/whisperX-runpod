#!/bin/bash
# =============================================================================
# 300-LOCAL--create-runpod-gpu.sh
# =============================================================================
# Creates a RunPod GPU Pod for WhisperX transcription
#
# WHAT THIS SCRIPT DOES:
#   1. Validates your RunPod API key and configuration
#   2. Lists available GPU types with pricing
#   3. Creates a GPU pod with your Docker image
#   4. Waits for the pod to become ready
#   5. Saves the pod ID and endpoint URL to .env
#
# PREREQUISITES:
#   - RunPod account with API key (https://www.runpod.io/console/user/settings)
#   - Docker image pushed to Docker Hub (110-build--push-to-dockerhub.sh)
#   - .env file configured (010-setup--configure-environment.sh)
#
# DEBUGGING:
#   - All output is logged to logs/300-LOCAL--create-runpod-gpu-TIMESTAMP.log
#   - Use --debug flag for verbose API responses
#   - Check RunPod console: https://www.runpod.io/console/pods
#
# Usage: ./scripts/300-LOCAL--create-runpod-gpu.sh [OPTIONS]
#
# Options:
#   --gpu TYPE      GPU type ID (default: NVIDIA GeForce RTX 3070 - cheapest)
#                   Cheap options: "NVIDIA GeForce RTX 3070" ($0.13/hr, 8GB)
#                                  "NVIDIA RTX A4000" ($0.17/hr, 16GB)
#                                  "NVIDIA GeForce RTX 3080" ($0.17/hr, 10GB)
#   --list-gpus     List available GPU types and exit
#   --name NAME     Pod name (default: whisperx-TIMESTAMP)
#   --debug         Show full API responses
#   --help          Show this help message
#
# Examples:
#   ./scripts/300-LOCAL--create-runpod-gpu.sh
#   ./scripts/300-LOCAL--create-runpod-gpu.sh --gpu "NVIDIA RTX 4090"
#   ./scripts/300-LOCAL--create-runpod-gpu.sh --list-gpus
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="300-LOCAL--create-runpod-gpu"
SCRIPT_VERSION="2.0.0"

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
DEBUG_MODE=false
LIST_GPUS=false

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
        --list-gpus)
            LIST_GPUS=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --help)
            head -50 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Debug Helper
# =============================================================================

debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN:-}[DEBUG] $1${NC:-}"
    fi
}

debug_json() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN:-}[DEBUG] API Response:${NC:-}"
        echo "$1" | jq . 2>/dev/null || echo "$1"
        echo ""
    fi
}

# =============================================================================
# List Available GPUs
# =============================================================================

list_available_gpus() {
    print_status "info" "Fetching available GPU types from RunPod..."
    echo ""

    local response=$(curl -s "${RUNPOD_REST_API}/gpus" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json")

    debug_json "$response"

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Failed to fetch GPU types"
        echo "$response" | jq .
        return 1
    fi

    echo "============================================"
    echo "Available GPU Types on RunPod"
    echo "============================================"
    echo ""
    printf "%-30s %-10s %-12s %s\n" "GPU Type" "VRAM" "Price/hr" "Available"
    printf "%-30s %-10s %-12s %s\n" "--------" "----" "--------" "---------"

    echo "$response" | jq -r '.[] | "\(.id)|\(.memoryInGb)GB|\($"\(.securePrice // .communityPrice // "N/A")")|\(.availableStock // "?")"' 2>/dev/null | \
    while IFS='|' read -r id vram price avail; do
        printf "%-30s %-10s \$%-11s %s\n" "$id" "$vram" "$price" "$avail"
    done

    echo ""
    echo "Recommended for WhisperX:"
    echo "  - small/medium models: NVIDIA RTX A4000 (16GB, ~\$0.20/hr)"
    echo "  - large-v2 model:      NVIDIA RTX A5000 (24GB, ~\$0.30/hr)"
    echo "  - large-v3 model:      NVIDIA A40 (48GB, ~\$0.40/hr)"
    echo ""
}

# =============================================================================
# Create Pod
# =============================================================================

create_pod() {
    local gpu_type="$1"
    local pod_name="$2"
    local docker_image="$3"

    print_status "info" "Creating RunPod GPU Pod..."
    echo ""
    echo "  Configuration:"
    echo "  ─────────────────────────────────────────"
    echo "  Pod Name:     $pod_name"
    echo "  GPU Type:     $gpu_type"
    echo "  Cloud Type:   COMMUNITY (cheapest)"
    echo "  Docker Image: $docker_image"
    echo "  Whisper Model: ${WHISPER_MODEL:-small}"
    echo "  Compute Type: ${WHISPER_COMPUTE_TYPE:-float16}"
    echo "  Diarization:  ${ENABLE_DIARIZATION:-false}"
    echo "  ─────────────────────────────────────────"
    echo ""

    # Build request payload - use community cloud for lowest price
    local payload=$(cat <<EOF
{
    "name": "$pod_name",
    "imageName": "$docker_image",
    "gpuTypeId": "$gpu_type",
    "cloudType": "COMMUNITY",
    "gpuCount": ${GPU_COUNT:-1},
    "volumeInGb": 0,
    "containerDiskInGb": 50,
    "ports": "8000/http",
    "env": {
        "WHISPER_MODEL": "${WHISPER_MODEL:-small}",
        "WHISPER_COMPUTE_TYPE": "${WHISPER_COMPUTE_TYPE:-float16}",
        "WHISPER_BATCH_SIZE": "${WHISPER_BATCH_SIZE:-16}",
        "HF_TOKEN": "${HF_TOKEN:-}",
        "ENABLE_DIARIZATION": "${ENABLE_DIARIZATION:-false}"
    }
}
EOF
)

    debug_log "Request payload:"
    debug_json "$payload"

    print_status "info" "Sending create request to RunPod API..."

    local response=$(curl -s -X POST "${RUNPOD_REST_API}/pods" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    debug_json "$response"

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Failed to create pod"
        echo ""
        echo "Error details:"
        echo "$response" | jq .
        echo ""
        echo "Common issues:"
        echo "  - Invalid GPU type: Use --list-gpus to see available types"
        echo "  - Insufficient funds: Check your RunPod balance"
        echo "  - Invalid API key: Verify RUNPOD_API_KEY in .env"
        return 1
    fi

    # Extract pod ID
    local pod_id=$(echo "$response" | jq -r '.id // .podId // empty')

    if [ -z "$pod_id" ]; then
        print_status "error" "No pod ID in response"
        echo "$response" | jq .
        return 1
    fi

    print_status "ok" "Pod created! ID: $pod_id"
    json_log "$SCRIPT_NAME" "pod_created" "ok" "Pod ID: $pod_id" "pod_id=$pod_id"

    # Save pod ID to .env
    update_env_file "RUNPOD_POD_ID" "$pod_id"
    print_status "ok" "Saved RUNPOD_POD_ID to .env"

    echo "$pod_id"
}

# =============================================================================
# Wait for Pod Ready
# =============================================================================

wait_for_pod_ready() {
    local pod_id="$1"
    local max_attempts=30
    local attempt=1

    print_status "info" "Waiting for pod to become ready..."
    echo "  (This typically takes 1-3 minutes for image pull + startup)"
    echo ""

    while [ $attempt -le $max_attempts ]; do
        local response=$(curl -s "${RUNPOD_REST_API}/pods/${pod_id}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        local status=$(echo "$response" | jq -r '.desiredStatus // .status // "unknown"')
        local runtime_status=$(echo "$response" | jq -r '.runtime.status // "pending"')

        # Show progress
        printf "  [%2d/%d] Status: %-12s Runtime: %s\n" "$attempt" "$max_attempts" "$status" "$runtime_status"

        if [ "$status" = "RUNNING" ]; then
            # Get endpoint info
            local pod_ip=$(echo "$response" | jq -r '.runtime.ports[0].ip // empty')
            local pod_port=$(echo "$response" | jq -r '.runtime.ports[0].publicPort // empty')

            if [ -n "$pod_ip" ] && [ -n "$pod_port" ]; then
                echo ""
                print_status "ok" "============================================"
                print_status "ok" "POD IS READY!"
                print_status "ok" "============================================"
                echo ""
                echo "  Pod ID:   $pod_id"
                echo "  Endpoint: http://${pod_ip}:${pod_port}"
                echo ""

                # Save endpoint to .env
                update_env_file "RUNPOD_API_HOST" "$pod_ip"
                update_env_file "RUNPOD_API_PORT" "$pod_port"

                echo "  Saved endpoint to .env"
                echo ""
                echo "  Next steps:"
                echo "  ─────────────────────────────────────────"
                echo "  1. Test health:  curl http://${pod_ip}:${pod_port}/health"
                echo "  2. Test API:     ./scripts/320-LOCAL--test-runpod-gpu-api.sh"
                echo "  3. View logs:    ./scripts/330-LOCAL--view-runpod-gpu-logs.sh"
                echo "  4. Stop pod:     ./scripts/340-LOCAL--stop-runpod-gpu.sh"
                echo ""

                json_log "$SCRIPT_NAME" "pod_ready" "ok" "Pod ready at http://${pod_ip}:${pod_port}" \
                    "pod_id=$pod_id" "host=$pod_ip" "port=$pod_port"

                return 0
            fi
        fi

        # Check for failed state
        if [ "$status" = "EXITED" ] || [ "$status" = "FAILED" ]; then
            print_status "error" "Pod failed to start (status: $status)"
            echo ""
            echo "Full response:"
            echo "$response" | jq .
            return 1
        fi

        sleep 10
        attempt=$((attempt + 1))
    done

    print_status "warn" "Timeout waiting for pod"
    echo ""
    echo "The pod may still be starting. Check status manually:"
    echo "  ./scripts/330-LOCAL--view-runpod-gpu-logs.sh"
    echo ""
    echo "Or check the RunPod console:"
    echo "  https://www.runpod.io/console/pods"

    return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    print_status "info" "============================================"
    print_status "info" "RunPod GPU Pod Creator v${SCRIPT_VERSION}"
    print_status "info" "============================================"
    echo ""

    # Load environment
    load_env_or_fail

    # Validate API key
    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        print_status "error" "RUNPOD_API_KEY not set in .env"
        echo ""
        echo "Get your API key from: https://www.runpod.io/console/user/settings"
        echo "Then add it to .env: RUNPOD_API_KEY=rpa_xxxxx"
        exit 1
    fi

    debug_log "API Key: ${RUNPOD_API_KEY:0:10}...${RUNPOD_API_KEY: -4}"

    # Handle --list-gpus
    if [ "$LIST_GPUS" = true ]; then
        list_available_gpus
        exit 0
    fi

    # Check if pod already exists
    if [ -n "${RUNPOD_POD_ID:-}" ] && [ "${RUNPOD_POD_ID}" != "" ]; then
        print_status "warn" "Pod ID already configured: $RUNPOD_POD_ID"
        echo ""
        echo "Options:"
        echo "  1. Delete existing pod first:"
        echo "     ./scripts/340-LOCAL--stop-runpod-gpu.sh --delete"
        echo ""
        echo "  2. Check existing pod status:"
        echo "     ./scripts/330-LOCAL--view-runpod-gpu-logs.sh"
        echo ""
        echo "  3. Clear the pod ID manually:"
        echo "     Edit .env and remove RUNPOD_POD_ID value"
        exit 1
    fi

    # Set defaults - RTX 3070 is cheapest at $0.13/hr community cloud
    GPU_TYPE="${GPU_TYPE:-${GPU_TYPE_DEFAULT:-NVIDIA GeForce RTX 3070}}"
    POD_NAME="${POD_NAME:-whisperx-$(date +%Y%m%d-%H%M%S)}"

    local docker_image="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG:-latest}"

    # Create pod
    local pod_id=$(create_pod "$GPU_TYPE" "$POD_NAME" "$docker_image")

    if [ -z "$pod_id" ]; then
        exit 1
    fi

    # Wait for ready
    wait_for_pod_ready "$pod_id"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
