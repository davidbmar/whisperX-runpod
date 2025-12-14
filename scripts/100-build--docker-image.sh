#!/bin/bash
# =============================================================================
# Build Docker Image - WhisperX with FastAPI HTTP API
# =============================================================================
#
# PLAIN ENGLISH:
#   This script packages up the WhisperX transcription software into a Docker
#   "container" - think of it like creating a shipping container that has
#   everything needed to run the software (code, libraries, AI models) all
#   bundled together. Once built, this container can be shipped to any server
#   (EC2, RunPod, etc.) and it will run exactly the same way everywhere.
#
#   The container includes a web API (like a website backend) that listens for
#   audio files and returns transcriptions. It uses NVIDIA CUDA for GPU
#   acceleration, which makes transcription 10-70x faster than on a CPU.
#
# WHAT THIS SCRIPT DOES:
#   1. Builds Docker image with FastAPI HTTP API for transcription
#   2. Uses cuDNN-enabled CUDA base for GPU deep learning support
#   3. Pre-downloads Whisper model into image for faster startup
#   4. Tags image for Docker Hub push
#
# WHERE IT RUNS:
#   - Runs on: Your build box (LOCAL)
#   - Creates: A Docker image file on your local machine
#
# PREREQUISITES:
#   - Docker installed and running
#   - .env file configured (run 010-setup--configure-environment.sh first)
#
# Usage: ./scripts/100-build--docker-image.sh [OPTIONS]
#
# Options:
#   --no-cache     Force rebuild without Docker cache
#   --help         Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="100-build--docker-image"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

NO_CACHE=""
DOCKERFILE="$PROJECT_ROOT/docker/Dockerfile.pod"

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --help)
            echo "Usage: $0 [--no-cache]"
            echo ""
            echo "Build WhisperX Docker image with FastAPI HTTP API."
            echo ""
            echo "Options:"
            echo "  --no-cache   Force rebuild without Docker cache"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting Docker image build"

    # Load environment
    load_env_or_fail

    # Set image tag
    local docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG:-latest}"

    print_status "info" "Building WhisperX Docker image..."
    echo ""
    echo "  Dockerfile: $DOCKERFILE"
    echo "  Tag: $docker_tag"
    echo "  Model: ${WHISPER_MODEL:-small}"
    echo "  Compute: ${WHISPER_COMPUTE_TYPE:-float16}"
    echo ""

    # Check Dockerfile exists
    if [ ! -f "$DOCKERFILE" ]; then
        print_status "error" "Dockerfile not found: $DOCKERFILE"
        print_status "error" "Expected: docker/Dockerfile.pod"
        exit 1
    fi

    # Build
    local start_time=$(date +%s)

    print_status "info" "Building image (this may take 10-15 minutes)..."
    echo ""

    docker build \
        $NO_CACHE \
        --build-arg WHISPER_MODEL="${WHISPER_MODEL:-small}" \
        -t "$docker_tag" \
        -f "$DOCKERFILE" \
        "$PROJECT_ROOT"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    json_log "$SCRIPT_NAME" "build" "ok" "Image built successfully" "duration=$duration"

    # Get image size
    local image_size=$(docker images "$docker_tag" --format "{{.Size}}")

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Docker image built successfully!"
    print_status "ok" "============================================"
    echo ""
    echo "Image: $docker_tag"
    echo "Size: $image_size"
    echo "Build time: $(format_duration $duration)"
    echo ""
    echo "To test locally (requires NVIDIA GPU):"
    echo "  docker run --gpus all -p 8000:8000 \\"
    echo "    -e HF_TOKEN=\$HF_TOKEN \\"
    echo "    -e WHISPER_MODEL=${WHISPER_MODEL:-small} \\"
    echo "    $docker_tag"
    echo ""
    echo "Next step: ./scripts/110-build--push-to-dockerhub.sh"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
