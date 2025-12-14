#!/bin/bash
# =============================================================================
# RunPod View Logs - Show Pod Container Logs
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Connects to RunPod pod via API
#   2. Retrieves container logs
#   3. Optionally polls logs in real-time
#
# PREREQUISITES:
#   - RunPod pod created (300-runpod--create-pod.sh)
#   - RUNPOD_POD_ID set in .env
#
# Usage: ./scripts/330-runpod--view-logs.sh [OPTIONS]
#
# Options:
#   --pod-id ID     Pod ID (or set RUNPOD_POD_ID in .env)
#   --follow        Poll logs every 10 seconds (Ctrl+C to exit)
#   --help          Show this help message
#
# Note: For detailed live logs, use the RunPod console:
#       https://www.runpod.io/console/pods
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="330-runpod--view-logs"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_REST_API="https://rest.runpod.io/v1"
POD_ID=""
FOLLOW_MODE=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --pod-id)
            POD_ID="$2"
            shift 2
            ;;
        --follow|-f)
            FOLLOW_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--pod-id ID] [--follow]"
            echo ""
            echo "View RunPod pod logs and status."
            echo ""
            echo "Options:"
            echo "  --pod-id ID   Pod ID (default: from RUNPOD_POD_ID in .env)"
            echo "  --follow, -f  Poll logs every 10 seconds"
            echo ""
            echo "For detailed live logs, visit:"
            echo "  https://www.runpod.io/console/pods"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Display Logs
# =============================================================================

display_pod_info() {
    local pod_id="$1"

    local response=$(curl -s "${RUNPOD_REST_API}/pods/${pod_id}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Failed to get pod info"
        echo "$response" | jq .
        return 1
    fi

    echo "============================================"
    echo "RunPod Pod Status"
    echo "============================================"
    echo ""
    echo "Time: $(date)"
    echo ""

    # Extract and display pod info
    local name=$(echo "$response" | jq -r '.name // "unknown"')
    local status=$(echo "$response" | jq -r '.desiredStatus // .status // "unknown"')
    local gpu_type=$(echo "$response" | jq -r '.machine.gpuTypeId // .gpuTypeId // "unknown"')
    local image=$(echo "$response" | jq -r '.imageName // "unknown"')

    echo "Pod: $name"
    echo "ID: $pod_id"
    echo "Status: $status"
    echo "GPU: $gpu_type"
    echo "Image: $image"
    echo ""

    # Show runtime info if running
    if [ "$status" = "RUNNING" ]; then
        local pod_ip=$(echo "$response" | jq -r '.runtime.ports[0].ip // "N/A"')
        local pod_port=$(echo "$response" | jq -r '.runtime.ports[0].publicPort // "N/A"')
        local uptime=$(echo "$response" | jq -r '.runtime.uptimeInSeconds // 0')

        echo "Endpoint: http://${pod_ip}:${pod_port}"
        echo "Uptime: ${uptime}s"
        echo ""
    fi

    # Show environment variables
    echo "--- Environment ---"
    echo "$response" | jq -r '.env // {} | to_entries[] | "  \(.key)=\(.value)"' 2>/dev/null || echo "  (none)"
    echo ""

    # Note about logs
    echo "--- Logs ---"
    echo "Note: RunPod REST API doesn't provide container logs directly."
    echo "For live container logs, use the RunPod console:"
    echo "  https://www.runpod.io/console/pods/${pod_id}"
    echo ""
    echo "Or SSH into the pod (if enabled) and run:"
    echo "  docker logs <container_name>"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Load environment
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi

    POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"

    if [ -z "$POD_ID" ]; then
        print_status "error" "No pod ID configured"
        echo ""
        echo "Either:"
        echo "  1. Create a pod: ./scripts/300-runpod--create-pod.sh"
        echo "  2. Set RUNPOD_POD_ID in .env"
        echo "  3. Use --pod-id flag"
        exit 1
    fi

    if [ "$FOLLOW_MODE" = true ]; then
        print_status "info" "Polling pod status every 10 seconds (Ctrl+C to exit)..."
        echo ""
        while true; do
            clear
            display_pod_info "$POD_ID"
            sleep 10
        done
    else
        display_pod_info "$POD_ID"
    fi
}

# =============================================================================
# Run
# =============================================================================

main "$@"
