#!/bin/bash
# =============================================================================
# View RunPod Endpoint Logs
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Retrieves logs from RunPod endpoint workers
#   2. Displays recent log entries with timestamps
#   3. Supports filtering by job ID or time range
#   4. Can follow logs in real-time
#
# PREREQUISITES:
#   - Endpoint created (RUNPOD_ENDPOINT_ID in .env)
#   - Valid RunPod API key
#
# CONFIGURATION:
#   All settings read from .env file:
#   - RUNPOD_API_KEY: RunPod API key
#   - RUNPOD_ENDPOINT_ID: Endpoint ID
#
# Usage: ./scripts/905-runpod-logs.sh [OPTIONS]
#
# Options:
#   --job ID     Show logs for specific job ID
#   --follow     Follow logs in real-time (like tail -f)
#   --help       Show this help message
#
# Note: RunPod's log API is limited. For detailed logs, use the RunPod console.
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="905-runpod-logs"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# =============================================================================
# Parse Arguments
# =============================================================================

JOB_ID=""
FOLLOW_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --job)
            JOB_ID="$2"
            shift 2
            ;;
        --follow)
            FOLLOW_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--job ID] [--follow]"
            echo ""
            echo "Options:"
            echo "  --job ID     Show logs for specific job ID"
            echo "  --follow     Follow logs in real-time"
            echo ""
            echo "Note: For detailed logs, use RunPod console:"
            echo "  https://www.runpod.io/console/serverless"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# GraphQL Queries
# =============================================================================

RUNPOD_GRAPHQL_URL="https://api.runpod.io/graphql"

runpod_graphql() {
    local query="$1"

    curl -s -X POST "$RUNPOD_GRAPHQL_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -d "$query"
}

# =============================================================================
# Job Status Check
# =============================================================================

check_job_status() {
    local job_id="$1"

    local status_url="${RUNPOD_API_BASE}/${RUNPOD_ENDPOINT_ID}/status/${job_id}"

    local response=$(curl -s -X GET "$status_url" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json")

    echo "$response" | jq .
}

# =============================================================================
# Recent Jobs Query
# =============================================================================

get_recent_jobs() {
    # Query for recent endpoint jobs via GraphQL
    local query=$(cat <<EOF
{
    "query": "query {
        myself {
            serverlessDispatches(first: 20, input: {endpointId: \"${RUNPOD_ENDPOINT_ID}\"}) {
                nodes {
                    id
                    status
                    createdAt
                    completedAt
                    executionTime
                }
            }
        }
    }"
}
EOF
)

    # Clean up the query
    query=$(echo "$query" | tr '\n' ' ' | sed 's/  */ /g')

    local response=$(runpod_graphql "$query")

    echo "$response"
}

# =============================================================================
# Display Logs
# =============================================================================

display_logs() {
    echo "============================================"
    echo "RunPod Endpoint Logs"
    echo "============================================"
    echo ""
    echo "Endpoint: $RUNPOD_ENDPOINT_ID"
    echo "Time: $(date)"
    echo ""

    if [ -n "$JOB_ID" ]; then
        echo "--- Job: $JOB_ID ---"
        echo ""
        check_job_status "$JOB_ID"
    else
        echo "--- Recent Jobs ---"
        echo ""

        local jobs_response=$(get_recent_jobs)

        # Check for errors
        if echo "$jobs_response" | jq -e '.errors' &>/dev/null; then
            local error_msg=$(echo "$jobs_response" | jq -r '.errors[0].message // "Unknown error"')
            print_status "warn" "Could not fetch jobs: $error_msg"
            echo ""
        else
            # Display jobs
            echo "$jobs_response" | jq -r '
                .data.myself.serverlessDispatches.nodes[] |
                "Job: \(.id)\n  Status: \(.status)\n  Created: \(.createdAt)\n  Completed: \(.completedAt // "N/A")\n  Execution: \(.executionTime // "N/A")ms\n"
            ' 2>/dev/null || echo "No recent jobs found."
        fi
    fi

    echo ""
    echo "---"
    echo ""
    echo "For detailed logs, visit:"
    echo "  https://www.runpod.io/console/serverless"
    echo ""
}

# =============================================================================
# Main Process
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
        print_status "error" "Run ./scripts/210-create-endpoint.sh first"
        exit 1
    fi

    if [ "$FOLLOW_MODE" = true ]; then
        echo "Following logs (Ctrl+C to exit)..."
        echo ""
        while true; do
            clear
            display_logs
            sleep 10
        done
    else
        display_logs
    fi
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
