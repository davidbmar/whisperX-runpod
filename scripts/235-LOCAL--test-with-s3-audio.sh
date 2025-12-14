#!/bin/bash
# =============================================================================
# LOCAL → Test EC2 GPU with S3 Audio Files
# =============================================================================
#
# PLAIN ENGLISH:
#   This script tests your WhisperX transcription service using real audio files
#   stored in Amazon S3. Instead of using a tiny test clip, this lets you test
#   with your actual audio files to see how well the transcription works on
#   real-world data.
#
#   The script downloads the audio from S3 to your local machine, then uploads
#   it to the EC2 GPU server for transcription. This tests the full pipeline
#   you'd use in production.
#
# WHAT THIS SCRIPT DOES:
#   1. Lists available audio files in your S3 bucket
#   2. Downloads selected file (or uses provided path)
#   3. Sends it to the WhisperX API on EC2
#   4. Displays transcription results with timing
#
# WHERE IT RUNS:
#   - Runs on: Your build box (LOCAL)
#   - Downloads from: S3 bucket
#   - Sends to: EC2 GPU instance (REMOTE)
#
# Usage: ./scripts/235-LOCAL--test-with-s3-audio.sh [OPTIONS]
#
# Options:
#   --list              List available audio files in S3
#   --s3-path PATH      S3 path to audio file (e.g., test-files/audio.m4a)
#   --bucket BUCKET     S3 bucket name (default: clouddrive-app-bucket)
#   --no-diarize        Disable speaker diarization
#   --help              Show this help message
#
# Examples:
#   ./scripts/235-LOCAL--test-with-s3-audio.sh --list
#   ./scripts/235-LOCAL--test-with-s3-audio.sh --s3-path test-files/circular-audio-test.m4a
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="235-LOCAL--test-with-s3-audio"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

# Load .env
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Try to get host from state file
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"
if [ -z "${AWS_EC2_HOST:-}" ] && [ -f "$EC2_STATE_FILE" ]; then
    AWS_EC2_HOST=$(jq -r '.public_ip // empty' "$EC2_STATE_FILE" 2>/dev/null || true)
fi

S3_BUCKET="${S3_BUCKET:-clouddrive-app-bucket}"
S3_PATH=""
LIST_ONLY="false"
DIARIZE="true"
API_HOST="${AWS_EC2_HOST:-localhost}"
API_PORT="8000"

# Temp directory for downloads
TEMP_DIR="/tmp/whisperx-test"
mkdir -p "$TEMP_DIR"

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            LIST_ONLY="true"
            shift
            ;;
        --s3-path)
            S3_PATH="$2"
            shift 2
            ;;
        --bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        --no-diarize)
            DIARIZE="false"
            shift
            ;;
        --host)
            API_HOST="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Test WhisperX API with audio files from S3."
            echo ""
            echo "Options:"
            echo "  --list              List available audio files in S3"
            echo "  --s3-path PATH      S3 path to audio file"
            echo "  --bucket BUCKET     S3 bucket (default: clouddrive-app-bucket)"
            echo "  --no-diarize        Disable speaker diarization"
            echo "  --host HOST         API host (default: from EC2 state)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# List Mode
# =============================================================================

if [ "$LIST_ONLY" = "true" ]; then
    echo "============================================"
    echo "Audio Files in S3: $S3_BUCKET"
    echo "============================================"
    echo ""

    echo "--- Test Files ---"
    aws s3 ls "s3://${S3_BUCKET}/test-files/" 2>/dev/null | grep -E "\.(wav|mp3|flac|m4a|webm|ogg)" || echo "  (none)"
    echo ""

    echo "--- Recent User Uploads (last 10) ---"
    aws s3 ls "s3://${S3_BUCKET}/" --recursive 2>/dev/null | \
        grep -E "\.(wav|mp3|flac|m4a|webm|ogg)" | \
        sort -k1,2 -r | \
        head -10 | \
        awk '{
            size_mb = $3 / 1024 / 1024;
            printf "  %6.1f MB  %s %s  %s\n", size_mb, $1, $2, $4
        }'
    echo ""

    echo "Usage:"
    echo "  $0 --s3-path test-files/circular-audio-test.m4a"
    exit 0
fi

# =============================================================================
# Main Test
# =============================================================================

main() {
    echo "============================================"
    echo "Testing WhisperX with S3 Audio"
    echo "============================================"
    echo ""

    # Check API host
    if [ -z "$API_HOST" ] || [ "$API_HOST" = "localhost" ]; then
        print_status "error" "No EC2 host configured"
        echo ""
        echo "Either:"
        echo "  1. Launch EC2: ./scripts/200-LOCAL--launch-ec2-gpu.sh"
        echo "  2. Deploy: ./scripts/210-LOCAL--deploy-to-ec2-gpu.sh"
        exit 1
    fi

    # Check S3 path
    if [ -z "$S3_PATH" ]; then
        print_status "error" "No S3 path specified"
        echo ""
        echo "List available files:"
        echo "  $0 --list"
        echo ""
        echo "Then specify a file:"
        echo "  $0 --s3-path test-files/circular-audio-test.m4a"
        exit 1
    fi

    local s3_uri="s3://${S3_BUCKET}/${S3_PATH}"
    local filename=$(basename "$S3_PATH")
    local local_file="${TEMP_DIR}/${filename}"

    echo "S3 Source:  $s3_uri"
    echo "API Target: http://${API_HOST}:${API_PORT}"
    echo "Diarize:    $DIARIZE"
    echo ""

    # Download from S3
    print_status "info" "Downloading from S3..."
    if ! aws s3 cp "$s3_uri" "$local_file" 2>/dev/null; then
        print_status "error" "Failed to download from S3"
        echo "Check that the file exists: aws s3 ls $s3_uri"
        exit 1
    fi

    local file_size=$(du -h "$local_file" | cut -f1)
    print_status "ok" "Downloaded: $filename ($file_size)"
    echo ""

    # Check API health
    print_status "info" "Checking API health..."
    if ! curl -s "http://${API_HOST}:${API_PORT}/health" | grep -q '"status"'; then
        print_status "error" "API not responding"
        exit 1
    fi
    print_status "ok" "API is healthy"
    echo ""

    # Send for transcription
    print_status "info" "Uploading for transcription (this may take a while for large files)..."
    local start_time=$(date +%s)

    local response=$(curl -s -X POST "http://${API_HOST}:${API_PORT}/transcribe/upload" \
        -F "file=@${local_file}" \
        -F "diarize=${DIARIZE}" \
        --max-time 600)

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    print_status "ok" "Transcription complete in ${duration} seconds"
    echo ""

    # Display results
    echo "============================================"
    echo "TRANSCRIPTION RESULTS"
    echo "============================================"
    echo ""

    # Check for error
    if echo "$response" | jq -e '.error' &>/dev/null; then
        print_status "error" "Transcription failed"
        echo "$response" | jq .
        exit 1
    fi

    # Show language
    local language=$(echo "$response" | jq -r '.language // "unknown"')
    echo "Language: $language"
    echo ""

    # Show speakers if diarization enabled
    if [ "$DIARIZE" = "true" ]; then
        local speakers=$(echo "$response" | jq -r '.speakers // [] | join(", ")')
        echo "Speakers: ${speakers:-none detected}"
        echo ""
    fi

    # Show transcript
    echo "--- Transcript ---"
    echo "$response" | jq -r '.segments[]? | "\(.speaker // "")  [\(.start | tostring | .[0:5])s] \(.text)"' 2>/dev/null || \
    echo "$response" | jq -r '.segments[]?.text' 2>/dev/null || \
    echo "$response" | jq .

    echo ""
    echo "============================================"
    echo "Stats"
    echo "============================================"
    local segment_count=$(echo "$response" | jq '.segments | length' 2>/dev/null || echo "0")
    local word_count=$(echo "$response" | jq '[.segments[]?.words // [] | length] | add // 0' 2>/dev/null || echo "0")
    echo "Segments: $segment_count"
    echo "Words: $word_count"
    echo "Processing time: ${duration}s"
    echo "File size: $file_size"
    echo ""

    # Cleanup
    rm -f "$local_file"
    print_status "ok" "Cleaned up temp file"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
