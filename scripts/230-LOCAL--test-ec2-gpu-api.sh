#!/bin/bash
# =============================================================================
# LOCAL → Test EC2 GPU API
# =============================================================================
#
# PLAIN ENGLISH:
#   This script runs on YOUR computer (the build box) and tests the WhisperX
#   API running on a remote EC2 GPU instance. Think of it like this: you're
#   sitting at your laptop, and you want to check if the powerful GPU server
#   in the cloud is working correctly. This script sends a test audio file
#   (a famous JFK speech clip) to that server and checks if it can transcribe
#   it properly. It's like sending a "ping" but instead of just checking if
#   the server is alive, we're checking if the AI transcription is working.
#
# WHAT THIS SCRIPT DOES:
#   1. Checks API health endpoint
#   2. Submits test transcription request (JFK speech by default)
#   3. Displays results with timing information
#
# WHERE IT RUNS:
#   - Runs on: Your build box (LOCAL)
#   - Talks to: EC2 GPU instance (REMOTE)
#
# PREREQUISITES:
#   - WhisperX container running on EC2 (use 210-LOCAL--deploy-to-ec2-gpu.sh)
#   - API accessible on specified host:port
#
# Usage: ./scripts/230-LOCAL--test-ec2-gpu-api.sh [OPTIONS]
#
# Options:
#   --host HOST     API host (default: from AWS_EC2_HOST or localhost)
#   --port PORT     API port (default: 8000)
#   --url URL       Audio URL to transcribe (default: JFK speech)
#   --file FILE     Audio file to upload instead of URL
#   --no-diarize    Disable speaker diarization
#   --language LANG Force language code (e.g., en, es, fr)
#   --health        Only check health endpoint
#   --help          Show this help message
#
# Examples:
#   ./scripts/220-ec2--test-api.sh --host ec2-xx-xx.amazonaws.com
#   ./scripts/220-ec2--test-api.sh --file test-audio/meeting.wav
#   ./scripts/220-ec2--test-api.sh --url https://example.com/audio.mp3
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="220-ec2--test-api"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

# Load .env first
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Try to get host from state file if not in env
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"
if [ -z "${AWS_EC2_HOST:-}" ] && [ -f "$EC2_STATE_FILE" ]; then
    AWS_EC2_HOST=$(jq -r '.public_ip // empty' "$EC2_STATE_FILE" 2>/dev/null || true)
fi

API_HOST="${AWS_EC2_HOST:-localhost}"
API_PORT="${API_PORT:-8000}"
AUDIO_URL=""
AUDIO_FILE=""
DIARIZE="true"
LANGUAGE=""
HEALTH_ONLY="false"

# Default test audio URL (JFK "ask not what your country can do for you" speech)
DEFAULT_AUDIO_URL="https://github.com/openai/whisper/raw/main/tests/jfk.flac"

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            API_HOST="$2"
            shift 2
            ;;
        --port)
            API_PORT="$2"
            shift 2
            ;;
        --url)
            AUDIO_URL="$2"
            shift 2
            ;;
        --file)
            AUDIO_FILE="$2"
            shift 2
            ;;
        --no-diarize)
            DIARIZE="false"
            shift
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --health)
            HEALTH_ONLY="true"
            shift
            ;;
        --help)
            echo "Usage: $0 [--host HOST] [--port PORT] [--url URL] [--file FILE]"
            echo ""
            echo "Test the WhisperX API with a sample transcription."
            echo ""
            echo "Options:"
            echo "  --host HOST     API host (default: \$AWS_EC2_HOST or localhost)"
            echo "  --port PORT     API port (default: 8000)"
            echo "  --url URL       Audio URL to transcribe"
            echo "  --file FILE     Audio file to upload"
            echo "  --no-diarize    Disable speaker diarization"
            echo "  --language LANG Force language code (en, es, fr, etc.)"
            echo "  --health        Only check health endpoint"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# API URL
# =============================================================================

API_BASE="http://${API_HOST}:${API_PORT}"

# =============================================================================
# Health Check
# =============================================================================

check_health() {
    print_status "info" "Checking API health..."
    echo "URL: ${API_BASE}/health"
    echo ""

    local response
    if ! response=$(curl -s --connect-timeout 10 "${API_BASE}/health"); then
        print_status "error" "Failed to connect to API at $API_BASE"
        echo ""
        echo "Make sure:"
        echo "  1. Container is running on the host"
        echo "  2. Port $API_PORT is accessible (check security group/firewall)"
        echo "  3. Host address is correct"
        return 1
    fi

    if echo "$response" | jq -e '.status == "ok"' &>/dev/null; then
        print_status "ok" "API is healthy"
        echo ""
        echo "$response" | jq .
        return 0
    else
        print_status "error" "API returned unexpected response"
        echo "$response"
        return 1
    fi
}

# =============================================================================
# Transcribe from URL
# =============================================================================

transcribe_url() {
    local url="$1"

    print_status "info" "Transcribing audio from URL..."
    echo "URL: $url"
    echo "Diarize: $DIARIZE"
    [ -n "$LANGUAGE" ] && echo "Language: $LANGUAGE"
    echo ""

    # Build JSON payload
    local payload=$(jq -n \
        --arg url "$url" \
        --argjson diarize "$DIARIZE" \
        --arg lang "$LANGUAGE" \
        '{
            audio_url: $url,
            diarize: $diarize
        } + (if $lang != "" then {language: $lang} else {} end)')

    echo "Request payload:"
    echo "$payload" | jq .
    echo ""

    print_status "info" "Sending request (this may take 30-60 seconds)..."

    # Time the request
    local start_time=$(date +%s.%N)

    local response
    if ! response=$(curl -s --connect-timeout 300 -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${API_BASE}/transcribe"); then
        print_status "error" "Request failed"
        return 1
    fi

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Transcription failed"
        echo "$response" | jq .
        return 1
    fi

    # Success
    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Transcription Complete!"
    print_status "ok" "============================================"
    echo ""

    echo "=== SUMMARY ==="
    echo "Segments: $(echo "$response" | jq '.segments | length')"
    echo "Language: $(echo "$response" | jq -r '.language')"

    local speakers=$(echo "$response" | jq -r '.speakers // [] | join(", ")')
    [ -n "$speakers" ] && [ "$speakers" != "" ] && echo "Speakers: $speakers"

    local server_time=$(echo "$response" | jq -r '.processing_time_seconds // "N/A"')
    echo "Server processing time: ${server_time}s"
    echo "Total request time: ${duration}s"
    echo ""

    # Show transcript
    echo "=== TRANSCRIPT ==="
    echo "$response" | jq -r '.segments[] | "\(.start | tostring | .[0:5])s: \(.text)"'
    echo ""

    # Show full JSON (collapsed)
    echo "=== FULL RESPONSE (run with | jq for details) ==="
    echo "$response" | jq -c .
}

# =============================================================================
# Transcribe from File
# =============================================================================

transcribe_file() {
    local file="$1"

    # Check file exists
    if [ ! -f "$file" ]; then
        print_status "error" "File not found: $file"
        return 1
    fi

    local file_size=$(du -h "$file" | cut -f1)
    print_status "info" "Uploading and transcribing file..."
    echo "File: $file"
    echo "Size: $file_size"
    echo "Diarize: $DIARIZE"
    [ -n "$LANGUAGE" ] && echo "Language: $LANGUAGE"
    echo ""

    print_status "info" "Uploading (this may take a while for large files)..."

    # Time the request
    local start_time=$(date +%s.%N)

    local response
    local curl_args=(
        -s --connect-timeout 300
        -X POST
        -F "file=@$file"
        -F "diarize=$DIARIZE"
    )
    [ -n "$LANGUAGE" ] && curl_args+=(-F "language=$LANGUAGE")

    if ! response=$(curl "${curl_args[@]}" "${API_BASE}/transcribe/upload"); then
        print_status "error" "Upload failed"
        return 1
    fi

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Transcription failed"
        echo "$response" | jq .
        return 1
    fi

    # Success
    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Transcription Complete!"
    print_status "ok" "============================================"
    echo ""

    echo "=== SUMMARY ==="
    echo "Segments: $(echo "$response" | jq '.segments | length')"
    echo "Language: $(echo "$response" | jq -r '.language')"

    local speakers=$(echo "$response" | jq -r '.speakers // [] | join(", ")')
    [ -n "$speakers" ] && [ "$speakers" != "" ] && echo "Speakers: $speakers"

    local server_time=$(echo "$response" | jq -r '.processing_time_seconds // "N/A"')
    echo "Server processing time: ${server_time}s"
    echo "Total request time: ${duration}s"
    echo ""

    # Show transcript
    echo "=== TRANSCRIPT ==="
    echo "$response" | jq -r '.segments[] | "\(.start | tostring | .[0:5])s: \(.text)"'
}

# =============================================================================
# Main
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Testing API" "host=$API_HOST"

    echo ""
    print_status "info" "WhisperX API Test"
    echo "API: $API_BASE"
    echo ""

    # Health check first
    if ! check_health; then
        exit 1
    fi

    if [ "$HEALTH_ONLY" = "true" ]; then
        exit 0
    fi

    echo ""
    echo "============================================"
    echo ""

    # Transcribe
    if [ -n "$AUDIO_FILE" ]; then
        transcribe_file "$AUDIO_FILE"
    elif [ -n "$AUDIO_URL" ]; then
        transcribe_url "$AUDIO_URL"
    else
        # Use default test audio
        print_status "info" "Using default test audio (JFK speech, 11 seconds)"
        echo ""
        transcribe_url "$DEFAULT_AUDIO_URL"
    fi
}

# =============================================================================
# Run
# =============================================================================

main "$@"
