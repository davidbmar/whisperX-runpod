#!/bin/bash
# =============================================================================
# Terminate EC2 GPU Test Instance
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Reads EC2 instance info from artifacts
#   2. Terminates the EC2 instance
#   3. Cleans up local state files
#
# PREREQUISITES:
#   - EC2 instance launched (200-ec2--launch-gpu-instance.sh)
#
# Usage: ./scripts/220-ec2--terminate-instance.sh [--force]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="220-ec2--terminate-instance"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Options
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Terminate EC2 GPU test instance."
            echo ""
            echo "Options:"
            echo "  --force, -f  Skip confirmation prompt"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================================"
echo "Terminating EC2 GPU Test Instance"
echo "============================================================================"
echo ""

# ============================================================================
# Load EC2 instance info
# ============================================================================
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"

if [ ! -f "$EC2_STATE_FILE" ]; then
    print_status "warn" "No EC2 instance state file found"
    echo "Nothing to terminate."
    exit 0
fi

INSTANCE_ID=$(jq -r '.instance_id' "$EC2_STATE_FILE")
PUBLIC_IP=$(jq -r '.public_ip' "$EC2_STATE_FILE")
INSTANCE_NAME=$(jq -r '.instance_name' "$EC2_STATE_FILE")
REGION=$(jq -r '.region' "$EC2_STATE_FILE")

echo "Instance to terminate:"
echo "  ID:        $INSTANCE_ID"
echo "  Name:      $INSTANCE_NAME"
echo "  Public IP: $PUBLIC_IP"
echo "  Region:    $REGION"
echo ""

# Check current state
CURRENT_STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" = "terminated" ] || [ "$CURRENT_STATE" = "not-found" ]; then
    print_status "info" "Instance already terminated or not found"
    rm -f "$EC2_STATE_FILE"
    exit 0
fi

echo "Current state: $CURRENT_STATE"
echo ""

# ============================================================================
# Confirmation
# ============================================================================
if [ "$FORCE" != true ]; then
    echo -e "${YELLOW}This will terminate the EC2 instance and you will lose any unsaved data.${NC}"
    echo ""
    read -p "Terminate instance? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# ============================================================================
# Terminate instance
# ============================================================================
print_status "info" "Terminating instance..."

aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" >/dev/null

print_status "ok" "Terminate command sent"

# Wait for termination
echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" 2>/dev/null || true

print_status "ok" "Instance terminated"

# ============================================================================
# Cleanup local state
# ============================================================================
rm -f "$EC2_STATE_FILE"
print_status "ok" "Local state cleaned up"

# Clear EC2 host from .env
if [ -f "$ENV_FILE" ]; then
    update_env_file "AWS_EC2_HOST" ""
    print_status "ok" "Cleared AWS_EC2_HOST from .env"
fi

echo ""
echo "============================================================================"
echo -e "${GREEN}EC2 Instance Terminated${NC}"
echo "============================================================================"
echo ""
echo "To launch a new instance:"
echo "  ./scripts/200-ec2--launch-gpu-instance.sh"
echo ""
