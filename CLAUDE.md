# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperX-RunPod is a batch transcription service with speaker diarization that runs on GPU cloud platforms (AWS EC2 or RunPod). It uses WhisperX for fast transcription with word-level timestamps and pyannote for speaker diarization.

## Architecture Components

### 1. Build Box (This Machine - NO GPU)

The build box is a regular Linux machine (t3.medium or similar) that:
- **Does NOT have a GPU** - it cannot run transcription locally
- Builds Docker images using `docker build`
- Pushes images to Docker Hub
- Orchestrates deployments via AWS CLI and RunPod REST API
- Runs all the deployment scripts

**Why no GPU?** Building Docker images doesn't require a GPU. The GPU is only needed at runtime when the container runs WhisperX. This saves money - GPU instances are expensive.

### 2. AWS EC2 GPU Instance (Testing)

A temporary GPU instance (g4dn.xlarge with Tesla T4) used for:
- Testing Docker images before deploying to RunPod
- Debugging issues with full SSH access
- Validating transcription works correctly

**Workflow:** Build box launches EC2 via AWS CLI → SSH deploys container → Test API → Terminate when done

**Cost:** ~$0.52/hr (pay only while testing)

### 3. RunPod GPU Pod (Production)

Cloud GPU instances for production workloads:
- Cheaper than EC2 ($0.13-0.20/hr for community cloud)
- Easy scaling
- No SSH needed - managed via REST API

**Workflow:** Build box creates pod via RunPod API → Container auto-starts → Access via proxy URL

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ARCHITECTURE                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   BUILD BOX (no GPU)                                                        │
│   ├── Build Docker image (docker build)                                     │
│   ├── Push to Docker Hub (docker push)                                      │
│   ├── Launch EC2 via AWS CLI ─────────────► EC2 GPU INSTANCE               │
│   │                                         ├── Pull image from Docker Hub  │
│   │                                         ├── Run container with GPU      │
│   │                                         ├── Expose HTTP API port 8000   │
│   │                                         └── Test & validate             │
│   │                                                                         │
│   └── Create RunPod pod via REST API ─────► RUNPOD GPU POD                 │
│                                             ├── Pull image from Docker Hub  │
│                                             ├── Run container with GPU      │
│                                             ├── Expose via proxy URL        │
│                                             └── Production workloads        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Script Structure

Scripts use the naming convention: `NNN-section--action-description.sh`

```
scripts/
├── _common.sh                              # Shared functions (underscore sorts first)
│
├── 010-setup--configure-environment.sh     # Interactive .env setup
│
├── 100-build--docker-image.sh              # Build Docker image
├── 110-build--push-to-dockerhub.sh         # Push image to Docker Hub
│
├── 200-ec2--launch-gpu-instance.sh         # Launch EC2 GPU instance via AWS CLI
├── 205-ec2--wait-for-ready.sh              # Wait for Docker + GPU to be ready
├── 210-ec2--deploy-container.sh            # SSH to EC2, pull & run container
├── 220-ec2--terminate-instance.sh          # Terminate EC2 instance
├── 230-ec2--test-api.sh                    # Test HTTP API
├── 240-ec2--view-logs.sh                   # View container logs
├── 250-ec2--stop-container.sh              # Stop container (keep instance)
│
├── 300-runpod--create-pod.sh               # Create RunPod GPU pod
├── 310-runpod--deploy-container.sh         # Redeploy container to pod
├── 320-runpod--test-api.sh                 # Test HTTP API on RunPod
├── 330-runpod--view-logs.sh                # View pod status
├── 340-runpod--stop-pod.sh                 # Stop/delete pod
│
└── 900-manage--cleanup-all.sh              # Stop all running resources
```

## Typical Workflow

### First Time Setup
```bash
./scripts/010-setup--configure-environment.sh
```

### Build & Push
```bash
./scripts/100-build--docker-image.sh
./scripts/110-build--push-to-dockerhub.sh
```

### Test on EC2 (Recommended First)
```bash
./scripts/200-ec2--launch-gpu-instance.sh    # Launch g4dn.xlarge via AWS CLI
./scripts/205-ec2--wait-for-ready.sh         # Wait for Docker + GPU
./scripts/210-ec2--deploy-container.sh       # Deploy container
./scripts/230-ec2--test-api.sh               # Test transcription
./scripts/220-ec2--terminate-instance.sh     # Terminate when done
```

### Deploy to RunPod (After EC2 Validation)
```bash
./scripts/300-runpod--create-pod.sh
./scripts/320-runpod--test-api.sh
./scripts/340-runpod--stop-pod.sh            # When done
```

## Key Files

- `.env` - Configuration (API keys, Docker Hub username, model settings)
- `artifacts/ec2-test-instance.json` - EC2 instance state (auto-created)
- `docker/Dockerfile.pod` - Docker image for HTTP API
- `src/handler_pod.py` - FastAPI HTTP endpoint

## API Endpoints

The WhisperX container exposes:
- `GET /health` - Health check
- `POST /transcribe` - Transcribe from URL
- `POST /transcribe/upload` - Transcribe uploaded file

Example:
```bash
curl -X POST http://HOST:8000/transcribe \
  -H "Content-Type: application/json" \
  -d '{"audio_url": "https://example.com/audio.wav", "diarize": true}'
```

## Input/Output Format

### Input
```json
{
    "audio_url": "https://...",    // URL to audio file
    "language": "en",              // Optional: force language
    "diarize": true,               // Optional: enable diarization
    "min_speakers": 1,             // Optional: speaker hint
    "max_speakers": 10             // Optional: speaker hint
}
```

### Output
```json
{
    "segments": [
        {
            "start": 0.0,
            "end": 2.5,
            "text": "Hello world",
            "speaker": "SPEAKER_00",
            "words": [
                {"word": "Hello", "start": 0.0, "end": 0.5, "speaker": "SPEAKER_00"},
                {"word": "world", "start": 0.6, "end": 1.0, "speaker": "SPEAKER_00"}
            ]
        }
    ],
    "language": "en",
    "speakers": ["SPEAKER_00", "SPEAKER_01"]
}
```

## Configuration Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `RUNPOD_API_KEY` | Yes | RunPod API key |
| `DOCKER_HUB_USERNAME` | Yes | Docker Hub username |
| `DOCKER_IMAGE` | Yes | Image name (default: whisperx-runpod) |
| `WHISPER_MODEL` | No | Model size: tiny, base, small, medium, large-v2, large-v3 |
| `WHISPER_COMPUTE_TYPE` | No | Precision: float16/int8 |
| `HF_TOKEN` | For diarization | HuggingFace token |
| `ENABLE_DIARIZATION` | No | Enable speaker detection (default: true) |
| `EC2_KEY_NAME` | For EC2 | AWS SSH key pair name |
| `AWS_REGION` | For EC2 | AWS region (default: us-east-2) |

## Safety Features

- EC2 instances auto-terminate after 90 minutes (safety net)
- State files track running resources
- Cleanup script stops all resources at once

## Common Issues

### EC2 Launch Fails
- Check AWS CLI is configured: `aws sts get-caller-identity`
- Ensure SSH key pair exists in the region
- Check you have g4dn.xlarge quota in the region

### Container Won't Start
- Check HF_TOKEN is set for diarization models
- View logs: `./scripts/240-ec2--view-logs.sh`

### Model Loading Slow
- First run downloads models (~2-5GB depending on model size)
- Subsequent runs use cached models

## Docker Image

The image uses:
- Base: `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04`
- WhisperX with faster-whisper backend
- pyannote for speaker diarization
- FastAPI for HTTP API

Build locally:
```bash
./scripts/100-build--docker-image.sh
```

## Model Options

| Model | Speed | Accuracy | VRAM | GPU Type |
|-------|-------|----------|------|----------|
| tiny | Fastest | Lowest | ~1GB | RTX A4000 |
| base | Fast | Low | ~1GB | RTX A4000 |
| small | Medium | Good | ~2GB | RTX A4000 |
| medium | Slower | Better | ~5GB | RTX A4000 |
| large-v2 | Slow | Best | ~8GB | RTX A5000 |
| large-v3 | Slowest | Best | ~10GB | RTX A6000 |

## RunPod vs EC2

| Aspect | EC2 | RunPod |
|--------|-----|--------|
| Cost | ~$0.52/hr (g4dn.xlarge) | ~$0.20-0.50/hr |
| Setup | More complex | Simple |
| Debugging | Full SSH access | Limited |
| Use case | Testing/validation | Production |

**Recommendation:** Test on EC2 first, then deploy to RunPod.

## Security Notes

- Never commit `.env` file (contains secrets)
- Only `.env.template` should be in version control
- HF_TOKEN is sensitive - don't log it
- RunPod API key is sensitive - don't log it
