#!/bin/bash
# =============================================================================
# Wait for EC2 GPU Instance to be Fully Ready
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Reads EC2 instance info from artifacts
#   2. Waits for cloud-init to complete
#   3. Verifies Docker is installed and running
#   4. Verifies nvidia-container-toolkit is working (GPU visible to Docker)
#
# PREREQUISITES:
#   - EC2 instance launched (run 200-ec2--launch-gpu-instance.sh first)
#
# Usage: ./scripts/205-ec2--wait-for-ready.sh [--timeout SECONDS]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="205-ec2--wait-for-ready"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Default timeout (5 minutes)
TIMEOUT_SECONDS=300

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--timeout SECONDS]"
            echo ""
            echo "Wait for EC2 GPU instance to be fully ready."
            echo ""
            echo "Options:"
            echo "  --timeout SECONDS  Max wait time (default: 300)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================================"
echo "Waiting for EC2 GPU Instance to be Ready"
echo "============================================================================"
echo ""

# ============================================================================
# [1/4] Load EC2 instance info
# ============================================================================
echo -e "${BLUE}[1/4] Loading EC2 instance info...${NC}"

EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"

if [ ! -f "$EC2_STATE_FILE" ]; then
    print_status "error" "No EC2 instance state file found"
    echo "Launch an instance first: ./scripts/200-ec2--launch-gpu-instance.sh"
    exit 1
fi

PUBLIC_IP=$(jq -r '.public_ip' "$EC2_STATE_FILE")
KEY_NAME=$(jq -r '.key_name' "$EC2_STATE_FILE")
INSTANCE_ID=$(jq -r '.instance_id' "$EC2_STATE_FILE")

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
    print_status "error" "No public IP in state file"
    exit 1
fi

# Find the SSH key file
SSH_KEY=""
for key_path in ~/.ssh/${KEY_NAME}.pem ~/.ssh/${KEY_NAME} /home/ubuntu/.ssh/${KEY_NAME}.pem; do
    if [ -f "$key_path" ]; then
        SSH_KEY="$key_path"
        break
    fi
done

if [ -z "$SSH_KEY" ]; then
    print_status "error" "SSH key not found: ~/.ssh/${KEY_NAME}.pem"
    exit 1
fi

print_status "ok" "Instance: $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  SSH Key:   $SSH_KEY"
echo ""

# SSH command helper
ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR \
        ubuntu@"$PUBLIC_IP" "$@" 2>/dev/null
}

# ============================================================================
# [2/4] Wait for instance setup to complete
# ============================================================================
echo -e "${BLUE}[2/4] Waiting for instance setup to complete...${NC}"

START_TIME=$(date +%s)
while true; do
    ELAPSED=$(($(date +%s) - START_TIME))

    if [ $ELAPSED -ge $TIMEOUT_SECONDS ]; then
        print_status "warn" "Timeout waiting for setup script (${TIMEOUT_SECONDS}s)"
        echo "  Continuing anyway - will check Docker and GPU directly..."
        break
    fi

    # Check for ready file (created by user-data script when done)
    READY=$(ssh_cmd "test -f /tmp/instance-ready && echo 'ready' || echo 'waiting'" || echo "connecting")

    case "$READY" in
        ready)
            print_status "ok" "Instance setup completed"
            break
            ;;
        waiting)
            # Check if Docker and GPU work anyway (AMI may have everything pre-installed)
            DOCKER_OK=$(ssh_cmd "docker --version >/dev/null 2>&1 && echo 'yes'" || echo "no")
            GPU_OK=$(ssh_cmd "nvidia-smi >/dev/null 2>&1 && echo 'yes'" || echo "no")

            if [ "$DOCKER_OK" = "yes" ] && [ "$GPU_OK" = "yes" ]; then
                print_status "ok" "Docker and GPU already available"
                break
            fi

            printf "\r  Status: setting up... (elapsed: %ds)" "$ELAPSED"
            sleep 5
            ;;
        connecting)
            printf "\r  Status: connecting...  (elapsed: %ds)" "$ELAPSED"
            sleep 5
            ;;
    esac
done
echo ""

# ============================================================================
# [3/4] Verify Docker is running
# ============================================================================
echo -e "${BLUE}[3/4] Verifying Docker...${NC}"

DOCKER_VERSION=$(ssh_cmd "docker --version 2>/dev/null" || echo "")

if [ -z "$DOCKER_VERSION" ]; then
    print_status "error" "Docker not found or not accessible"
    exit 1
fi

print_status "ok" "$DOCKER_VERSION"
echo ""

# ============================================================================
# [4/4] Verify GPU is visible to Docker
# ============================================================================
echo -e "${BLUE}[4/4] Verifying GPU access in Docker...${NC}"

GPU_TEST=$(ssh_cmd "docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null" || echo "")

if [ -z "$GPU_TEST" ]; then
    print_status "error" "GPU not accessible in Docker"
    echo ""
    echo "Troubleshooting:"
    echo "  ssh -i $SSH_KEY ubuntu@$PUBLIC_IP"
    echo "  nvidia-smi                    # Check GPU on host"
    echo "  docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi"
    exit 1
fi

GPU_NAME=$(echo "$GPU_TEST" | cut -d',' -f1 | xargs)
GPU_MEMORY=$(echo "$GPU_TEST" | cut -d',' -f2 | xargs)

print_status "ok" "GPU accessible: $GPU_NAME ($GPU_MEMORY)"
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}EC2 GPU Instance Ready!${NC}"
echo "============================================================================"
echo ""
echo "  Instance:  $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  GPU:       $GPU_NAME ($GPU_MEMORY)"
echo ""
echo "Next Step:"
echo "  ./scripts/210-ec2--deploy-container.sh"
echo ""
