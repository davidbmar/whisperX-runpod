#!/bin/bash
# =============================================================================
# Test WhisperX Transcription on RunPod Endpoint
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Validates endpoint is available
#   2. Sends a test audio file for transcription
#   3. Waits for and displays transcription results
#   4. Shows timing and performance metrics
#
# PREREQUISITES:
#   - Endpoint created and running (run 210-create-endpoint.sh first)
#   - Test audio file (or provide URL)
#
# CONFIGURATION:
#   All settings read from .env file:
#   - RUNPOD_API_KEY: RunPod API key
#   - RUNPOD_ENDPOINT_ID: Endpoint ID
#
# Usage: ./scripts/220-test-transcription.sh [OPTIONS]
#
# Options:
#   --file FILE    Audio file to transcribe
#   --url URL      Audio URL to transcribe
#   --no-diarize   Disable speaker diarization
#   --language XX  Force language code (e.g., en, es, fr)
#   --help         Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="220-test-transcription"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Start logging
start_logging "$SCRIPT_NAME"

# =============================================================================
# Parse Arguments
# =============================================================================

AUDIO_FILE=""
AUDIO_URL=""
DIARIZE=true
LANGUAGE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            AUDIO_FILE="$2"
            shift 2
            ;;
        --url)
            AUDIO_URL="$2"
            shift 2
            ;;
        --no-diarize)
            DIARIZE=false
            shift
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--file FILE] [--url URL] [--no-diarize] [--language XX]"
            echo ""
            echo "Options:"
            echo "  --file FILE    Audio file to transcribe"
            echo "  --url URL      Audio URL to transcribe"
            echo "  --no-diarize   Disable speaker diarization"
            echo "  --language XX  Force language code (e.g., en, es, fr)"
            echo ""
            echo "If no file or URL is provided, uses a sample audio URL."
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
    json_log "$SCRIPT_NAME" "start" "ok" "Starting transcription test"

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

    # =========================================================================
    # Prepare Audio Input
    # =========================================================================

    local input_json=""

    if [ -n "$AUDIO_FILE" ]; then
        # Check file exists
        if [ ! -f "$AUDIO_FILE" ]; then
            print_status "error" "Audio file not found: $AUDIO_FILE"
            exit 1
        fi

        # Encode to base64
        print_status "info" "Encoding audio file: $AUDIO_FILE"
        local file_size=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || stat -c%s "$AUDIO_FILE" 2>/dev/null)
        local audio_base64=$(base64 -w0 "$AUDIO_FILE" 2>/dev/null || base64 "$AUDIO_FILE" 2>/dev/null)

        json_log "$SCRIPT_NAME" "encode_audio" "ok" "Audio encoded" \
            "file=$AUDIO_FILE" \
            "size=$file_size"

        input_json="{\"audio_base64\":\"$audio_base64\""

    elif [ -n "$AUDIO_URL" ]; then
        print_status "info" "Using audio URL: $AUDIO_URL"
        input_json="{\"audio_url\":\"$AUDIO_URL\""

    else
        # Use sample audio URL
        AUDIO_URL="https://github.com/openai/whisper/raw/main/tests/jfk.flac"
        print_status "info" "Using sample audio: JFK speech"
        print_status "info" "URL: $AUDIO_URL"
        input_json="{\"audio_url\":\"$AUDIO_URL\""
    fi

    # Add options
    input_json+=",\"diarize\":$DIARIZE"

    if [ -n "$LANGUAGE" ]; then
        input_json+=",\"language\":\"$LANGUAGE\""
    fi

    input_json+="}"

    # =========================================================================
    # Send Request
    # =========================================================================

    print_status "info" "Sending transcription request..."
    echo ""
    echo "Endpoint: $RUNPOD_ENDPOINT_ID"
    echo "Diarization: $DIARIZE"
    if [ -n "$LANGUAGE" ]; then
        echo "Language: $LANGUAGE"
    fi
    echo ""

    local runsync_url="${RUNPOD_API_BASE}/${RUNPOD_ENDPOINT_ID}/runsync"
    local request_body="{\"input\":$input_json}"

    local start_time=$(date +%s.%N)

    json_log "$SCRIPT_NAME" "request_sent" "ok" "Request sent to RunPod"

    local response=$(curl -s -X POST "$runsync_url" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        --max-time 600)

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    # =========================================================================
    # Handle Response
    # =========================================================================

    # Check for errors
    if echo "$response" | jq -e '.error' &>/dev/null; then
        local error_msg=$(echo "$response" | jq -r '.error // "Unknown error"')
        json_log "$SCRIPT_NAME" "transcription" "error" "Request failed: $error_msg"
        print_status "error" "Request failed: $error_msg"
        echo ""
        echo "Full response:"
        echo "$response" | jq .
        exit 1
    fi

    # Check status
    local status=$(echo "$response" | jq -r '.status // "unknown"')

    if [ "$status" = "FAILED" ]; then
        local error_msg=$(echo "$response" | jq -r '.error // "Unknown error"')
        json_log "$SCRIPT_NAME" "transcription" "error" "Transcription failed: $error_msg"
        print_status "error" "Transcription failed: $error_msg"
        exit 1
    fi

    if [ "$status" != "COMPLETED" ]; then
        print_status "warn" "Unexpected status: $status"
        echo "Response:"
        echo "$response" | jq .
        exit 1
    fi

    # Extract results
    local output=$(echo "$response" | jq '.output')

    # Check for error in output
    if echo "$output" | jq -e '.error' &>/dev/null; then
        local error_msg=$(echo "$output" | jq -r '.error')
        json_log "$SCRIPT_NAME" "transcription" "error" "Transcription error: $error_msg"
        print_status "error" "Transcription error: $error_msg"
        exit 1
    fi

    local language=$(echo "$output" | jq -r '.language // "unknown"')
    local segment_count=$(echo "$output" | jq '.segments | length')
    local speakers=$(echo "$output" | jq -r '.speakers // [] | join(", ")')

    json_log "$SCRIPT_NAME" "transcription" "ok" "Transcription complete" \
        "duration=${duration}s" \
        "segments=$segment_count" \
        "language=$language"

    # =========================================================================
    # Display Results
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Transcription Results"
    print_status "ok" "============================================"
    echo ""
    echo "Status: $status"
    echo "Duration: ${duration}s"
    echo "Language: $language"
    echo "Segments: $segment_count"

    if [ -n "$speakers" ] && [ "$speakers" != "" ]; then
        echo "Speakers: $speakers"
    fi

    echo ""
    echo "--- Transcript ---"
    echo ""

    # Print segments with speaker labels if available
    echo "$output" | jq -r '.segments[] |
        (if .speaker then "[\(.speaker)] " else "" end) +
        "[\(.start | tostring | .[0:5])s - \(.end | tostring | .[0:5])s] " +
        .text'

    echo ""
    echo "--- End Transcript ---"
    echo ""

    # =========================================================================
    # Save Output
    # =========================================================================

    mkdir -p "$ARTIFACTS_DIR"
    local output_file="$ARTIFACTS_DIR/transcription-$(date +%Y%m%d-%H%M%S).json"
    echo "$output" | jq . > "$output_file"

    print_status "ok" "Full output saved to: $output_file"
    echo ""

    # =========================================================================
    # Performance Summary
    # =========================================================================

    print_status "ok" "============================================"
    print_status "ok" "Performance Summary"
    print_status "ok" "============================================"
    echo ""
    echo "Total request time: ${duration}s"
    echo "Segments processed: $segment_count"
    echo ""

    # Calculate execution time from RunPod response if available
    local exec_time=$(echo "$response" | jq -r '.executionTime // 0')
    if [ "$exec_time" != "0" ] && [ "$exec_time" != "null" ]; then
        echo "RunPod execution time: ${exec_time}ms"
    fi

    local delay_time=$(echo "$response" | jq -r '.delayTime // 0')
    if [ "$delay_time" != "0" ] && [ "$delay_time" != "null" ]; then
        echo "Queue delay time: ${delay_time}ms"
    fi

    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
