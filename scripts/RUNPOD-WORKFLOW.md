# RunPod Deployment Workflow

This document explains how to deploy and manage WhisperX on RunPod GPU pods.

## Quick Start

```bash
# 1. Configure your environment (if not done already)
./scripts/010-setup--configure-environment.sh

# 2. Build and push Docker image (if not done already)
./scripts/100-build--docker-image.sh
./scripts/110-build--push-to-dockerhub.sh

# 3. Create RunPod GPU pod
./scripts/300-LOCAL--create-runpod-gpu.sh

# 4. Test the API
./scripts/320-LOCAL--test-runpod-gpu-api.sh

# 5. When done, stop the pod to save costs
./scripts/340-LOCAL--stop-runpod-gpu.sh
```

---

## Script Reference

### Setup & Build (100-series)

| Script | Description |
|--------|-------------|
| `010-setup--configure-environment.sh` | Interactive setup wizard to configure `.env` |
| `100-build--docker-image.sh` | Build the WhisperX Docker image locally |
| `110-build--push-to-dockerhub.sh` | Push image to Docker Hub |

### EC2 Testing (200-series) - Optional

Test on EC2 before deploying to RunPod:

| Script | Description |
|--------|-------------|
| `200-LOCAL--launch-ec2-gpu.sh` | Launch a g4dn.xlarge EC2 instance |
| `205-LOCAL--wait-ec2-gpu-ready.sh` | Wait for EC2 to be ready |
| `210-LOCAL--deploy-to-ec2-gpu.sh` | Deploy container to EC2 |
| `230-LOCAL--test-ec2-gpu-api.sh` | Test API on EC2 |
| `240-LOCAL--view-ec2-gpu-logs.sh` | View container logs |
| `220-LOCAL--terminate-ec2-gpu.sh` | Terminate EC2 instance |

### RunPod Deployment (300-series)

| Script | Description |
|--------|-------------|
| `300-LOCAL--create-runpod-gpu.sh` | Create a RunPod GPU pod |
| `310-LOCAL--deploy-to-runpod-gpu.sh` | Redeploy/update container |
| `320-LOCAL--test-runpod-gpu-api.sh` | Test the WhisperX API |
| `330-LOCAL--view-runpod-gpu-logs.sh` | View pod status and info |
| `340-LOCAL--stop-runpod-gpu.sh` | Stop or delete the pod |

---

## Detailed Workflow

### Step 1: Initial Setup

```bash
# Run the setup wizard
./scripts/010-setup--configure-environment.sh
```

This creates a `.env` file with:
- **RUNPOD_API_KEY**: Your RunPod API key (get from [RunPod Settings](https://www.runpod.io/console/user/settings))
- **DOCKER_HUB_USERNAME**: Your Docker Hub username
- **WHISPER_MODEL**: Model size (small, medium, large-v2, large-v3)
- **HF_TOKEN**: Hugging Face token (only if using diarization)

### Step 2: Build & Push Docker Image

```bash
# Build the image
./scripts/100-build--docker-image.sh

# Push to Docker Hub
./scripts/110-build--push-to-dockerhub.sh
```

The image is pushed to: `your-username/whisperx-runpod:latest`

### Step 3: Create RunPod Pod

```bash
# List available GPU types
./scripts/300-LOCAL--create-runpod-gpu.sh --list-gpus

# Create pod (uses NVIDIA RTX A4000 by default)
./scripts/300-LOCAL--create-runpod-gpu.sh

# Or specify a different GPU
./scripts/300-LOCAL--create-runpod-gpu.sh --gpu "NVIDIA RTX 4090"
```

The script will:
1. Create a GPU pod on RunPod
2. Wait for it to become ready (1-3 minutes)
3. Save the pod ID and endpoint to `.env`
4. Print the API URL

### Step 4: Test the API

```bash
# Run health check + sample transcription
./scripts/320-LOCAL--test-runpod-gpu-api.sh

# Health check only
./scripts/320-LOCAL--test-runpod-gpu-api.sh --health-only

# Test with your own audio file
./scripts/320-LOCAL--test-runpod-gpu-api.sh --file /path/to/audio.mp3

# Test with an audio URL
./scripts/320-LOCAL--test-runpod-gpu-api.sh --url "https://example.com/audio.mp3"
```

### Step 5: Use the API

Once running, use the API directly:

```bash
# Health check
curl http://<pod-ip>:<port>/health

# Transcribe from URL
curl -X POST http://<pod-ip>:<port>/transcribe \
  -H "Content-Type: application/json" \
  -d '{"audio_url": "https://example.com/audio.mp3", "language": "en"}'

# Upload and transcribe file
curl -X POST http://<pod-ip>:<port>/transcribe/upload \
  -F "file=@audio.mp3" \
  -F "language=en"
```

### Step 6: Stop When Done

**IMPORTANT**: RunPod charges by the hour. Stop your pod when not in use!

```bash
# Stop pod (can restart later)
./scripts/340-LOCAL--stop-runpod-gpu.sh

# Delete pod (removes completely)
./scripts/340-LOCAL--stop-runpod-gpu.sh --delete
```

---

## Debugging

### View Logs

```bash
# View pod status
./scripts/330-LOCAL--view-runpod-gpu-logs.sh

# Follow status updates
./scripts/330-LOCAL--view-runpod-gpu-logs.sh --follow
```

For detailed container logs, use the [RunPod Console](https://www.runpod.io/console/pods).

### Check Script Logs

All scripts log to `logs/` directory:

```bash
# View recent logs
ls -la logs/
cat logs/300-LOCAL--create-runpod-gpu-*.log
```

### Debug Mode

Add `--debug` to any script for verbose output:

```bash
./scripts/300-LOCAL--create-runpod-gpu.sh --debug
./scripts/320-LOCAL--test-runpod-gpu-api.sh --debug
```

### Common Issues

1. **"Pod ID already configured"**
   - Delete existing pod: `./scripts/340-LOCAL--stop-runpod-gpu.sh --delete`
   - Or clear manually: edit `.env` and remove `RUNPOD_POD_ID` value

2. **"Invalid GPU type"**
   - List available types: `./scripts/300-LOCAL--create-runpod-gpu.sh --list-gpus`

3. **"Health check failed"**
   - Pod may still be starting (model loading takes 1-2 minutes)
   - Check pod logs in RunPod console
   - Try again in 30 seconds

4. **"Insufficient funds"**
   - Add credits at [RunPod Billing](https://www.runpod.io/console/billing)

---

## GPU Recommendations

| Model | VRAM Needed | Recommended GPU | Cost/hr |
|-------|-------------|-----------------|---------|
| tiny/base | 2-4 GB | Any | ~$0.15 |
| small | 4-6 GB | NVIDIA RTX A4000 | ~$0.20 |
| medium | 6-8 GB | NVIDIA RTX A4000 | ~$0.20 |
| large-v2 | 10-12 GB | NVIDIA RTX A5000 | ~$0.30 |
| large-v3 | 12-16 GB | NVIDIA A40 | ~$0.40 |

---

## Performance Expectations

Based on testing with `small` model on NVIDIA RTX A4000:

| Audio Length | Transcription Time | Speed |
|--------------|-------------------|-------|
| 1 minute | ~3 seconds | 20x real-time |
| 10 minutes | ~25 seconds | 24x real-time |
| 1 hour | ~2.5 minutes | 24x real-time |

Larger models (large-v2, large-v3) will be slower but more accurate.

---

## API Reference

### `GET /health`
Health check endpoint.

**Response:**
```json
{
  "status": "ok",
  "model": "small",
  "device": "cuda",
  "diarization": false
}
```

### `POST /transcribe`
Transcribe audio from URL.

**Request:**
```json
{
  "audio_url": "https://example.com/audio.mp3",
  "language": "en",
  "diarize": false
}
```

### `POST /transcribe/upload`
Transcribe uploaded audio file.

**Form fields:**
- `file`: Audio file (mp3, wav, flac, etc.)
- `language`: Language code (optional)
- `diarize`: Enable speaker diarization (default: true)

**Response:**
```json
{
  "segments": [
    {"start": 0.0, "end": 2.5, "text": "Hello world"},
    ...
  ],
  "processing_time_seconds": 3.45
}
```
