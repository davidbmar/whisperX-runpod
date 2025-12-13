#!/bin/bash
# =============================================================================
# Delete RunPod Serverless Endpoint
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Confirms deletion with user
#   2. Deletes the serverless endpoint via RunPod API
#   3. Cleans up local state files
#   4. Updates .env to remove endpoint ID
#
# PREREQUISITES:
#   - Endpoint created (RUNPOD_ENDPOINT_ID in .env)
#   - Valid RunPod API key
#
# CONFIGURATION:
#   All settings read from .env file:
#   - RUNPOD_API_KEY: RunPod API key
#   - RUNPOD_ENDPOINT_ID: Endpoint ID to delete
#
# Usage: ./scripts/915-runpod-delete.sh [OPTIONS]
#
# Options:
#   --force      Skip confirmation prompt
#   --help       Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="915-runpod-delete"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Start logging
start_logging "$SCRIPT_NAME"

# =============================================================================
# Parse Arguments
# =============================================================================

FORCE_DELETE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DELETE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Options:"
            echo "  --force      Skip confirmation prompt"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# GraphQL API
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
# Main Delete Process
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting endpoint deletion"

    # =========================================================================
    # Load Environment
    # =========================================================================

    load_env_or_fail

    if [ -z "${RUNPOD_ENDPOINT_ID:-}" ] || [ "$RUNPOD_ENDPOINT_ID" = "TO_BE_DISCOVERED" ]; then
        json_log "$SCRIPT_NAME" "config" "warn" "No endpoint ID configured"
        print_status "warn" "No endpoint ID configured in .env"
        print_status "info" "Nothing to delete."
        exit 0
    fi

    json_log "$SCRIPT_NAME" "config" "ok" "Endpoint to delete: $RUNPOD_ENDPOINT_ID"

    # =========================================================================
    # Confirmation
    # =========================================================================

    echo ""
    print_status "warn" "============================================"
    print_status "warn" "WARNING: This will delete the endpoint!"
    print_status "warn" "============================================"
    echo ""
    echo "Endpoint ID: $RUNPOD_ENDPOINT_ID"
    echo "Endpoint Name: ${RUNPOD_ENDPOINT_NAME:-unknown}"
    echo ""

    if [ "$FORCE_DELETE" != true ]; then
        echo -e "${RED}This action cannot be undone.${NC}"
        echo ""
        read -p "Type 'DELETE' to confirm: " confirmation
        echo ""

        if [ "$confirmation" != "DELETE" ]; then
            json_log "$SCRIPT_NAME" "cancel" "ok" "Deletion cancelled by user"
            print_status "info" "Deletion cancelled."
            exit 0
        fi
    fi

    # =========================================================================
    # Delete Endpoint
    # =========================================================================

    print_status "info" "Deleting endpoint..."

    local delete_query=$(cat <<EOF
{
    "query": "mutation {
        deleteEndpoint(id: \"${RUNPOD_ENDPOINT_ID}\")
    }"
}
EOF
)

    # Clean up the query
    delete_query=$(echo "$delete_query" | tr '\n' ' ' | sed 's/  */ /g')

    local response=$(runpod_graphql "$delete_query")

    # Check for errors
    if echo "$response" | jq -e '.errors' &>/dev/null; then
        local error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        json_log "$SCRIPT_NAME" "delete" "error" "Failed to delete: $error_msg"
        print_status "error" "Failed to delete endpoint: $error_msg"
        echo ""
        echo "Response:"
        echo "$response" | jq .
        exit 1
    fi

    json_log "$SCRIPT_NAME" "delete" "ok" "Endpoint deleted from RunPod"

    # =========================================================================
    # Clean Up Local State
    # =========================================================================

    print_status "info" "Cleaning up local state..."

    # Remove endpoint file
    if [ -f "$ENDPOINT_FILE" ]; then
        rm -f "$ENDPOINT_FILE"
        json_log "$SCRIPT_NAME" "cleanup" "ok" "Removed endpoint.json"
    fi

    # Update .env to clear endpoint ID
    update_env_file "RUNPOD_ENDPOINT_ID" "TO_BE_DISCOVERED"

    json_log "$SCRIPT_NAME" "cleanup" "ok" "Updated .env"

    # =========================================================================
    # Summary
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Endpoint deleted successfully!"
    print_status "ok" "============================================"
    echo ""
    echo "Deleted: $RUNPOD_ENDPOINT_ID"
    echo ""
    echo "Local state cleaned up:"
    echo "  - endpoint.json removed"
    echo "  - .env updated (RUNPOD_ENDPOINT_ID cleared)"
    echo ""
    echo "To create a new endpoint:"
    echo "  ./scripts/210-create-endpoint.sh"
    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
