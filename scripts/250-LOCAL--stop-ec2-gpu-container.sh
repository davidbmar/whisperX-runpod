#!/bin/bash
# =============================================================================
# EC2 Stop Container - Stop and Remove WhisperX Container
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Connects to EC2 instance via SSH
#   2. Stops the running WhisperX container
#   3. Removes the container (image remains cached)
#
# PREREQUISITES:
#   - WhisperX container running on EC2
#
# Usage: ./scripts/240-ec2--stop-container.sh [OPTIONS]
#
# Options:
#   --host HOST     EC2 instance hostname/IP (or set AWS_EC2_HOST)
#   --key FILE      SSH key file (or set AWS_SSH_KEY)
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="240-ec2--stop-container"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# =============================================================================
# Configuration
# =============================================================================

EC2_HOST="${AWS_EC2_HOST:-}"
SSH_KEY="${AWS_SSH_KEY:-}"
SSH_USER="${AWS_SSH_USER:-ubuntu}"
CONTAINER_NAME="whisperx"

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
        --help)
            echo "Usage: $0 [--host HOST] [--key FILE]"
            echo ""
            echo "Stop WhisperX container on EC2."
            echo ""
            echo "Options:"
            echo "  --host HOST   EC2 instance hostname/IP"
            echo "  --key FILE    SSH private key file"
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
    # Load environment (optional - for defaults)
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        EC2_HOST="${EC2_HOST:-$AWS_EC2_HOST}"
        SSH_KEY="${SSH_KEY:-$AWS_SSH_KEY}"
    fi

    # Check host
    if [ -z "$EC2_HOST" ]; then
        print_status "error" "EC2 host not configured"
        echo ""
        echo "Use --host or set AWS_EC2_HOST in .env"
        exit 1
    fi

    print_status "info" "Stopping container on $EC2_HOST..."
    echo "Container: $CONTAINER_NAME"
    echo ""

    # Check if container exists
    local status=$(ssh_cmd "docker ps -a --filter name=$CONTAINER_NAME --format '{{.Status}}'" 2>/dev/null || echo "")

    if [ -z "$status" ]; then
        print_status "info" "Container not found (already stopped/removed)"
        exit 0
    fi

    echo "Current status: $status"
    echo ""

    # Stop container
    print_status "info" "Stopping container..."
    ssh_cmd "docker stop $CONTAINER_NAME 2>/dev/null || true"

    # Remove container
    print_status "info" "Removing container..."
    ssh_cmd "docker rm $CONTAINER_NAME 2>/dev/null || true"

    print_status "ok" "Container stopped and removed"
    echo ""
    echo "Note: Docker image is still cached on the instance."
    echo "To restart: ./scripts/210-ec2--deploy-container.sh"
}

# =============================================================================
# Run
# =============================================================================

main "$@"
