#!/bin/bash
# =============================================================================
# RunPod Stop Pod - Stop or Delete RunPod GPU Pod
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Confirms action with user
#   2. Stops or deletes the RunPod pod via REST API
#   3. Optionally clears pod ID from .env
#
# PREREQUISITES:
#   - RunPod pod created (300-runpod--create-pod.sh)
#   - RUNPOD_POD_ID set in .env
#
# Usage: ./scripts/340-runpod--stop-pod.sh [OPTIONS]
#
# Options:
#   --pod-id ID     Pod ID (or set RUNPOD_POD_ID in .env)
#   --delete        Delete pod entirely (default: just stop)
#   --force         Skip confirmation prompt
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="340-runpod--stop-pod"
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
DELETE_POD=false
FORCE_ACTION=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --pod-id)
            POD_ID="$2"
            shift 2
            ;;
        --delete)
            DELETE_POD=true
            shift
            ;;
        --force)
            FORCE_ACTION=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--pod-id ID] [--delete] [--force]"
            echo ""
            echo "Stop or delete a RunPod GPU pod."
            echo ""
            echo "Options:"
            echo "  --pod-id ID   Pod ID (default: from RUNPOD_POD_ID in .env)"
            echo "  --delete      Delete pod entirely (default: just stop)"
            echo "  --force       Skip confirmation prompt"
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
    json_log "$SCRIPT_NAME" "start" "ok" "Stopping/deleting RunPod pod"

    # Load environment
    load_env_or_fail

    POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"

    if [ -z "$POD_ID" ]; then
        print_status "warn" "No pod ID configured in .env"
        print_status "info" "Nothing to stop/delete."
        exit 0
    fi

    # Get current pod status
    print_status "info" "Checking pod status..."

    local status_response=$(curl -s "${RUNPOD_REST_API}/pods/${POD_ID}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    local status=$(echo "$status_response" | jq -r '.desiredStatus // .status // "unknown"')
    local pod_name=$(echo "$status_response" | jq -r '.name // "unknown"')

    echo ""
    if [ "$DELETE_POD" = true ]; then
        print_status "warn" "============================================"
        print_status "warn" "WARNING: This will DELETE the pod!"
        print_status "warn" "============================================"
    else
        print_status "info" "============================================"
        print_status "info" "Stopping pod (can be restarted later)"
        print_status "info" "============================================"
    fi
    echo ""
    echo "Pod ID: $POD_ID"
    echo "Pod Name: $pod_name"
    echo "Current Status: $status"
    echo ""

    # Confirmation
    if [ "$FORCE_ACTION" != true ]; then
        if [ "$DELETE_POD" = true ]; then
            echo -e "${RED:-}This action cannot be undone.${NC:-}"
            echo ""
            read -p "Type 'DELETE' to confirm: " confirmation
            if [ "$confirmation" != "DELETE" ]; then
                print_status "info" "Deletion cancelled."
                exit 0
            fi
        else
            read -p "Stop this pod? (y/N): " confirmation
            if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
                print_status "info" "Stop cancelled."
                exit 0
            fi
        fi
        echo ""
    fi

    # Perform action
    if [ "$DELETE_POD" = true ]; then
        print_status "info" "Deleting pod..."

        local response=$(curl -s -X DELETE "${RUNPOD_REST_API}/pods/${POD_ID}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        # Check for error
        if echo "$response" | jq -e '.error' &>/dev/null; then
            print_status "error" "Failed to delete pod"
            echo "$response" | jq .
            exit 1
        fi

        json_log "$SCRIPT_NAME" "delete" "ok" "Pod deleted"

        # Clear pod ID from .env
        update_env_file "RUNPOD_POD_ID" ""

        echo ""
        print_status "ok" "============================================"
        print_status "ok" "Pod deleted successfully!"
        print_status "ok" "============================================"
        echo ""
        echo "Deleted: $POD_ID"
        echo ""
        echo "To create a new pod:"
        echo "  ./scripts/300-runpod--create-pod.sh"
    else
        print_status "info" "Stopping pod..."

        local response=$(curl -s -X POST "${RUNPOD_REST_API}/pods/${POD_ID}/stop" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        # Check for error
        if echo "$response" | jq -e '.error' &>/dev/null; then
            print_status "error" "Failed to stop pod"
            echo "$response" | jq .
            exit 1
        fi

        json_log "$SCRIPT_NAME" "stop" "ok" "Pod stopped"

        echo ""
        print_status "ok" "============================================"
        print_status "ok" "Pod stopped successfully!"
        print_status "ok" "============================================"
        echo ""
        echo "Stopped: $POD_ID"
        echo ""
        echo "The pod can be restarted from the RunPod console:"
        echo "  https://www.runpod.io/console/pods"
        echo ""
        echo "Or create a fresh deployment:"
        echo "  ./scripts/300-runpod--create-pod.sh"
    fi
}

# =============================================================================
# Run
# =============================================================================

main "$@"
