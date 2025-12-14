#!/bin/bash
# =============================================================================
# LOCAL → Test All S3 Audio Files
# =============================================================================
#
# PLAIN ENGLISH:
#   This script downloads all test audio files from S3 and transcribes them
#   using the WhisperX API on EC2. It prints out the full transcript for each
#   file so you can verify the transcription quality.
#
# WHERE IT RUNS:
#   - Runs on: Your build box (LOCAL)
#   - Downloads from: S3 bucket (dbm-cf-2-web)
#   - Sends to: EC2 GPU instance (REMOTE)
#
# Usage: ./scripts/237-LOCAL--test-all-s3-audio.sh [--quick|--medium|--full]
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Load .env
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Get EC2 host from state file
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"
if [ -z "${AWS_EC2_HOST:-}" ] && [ -f "$EC2_STATE_FILE" ]; then
    AWS_EC2_HOST=$(jq -r '.public_ip // empty' "$EC2_STATE_FILE" 2>/dev/null || true)
fi

API_HOST="${AWS_EC2_HOST:-localhost}"
API_PORT="8000"
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="integration-test"
TEMP_DIR="/tmp/whisperx-test-all"
TEST_LEVEL="${1:---medium}"

mkdir -p "$TEMP_DIR"

# Test files
declare -a QUICK_FILES=("test-validation.wav")
declare -a MEDIUM_FILES=("test-validation.wav" "billionaire_chatgpt_podcast.mp3")
declare -a FULL_FILES=("test-validation.wav" "billionaire_chatgpt_podcast.mp3" "lex_ai_dhh_david_heinemeier_hansson.mp3")

# Select files based on test level
case "$TEST_LEVEL" in
    --quick)
        FILES=("${QUICK_FILES[@]}")
        echo "Running QUICK test (1 file)"
        ;;
    --medium)
        FILES=("${MEDIUM_FILES[@]}")
        echo "Running MEDIUM test (2 files)"
        ;;
    --full)
        FILES=("${FULL_FILES[@]}")
        echo "Running FULL test (3 files)"
        ;;
    *)
        echo "Usage: $0 [--quick|--medium|--full]"
        exit 1
        ;;
esac

echo ""
echo "============================================"
echo "Testing WhisperX with S3 Audio Files"
echo "============================================"
echo "API: http://${API_HOST}:${API_PORT}"
echo ""

# Check API health
print_status "info" "Checking API health..."
if ! curl -s "http://${API_HOST}:${API_PORT}/health" | grep -q '"status"'; then
    print_status "error" "API not responding at http://${API_HOST}:${API_PORT}"
    exit 1
fi
print_status "ok" "API is healthy"
echo ""

# Process each file
for filename in "${FILES[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "FILE: $filename"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local_file="${TEMP_DIR}/${filename}"
    s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${filename}"

    # Download from S3
    print_status "info" "Downloading from S3..."
    if ! aws s3 cp "$s3_uri" "$local_file" 2>/dev/null; then
        print_status "error" "Failed to download $s3_uri"
        continue
    fi
    file_size=$(du -h "$local_file" | cut -f1)
    print_status "ok" "Downloaded: $file_size"

    # Transcribe
    print_status "info" "Transcribing (this may take a while for large files)..."
    start_time=$(date +%s)

    response=$(curl -s -X POST "http://${API_HOST}:${API_PORT}/transcribe/upload" \
        -F "file=@${local_file}" \
        -F "diarize=false" \
        --max-time 600 2>&1) || true

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Check for errors
    if [ -z "$response" ]; then
        print_status "error" "No response from API (timeout?)"
        rm -f "$local_file"
        continue
    fi

    if echo "$response" | jq -e '.error' &>/dev/null; then
        error_msg=$(echo "$response" | jq -r '.error // .detail // "Unknown error"')
        print_status "error" "API error: $error_msg"
        rm -f "$local_file"
        continue
    fi

    # Extract results
    language=$(echo "$response" | jq -r '.language // "unknown"')
    segment_count=$(echo "$response" | jq '.segments | length' 2>/dev/null || echo "0")

    print_status "ok" "Transcription complete in ${duration}s"
    echo ""
    echo "Language: $language"
    echo "Segments: $segment_count"
    echo "Time: ${duration}s"
    echo ""
    echo "--- TRANSCRIPT ---"
    echo "$response" | jq -r '[.segments[]?.text] | join(" ")' 2>/dev/null || echo "(no transcript)"
    echo ""
    echo "--- END TRANSCRIPT ---"
    echo ""

    # Cleanup
    rm -f "$local_file"
done

echo "============================================"
echo "All tests complete!"
echo "============================================"
