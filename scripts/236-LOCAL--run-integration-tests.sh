#!/bin/bash
# =============================================================================
# LOCAL → Run Integration Tests with S3 Audio Files
# =============================================================================
#
# PLAIN ENGLISH:
#   This script runs a series of automated tests against your WhisperX API
#   using real audio files stored in S3. It's like a "health checkup" for your
#   transcription service - it tests small, medium, and large files to make
#   sure everything is working correctly before you use it for real work.
#
#   The script will:
#   - Test a small 2MB file (should complete in ~10 seconds)
#   - Test a medium 47MB podcast (should complete in ~1-2 minutes)
#   - Optionally test a large 281MB file (takes several minutes)
#
#   At the end, you get a summary showing what passed and what failed.
#
# WHAT THIS SCRIPT DOES:
#   1. Checks API is healthy
#   2. Runs small/medium/large transcription tests
#   3. Validates results have expected fields
#   4. Reports timing and success/failure for each test
#
# WHERE IT RUNS:
#   - Runs on: Your build box (LOCAL)
#   - Downloads from: S3 bucket (dbm-cf-2-web)
#   - Sends to: EC2 GPU instance (REMOTE)
#
# Usage: ./scripts/236-LOCAL--run-integration-tests.sh [OPTIONS]
#
# Options:
#   --quick         Only run the quick 2MB test
#   --medium        Run quick + medium (47MB) tests
#   --full          Run all tests including 281MB file (slow!)
#   --host HOST     Override API host
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="236-LOCAL--run-integration-tests"
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

API_HOST="${AWS_EC2_HOST:-localhost}"
API_PORT="8000"
TEST_LEVEL="medium"  # quick, medium, full

# S3 test files
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="integration-test"

# Test files with expected characteristics
declare -A TEST_FILES
TEST_FILES[quick]="test-validation.wav|1.9MB|~10s"
TEST_FILES[medium]="billionaire_chatgpt_podcast.mp3|47MB|~1-2min"
TEST_FILES[large]="lex_ai_dhh_david_heinemeier_hansson.mp3|281MB|~5-10min"

# Temp directory
TEMP_DIR="/tmp/whisperx-integration-test"
mkdir -p "$TEMP_DIR"

# Results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
declare -a TEST_RESULTS

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            TEST_LEVEL="quick"
            shift
            ;;
        --medium)
            TEST_LEVEL="medium"
            shift
            ;;
        --full)
            TEST_LEVEL="full"
            shift
            ;;
        --host)
            API_HOST="$2"
            shift 2
            ;;
        --help|-h)
            cat << 'HELPEOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║  236-LOCAL--run-integration-tests.sh                                          ║
║  Run automated integration tests against WhisperX API                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

USAGE:
    ./scripts/236-LOCAL--run-integration-tests.sh [OPTIONS]

OPTIONS:
    --quick         Run only the 2MB test file
                    CPU: ~30 seconds  |  GPU: ~10 seconds

    --medium        Run 2MB + 47MB tests (DEFAULT)
                    CPU: ~10 minutes  |  GPU: ~2 minutes

    --full          Run all tests including 281MB file
                    CPU: ~45 minutes  |  GPU: ~10 minutes

    --host HOST     Override API host (auto-detected from EC2 state file)

    --help, -h      Show this help message

TEST FILES (from S3):
    ┌─────────────────────────────────────────────────────────────────────────┐
    │  File                                    Size      Audio Length         │
    ├─────────────────────────────────────────────────────────────────────────┤
    │  test-validation.wav                     1.9 MB    60 seconds           │
    │  billionaire_chatgpt_podcast.mp3         47 MB     ~47 minutes          │
    │  lex_ai_dhh_david_heinemeier_hansson.mp3 281 MB    ~3 hours             │
    └─────────────────────────────────────────────────────────────────────────┘

EXAMPLES:
    # Quick smoke test
    ./scripts/236-LOCAL--run-integration-tests.sh --quick

    # Standard test (recommended)
    ./scripts/236-LOCAL--run-integration-tests.sh --medium

    # Full test suite (takes a long time on CPU)
    ./scripts/236-LOCAL--run-integration-tests.sh --full

    # Test against specific host
    ./scripts/236-LOCAL--run-integration-tests.sh --quick --host 1.2.3.4

HELPEOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Helper Functions
# =============================================================================

run_test() {
    local test_name="$1"
    local s3_file="$2"
    local expected_size="$3"
    local expected_time="$4"

    TESTS_RUN=$((TESTS_RUN + 1))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: $test_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "File: $s3_file ($expected_size)"
    echo "Expected time: $expected_time"
    echo ""

    local s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${s3_file}"
    local local_file="${TEMP_DIR}/${s3_file##*/}"

    # Download
    print_status "info" "[1/4] Downloading from S3..."
    local dl_start=$(date +%s)
    if ! aws s3 cp "$s3_uri" "$local_file" 2>/dev/null; then
        print_status "error" "FAILED: Could not download $s3_uri"
        TEST_RESULTS+=("$test_name|FAIL|Download failed")
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
    local dl_end=$(date +%s)
    local dl_time=$((dl_end - dl_start))
    local actual_size=$(du -h "$local_file" | cut -f1)
    print_status "ok" "Downloaded in ${dl_time}s ($actual_size)"

    # Transcribe
    print_status "info" "[2/4] Sending to WhisperX API..."
    local tx_start=$(date +%s)

    local response=$(curl -s -X POST "http://${API_HOST}:${API_PORT}/transcribe/upload" \
        -F "file=@${local_file}" \
        -F "diarize=true" \
        --max-time 900 2>&1) || true

    local tx_end=$(date +%s)
    local tx_time=$((tx_end - tx_start))

    # Validate response
    print_status "info" "[3/4] Validating response..."

    # Check for curl/network error
    if [ -z "$response" ]; then
        print_status "error" "FAILED: No response from API"
        TEST_RESULTS+=("$test_name|FAIL|No response (timeout?)")
        TESTS_FAILED=$((TESTS_FAILED + 1))
        rm -f "$local_file"
        return 1
    fi

    # Check for error in response
    if echo "$response" | jq -e '.error' &>/dev/null; then
        local error_msg=$(echo "$response" | jq -r '.error // .detail // "Unknown error"')
        print_status "error" "FAILED: API error - $error_msg"
        TEST_RESULTS+=("$test_name|FAIL|API error: $error_msg")
        TESTS_FAILED=$((TESTS_FAILED + 1))
        rm -f "$local_file"
        return 1
    fi

    # Check for segments
    local segment_count=$(echo "$response" | jq '.segments | length' 2>/dev/null || echo "0")
    if [ "$segment_count" = "0" ] || [ "$segment_count" = "null" ]; then
        print_status "error" "FAILED: No segments in response"
        TEST_RESULTS+=("$test_name|FAIL|No segments returned")
        TESTS_FAILED=$((TESTS_FAILED + 1))
        rm -f "$local_file"
        return 1
    fi

    # Check for language
    local language=$(echo "$response" | jq -r '.language // "unknown"')

    # Get word count
    local word_count=$(echo "$response" | jq '[.segments[]?.words // [] | length] | add // 0' 2>/dev/null || echo "0")

    # Get speakers
    local speakers=$(echo "$response" | jq -r '.speakers // [] | length' 2>/dev/null || echo "0")

    # Success!
    print_status "ok" "[4/4] Validation passed!"
    echo ""
    echo "Results:"
    echo "  Transcription time: ${tx_time}s"
    echo "  Language: $language"
    echo "  Segments: $segment_count"
    echo "  Words: $word_count"
    echo "  Speakers: $speakers"

    # Show sample of transcript
    echo ""
    echo "Sample transcript (first 200 chars):"
    echo "$response" | jq -r '[.segments[]?.text] | join(" ")' 2>/dev/null | head -c 200
    echo "..."

    TEST_RESULTS+=("$test_name|PASS|${tx_time}s, ${segment_count} segments, ${word_count} words")
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Cleanup
    rm -f "$local_file"
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║           WhisperX Integration Test Suite                                ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Test Level: $TEST_LEVEL"
    echo "API Target: http://${API_HOST}:${API_PORT}"
    echo "S3 Bucket:  s3://${S3_BUCKET}/${S3_PREFIX}/"
    echo ""

    # Check API host
    if [ -z "$API_HOST" ] || [ "$API_HOST" = "localhost" ]; then
        print_status "error" "No EC2 host configured"
        echo ""
        echo "Launch and deploy first:"
        echo "  ./scripts/200-LOCAL--launch-ec2-gpu.sh"
        echo "  ./scripts/210-LOCAL--deploy-to-ec2-gpu.sh"
        exit 1
    fi

    # Health check
    print_status "info" "Checking API health..."
    if ! curl -s "http://${API_HOST}:${API_PORT}/health" | grep -q '"status"'; then
        print_status "error" "API not responding at http://${API_HOST}:${API_PORT}"
        exit 1
    fi
    print_status "ok" "API is healthy"

    local start_time=$(date +%s)

    # Run tests based on level
    case $TEST_LEVEL in
        quick)
            run_test "Quick (2MB WAV)" "test-validation.wav" "1.9MB" "~10s"
            ;;
        medium)
            run_test "Quick (2MB WAV)" "test-validation.wav" "1.9MB" "~10s"
            run_test "Medium (47MB Podcast)" "billionaire_chatgpt_podcast.mp3" "47MB" "~1-2min"
            ;;
        full)
            run_test "Quick (2MB WAV)" "test-validation.wav" "1.9MB" "~10s"
            run_test "Medium (47MB Podcast)" "billionaire_chatgpt_podcast.mp3" "47MB" "~1-2min"
            run_test "Large (281MB Lex Fridman)" "lex_ai_dhh_david_heinemeier_hansson.mp3" "281MB" "~5-10min"
            ;;
    esac

    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))

    # Summary
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                         TEST SUMMARY                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Total time: ${total_time}s"
    echo "Tests run:  $TESTS_RUN"
    echo "Passed:     $TESTS_PASSED"
    echo "Failed:     $TESTS_FAILED"
    echo ""

    echo "Results:"
    for result in "${TEST_RESULTS[@]}"; do
        local name=$(echo "$result" | cut -d'|' -f1)
        local status=$(echo "$result" | cut -d'|' -f2)
        local details=$(echo "$result" | cut -d'|' -f3)

        if [ "$status" = "PASS" ]; then
            echo -e "  ${GREEN}✓ PASS${NC} $name - $details"
        else
            echo -e "  ${RED}✗ FAIL${NC} $name - $details"
        fi
    done

    echo ""
    if [ $TESTS_FAILED -eq 0 ]; then
        print_status "ok" "All tests passed!"
        exit 0
    else
        print_status "error" "$TESTS_FAILED test(s) failed"
        exit 1
    fi
}

# =============================================================================
# Run
# =============================================================================

main "$@"
