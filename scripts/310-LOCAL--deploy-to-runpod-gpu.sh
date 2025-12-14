#!/bin/bash
# =============================================================================
# RunPod Deploy Container - Update Container on Existing Pod
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Connects to existing RunPod pod
#   2. Pulls latest Docker image
#   3. Restarts the container
#
# NOTE: For initial deployment, use 300-runpod--create-pod.sh instead.
#       This script is for updating an existing pod with a new image.
#
# PREREQUISITES:
#   - RunPod pod already created (300-runpod--create-pod.sh)
#   - RUNPOD_POD_ID set in .env
#
# Usage: ./scripts/310-runpod--deploy-container.sh [OPTIONS]
#
# Options:
#   --pod-id ID     Pod ID (or set RUNPOD_POD_ID in .env)
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="310-runpod--deploy-container"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_REST_API="https://rest.runpod.io/v1"
POD_ID=""

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --pod-id)
            POD_ID="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--pod-id ID]"
            echo ""
            echo "Update/redeploy container on existing RunPod pod."
            echo ""
            echo "Options:"
            echo "  --pod-id ID   Pod ID (default: from RUNPOD_POD_ID in .env)"
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
    json_log "$SCRIPT_NAME" "start" "ok" "Redeploying to RunPod pod"

    # Load environment
    load_env_or_fail

    POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"

    if [ -z "$POD_ID" ]; then
        print_status "error" "No pod ID configured"
        echo ""
        echo "Either:"
        echo "  1. Create a new pod: ./scripts/300-runpod--create-pod.sh"
        echo "  2. Set RUNPOD_POD_ID in .env"
        echo "  3. Use --pod-id flag"
        exit 1
    fi

    local docker_image="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG:-latest}"

    print_status "info" "Redeploying to RunPod pod"
    echo ""
    echo "  Pod ID: $POD_ID"
    echo "  Image: $docker_image"
    echo ""

    # Get current pod status
    print_status "info" "Checking pod status..."

    local status_response=$(curl -s "${RUNPOD_REST_API}/pods/${POD_ID}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    local status=$(echo "$status_response" | jq -r '.desiredStatus // .status // "unknown"')

    if [ "$status" = "EXITED" ] || [ "$status" = "unknown" ]; then
        print_status "warn" "Pod is not running (status: $status)"
        echo ""
        echo "Start the pod first, or create a new one:"
        echo "  ./scripts/300-runpod--create-pod.sh"
        exit 1
    fi

    print_status "ok" "Pod status: $status"

    # Restart pod to pull new image
    print_status "info" "Restarting pod to pull latest image..."

    local restart_response=$(curl -s -X POST "${RUNPOD_REST_API}/pods/${POD_ID}/restart" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    if echo "$restart_response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Failed to restart pod"
        echo "$restart_response" | jq .
        exit 1
    fi

    print_status "ok" "Pod restart initiated"

    # Wait for pod to be ready
    print_status "info" "Waiting for pod to be ready..."

    local max_attempts=24
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        sleep 5

        local check_response=$(curl -s "${RUNPOD_REST_API}/pods/${POD_ID}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        local check_status=$(echo "$check_response" | jq -r '.desiredStatus // .status // "unknown"')

        echo "  Attempt $attempt/$max_attempts: Status = $check_status"

        if [ "$check_status" = "RUNNING" ]; then
            local pod_ip=$(echo "$check_response" | jq -r '.runtime.ports[0].ip // empty')
            local pod_port=$(echo "$check_response" | jq -r '.runtime.ports[0].publicPort // empty')

            if [ -n "$pod_ip" ] && [ -n "$pod_port" ]; then
                echo ""
                print_status "ok" "Pod redeployed successfully!"
                echo ""
                echo "API URL: http://${pod_ip}:${pod_port}"
                echo ""
                echo "Test with: ./scripts/320-runpod--test-api.sh --host $pod_ip --port $pod_port"
                return 0
            fi
        fi

        attempt=$((attempt + 1))
    done

    print_status "warn" "Pod may still be restarting. Check status manually."
}

# =============================================================================
# Run
# =============================================================================

main "$@"
