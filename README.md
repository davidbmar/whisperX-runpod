# WhisperX-RunPod

Serverless batch transcription with speaker diarization on RunPod GPU cloud.

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

# Run interactive setup (copies Docker Hub username if you have whisperlive-salad configured)
./scripts/000-questions.sh
```

### 2. Build & Deploy

```bash
./scripts/200-build-image.sh        # Build Docker image
./scripts/205-push-to-registry.sh   # Push to Docker Hub
./scripts/210-create-endpoint.sh    # Create RunPod endpoint
```

### 3. Test

```bash
./scripts/215-test-endpoint.sh      # Quick health check
./scripts/220-test-transcription.sh # Full transcription test
```

## Usage

### Via API

```bash
# Transcribe from URL
curl -X POST "https://api.runpod.ai/v2/${ENDPOINT_ID}/runsync" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "audio_url": "https://example.com/audio.wav",
      "diarize": true
    }
  }'

# Transcribe from base64
curl -X POST "https://api.runpod.ai/v2/${ENDPOINT_ID}/runsync" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "audio_base64": "'$(base64 -w0 audio.wav)'",
      "language": "en",
      "diarize": true
    }
  }'
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

## Scripts

| Script | Description |
|--------|-------------|
| `000-questions.sh` | Interactive setup - configure API keys, model selection |
| `200-build-image.sh` | Build Docker image with selected model |
| `205-push-to-registry.sh` | Push image to Docker Hub |
| `210-create-endpoint.sh` | Create RunPod serverless endpoint |
| `215-test-endpoint.sh` | Quick health check |
| `220-test-transcription.sh` | Full transcription test |
| `900-runpod-status.sh` | Check endpoint status |
| `905-runpod-logs.sh` | View endpoint logs |
| `915-runpod-delete.sh` | Delete endpoint |

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

## License

MIT License - see LICENSE file for details.

## Credits

- [WhisperX](https://github.com/m-bain/whisperX) - Fast transcription with word-level timestamps
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) - CTranslate2 backend
- [pyannote-audio](https://github.com/pyannote/pyannote-audio) - Speaker diarization
- [RunPod](https://www.runpod.io/) - Serverless GPU cloud
