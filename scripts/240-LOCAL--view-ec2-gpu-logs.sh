#!/bin/bash
# =============================================================================
# EC2 View Logs - Show WhisperX Container Logs
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Connects to EC2 instance via SSH
#   2. Retrieves container logs
#   3. Optionally follows logs in real-time
#
# PREREQUISITES:
#   - WhisperX container running on EC2 (210-ec2--deploy-container.sh)
#
# Usage: ./scripts/230-ec2--view-logs.sh [OPTIONS]
#
# Options:
#   --host HOST     EC2 instance hostname/IP (or set AWS_EC2_HOST)
#   --key FILE      SSH key file (or set AWS_SSH_KEY)
#   --follow        Follow logs in real-time (Ctrl+C to exit)
#   --lines N       Number of lines to show (default: 100)
#   --help          Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="230-ec2--view-logs"
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
FOLLOW="false"
LINES="100"

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
        --follow|-f)
            FOLLOW="true"
            shift
            ;;
        --lines|-n)
            LINES="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--host HOST] [--follow] [--lines N]"
            echo ""
            echo "View WhisperX container logs on EC2."
            echo ""
            echo "Options:"
            echo "  --host HOST   EC2 instance hostname/IP"
            echo "  --key FILE    SSH private key file"
            echo "  --follow, -f  Follow logs in real-time"
            echo "  --lines N     Number of lines to show (default: 100)"
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

    print_status "info" "Fetching logs from $EC2_HOST..."
    echo "Container: $CONTAINER_NAME"
    echo ""

    if [ "$FOLLOW" = "true" ]; then
        print_status "info" "Following logs (Ctrl+C to exit)..."
        echo ""
        ssh_cmd "docker logs -f $CONTAINER_NAME 2>&1"
    else
        ssh_cmd "docker logs --tail $LINES $CONTAINER_NAME 2>&1"
    fi
}

# =============================================================================
# Run
# =============================================================================

main "$@"
