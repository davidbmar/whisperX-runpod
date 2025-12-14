# WhisperX-RunPod

Batch transcription with speaker diarization on GPU cloud (RunPod or AWS EC2).

## Features

- **70x Realtime Speed** - Batch processing is significantly faster than real-time
- **Word-Level Timestamps** - Accurate timing via wav2vec2 alignment
- **Speaker Diarization** - Automatic speaker identification with pyannote
- **Multiple Models** - From tiny (fastest) to large-v3 (most accurate)
- **Pay Per Second** - Only pay for actual GPU usage

## Quick Start

### 1. Setup

```bash
# Clone the repository
cd ~/event-b/whisperX-runpod

# Run interactive setup
./scripts/010-setup--configure-environment.sh
```

### 2. Build & Push

```bash
./scripts/100-build--docker-image.sh      # Build Docker image
./scripts/110-build--push-to-dockerhub.sh # Push to Docker Hub
```

### 3. Test on EC2 (Recommended First)

```bash
# Launch a GPU instance from your build box
./scripts/200-ec2--launch-gpu-instance.sh  # Launches g4dn.xlarge via AWS CLI
./scripts/205-ec2--wait-for-ready.sh       # Wait for Docker + GPU ready

# Deploy and test
./scripts/210-ec2--deploy-container.sh     # Pull and run container
./scripts/230-ec2--test-api.sh             # Test transcription
./scripts/240-ec2--view-logs.sh            # View logs if needed
./scripts/220-ec2--terminate-instance.sh   # Terminate when done (saves money!)
```

### 4. Deploy to RunPod

```bash
./scripts/300-runpod--create-pod.sh       # Create RunPod GPU pod
./scripts/320-runpod--test-api.sh         # Test transcription
./scripts/330-runpod--view-logs.sh        # View pod status
./scripts/340-runpod--stop-pod.sh         # Stop when done
```

### 5. Cleanup

```bash
./scripts/900-manage--cleanup-all.sh      # Stop all running resources
```

---

## API Usage

### Health Check

```bash
curl http://HOST:8000/health
```

### Transcribe from URL

```bash
curl -X POST http://HOST:8000/transcribe \
  -H "Content-Type: application/json" \
  -d '{"audio_url": "https://example.com/audio.wav", "diarize": true}'
```

### Upload File

```bash
curl -X POST http://HOST:8000/transcribe/upload \
  -F "file=@audio.wav" \
  -F "diarize=true"
```

### Response Format

```json
{
  "segments": [
    {
      "start": 0.0,
      "end": 2.5,
      "text": "Hello, how are you?",
      "speaker": "SPEAKER_00",
      "words": [
        {"word": "Hello,", "start": 0.0, "end": 0.4, "speaker": "SPEAKER_00"},
        {"word": "how", "start": 0.5, "end": 0.7, "speaker": "SPEAKER_00"},
        {"word": "are", "start": 0.8, "end": 1.0, "speaker": "SPEAKER_00"},
        {"word": "you?", "start": 1.1, "end": 1.4, "speaker": "SPEAKER_00"}
      ]
    }
  ],
  "language": "en",
  "speakers": ["SPEAKER_00", "SPEAKER_01"]
}
```

---

## Scripts

### Setup (010)

| Script | Description |
|--------|-------------|
| `010-setup--configure-environment.sh` | Interactive setup - configure API keys, model selection |

### Build (100)

| Script | Description |
|--------|-------------|
| `100-build--docker-image.sh` | Build Docker image with selected model |
| `110-build--push-to-dockerhub.sh` | Push image to Docker Hub |

### EC2 (200)

| Script | Description |
|--------|-------------|
| `200-ec2--launch-gpu-instance.sh` | Launch EC2 GPU instance via AWS CLI |
| `205-ec2--wait-for-ready.sh` | Wait for Docker + GPU to be ready |
| `210-ec2--deploy-container.sh` | Deploy and run container on EC2 |
| `220-ec2--terminate-instance.sh` | Terminate EC2 instance |
| `230-ec2--test-api.sh` | Test HTTP API (works for any host) |
| `240-ec2--view-logs.sh` | View container logs on EC2 |
| `250-ec2--stop-container.sh` | Stop container (keep instance) |

### RunPod (300)

| Script | Description |
|--------|-------------|
| `300-runpod--create-pod.sh` | Create RunPod GPU pod |
| `310-runpod--deploy-container.sh` | Redeploy container to existing pod |
| `320-runpod--test-api.sh` | Test HTTP API on RunPod |
| `330-runpod--view-logs.sh` | View pod status and info |
| `340-runpod--stop-pod.sh` | Stop or delete RunPod pod |

### Management (900)

| Script | Description |
|--------|-------------|
| `900-manage--cleanup-all.sh` | Stop all running resources |

---

## Model Selection

| Model | Speed | Accuracy | VRAM | Cost/hr |
|-------|-------|----------|------|---------|
| tiny | 32x RT | Low | ~1GB | ~$0.20 |
| base | 16x RT | Fair | ~1GB | ~$0.20 |
| small | 10x RT | Good | ~2GB | ~$0.20 |
| medium | 5x RT | Better | ~5GB | ~$0.20 |
| large-v2 | 2x RT | Best | ~8GB | ~$0.30 |
| large-v3 | 1.5x RT | Best | ~10GB | ~$0.50 |

*RT = Realtime (1 hour audio processed in X minutes)*

## Prerequisites

- Docker installed locally
- Docker Hub account
- RunPod account with API key
- AWS account with EC2 access (optional, for testing)
- HuggingFace account with token (for diarization)

### HuggingFace Setup (for Diarization)

1. Create account at https://huggingface.co
2. Get token from https://huggingface.co/settings/tokens
3. Accept terms at:
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0

## Configuration

All configuration is done via environment variables in `.env`:

| Variable | Required | Description |
|----------|----------|-------------|
| `RUNPOD_API_KEY` | Yes | RunPod API key |
| `DOCKER_HUB_USERNAME` | Yes | Docker Hub username |
| `WHISPER_MODEL` | No | Model size (default: small) |
| `HF_TOKEN` | For diarization | HuggingFace token |
| `ENABLE_DIARIZATION` | No | Enable speakers (default: true) |
| `AWS_EC2_HOST` | For EC2 | EC2 instance hostname |
| `AWS_SSH_KEY` | For EC2 | Path to SSH key file |

## License

MIT License - see LICENSE file for details.

## Credits

- [WhisperX](https://github.com/m-bain/whisperX) - Fast transcription with word-level timestamps
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) - CTranslate2 backend
- [pyannote-audio](https://github.com/pyannote/pyannote-audio) - Speaker diarization
- [RunPod](https://www.runpod.io/) - GPU cloud
