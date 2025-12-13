#!/bin/bash
# =============================================================================
# Build WhisperX Docker Image for RunPod Serverless
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Validates environment configuration
#   2. Builds Docker image with WhisperX and selected model
#   3. Pre-downloads Whisper model into image for faster cold starts
#   4. Tags image for Docker Hub push
#
# PREREQUISITES:
#   - Docker installed and running
#   - .env file configured (run 000-questions.sh first)
#
# CONFIGURATION:
#   All settings read from .env file:
#   - WHISPER_MODEL: Model to bake into image
#   - DOCKER_IMAGE: Image name
#   - DOCKER_TAG: Image tag
#
# Usage: ./scripts/200-build-image.sh [OPTIONS]
#
# Options:
#   --slim       Build slim image without diarization
#   --no-cache   Build without Docker cache
#   --help       Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="200-build-image"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Start logging
start_logging "$SCRIPT_NAME"

# =============================================================================
# Parse Arguments
# =============================================================================

BUILD_SLIM=false
NO_CACHE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --slim)
            BUILD_SLIM=true
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --help)
            echo "Usage: $0 [--slim] [--no-cache]"
            echo ""
            echo "Options:"
            echo "  --slim       Build slim image without diarization"
            echo "  --no-cache   Build without Docker cache"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Build Process
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting Docker image build"

    # =========================================================================
    # Load Environment
    # =========================================================================

    load_env_or_fail

    local docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG}"
    local dockerfile="$PROJECT_ROOT/docker/Dockerfile"

    if [ "$BUILD_SLIM" = true ]; then
        dockerfile="$PROJECT_ROOT/docker/Dockerfile.slim"
        docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG}-slim"
        if [ ! -f "$dockerfile" ]; then
            json_log "$SCRIPT_NAME" "dockerfile_check" "error" "Slim Dockerfile not found: $dockerfile"
            exit 1
        fi
    fi

    json_log "$SCRIPT_NAME" "config" "ok" "Build configuration loaded" \
        "model=$WHISPER_MODEL" \
        "image=$docker_tag" \
        "slim=$BUILD_SLIM"

    # =========================================================================
    # Verify Docker
    # =========================================================================

    print_status "info" "Checking Docker..."

    if ! command -v docker &> /dev/null; then
        json_log "$SCRIPT_NAME" "docker_check" "error" "Docker not found"
        print_status "error" "Docker is not installed. Please install Docker first."
        exit 1
    fi

    if ! docker info &> /dev/null; then
        json_log "$SCRIPT_NAME" "docker_check" "error" "Docker daemon not running"
        print_status "error" "Docker daemon is not running. Please start Docker."
        exit 1
    fi

    json_log "$SCRIPT_NAME" "docker_check" "ok" "Docker is available"

    # =========================================================================
    # Build Image
    # =========================================================================

    print_status "info" "Building Docker image: $docker_tag"
    print_status "info" "Whisper model: $WHISPER_MODEL (will be pre-downloaded)"
    echo ""

    local start_time=$(date +%s)

    # Build with model as build argument
    # Context is project root (contains src/ and requirements.txt)
    docker build \
        $NO_CACHE \
        --build-arg WHISPER_MODEL="$WHISPER_MODEL" \
        -t "$docker_tag" \
        -f "$dockerfile" \
        "$PROJECT_ROOT"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    json_log "$SCRIPT_NAME" "build" "ok" "Docker image built successfully" \
        "duration=${duration}s" \
        "image=$docker_tag"

    # =========================================================================
    # Get Image Size
    # =========================================================================

    local image_size=$(docker images "$docker_tag" --format "{{.Size}}" | head -1)
    json_log "$SCRIPT_NAME" "image_size" "ok" "Image size: $image_size"

    # =========================================================================
    # Summary
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Docker image built successfully!"
    print_status "ok" "============================================"
    echo ""
    echo "Image: $docker_tag"
    echo "Size: $image_size"
    echo "Model: $WHISPER_MODEL (pre-downloaded)"
    echo "Build time: $(format_duration $duration)"
    echo ""
    echo "Next step: ./scripts/205-push-to-registry.sh"
    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
