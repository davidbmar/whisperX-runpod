#!/bin/bash
# =============================================================================
# Common Functions for WhisperX-RunPod
# =============================================================================
# Shared library for deployment and management scripts
# Version: 1.0.0
#
# WHAT THIS LIBRARY PROVIDES:
#   - Logging functions (JSON structured, file-based)
#   - Environment management (.env loading, updating)
#   - RunPod API functions (create/delete endpoints, status)
#   - Utility functions (duration formatting, status output)
# =============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$PROJECT_ROOT/artifacts}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"

# Ensure directories exist
mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"

# State files
ENDPOINT_FILE="$ARTIFACTS_DIR/endpoint.json"

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# RunPod API
RUNPOD_API_BASE="https://api.runpod.io/v2"

# ============================================================================
# JSON Logging
# ============================================================================

json_log() {
    local script="${1:-unknown}"
    local step="${2:-unknown}"
    local status="${3:-ok}"
    local details="${4:-}"
    shift 4 || true

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Build JSON object
    local json='{'
    json+='"ts":"'$timestamp'"'
    json+=',"script":"'$script'"'
    json+=',"step":"'$step'"'
    json+=',"status":"'$status'"'
    json+=',"details":"'$(echo "$details" | sed 's/"/\\"/g')'"'

    # Parse additional key=value pairs
    while [ $# -gt 0 ]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        if [ "$key" != "$1" ]; then
            if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                json+=',"'$key'":'$value
            else
                json+=',"'$key'":"'$(echo "$value" | sed 's/"/\\"/g')'"'
            fi
        fi
        shift
    done

    json+='}'

    # Print to console with color coding
    local color="$NC"
    case "$status" in
        ok) color="$GREEN" ;;
        warn) color="$YELLOW" ;;
        error) color="$RED" ;;
    esac

    echo -e "${color}[$step] $details${NC}" >&2
}

# ============================================================================
# File Logging
# ============================================================================

# Global to track if logging has been started
_LOGGING_STARTED="${_LOGGING_STARTED:-false}"
_LOG_FILE=""

start_logging() {
    local script_name="${1:-${SCRIPT_NAME:-unknown}}"

    # Don't start logging twice
    if [ "$_LOGGING_STARTED" = "true" ]; then
        return 0
    fi

    # Create log filename
    local timestamp=$(date +%Y%m%d-%H%M%S)
    _LOG_FILE="$LOGS_DIR/${script_name}-${timestamp}.log"

    # Redirect stdout and stderr to both console and log file
    exec > >(tee -a "$_LOG_FILE") 2>&1

    _LOGGING_STARTED="true"

    # Log header
    echo "============================================================================"
    echo "Log started: $(date)"
    echo "Script: $script_name"
    echo "Log file: $_LOG_FILE"
    echo "============================================================================"
    echo ""
}

get_log_file() {
    echo "$_LOG_FILE"
}

# ============================================================================
# Status Output
# ============================================================================

print_status() {
    local status="$1"
    local message="$2"

    case "$status" in
        ok)
            echo -e "${GREEN}${message}${NC}"
            ;;
        warn)
            echo -e "${YELLOW}${message}${NC}"
            ;;
        error)
            echo -e "${RED}${message}${NC}"
            ;;
        info)
            echo -e "${BLUE}${message}${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# ============================================================================
# Environment Management
# ============================================================================

load_env_or_fail() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Configuration file not found: $ENV_FILE${NC}"
        echo "Run: ./scripts/000-questions.sh"
        return 1
    fi

    source "$ENV_FILE"
    json_log "${SCRIPT_NAME:-common}" "load_env" "ok" "Environment loaded from $ENV_FILE"
}

update_env_file() {
    local key="$1"
    local value="$2"
    local temp_file="${ENV_FILE}.tmp.$$"

    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$temp_file"
    else
        cp "$ENV_FILE" "$temp_file"
        echo "${key}=${value}" >> "$temp_file"
    fi

    # Update ENV_VERSION
    if grep -q "^ENV_VERSION=" "$temp_file"; then
        local current_version=$(grep "^ENV_VERSION=" "$temp_file" | cut -d= -f2)
        local new_version=$((current_version + 1))
        sed -i "s|^ENV_VERSION=.*|ENV_VERSION=${new_version}|" "$temp_file"
    fi

    mv -f "$temp_file" "$ENV_FILE"
}

# ============================================================================
# RunPod API Functions
# ============================================================================

runpod_api_call() {
    # Make authenticated API call to RunPod
    # Usage: runpod_api_call METHOD ENDPOINT [DATA]
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        echo '{"error": "RUNPOD_API_KEY not set"}' >&2
        return 1
    fi

    local curl_args=(
        -s
        -X "$method"
        -H "Authorization: Bearer ${RUNPOD_API_KEY}"
        -H "Content-Type: application/json"
    )

    if [ -n "$data" ]; then
        curl_args+=(-d "$data")
    fi

    curl "${curl_args[@]}" "${RUNPOD_API_BASE}${endpoint}"
}

get_runpod_endpoint_status() {
    # Get status of a RunPod endpoint
    # Usage: get_runpod_endpoint_status [ENDPOINT_ID]
    local endpoint_id="${1:-${RUNPOD_ENDPOINT_ID:-}}"

    if [ -z "$endpoint_id" ] || [ "$endpoint_id" = "TO_BE_DISCOVERED" ]; then
        echo "not_found"
        return 0
    fi

    local response=$(runpod_api_call "GET" "/${endpoint_id}/health" 2>/dev/null || echo '{}')

    # Check for errors
    if echo "$response" | jq -e '.error' &>/dev/null; then
        echo "error"
        return 1
    fi

    # Extract workers info
    local workers=$(echo "$response" | jq -r '.workers // {}' 2>/dev/null)
    local ready=$(echo "$workers" | jq -r '.ready // 0' 2>/dev/null)
    local running=$(echo "$workers" | jq -r '.running // 0' 2>/dev/null)

    if [ "$ready" -gt 0 ] || [ "$running" -gt 0 ]; then
        echo "running"
    else
        echo "idle"
    fi
}

test_runpod_endpoint() {
    # Send a test request to RunPod endpoint
    # Usage: test_runpod_endpoint [ENDPOINT_ID] [INPUT_JSON]
    local endpoint_id="${1:-${RUNPOD_ENDPOINT_ID:-}}"
    local input_json="${2:-'{\"input\": {\"test\": true}}'}"

    if [ -z "$endpoint_id" ] || [ "$endpoint_id" = "TO_BE_DISCOVERED" ]; then
        echo '{"error": "No endpoint ID"}'
        return 1
    fi

    runpod_api_call "POST" "/${endpoint_id}/runsync" "$input_json"
}

delete_runpod_endpoint() {
    # Delete a RunPod endpoint
    # Note: RunPod endpoints are managed via the web console
    # This function just clears local state
    local endpoint_id="${1:-${RUNPOD_ENDPOINT_ID:-}}"

    if [ -f "$ENDPOINT_FILE" ]; then
        rm -f "$ENDPOINT_FILE"
    fi

    if [ -n "$endpoint_id" ] && [ "$endpoint_id" != "TO_BE_DISCOVERED" ]; then
        update_env_file "RUNPOD_ENDPOINT_ID" "TO_BE_DISCOVERED"
    fi

    echo "Local endpoint state cleared"
    echo "Note: Delete the endpoint from RunPod console: https://www.runpod.io/console/serverless"
}

# ============================================================================
# Utility Functions
# ============================================================================

format_duration() {
    # Format seconds into human-readable duration
    # Usage: format_duration SECONDS
    local seconds="$1"

    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        local secs=$((seconds % 60))
        echo "${hours}h ${mins}m ${secs}s"
    fi
}

# ============================================================================
# Model to GPU Mapping
# ============================================================================

get_gpu_type_for_model() {
    # Returns recommended GPU type for a given Whisper model
    # Usage: get_gpu_type_for_model MODEL_NAME
    local model="${1:-small}"

    case "$model" in
        tiny|base|small|medium)
            echo "NVIDIA RTX A4000"
            ;;
        large-v2)
            echo "NVIDIA RTX A5000"
            ;;
        large-v3)
            echo "NVIDIA RTX A6000"
            ;;
        *)
            echo "NVIDIA RTX A4000"
            ;;
    esac
}

get_gpu_cost_for_model() {
    # Returns estimated hourly cost for a given model's GPU
    # Usage: get_gpu_cost_for_model MODEL_NAME
    local model="${1:-small}"

    case "$model" in
        tiny|base|small|medium)
            echo "0.20"
            ;;
        large-v2)
            echo "0.30"
            ;;
        large-v3)
            echo "0.50"
            ;;
        *)
            echo "0.20"
            ;;
    esac
}

# ============================================================================
# Self Test
# ============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "WhisperX-RunPod Common Functions Library v1.0.0"
    echo "================================================"
    echo ""
    echo "Available functions:"
    echo "  - Logging: json_log, start_logging, print_status"
    echo "  - Environment: load_env_or_fail, update_env_file"
    echo "  - RunPod: runpod_api_call, get_runpod_endpoint_status,"
    echo "            test_runpod_endpoint, delete_runpod_endpoint"
    echo "  - Models: get_gpu_type_for_model, get_gpu_cost_for_model"
    echo "  - Utility: format_duration"
    echo ""
    echo "To use in your script:"
    echo '  source "$(dirname "$0")/common-library.sh"'
fi
