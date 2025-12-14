#!/bin/bash
# =============================================================================
# LOCAL → Deploy Container to EC2 GPU
# =============================================================================
#
# PLAIN ENGLISH:
#   This script runs on YOUR computer but does its work on the REMOTE EC2 GPU
#   server. Think of it like a TV remote control - you press buttons here, but
#   the TV (EC2 instance) does the actual work.
#
#   The script SSHs into the EC2 GPU instance, downloads your Docker image from
#   Docker Hub (like downloading an app), and starts it running with GPU access.
#   Once started, the WhisperX API will be listening on port 8000, ready to
#   transcribe any audio you send it.
#
#   It's like installing and launching an app, but on a remote server instead
#   of your own computer.
#
# WHAT THIS SCRIPT DOES:
#   1. Connects to AWS EC2 GPU instance via SSH
#   2. Pulls the Docker image from Docker Hub
#   3. Runs the WhisperX API container with GPU support
#   4. Waits for the API to be ready
#
# WHERE IT RUNS:
#   - Runs on: Your build box (LOCAL)
#   - Deploys to: EC2 GPU instance (REMOTE)
#
# PREREQUISITES:
#   - EC2 GPU instance running (use 200-LOCAL--launch-ec2-gpu.sh)
#   - Docker image pushed to Docker Hub (use 110-build--push-to-dockerhub.sh)
#
# Usage: ./scripts/210-LOCAL--deploy-to-ec2-gpu.sh [OPTIONS]
#
# Options:
#   --host HOST     EC2 instance hostname/IP (or set AWS_EC2_HOST in .env)
#   --key FILE      SSH key file (or set AWS_SSH_KEY in .env)
#   --user USER     SSH user (default: ubuntu)
#   --pull          Force pull latest image before running
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="210-ec2--deploy-container"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
start_logging "$SCRIPT_NAME"

# =============================================================================
# Configuration
# =============================================================================

EC2_HOST="${AWS_EC2_HOST:-}"
SSH_KEY="${AWS_SSH_KEY:-}"
SSH_USER="${AWS_SSH_USER:-ubuntu}"
CONTAINER_NAME="whisperx"
CONTAINER_PORT="8000"
FORCE_PULL="false"

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            EC2_HOST="$2"
            shift 2
            ;;
        --key)
            SSH_KEY="$2"
            shift 2
            ;;
        --user)
            SSH_USER="$2"
            shift 2
            ;;
        --pull)
            FORCE_PULL="true"
            shift
            ;;
        --help)
            echo "Usage: $0 [--host HOST] [--key FILE] [--pull]"
            echo ""
            echo "Deploy WhisperX container to AWS EC2 GPU instance."
            echo ""
            echo "Options:"
            echo "  --host HOST   EC2 instance hostname/IP"
            echo "  --key FILE    SSH private key file"
            echo "  --user USER   SSH user (default: ubuntu)"
            echo "  --pull        Force pull latest image"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# SSH Helper
# =============================================================================

ssh_cmd() {
    local cmd="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

    if [ -n "$SSH_KEY" ]; then
        ssh_opts="$ssh_opts -i $SSH_KEY"
    fi

    ssh $ssh_opts "${SSH_USER}@${EC2_HOST}" "$cmd"
}

# =============================================================================
# Main
# =============================================================================

main() {
    json_log "$SCRIPT_NAME" "start" "ok" "Starting EC2 deployment"

    # Load environment
    load_env_or_fail

    # Try to get host from state file if not set
    EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"
    if [ -z "$EC2_HOST" ] && [ -f "$EC2_STATE_FILE" ]; then
        EC2_HOST=$(jq -r '.public_ip // empty' "$EC2_STATE_FILE")
        KEY_NAME=$(jq -r '.key_name // empty' "$EC2_STATE_FILE")

        # Try to find SSH key
        if [ -z "$SSH_KEY" ] && [ -n "$KEY_NAME" ]; then
            for key_path in ~/.ssh/${KEY_NAME}.pem ~/.ssh/${KEY_NAME}; do
                if [ -f "$key_path" ]; then
                    SSH_KEY="$key_path"
                    break
                fi
            done
        fi
    fi

    # Check host is configured
    if [ -z "$EC2_HOST" ]; then
        print_status "error" "EC2 host not configured"
        echo ""
        echo "Either:"
        echo "  1. Launch an instance: ./scripts/200-ec2--launch-gpu-instance.sh"
        echo "  2. Set AWS_EC2_HOST in .env"
        echo "  3. Use --host flag: $0 --host <IP>"
        exit 1
    fi

    local docker_tag="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE}:${DOCKER_TAG:-latest}"

    print_status "info" "Deploying WhisperX to EC2"
    echo ""
    echo "  Host: $EC2_HOST"
    echo "  Image: $docker_tag"
    echo "  Container: $CONTAINER_NAME"
    echo "  Port: $CONTAINER_PORT"
    echo ""

    # Test SSH connection
    print_status "info" "Testing SSH connection..."
    if ! ssh_cmd "echo 'SSH OK'" &>/dev/null; then
        print_status "error" "Cannot connect to $EC2_HOST"
        echo ""
        echo "Make sure:"
        echo "  1. EC2 instance is running"
        echo "  2. Security group allows SSH (port 22) and HTTP ($CONTAINER_PORT)"
        echo "  3. SSH key is correct (use --key)"
        exit 1
    fi
    print_status "ok" "SSH connection successful"

    # Stop existing container
    print_status "info" "Stopping existing container (if any)..."
    ssh_cmd "docker stop $CONTAINER_NAME 2>/dev/null || true; docker rm $CONTAINER_NAME 2>/dev/null || true"

    # Pull image
    if [ "$FORCE_PULL" = "true" ]; then
        print_status "info" "Pulling latest image..."
        ssh_cmd "docker pull $docker_tag"
    else
        print_status "info" "Pulling image (if not cached)..."
        ssh_cmd "docker pull $docker_tag" || true
    fi

    # Run container
    print_status "info" "Starting container..."
    ssh_cmd "docker run -d \
        --name $CONTAINER_NAME \
        --gpus all \
        -p ${CONTAINER_PORT}:8000 \
        -e HF_TOKEN='${HF_TOKEN:-}' \
        -e WHISPER_MODEL='${WHISPER_MODEL:-small}' \
        -e WHISPER_COMPUTE_TYPE='${WHISPER_COMPUTE_TYPE:-float16}' \
        -e ENABLE_DIARIZATION='${ENABLE_DIARIZATION:-true}' \
        --restart unless-stopped \
        $docker_tag"

    print_status "ok" "Container started!"
    echo ""

    # Wait for startup
    print_status "info" "Waiting for API to initialize (30-60 seconds for model loading)..."

    local max_attempts=12
    local attempt=1
    local health_url="http://${EC2_HOST}:${CONTAINER_PORT}/health"

    while [ $attempt -le $max_attempts ]; do
        sleep 5
        echo -n "  Attempt $attempt/$max_attempts: "

        if curl -s --connect-timeout 5 "$health_url" 2>/dev/null | grep -q '"status":"ok"'; then
            echo "Ready!"
            echo ""
            print_status "ok" "============================================"
            print_status "ok" "WhisperX deployed successfully!"
            print_status "ok" "============================================"
            echo ""
            echo "API URL: http://${EC2_HOST}:${CONTAINER_PORT}"
            echo "Health:  $health_url"
            echo ""
            echo "Next step: ./scripts/220-ec2--test-api.sh --host $EC2_HOST"
            return 0
        else
            echo "Not ready yet..."
        fi

        attempt=$((attempt + 1))
    done

    print_status "warn" "API not responding after 60 seconds"
    echo ""
    echo "The container may still be loading models. Check logs with:"
    echo "  ./scripts/230-ec2--view-logs.sh --host $EC2_HOST"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
