#!/bin/bash
# =============================================================================
# RunPod Test API - Verify WhisperX Transcription on RunPod
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Gets pod IP/port from RunPod API (or uses provided values)
#   2. Checks API health endpoint
#   3. Submits test transcription request
#
# NOTE: This script wraps 220-ec2--test-api.sh with RunPod-specific logic
#       to automatically discover the pod's public endpoint.
#
# PREREQUISITES:
#   - RunPod pod running (300-runpod--create-pod.sh)
#
# Usage: ./scripts/320-runpod--test-api.sh [OPTIONS]
#
# Options:
#   --host HOST     API host (auto-detected from pod if not provided)
#   --port PORT     API port (auto-detected from pod if not provided)
#   --pod-id ID     Pod ID (default: from RUNPOD_POD_ID in .env)
#   --url URL       Audio URL to transcribe
#   --file FILE     Audio file to upload
#   --no-diarize    Disable speaker diarization
#   --health        Only check health endpoint
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="320-runpod--test-api"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_REST_API="https://rest.runpod.io/v1"
POD_ID=""
API_HOST=""
API_PORT=""
EXTRA_ARGS=()

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --pod-id)
            POD_ID="$2"
            shift 2
            ;;
        --host)
            API_HOST="$2"
            shift 2
            ;;
        --port)
            API_PORT="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--pod-id ID] [--host HOST] [--port PORT] [OPTIONS]"
            echo ""
            echo "Test WhisperX API on RunPod pod."
            echo ""
            echo "Options:"
            echo "  --pod-id ID   Pod ID (default: from .env)"
            echo "  --host HOST   Override API host"
            echo "  --port PORT   Override API port"
            echo "  --url URL     Audio URL to transcribe"
            echo "  --file FILE   Audio file to upload"
            echo "  --no-diarize  Disable diarization"
            echo "  --health      Only check health"
            exit 0
            ;;
        *)
            # Pass through to test script
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# =============================================================================
# Main
# =============================================================================

main() {
    # Load environment
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi

    POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"

    # If host not provided, get from pod
    if [ -z "$API_HOST" ]; then
        if [ -z "$POD_ID" ]; then
            print_status "error" "No pod ID configured and no --host provided"
            echo ""
            echo "Either:"
            echo "  1. Provide --host and --port"
            echo "  2. Set RUNPOD_POD_ID in .env"
            echo "  3. Create a pod: ./scripts/300-runpod--create-pod.sh"
            exit 1
        fi

        print_status "info" "Getting pod endpoint from RunPod API..."

        local status_response=$(curl -s "${RUNPOD_REST_API}/pods/${POD_ID}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        local status=$(echo "$status_response" | jq -r '.desiredStatus // .status // "unknown"')

        if [ "$status" != "RUNNING" ]; then
            print_status "error" "Pod is not running (status: $status)"
            exit 1
        fi

        API_HOST=$(echo "$status_response" | jq -r '.runtime.ports[0].ip // empty')
        API_PORT=$(echo "$status_response" | jq -r '.runtime.ports[0].publicPort // empty')

        if [ -z "$API_HOST" ] || [ -z "$API_PORT" ]; then
            print_status "error" "Could not get pod endpoint"
            echo "$status_response" | jq .
            exit 1
        fi

        print_status "ok" "Found pod endpoint: ${API_HOST}:${API_PORT}"
        echo ""
    fi

    # Build args for test script
    local test_args=(--host "$API_HOST")
    [ -n "$API_PORT" ] && test_args+=(--port "$API_PORT")
    test_args+=("${EXTRA_ARGS[@]}")

    # Run the test script
    exec "$SCRIPT_DIR/220-ec2--test-api.sh" "${test_args[@]}"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
