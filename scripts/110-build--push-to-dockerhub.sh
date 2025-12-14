#!/bin/bash
# =============================================================================
# Push to Docker Hub - Upload WhisperX Image to Registry
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Verifies Docker image exists locally
#   2. Checks Docker Hub login status
#   3. Pushes image to Docker Hub registry
#
# PREREQUISITES:
#   - Docker image built (run 100-build--docker-image.sh first)
#   - Logged in to Docker Hub (docker login)
#
# Usage: ./scripts/110-build--push-to-dockerhub.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="110-build--push-to-dockerhub"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Main
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting Docker Hub push"

    # Load environment
    load_env_or_fail

    # Set image tag
    local docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG:-latest}"

    # Check image exists
    print_status "info" "Checking for local image: $docker_tag"
    if ! docker image inspect "$docker_tag" &>/dev/null; then
        print_status "error" "Image not found: $docker_tag"
        print_status "error" "Run ./scripts/100-build--docker-image.sh first"
        exit 1
    fi
    json_log "$SCRIPT_NAME" "image_check" "ok" "Image found"

    # Check Docker Hub login
    print_status "info" "Checking Docker Hub login..."
    if ! docker info 2>/dev/null | grep -q "Username"; then
        print_status "warn" "Not logged in to Docker Hub"
        print_status "info" "Run: docker login"
        echo ""
        read -p "Press Enter after logging in, or Ctrl+C to cancel..."
    fi
    json_log "$SCRIPT_NAME" "login" "ok" "Docker Hub login verified"

    # Push
    print_status "info" "Pushing image to Docker Hub..."
    echo "Image: $docker_tag"
    echo ""

    local start_time=$(date +%s)
    docker push "$docker_tag"
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    json_log "$SCRIPT_NAME" "push" "ok" "Image pushed successfully" "duration=$duration"

    # Get image size
    local image_size=$(docker images "$docker_tag" --format "{{.Size}}")

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
    echo "Next steps:"
    echo "  Test on EC2:    ./scripts/210-ec2--deploy-container.sh"
    echo "  Deploy RunPod:  ./scripts/300-runpod--create-pod.sh"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
