#!/bin/bash
# =============================================================================
# Cleanup All - Stop All Running Resources
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Stops WhisperX container on EC2 (if configured)
#   2. Stops/deletes RunPod pod (if configured)
#   3. Reports what was cleaned up
#
# Use this script to quickly tear down all running resources.
#
# Usage: ./scripts/900-manage--cleanup-all.sh [OPTIONS]
#
# Options:
#   --delete-pod    Delete RunPod pod entirely (default: just stop)
#   --force         Skip confirmation prompts
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="900-manage--cleanup-all"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

DELETE_POD=false
FORCE_ACTION=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --delete-pod)
            DELETE_POD=true
            shift
            ;;
        --force)
            FORCE_ACTION=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--delete-pod] [--force]"
            echo ""
            echo "Stop all running WhisperX resources."
            echo ""
            echo "Options:"
            echo "  --delete-pod  Delete RunPod pod entirely (default: just stop)"
            echo "  --force       Skip confirmation prompts"
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
    json_log "$SCRIPT_NAME" "start" "ok" "Cleaning up all resources"

    # Load environment
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi

    echo ""
    print_status "info" "============================================"
    print_status "info" "WhisperX Cleanup - Stopping All Resources"
    print_status "info" "============================================"
    echo ""

    local cleaned_up=0

    # =========================================================================
    # EC2 Container
    # =========================================================================

    if [ -n "${AWS_EC2_HOST:-}" ]; then
        print_status "info" "EC2 container configured: $AWS_EC2_HOST"

        if [ "$FORCE_ACTION" = true ]; then
            "$SCRIPT_DIR/240-ec2--stop-container.sh" 2>/dev/null && cleaned_up=$((cleaned_up + 1)) || true
        else
            read -p "Stop EC2 container? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                "$SCRIPT_DIR/240-ec2--stop-container.sh" 2>/dev/null && cleaned_up=$((cleaned_up + 1)) || true
            fi
        fi
        echo ""
    else
        print_status "info" "No EC2 host configured (skipping)"
        echo ""
    fi

    # =========================================================================
    # RunPod Pod
    # =========================================================================

    if [ -n "${RUNPOD_POD_ID:-}" ] && [ "$RUNPOD_POD_ID" != "" ]; then
        print_status "info" "RunPod pod configured: $RUNPOD_POD_ID"

        local pod_args=()
        [ "$DELETE_POD" = true ] && pod_args+=(--delete)
        [ "$FORCE_ACTION" = true ] && pod_args+=(--force)

        "$SCRIPT_DIR/340-runpod--stop-pod.sh" "${pod_args[@]}" 2>/dev/null && cleaned_up=$((cleaned_up + 1)) || true
        echo ""
    else
        print_status "info" "No RunPod pod configured (skipping)"
        echo ""
    fi

    # =========================================================================
    # Summary
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Cleanup Complete"
    print_status "ok" "============================================"
    echo ""

    if [ $cleaned_up -eq 0 ]; then
        echo "No resources were running."
    else
        echo "Stopped $cleaned_up resource(s)."
    fi

    echo ""
    echo "To redeploy:"
    echo "  EC2:    ./scripts/210-ec2--deploy-container.sh"
    echo "  RunPod: ./scripts/300-runpod--create-pod.sh"
    echo ""
}

# =============================================================================
# Run
# =============================================================================

main "$@"
