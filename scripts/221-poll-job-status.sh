#!/bin/bash
# =============================================================================
# Poll RunPod Job Status Until Completion
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Takes a job ID as input
#   2. Polls the RunPod API for job status every few seconds
#   3. Displays progress and status updates
#   4. Shows result when job completes or fails
#
# PREREQUISITES:
#   - Endpoint configured (RUNPOD_ENDPOINT_ID in .env)
#   - Valid RunPod API key
#
# Usage: ./scripts/221-poll-job-status.sh [JOB_ID] [OPTIONS]
#
# Options:
#   --interval N   Poll interval in seconds (default: 5)
#   --timeout N    Maximum wait time in seconds (default: 600)
#   --help         Show this help message
#
# Examples:
#   ./scripts/221-poll-job-status.sh sync-abc123-u1
#   ./scripts/221-poll-job-status.sh --interval 10 --timeout 300
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="221-poll-job-status"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# =============================================================================
# Configuration
# =============================================================================

POLL_INTERVAL=5
MAX_TIMEOUT=600
JOB_ID=""

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --timeout)
            MAX_TIMEOUT="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [JOB_ID] [--interval N] [--timeout N]"
            echo ""
            echo "Arguments:"
            echo "  JOB_ID         Job ID to poll (optional - will check health if not provided)"
            echo ""
            echo "Options:"
            echo "  --interval N   Poll interval in seconds (default: 5)"
            echo "  --timeout N    Maximum wait time in seconds (default: 600)"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            JOB_ID="$1"
            shift
            ;;
    esac
done

# =============================================================================
# Main Polling Function
# =============================================================================

poll_health() {
    # Poll endpoint health until jobs complete
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""

    print_status "info" "Monitoring endpoint health..."
    print_status "info" "Endpoint: $RUNPOD_ENDPOINT_ID"
    print_status "info" "Polling every ${POLL_INTERVAL}s (timeout: ${MAX_TIMEOUT}s)"
    echo ""

    while [ "$elapsed" -lt "$MAX_TIMEOUT" ]; do
        local response=$(curl -s "${RUNPOD_API_BASE}/${RUNPOD_ENDPOINT_ID}/health" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        local workers_ready=$(echo "$response" | jq -r '.workers.ready // 0')
        local workers_running=$(echo "$response" | jq -r '.workers.running // 0')
        local workers_idle=$(echo "$response" | jq -r '.workers.idle // 0')
        local jobs_completed=$(echo "$response" | jq -r '.jobs.completed // 0')
        local jobs_failed=$(echo "$response" | jq -r '.jobs.failed // 0')
        local jobs_in_progress=$(echo "$response" | jq -r '.jobs.inProgress // 0')
        local jobs_in_queue=$(echo "$response" | jq -r '.jobs.inQueue // 0')

        elapsed=$(($(date +%s) - start_time))

        # Build status line
        local status_line="[${elapsed}s] Workers: ${workers_running} running, ${workers_idle} idle | Jobs: ${jobs_in_progress} in-progress, ${jobs_in_queue} queued, ${jobs_completed} done, ${jobs_failed} failed"

        # Only print if status changed
        if [ "$status_line" != "$last_status" ]; then
            echo "$status_line"
            last_status="$status_line"
        else
            echo -ne "\r$status_line"
        fi

        # Check if all jobs completed
        if [ "$jobs_in_progress" -eq 0 ] && [ "$jobs_in_queue" -eq 0 ]; then
            echo ""
            if [ "$jobs_completed" -gt 0 ]; then
                print_status "ok" "All jobs completed!"
                print_status "ok" "Completed: $jobs_completed, Failed: $jobs_failed"
            elif [ "$jobs_failed" -gt 0 ]; then
                print_status "error" "Jobs failed: $jobs_failed"
            else
                print_status "info" "No jobs in progress"
            fi
            return 0
        fi

        sleep "$POLL_INTERVAL"
    done

    echo ""
    print_status "warn" "Timeout reached after ${MAX_TIMEOUT}s"
    return 1
}

poll_job() {
    # Poll specific job until completion
    local job_id="$1"
    local start_time=$(date +%s)
    local elapsed=0

    print_status "info" "Polling job: $job_id"
    print_status "info" "Polling every ${POLL_INTERVAL}s (timeout: ${MAX_TIMEOUT}s)"
    echo ""

    while [ "$elapsed" -lt "$MAX_TIMEOUT" ]; do
        local response=$(curl -s "${RUNPOD_API_BASE}/${RUNPOD_ENDPOINT_ID}/status/${job_id}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}")

        local status=$(echo "$response" | jq -r '.status // "unknown"')
        elapsed=$(($(date +%s) - start_time))

        echo -ne "\r[${elapsed}s] Status: $status     "

        case "$status" in
            COMPLETED)
                echo ""
                echo ""
                print_status "ok" "Job completed successfully!"
                echo ""
                echo "=== RESULT ==="
                echo "$response" | jq '.output'
                echo ""

                # Show timing info
                local delay=$(echo "$response" | jq -r '.delayTime // 0')
                local exec=$(echo "$response" | jq -r '.executionTime // 0')
                echo "Delay time: ${delay}ms"
                echo "Execution time: ${exec}ms"
                return 0
                ;;
            FAILED)
                echo ""
                echo ""
                print_status "error" "Job failed!"
                echo ""
                echo "$response" | jq .
                return 1
                ;;
            CANCELLED)
                echo ""
                print_status "warn" "Job was cancelled"
                return 1
                ;;
            IN_QUEUE|IN_PROGRESS)
                # Continue polling
                ;;
            *)
                echo ""
                print_status "warn" "Unknown status: $status"
                echo "$response" | jq .
                ;;
        esac

        sleep "$POLL_INTERVAL"
    done

    echo ""
    print_status "warn" "Timeout reached after ${MAX_TIMEOUT}s"
    print_status "info" "Job may still be running. Check status manually or increase timeout."
    return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Load environment
    if [ ! -f "$ENV_FILE" ]; then
        print_status "error" "Configuration file not found: $ENV_FILE"
        print_status "error" "Run ./scripts/000-questions.sh first"
        exit 1
    fi

    source "$ENV_FILE"

    if [ -z "${RUNPOD_ENDPOINT_ID:-}" ] || [ "$RUNPOD_ENDPOINT_ID" = "TO_BE_DISCOVERED" ]; then
        print_status "error" "No endpoint ID configured"
        exit 1
    fi

    if [ -n "$JOB_ID" ]; then
        poll_job "$JOB_ID"
    else
        poll_health
    fi
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
