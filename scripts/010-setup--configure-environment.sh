#!/bin/bash
# =============================================================================
# Configure Environment - Interactive Setup for WhisperX Deployment
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Checks for existing credentials in whisperlive-salad/.env
#   2. Collects RunPod API key and Docker Hub credentials
#   3. Asks for Whisper model selection (auto-sets GPU requirements)
#   4. Configures diarization settings with HuggingFace token
#   5. Creates .env file with all configuration values
#
# PREREQUISITES:
#   - RunPod account with API key (https://www.runpod.io/console/settings)
#   - Docker Hub account for image storage
#   - HuggingFace token for diarization (optional but recommended)
#
# Usage: ./scripts/010-setup--configure-environment.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="010-setup--configure-environment"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Don't start file logging for interactive script - just use console

# =============================================================================
# Configuration
# =============================================================================

SIBLING_ENV_FILE="$HOME/event-b/whisperlive-salad/.env"
TARGET_ENV_FILE="$PROJECT_ROOT/.env"

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}--- $1 ---${NC}"
    echo ""
}

ask_question() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"

    if [ -n "$default" ]; then
        echo -en "${GREEN}$prompt${NC} [$default]: "
        read -r response
        response="${response:-$default}"
    else
        echo -en "${GREEN}$prompt${NC}: "
        read -r response
    fi

    eval "$var_name=\"$response\""
}

ask_secret() {
    local prompt="$1"
    local var_name="$2"

    echo -en "${GREEN}$prompt${NC}: "
    read -rs response
    echo ""

    eval "$var_name=\"$response\""
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"

    if [ "$default" = "y" ]; then
        echo -en "${GREEN}$prompt${NC} [Y/n]: "
    else
        echo -en "${GREEN}$prompt${NC} [y/N]: "
    fi

    read -r response
    response="${response:-$default}"

    case "$response" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_not_empty() {
    local value="$1"
    local field_name="$2"

    if [ -z "$value" ]; then
        echo -e "${RED}Error: $field_name cannot be empty${NC}"
        return 1
    fi
    return 0
}

# =============================================================================
# Model Selection Menu
# =============================================================================

select_whisper_model() {
    echo ""
    echo -e "${CYAN}Available Whisper Models:${NC}"
    echo ""
    echo "  1) tiny     - Fastest, lowest accuracy (~1GB VRAM)"
    echo "  2) base     - Fast, basic accuracy (~1GB VRAM)"
    echo "  3) small    - Good balance of speed/accuracy (~2GB VRAM) [RECOMMENDED]"
    echo "  4) medium   - Better accuracy, slower (~5GB VRAM)"
    echo "  5) large-v2 - High accuracy (~8GB VRAM)"
    echo "  6) large-v3 - Highest accuracy (~10GB VRAM)"
    echo ""

    local choice
    ask_question "Select model (1-6)" "3" choice

    case "$choice" in
        1) WHISPER_MODEL="tiny" ;;
        2) WHISPER_MODEL="base" ;;
        3) WHISPER_MODEL="small" ;;
        4) WHISPER_MODEL="medium" ;;
        5) WHISPER_MODEL="large-v2" ;;
        6) WHISPER_MODEL="large-v3" ;;
        *) WHISPER_MODEL="small" ;;
    esac

    # Auto-set GPU type based on model
    GPU_TYPE=$(get_gpu_type_for_model "$WHISPER_MODEL")
    GPU_COST=$(get_gpu_cost_for_model "$WHISPER_MODEL")

    echo ""
    echo -e "${GREEN}Selected: $WHISPER_MODEL${NC}"
    echo -e "${BLUE}Auto-selected GPU: $GPU_TYPE (~\$$GPU_COST/hr)${NC}"
}

select_compute_type() {
    echo ""
    echo -e "${CYAN}Compute Type Options:${NC}"
    echo ""
    echo "  1) float16 - Faster, requires more VRAM [RECOMMENDED for GPU]"
    echo "  2) int8    - Slower, uses less VRAM"
    echo ""

    local choice
    ask_question "Select compute type (1-2)" "1" choice

    case "$choice" in
        1) WHISPER_COMPUTE_TYPE="float16" ;;
        2) WHISPER_COMPUTE_TYPE="int8" ;;
        *) WHISPER_COMPUTE_TYPE="float16" ;;
    esac

    echo -e "${GREEN}Selected: $WHISPER_COMPUTE_TYPE${NC}"
}

# =============================================================================
# Main Setup Flow
# =============================================================================

main() {
    print_header "WhisperX Deployment Setup v$SCRIPT_VERSION"

    echo "This script will configure your WhisperX deployment."
    echo "Your settings will be saved to: $TARGET_ENV_FILE"
    echo ""

    # Check if .env already exists
    if [ -f "$TARGET_ENV_FILE" ]; then
        echo -e "${YELLOW}Warning: .env file already exists${NC}"
        if ! ask_yes_no "Do you want to overwrite it?" "n"; then
            echo "Setup cancelled."
            exit 0
        fi
        echo ""
    fi

    # =========================================================================
    # Check for existing credentials
    # =========================================================================

    DOCKER_HUB_USERNAME=""

    if [ -f "$SIBLING_ENV_FILE" ]; then
        print_section "Existing Credentials Found"
        echo "Found existing configuration at: $SIBLING_ENV_FILE"
        echo ""

        # Try to extract Docker Hub username
        if grep -q "^DOCKER_HUB_USERNAME=" "$SIBLING_ENV_FILE" 2>/dev/null; then
            local existing_docker=$(grep "^DOCKER_HUB_USERNAME=" "$SIBLING_ENV_FILE" | cut -d= -f2)
            if [ -n "$existing_docker" ]; then
                echo "Found Docker Hub username: $existing_docker"
                if ask_yes_no "Use this Docker Hub username?" "y"; then
                    DOCKER_HUB_USERNAME="$existing_docker"
                fi
            fi
        fi
    fi

    # =========================================================================
    # RunPod Configuration
    # =========================================================================

    print_section "RunPod Configuration"

    echo "Get your RunPod API key from: https://www.runpod.io/console/user/settings"
    echo ""

    ask_secret "Enter your RunPod API key" RUNPOD_API_KEY
    validate_not_empty "$RUNPOD_API_KEY" "RunPod API key" || exit 1

    local default_endpoint_name="whisperx-$(date +%Y%m%d)"
    ask_question "Endpoint name" "$default_endpoint_name" RUNPOD_ENDPOINT_NAME

    # =========================================================================
    # Docker Hub Configuration
    # =========================================================================

    print_section "Docker Hub Configuration"

    if [ -z "$DOCKER_HUB_USERNAME" ]; then
        ask_question "Docker Hub username" "" DOCKER_HUB_USERNAME
        validate_not_empty "$DOCKER_HUB_USERNAME" "Docker Hub username" || exit 1
    else
        echo "Using Docker Hub username: $DOCKER_HUB_USERNAME"
    fi

    DOCKER_IMAGE="whisperx-runpod"
    DOCKER_TAG="latest"

    echo "Image will be: $DOCKER_HUB_USERNAME/$DOCKER_IMAGE:$DOCKER_TAG"

    # =========================================================================
    # AWS EC2 Configuration
    # =========================================================================

    print_section "AWS EC2 Configuration (for testing)"

    echo "EC2 settings are optional - you can configure them later in .env"
    echo ""

    if ask_yes_no "Configure AWS EC2 settings now?" "n"; then
        ask_question "EC2 hostname or IP" "" AWS_EC2_HOST
        ask_question "SSH key file path" "~/.ssh/id_rsa" AWS_SSH_KEY
        ask_question "SSH username" "ubuntu" AWS_SSH_USER
    else
        AWS_EC2_HOST=""
        AWS_SSH_KEY=""
        AWS_SSH_USER="ubuntu"
    fi

    # =========================================================================
    # Whisper Model Configuration
    # =========================================================================

    print_section "Whisper Model Configuration"

    select_whisper_model
    select_compute_type

    ask_question "Batch size (higher = faster, more VRAM)" "16" WHISPER_BATCH_SIZE

    # =========================================================================
    # Diarization Configuration
    # =========================================================================

    print_section "Speaker Diarization Configuration"

    echo "Diarization identifies who is speaking in the audio."
    echo "It requires a HuggingFace token with access to pyannote models."
    echo ""
    echo "To enable diarization:"
    echo "  1. Create HF token: https://huggingface.co/settings/tokens"
    echo "  2. Accept terms at: https://huggingface.co/pyannote/speaker-diarization-3.1"
    echo "  3. Accept terms at: https://huggingface.co/pyannote/segmentation-3.0"
    echo ""

    if ask_yes_no "Enable speaker diarization?" "y"; then
        ENABLE_DIARIZATION="true"

        echo ""
        ask_secret "Enter your HuggingFace token (hf_...)" HF_TOKEN

        if [ -z "$HF_TOKEN" ]; then
            echo -e "${YELLOW}Warning: No HF token provided. Diarization will be disabled.${NC}"
            ENABLE_DIARIZATION="false"
            HF_TOKEN=""
        fi

        if [ "$ENABLE_DIARIZATION" = "true" ]; then
            ask_question "Minimum speakers (hint for diarization)" "1" MIN_SPEAKERS
            ask_question "Maximum speakers (hint for diarization)" "10" MAX_SPEAKERS
        else
            MIN_SPEAKERS="1"
            MAX_SPEAKERS="10"
        fi
    else
        ENABLE_DIARIZATION="false"
        HF_TOKEN=""
        MIN_SPEAKERS="1"
        MAX_SPEAKERS="10"
    fi

    # =========================================================================
    # Generate Deployment ID
    # =========================================================================

    DEPLOYMENT_ID="whisperx-$(date +%Y%m%d-%H%M%S)"
    DEPLOYMENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # =========================================================================
    # Write .env File
    # =========================================================================

    print_section "Writing Configuration"

    cat > "$TARGET_ENV_FILE" << EOF
# =============================================================================
# WhisperX Deployment Configuration
# Generated by: scripts/010-setup--configure-environment.sh
# Generated at: $DEPLOYMENT_TIMESTAMP
# =============================================================================
# WARNING: This file contains secrets. NEVER commit to version control!
# =============================================================================

# =============================================================================
# RunPod Configuration
# =============================================================================
RUNPOD_API_KEY=${RUNPOD_API_KEY}
RUNPOD_POD_ID=
RUNPOD_ENDPOINT_NAME=${RUNPOD_ENDPOINT_NAME}

# =============================================================================
# Docker Hub Configuration
# =============================================================================
DOCKER_HUB_USERNAME=${DOCKER_HUB_USERNAME}
DOCKER_IMAGE=${DOCKER_IMAGE}
DOCKER_TAG=${DOCKER_TAG}

# =============================================================================
# AWS EC2 Configuration (for testing before RunPod)
# =============================================================================
AWS_EC2_HOST=${AWS_EC2_HOST}
AWS_SSH_KEY=${AWS_SSH_KEY}
AWS_SSH_USER=${AWS_SSH_USER}

# =============================================================================
# WhisperX Configuration
# =============================================================================
# Model options: tiny, base, small, medium, large-v2, large-v3
WHISPER_MODEL=${WHISPER_MODEL}
# Compute options: float16 (faster), int8 (less memory)
WHISPER_COMPUTE_TYPE=${WHISPER_COMPUTE_TYPE}
WHISPER_BATCH_SIZE=${WHISPER_BATCH_SIZE}

# =============================================================================
# Diarization Configuration
# =============================================================================
# HuggingFace token for pyannote speaker diarization
HF_TOKEN=${HF_TOKEN}
ENABLE_DIARIZATION=${ENABLE_DIARIZATION}
MIN_SPEAKERS=${MIN_SPEAKERS}
MAX_SPEAKERS=${MAX_SPEAKERS}

# =============================================================================
# GPU Configuration (auto-set based on model choice)
# =============================================================================
GPU_TYPE="${GPU_TYPE}"
GPU_COUNT=1

# =============================================================================
# Deployment Metadata
# =============================================================================
DEPLOYMENT_ID=${DEPLOYMENT_ID}
DEPLOYMENT_TIMESTAMP=${DEPLOYMENT_TIMESTAMP}
ENV_VERSION=1
EOF

    chmod 600 "$TARGET_ENV_FILE"

    echo -e "${GREEN}Configuration saved to: $TARGET_ENV_FILE${NC}"

    # =========================================================================
    # Summary
    # =========================================================================

    print_header "Setup Complete"

    echo "Configuration Summary:"
    echo "  - RunPod Endpoint: $RUNPOD_ENDPOINT_NAME"
    echo "  - Docker Image: $DOCKER_HUB_USERNAME/$DOCKER_IMAGE:$DOCKER_TAG"
    echo "  - Whisper Model: $WHISPER_MODEL ($WHISPER_COMPUTE_TYPE)"
    echo "  - GPU Type: $GPU_TYPE"
    echo "  - Diarization: $ENABLE_DIARIZATION"
    [ -n "$AWS_EC2_HOST" ] && echo "  - EC2 Host: $AWS_EC2_HOST"
    echo ""
    echo "Next steps:"
    echo "  1. ./scripts/100-build--docker-image.sh       # Build Docker image"
    echo "  2. ./scripts/110-build--push-to-dockerhub.sh  # Push to Docker Hub"
    echo "  3. ./scripts/210-ec2--deploy-container.sh     # Test on EC2"
    echo "  4. ./scripts/300-runpod--create-pod.sh        # Deploy to RunPod"
    echo ""
}

# =============================================================================
# Run Main
# =============================================================================

main "$@"
