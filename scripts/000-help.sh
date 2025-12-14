#!/bin/bash
# =============================================================================
# WhisperX Scripts - Quick Reference Guide
# =============================================================================
#
# Run this script to see all available commands and their options.
#
# Usage: ./scripts/000-help.sh
#
# =============================================================================

cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                    WhisperX Deployment Scripts                                ║
║                         Quick Reference Guide                                 ║
╚══════════════════════════════════════════════════════════════════════════════╝

Scripts are numbered by workflow stage. Run them in order for first-time setup.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SETUP (010)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  010-setup--configure-environment.sh
      Interactive setup wizard for .env configuration.

      Usage: ./scripts/010-setup--configure-environment.sh

      No flags - runs interactively.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 BUILD (100)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  100-build--docker-image.sh
      Build the WhisperX Docker image locally.

      Usage: ./scripts/100-build--docker-image.sh [OPTIONS]

      Options:
        --no-cache    Force full rebuild (ignore Docker cache)
        --help        Show help

  110-build--push-to-dockerhub.sh
      Push built image to Docker Hub.

      Usage: ./scripts/110-build--push-to-dockerhub.sh [OPTIONS]

      Options:
        --help        Show help

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 EC2 GPU TESTING (200)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  200-LOCAL--launch-ec2-gpu.sh
      Launch an EC2 GPU instance (g4dn.xlarge with T4 GPU).
      Runs on YOUR machine, creates instance in AWS.

      Usage: ./scripts/200-LOCAL--launch-ec2-gpu.sh [OPTIONS]

      Options:
        --instance-type TYPE   GPU instance type (default: g4dn.xlarge)
        --key-name NAME        SSH key pair name
        --region REGION        AWS region (default: us-east-2)
        --help                 Show help

      Cost: ~$0.52/hour. Auto-terminates after 90 minutes!

  205-LOCAL--wait-for-ec2-ready.sh
      Wait for EC2 instance to be fully ready (Docker + GPU).

      Usage: ./scripts/205-LOCAL--wait-for-ec2-ready.sh [OPTIONS]

      Options:
        --host HOST    EC2 IP address (auto-detected from state file)
        --timeout SEC  Max wait time (default: 300)
        --help         Show help

  210-LOCAL--deploy-to-ec2-gpu.sh
      Deploy WhisperX container to EC2 GPU instance.
      Runs on YOUR machine, deploys to EC2.

      Usage: ./scripts/210-LOCAL--deploy-to-ec2-gpu.sh [OPTIONS]

      Options:
        --host HOST    EC2 IP address (auto-detected from state file)
        --key FILE     SSH key file
        --pull         Force pull latest image
        --help         Show help

  220-LOCAL--terminate-ec2.sh
      Terminate EC2 GPU instance to stop charges.

      Usage: ./scripts/220-LOCAL--terminate-ec2.sh [OPTIONS]

      Options:
        --force        Skip confirmation prompt
        --help         Show help

  230-LOCAL--test-ec2-gpu-api.sh
      Quick API test with a small audio sample.

      Usage: ./scripts/230-LOCAL--test-ec2-gpu-api.sh [OPTIONS]

      Options:
        --host HOST      API host (auto-detected from state file)
        --no-diarize     Disable speaker diarization
        --help           Show help

  231-LOCAL--view-ec2-logs.sh
      View container logs on EC2.

      Usage: ./scripts/231-LOCAL--view-ec2-logs.sh [OPTIONS]

      Options:
        --host HOST    EC2 IP address
        --follow       Follow logs in real-time (Ctrl+C to stop)
        --tail N       Show last N lines (default: 50)
        --help         Show help

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 INTEGRATION TESTING (235-237)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  235-LOCAL--test-with-s3-audio.sh
      Test with a specific audio file from S3.

      Usage: ./scripts/235-LOCAL--test-with-s3-audio.sh [OPTIONS]

      Options:
        --list              List available audio files in S3
        --s3-path PATH      S3 path to audio file
        --bucket BUCKET     S3 bucket (default: clouddrive-app-bucket)
        --no-diarize        Disable speaker diarization
        --host HOST         API host
        --help              Show help

      Example:
        ./scripts/235-LOCAL--test-with-s3-audio.sh --list
        ./scripts/235-LOCAL--test-with-s3-audio.sh --s3-path integration-test/podcast.mp3

  236-LOCAL--run-integration-tests.sh
      Automated test suite using S3 audio files.

      Usage: ./scripts/236-LOCAL--run-integration-tests.sh [OPTIONS]

      Options:
        --quick     Run 2MB test only (~30s on CPU)
        --medium    Run 2MB + 47MB tests (~5-10min on CPU)
        --full      Run all tests including 281MB (~30min on CPU)
        --host HOST Override API host
        --help      Show help

  237-LOCAL--test-all-s3-audio.sh
      Test all S3 files and print full transcripts.

      Usage: ./scripts/237-LOCAL--test-all-s3-audio.sh [OPTIONS]

      Options:
        --quick     Test 1 small file
        --medium    Test 2 files (small + medium)
        --full      Test all 3 files (small + medium + large)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 RUNPOD DEPLOYMENT (300)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  300-runpod--create-pod.sh
      Create a GPU pod on RunPod.

      Usage: ./scripts/300-runpod--create-pod.sh [OPTIONS]

      Options:
        --gpu-type TYPE    GPU type (default: NVIDIA RTX A4000)
        --help             Show help

  310-runpod--deploy-container.sh
      Deploy WhisperX container to RunPod pod.

      Usage: ./scripts/310-runpod--deploy-container.sh [OPTIONS]

      Options:
        --pod-id ID    Pod ID (auto-detected from state file)
        --help         Show help

  320-runpod--test-api.sh
      Test WhisperX API on RunPod.

      Usage: ./scripts/320-runpod--test-api.sh [OPTIONS]

      Options:
        --host HOST    RunPod API URL
        --help         Show help

  330-runpod--view-logs.sh
      View RunPod pod logs.

      Usage: ./scripts/330-runpod--view-logs.sh [OPTIONS]

      Options:
        --pod-id ID    Pod ID
        --help         Show help

  340-runpod--stop-pod.sh
      Stop and delete RunPod pod.

      Usage: ./scripts/340-runpod--stop-pod.sh [OPTIONS]

      Options:
        --pod-id ID    Pod ID
        --force        Skip confirmation
        --help         Show help

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 MANAGEMENT (900)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  900-manage--cleanup-all.sh
      Stop all running resources (EC2 + RunPod).

      Usage: ./scripts/900-manage--cleanup-all.sh [OPTIONS]

      Options:
        --force    Skip all confirmations
        --help     Show help

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 TYPICAL WORKFLOW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  First Time Setup:
    1. ./scripts/010-setup--configure-environment.sh
    2. ./scripts/100-build--docker-image.sh
    3. ./scripts/110-build--push-to-dockerhub.sh

  Test on EC2:
    4. ./scripts/200-LOCAL--launch-ec2-gpu.sh
    5. ./scripts/205-LOCAL--wait-for-ec2-ready.sh
    6. ./scripts/210-LOCAL--deploy-to-ec2-gpu.sh
    7. ./scripts/236-LOCAL--run-integration-tests.sh --quick
    8. ./scripts/220-LOCAL--terminate-ec2.sh    # Don't forget!

  Deploy to RunPod (after EC2 validation):
    9. ./scripts/300-runpod--create-pod.sh
   10. ./scripts/310-runpod--deploy-container.sh
   11. ./scripts/320-runpod--test-api.sh

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TIP: Any script with --help will show its full documentation.
     Example: ./scripts/200-LOCAL--launch-ec2-gpu.sh --help

EOF
