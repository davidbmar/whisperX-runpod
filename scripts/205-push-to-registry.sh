#!/bin/bash
# =============================================================================
# Push WhisperX Docker Image to Docker Hub
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Verifies Docker image exists locally
#   2. Logs into Docker Hub (if not already logged in)
#   3. Pushes image to Docker Hub registry
#   4. Verifies push was successful
#
# PREREQUISITES:
#   - Docker image built (run 200-build-image.sh first)
#   - Docker Hub account credentials
#
# CONFIGURATION:
#   All settings read from .env file:
#   - DOCKER_HUB_USERNAME: Docker Hub username
#   - DOCKER_IMAGE: Image name
#   - DOCKER_TAG: Image tag
#
# Usage: ./scripts/205-push-to-registry.sh [OPTIONS]
#
# Options:
#   --slim       Push slim image variant
#   --help       Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="205-push-to-registry"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Start logging
start_logging "$SCRIPT_NAME"

# =============================================================================
# Parse Arguments
# =============================================================================

PUSH_SLIM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --slim)
            PUSH_SLIM=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--slim]"
            echo ""
            echo "Options:"
            echo "  --slim       Push slim image variant"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Push Process
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting Docker Hub push"

    # =========================================================================
    # Load Environment
    # =========================================================================

    load_env_or_fail

    local docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG}"
    if [ "$PUSH_SLIM" = true ]; then
        docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG}-slim"
    fi

    json_log "$SCRIPT_NAME" "config" "ok" "Push configuration loaded" \
        "image=$docker_tag"

    # =========================================================================
    # Verify Image Exists
    # =========================================================================

    print_status "info" "Checking for local image: $docker_tag"

    if ! docker image inspect "$docker_tag" &> /dev/null; then
        json_log "$SCRIPT_NAME" "image_check" "error" "Image not found locally"
        print_status "error" "Image not found: $docker_tag"
        print_status "error" "Run ./scripts/200-build-image.sh first"
        exit 1
    fi

    local image_size=$(docker images "$docker_tag" --format "{{.Size}}" | head -1)
    json_log "$SCRIPT_NAME" "image_check" "ok" "Image found" \
        "size=$image_size"

    # =========================================================================
    # Docker Hub Login Check
    # =========================================================================

    print_status "info" "Checking Docker Hub login..."

    # Try to check if we're logged in by inspecting config
    if ! docker info 2>/dev/null | grep -q "Username: $DOCKER_HUB_USERNAME"; then
        print_status "info" "Please login to Docker Hub..."
        docker login -u "$DOCKER_HUB_USERNAME"
    fi

    json_log "$SCRIPT_NAME" "login" "ok" "Docker Hub login verified"

    # =========================================================================
    # Push Image
    # =========================================================================

    print_status "info" "Pushing image to Docker Hub..."
    echo "Image: $docker_tag"
    echo ""

    local start_time=$(date +%s)

    docker push "$docker_tag"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    json_log "$SCRIPT_NAME" "push" "ok" "Image pushed successfully" \
        "duration=${duration}s"

    # =========================================================================
    # Summary
    # =========================================================================

    echo ""
    print_status "ok" "============================================"
    print_status "ok" "Image pushed to Docker Hub successfully!"
    print_status "ok" "============================================"
    echo ""
    echo "Image: docker.io/$docker_tag"
    echo "Size: $image_size"
    echo "Push time: $(format_duration $duration)"
    echo ""
    echo "Image URL: https://hub.docker.com/r/${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}"
    echo ""
    echo "Next step: ./scripts/210-create-endpoint.sh"
    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
