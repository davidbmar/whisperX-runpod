#!/bin/bash
# =============================================================================
# 320-LOCAL--test-runpod-gpu-api.sh
# =============================================================================
# Tests the WhisperX API running on a RunPod GPU pod
#
# WHAT THIS SCRIPT DOES:
#   1. Gets pod endpoint from RunPod API (or uses provided values)
#   2. Tests the /health endpoint
#   3. Tests transcription with a sample audio file
#   4. Reports timing and results
#
# PREREQUISITES:
#   - RunPod pod running (300-LOCAL--create-runpod-gpu.sh)
#   - Pod endpoint accessible (port 8000 exposed)
#
# DEBUGGING:
#   - All output logged to logs/320-LOCAL--test-runpod-gpu-api-TIMESTAMP.log
#   - Use --debug for verbose output
#   - Check pod logs: ./scripts/330-LOCAL--view-runpod-gpu-logs.sh
#
# Usage: ./scripts/320-LOCAL--test-runpod-gpu-api.sh [OPTIONS]
#
# Options:
#   --host HOST       API host (auto-detected from pod if not provided)
#   --port PORT       API port (default: 8000)
#   --pod-id ID       Pod ID (default: from RUNPOD_POD_ID in .env)
#   --file FILE       Audio file to transcribe (local path)
#   --url URL         Audio URL to transcribe
#   --health-only     Only run health check
#   --quick           Use short test audio (~10s)
#   --debug           Show detailed output
#   --help            Show this help message
#
# Examples:
#   ./scripts/320-LOCAL--test-runpod-gpu-api.sh
#   ./scripts/320-LOCAL--test-runpod-gpu-api.sh --health-only
#   ./scripts/320-LOCAL--test-runpod-gpu-api.sh --file audio.mp3
#   ./scripts/320-LOCAL--test-runpod-gpu-api.sh --url "https://example.com/audio.mp3"
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="320-LOCAL--test-runpod-gpu-api"
SCRIPT_VERSION="2.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

RUNPOD_REST_API="https://rest.runpod.io/v1"
POD_ID=""
API_HOST=""
API_PORT="8000"
AUDIO_FILE=""
AUDIO_URL=""
HEALTH_ONLY=false
QUICK_TEST=false
DEBUG_MODE=false

# Test audio URL (JFK speech - ~20 seconds)
DEFAULT_TEST_URL="https://github.com/openai/whisper/raw/main/tests/jfk.flac"

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
        --file)
            AUDIO_FILE="$2"
            shift 2
            ;;
        --url)
            AUDIO_URL="$2"
            shift 2
            ;;
        --health-only)
            HEALTH_ONLY=true
            shift
            ;;
        --quick)
            QUICK_TEST=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --help)
            head -55 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Debug Helper
# =============================================================================

debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN:-}[DEBUG] $1${NC:-}"
    fi
}

# =============================================================================
# Get Pod Endpoint
# =============================================================================

get_pod_endpoint() {
    if [ -n "$API_HOST" ]; then
        debug_log "Using provided host: $API_HOST"
        return 0
    fi

    print_status "info" "Getting pod endpoint from RunPod API..."

    POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"

    if [ -z "$POD_ID" ]; then
        # Try to get from .env
        if [ -n "${RUNPOD_API_HOST:-}" ]; then
            API_HOST="$RUNPOD_API_HOST"
            API_PORT="${RUNPOD_API_PORT:-8000}"
            debug_log "Using endpoint from .env: $API_HOST:$API_PORT"
            return 0
        fi

        print_status "error" "No pod ID configured and no --host provided"
        echo ""
        echo "Either:"
        echo "  1. Provide --host and --port"
        echo "  2. Create a pod: ./scripts/300-LOCAL--create-runpod-gpu.sh"
        echo "  3. Set RUNPOD_POD_ID in .env"
        exit 1
    fi

    local response=$(curl -s "${RUNPOD_REST_API}/pods/${POD_ID}" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}")

    local status=$(echo "$response" | jq -r '.desiredStatus // .status // "unknown"')

    if [ "$status" != "RUNNING" ]; then
        print_status "error" "Pod is not running (status: $status)"
        echo ""
        echo "Start the pod or check its status:"
        echo "  ./scripts/330-LOCAL--view-runpod-gpu-logs.sh"
        exit 1
    fi

    API_HOST=$(echo "$response" | jq -r '.runtime.ports[0].ip // empty')
    API_PORT=$(echo "$response" | jq -r '.runtime.ports[0].publicPort // empty')

    if [ -z "$API_HOST" ] || [ -z "$API_PORT" ]; then
        print_status "error" "Could not get pod endpoint from API"
        echo "$response" | jq .
        exit 1
    fi

    print_status "ok" "Found endpoint: ${API_HOST}:${API_PORT}"
}

# =============================================================================
# Health Check
# =============================================================================

test_health() {
    local url="http://${API_HOST}:${API_PORT}/health"

    print_status "info" "Testing health endpoint..."
    echo "  URL: $url"
    echo ""

    local start_time=$(date +%s.%N)
    local response=$(curl -s -w "\n%{http_code}" "$url" --connect-timeout 10 --max-time 30 2>&1)
    local end_time=$(date +%s.%N)

    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)

    local elapsed=$(echo "$end_time - $start_time" | bc)

    if [ "$http_code" = "200" ]; then
        print_status "ok" "Health check passed (${elapsed}s)"
        echo ""
        echo "  Response:"
        echo "$body" | jq . 2>/dev/null | sed 's/^/    /'
        echo ""

        # Parse response for useful info
        local device=$(echo "$body" | jq -r '.device // "unknown"')
        local model=$(echo "$body" | jq -r '.model // "unknown"')
        local diarization=$(echo "$body" | jq -r '.diarization // "unknown"')

        echo "  Summary:"
        echo "    Device: $device"
        echo "    Model: $model"
        echo "    Diarization: $diarization"
        echo ""

        json_log "$SCRIPT_NAME" "health_check" "ok" "Health check passed" \
            "elapsed=${elapsed}" "device=$device" "model=$model"

        return 0
    else
        print_status "error" "Health check failed (HTTP $http_code)"
        echo ""
        echo "  Response: $body"
        echo ""
        echo "  Troubleshooting:"
        echo "    1. Check if pod is running: ./scripts/330-LOCAL--view-runpod-gpu-logs.sh"
        echo "    2. Check pod logs for errors"
        echo "    3. Verify the endpoint is correct"
        return 1
    fi
}

# =============================================================================
# Transcription Test
# =============================================================================

test_transcription() {
    print_status "info" "Testing transcription..."
    echo ""

    local url=""
    local method=""
    local data_args=()

    if [ -n "$AUDIO_FILE" ]; then
        # File upload
        if [ ! -f "$AUDIO_FILE" ]; then
            print_status "error" "Audio file not found: $AUDIO_FILE"
            exit 1
        fi

        local file_size=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || stat -c%s "$AUDIO_FILE")
        print_status "info" "Uploading file: $AUDIO_FILE ($(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "${file_size} bytes"))"

        url="http://${API_HOST}:${API_PORT}/transcribe/upload"
        method="POST"
        data_args=(-F "file=@${AUDIO_FILE}" -F "language=en" -F "diarize=false")

    elif [ -n "$AUDIO_URL" ]; then
        # URL-based
        print_status "info" "Using audio URL: $AUDIO_URL"

        url="http://${API_HOST}:${API_PORT}/transcribe"
        method="POST"
        data_args=(
            -H "Content-Type: application/json"
            -d "{\"audio_url\": \"$AUDIO_URL\", \"language\": \"en\", \"diarize\": false}"
        )

    else
        # Default test URL
        print_status "info" "Using default test audio (JFK speech, ~20s)"
        AUDIO_URL="$DEFAULT_TEST_URL"

        url="http://${API_HOST}:${API_PORT}/transcribe"
        method="POST"
        data_args=(
            -H "Content-Type: application/json"
            -d "{\"audio_url\": \"$AUDIO_URL\", \"language\": \"en\", \"diarize\": false}"
        )
    fi

    echo "  Endpoint: $url"
    echo ""

    print_status "info" "Sending transcription request..."
    local start_time=$(date +%s.%N)

    local response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
        -X "$method" \
        "$url" \
        "${data_args[@]}" \
        --connect-timeout 30 \
        --max-time 600 \
        2>&1)

    local end_time=$(date +%s.%N)

    local http_code=$(echo "$response" | grep "__HTTP_CODE__" | sed 's/__HTTP_CODE__//')
    local body=$(echo "$response" | grep -v "__HTTP_CODE__")

    local elapsed=$(echo "$end_time - $start_time" | bc)

    echo ""

    if [ "$http_code" = "200" ]; then
        print_status "ok" "============================================"
        print_status "ok" "TRANSCRIPTION SUCCESSFUL!"
        print_status "ok" "============================================"
        echo ""
        echo "  Total time: ${elapsed}s"
        echo ""

        # Parse response
        local proc_time=$(echo "$body" | jq -r '.processing_time_seconds // "N/A"')
        local segment_count=$(echo "$body" | jq -r '.segments | length // 0')
        local full_text=$(echo "$body" | jq -r '.text // (.segments | map(.text) | join(" ")) // "N/A"')

        echo "  Processing time: ${proc_time}s"
        echo "  Segments: $segment_count"
        echo ""
        echo "  Transcription:"
        echo "  ─────────────────────────────────────────"
        echo "$full_text" | fold -s -w 60 | sed 's/^/    /'
        echo "  ─────────────────────────────────────────"
        echo ""

        # Save full response
        local output_file="$PROJECT_ROOT/artifacts/transcription-test-$(date +%Y%m%d-%H%M%S).json"
        echo "$body" | jq . > "$output_file" 2>/dev/null || echo "$body" > "$output_file"
        print_status "ok" "Full response saved to: $output_file"

        json_log "$SCRIPT_NAME" "transcription" "ok" "Transcription successful" \
            "elapsed=${elapsed}" "processing_time=${proc_time}" "segments=$segment_count"

        return 0
    else
        print_status "error" "Transcription failed (HTTP $http_code)"
        echo ""
        echo "  Response:"
        echo "$body" | jq . 2>/dev/null | head -30 || echo "$body" | head -30
        echo ""
        echo "  Troubleshooting:"
        echo "    1. Check pod logs: ./scripts/330-LOCAL--view-runpod-gpu-logs.sh"
        echo "    2. Verify audio URL is accessible"
        echo "    3. Try a different audio file/URL"

        json_log "$SCRIPT_NAME" "transcription" "error" "HTTP $http_code" "elapsed=${elapsed}"

        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    print_status "info" "============================================"
    print_status "info" "RunPod WhisperX API Tester v${SCRIPT_VERSION}"
    print_status "info" "============================================"
    echo ""

    # Load environment
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi

    # Get pod endpoint
    get_pod_endpoint

    echo ""
    echo "  Target: http://${API_HOST}:${API_PORT}"
    echo ""

    # Health check
    if ! test_health; then
        exit 1
    fi

    # Transcription test
    if [ "$HEALTH_ONLY" = true ]; then
        print_status "ok" "Health check complete (--health-only specified)"
        exit 0
    fi

    echo ""
    if ! test_transcription; then
        exit 1
    fi

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "ALL TESTS PASSED!"
    print_status "ok" "============================================"
    echo ""
    echo "  Your WhisperX pod is ready for production use."
    echo ""
    echo "  Example usage:"
    echo "    curl -X POST 'http://${API_HOST}:${API_PORT}/transcribe/upload' \\"
    echo "      -F 'file=@your-audio.mp3' \\"
    echo "      -F 'language=en'"
    echo ""
}

# =============================================================================
# Run
# =============================================================================

main "$@"
