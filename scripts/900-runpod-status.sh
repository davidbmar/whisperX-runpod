#!/bin/bash
# =============================================================================
# Check RunPod Endpoint Status
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Queries RunPod API for endpoint information
#   2. Shows worker status (ready, running, throttled)
#   3. Shows job statistics (completed, failed, in progress)
#   4. Displays cost and usage information if available
#
# PREREQUISITES:
#   - Endpoint created (RUNPOD_ENDPOINT_ID in .env)
#   - Valid RunPod API key
#
# CONFIGURATION:
#   All settings read from .env file:
#   - RUNPOD_API_KEY: RunPod API key
#   - RUNPOD_ENDPOINT_ID: Endpoint ID to check
#
# Usage: ./scripts/900-runpod-status.sh [OPTIONS]
#
# Options:
#   --watch      Continuously monitor status (refresh every 5s)
#   --json       Output raw JSON response
#   --help       Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="900-runpod-status"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# =============================================================================
# Parse Arguments
# =============================================================================

WATCH_MODE=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--watch] [--json]"
            echo ""
            echo "Options:"
            echo "  --watch      Continuously monitor status (refresh every 5s)"
            echo "  --json       Output raw JSON response"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Status Check Function
# =============================================================================

check_status() {
    local health_url="${RUNPOD_API_BASE}/${RUNPOD_ENDPOINT_ID}/health"

    local health_response=$(curl -s -X GET "$health_url" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json")

    if [ "$JSON_OUTPUT" = true ]; then
        echo "$health_response" | jq .
        return
    fi

    # Check for errors
    if echo "$health_response" | jq -e '.error' &>/dev/null; then
        local error_msg=$(echo "$health_response" | jq -r '.error // "Unknown error"')
        print_status "error" "Error: $error_msg"
        return 1
    fi

    # Extract worker info
    local workers_ready=$(echo "$health_response" | jq -r '.workers.ready // 0')
    local workers_running=$(echo "$health_response" | jq -r '.workers.running // 0')
    local workers_throttled=$(echo "$health_response" | jq -r '.workers.throttled // 0')
    local workers_initializing=$(echo "$health_response" | jq -r '.workers.initializing // 0')

    # Extract job info
    local jobs_completed=$(echo "$health_response" | jq -r '.jobs.completed // 0')
    local jobs_failed=$(echo "$health_response" | jq -r '.jobs.failed // 0')
    local jobs_in_progress=$(echo "$health_response" | jq -r '.jobs.inProgress // 0')
    local jobs_in_queue=$(echo "$health_response" | jq -r '.jobs.inQueue // 0')
    local jobs_retried=$(echo "$health_response" | jq -r '.jobs.retried // 0')

    # Display status
    if [ "$WATCH_MODE" = true ]; then
        clear
        echo "RunPod Endpoint Status (refreshing every 5s)"
        echo "Press Ctrl+C to exit"
        echo ""
    fi

    echo "============================================"
    echo "Endpoint: $RUNPOD_ENDPOINT_ID"
    echo "Time: $(date)"
    echo "============================================"
    echo ""
    echo "Workers:"
    echo "  Ready:        $workers_ready"
    echo "  Running:      $workers_running"
    echo "  Initializing: $workers_initializing"
    echo "  Throttled:    $workers_throttled"
    echo ""
    echo "Jobs:"
    echo "  Completed:    $jobs_completed"
    echo "  Failed:       $jobs_failed"
    echo "  In Progress:  $jobs_in_progress"
    echo "  In Queue:     $jobs_in_queue"
    echo "  Retried:      $jobs_retried"
    echo ""

    # Status indicator
    if [ "$workers_running" -gt 0 ] || [ "$jobs_in_progress" -gt 0 ]; then
        print_status "ok" "Status: ACTIVE (processing requests)"
    elif [ "$workers_ready" -gt 0 ]; then
        print_status "ok" "Status: READY (workers available)"
    elif [ "$workers_initializing" -gt 0 ]; then
        print_status "info" "Status: STARTING (workers initializing)"
    else
        print_status "info" "Status: IDLE (will cold start on request)"
    fi
    echo ""
}

# =============================================================================
# Main Process
# =============================================================================

main() {
    # Load environment (quietly for watch mode)
    if [ ! -f "$ENV_FILE" ]; then
        print_status "error" "Configuration file not found: $ENV_FILE"
        print_status "error" "Run ./scripts/000-questions.sh first"
        exit 1
    fi

    source "$ENV_FILE"

    if [ -z "${RUNPOD_ENDPOINT_ID:-}" ] || [ "$RUNPOD_ENDPOINT_ID" = "TO_BE_DISCOVERED" ]; then
        print_status "error" "No endpoint ID configured"
        print_status "error" "Run ./scripts/210-create-endpoint.sh first"
        exit 1
    fi

    if [ "$WATCH_MODE" = true ]; then
        while true; do
            check_status
            sleep 5
        done
    else
        check_status
    fi
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
