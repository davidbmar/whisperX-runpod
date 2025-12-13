#!/bin/bash
# =============================================================================
# Test RunPod Endpoint Health and Readiness
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Checks if endpoint exists in RunPod
#   2. Verifies endpoint is healthy and ready
#   3. Waits for workers to be available (if needed)
#   4. Reports endpoint status and worker count
#
# PREREQUISITES:
#   - Endpoint created (run 210-create-endpoint.sh first)
#   - RUNPOD_ENDPOINT_ID configured in .env
#
# CONFIGURATION:
#   All settings read from .env file:
#   - RUNPOD_API_KEY: RunPod API key
#   - RUNPOD_ENDPOINT_ID: Endpoint ID to test
#
# Usage: ./scripts/215-test-endpoint.sh [OPTIONS]
#
# Options:
#   --wait       Wait for endpoint to become ready
#   --timeout N  Maximum wait time in seconds (default: 300)
#   --help       Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="215-test-endpoint"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Start logging
start_logging "$SCRIPT_NAME"

# =============================================================================
# Parse Arguments
# =============================================================================

WAIT_FOR_READY=false
WAIT_TIMEOUT=300

while [[ $# -gt 0 ]]; do
    case $1 in
        --wait)
            WAIT_FOR_READY=true
            shift
            ;;
        --timeout)
            WAIT_TIMEOUT="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--wait] [--timeout N]"
            echo ""
            echo "Options:"
            echo "  --wait       Wait for endpoint to become ready"
            echo "  --timeout N  Maximum wait time in seconds (default: 300)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Test Process
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Testing RunPod endpoint"

    # =========================================================================
    # Load Environment
    # =========================================================================

    load_env_or_fail

    if [ -z "${RUNPOD_ENDPOINT_ID:-}" ] || [ "$RUNPOD_ENDPOINT_ID" = "TO_BE_DISCOVERED" ]; then
        json_log "$SCRIPT_NAME" "config" "error" "No endpoint ID configured"
        print_status "error" "No endpoint ID configured"
        print_status "error" "Run ./scripts/210-create-endpoint.sh first"
        exit 1
    fi

    json_log "$SCRIPT_NAME" "config" "ok" "Testing endpoint: $RUNPOD_ENDPOINT_ID"
    print_status "info" "Testing endpoint: $RUNPOD_ENDPOINT_ID"

    # =========================================================================
    # Check Endpoint Health
    # =========================================================================

    local health_url="${RUNPOD_API_BASE}/${RUNPOD_ENDPOINT_ID}/health"

    print_status "info" "Checking endpoint health..."

    local health_response=$(curl -s -X GET "$health_url" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json")

    # Check for errors
    if echo "$health_response" | jq -e '.error' &>/dev/null; then
        local error_msg=$(echo "$health_response" | jq -r '.error // "Unknown error"')
        json_log "$SCRIPT_NAME" "health_check" "error" "Health check failed: $error_msg"
        print_status "error" "Health check failed: $error_msg"
        exit 1
    fi

    # Extract worker info
    local workers_ready=$(echo "$health_response" | jq -r '.workers.ready // 0')
    local workers_running=$(echo "$health_response" | jq -r '.workers.running // 0')
    local workers_throttled=$(echo "$health_response" | jq -r '.workers.throttled // 0')
    local jobs_completed=$(echo "$health_response" | jq -r '.jobs.completed // 0')
    local jobs_failed=$(echo "$health_response" | jq -r '.jobs.failed // 0')

    json_log "$SCRIPT_NAME" "health_check" "ok" "Health response received" \
        "ready=$workers_ready" \
        "running=$workers_running" \
        "jobs_completed=$jobs_completed"

    # =========================================================================
    # Wait for Ready (if requested)
    # =========================================================================

    if [ "$WAIT_FOR_READY" = true ] && [ "$workers_ready" -eq 0 ] && [ "$workers_running" -eq 0 ]; then
        print_status "info" "Waiting for workers to be ready (timeout: ${WAIT_TIMEOUT}s)..."

        local start_time=$(date +%s)
        local elapsed=0

        while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
            sleep 10

            health_response=$(curl -s -X GET "$health_url" \
                -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
                -H "Content-Type: application/json")

            workers_ready=$(echo "$health_response" | jq -r '.workers.ready // 0')
            workers_running=$(echo "$health_response" | jq -r '.workers.running // 0')

            elapsed=$(($(date +%s) - start_time))

            if [ "$workers_ready" -gt 0 ] || [ "$workers_running" -gt 0 ]; then
                print_status "ok" "Workers available after $(format_duration $elapsed)"
                break
            fi

            echo -ne "\r  Waiting... ${elapsed}s / ${WAIT_TIMEOUT}s"
        done

        echo ""

        if [ "$workers_ready" -eq 0 ] && [ "$workers_running" -eq 0 ]; then
            print_status "warn" "No workers ready after ${WAIT_TIMEOUT}s"
            print_status "info" "Workers will spin up on first request (cold start)"
        fi
    fi

    # =========================================================================
    # Summary
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Endpoint Status"
    print_status "ok" "============================================"
    echo ""
    echo "Endpoint ID: $RUNPOD_ENDPOINT_ID"
    echo ""
    echo "Workers:"
    echo "  Ready: $workers_ready"
    echo "  Running: $workers_running"
    echo "  Throttled: $workers_throttled"
    echo ""
    echo "Jobs:"
    echo "  Completed: $jobs_completed"
    echo "  Failed: $jobs_failed"
    echo ""

    if [ "$workers_ready" -gt 0 ] || [ "$workers_running" -gt 0 ]; then
        print_status "ok" "Endpoint is ready for requests!"
    else
        print_status "info" "Endpoint is idle. Workers will start on first request."
        print_status "info" "First request may take 30-60s (cold start)."
    fi

    echo ""
    echo "API URLs:"
    echo "  Sync:  https://api.runpod.ai/v2/$RUNPOD_ENDPOINT_ID/runsync"
    echo "  Async: https://api.runpod.ai/v2/$RUNPOD_ENDPOINT_ID/run"
    echo ""
    echo "Next step: ./scripts/220-test-transcription.sh"
    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
