# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperX-RunPod is a serverless batch transcription service using WhisperX with speaker diarization, deployed on RunPod GPU cloud. It provides 70x realtime transcription speed with word-level timestamps and automatic speaker identification.

## Build & Run Commands

### Initial Setup
```bash
./scripts/000-questions.sh     # Interactive configuration
```

### Build & Deploy
```bash
./scripts/200-build-image.sh        # Build Docker image
./scripts/205-push-to-registry.sh   # Push to Docker Hub
./scripts/210-create-endpoint.sh    # Create RunPod endpoint
./scripts/215-test-endpoint.sh      # Test endpoint health
./scripts/220-test-transcription.sh # Full transcription test
```

### Management
```bash
./scripts/900-runpod-status.sh   # Check endpoint status
./scripts/905-runpod-logs.sh     # View logs
./scripts/915-runpod-delete.sh   # Delete endpoint
```

### Local Testing
```bash
# Build image locally
docker build -t whisperx-runpod --build-arg WHISPER_MODEL=small docker/

# Test handler locally (requires GPU)
python src/handler.py
```

## Architecture

### Core Components

**RunPod Handler (`src/handler.py`)**
- Serverless entry point for RunPod
- Receives audio via base64 or URL
- Returns transcription with speaker labels

**WhisperX Transcriber (`src/transcribe.py`)**
- Wrapper around WhisperX library
- Handles model loading, transcription, alignment, diarization
- Caches model across requests for performance

**Common Library (`scripts/common-library.sh`)**
- Shared bash functions for all scripts
- Logging, environment management, RunPod API calls

### Request Flow
```
Client Request → RunPod API → Handler → WhisperX Transcriber → Response
                                ↓
                         Load audio (base64/URL)
                                ↓
                         Transcribe (faster-whisper)
                                ↓
                         Align (wav2vec2)
                                ↓
                         Diarize (pyannote)
                                ↓
                         Return JSON result
```

### Input Format
```json
{
    "input": {
        "audio_base64": "...",       // Base64 encoded audio
        "audio_url": "https://...",  // OR URL to audio file
        "language": "en",            // Optional: force language
        "diarize": true,             // Optional: enable diarization
        "min_speakers": 1,           // Optional: speaker hint
        "max_speakers": 10           // Optional: speaker hint
    }
}
```

### Output Format
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

## Directory Structure

```
whisperX-runpod/
├── src/                    # Python source code
│   ├── handler.py          # RunPod serverless handler
│   ├── transcribe.py       # WhisperX wrapper
│   └── utils.py            # Utilities
├── docker/                 # Docker configurations
│   ├── Dockerfile          # Full image with diarization
│   └── Dockerfile.slim     # Without diarization
├── scripts/                # Deployment scripts
│   ├── common-library.sh   # Shared functions
│   ├── config/             # Configuration modules
│   ├── 000-questions.sh    # Setup
│   ├── 2xx-*.sh            # Deployment
│   └── 9xx-*.sh            # Management
├── .env.template           # Configuration template
├── .gitignore              # Git exclusions
└── requirements.txt        # Python dependencies
```

## Key Patterns

### Adding New Features
1. Modify `src/handler.py` to accept new input parameters
2. Update `src/transcribe.py` to implement the feature
3. Update input/output documentation in handler docstring
4. Test locally before deploying

### Environment Variables
All configuration via environment variables (no hardcoded values):
- `WHISPER_MODEL`: Model size (tiny/base/small/medium/large-v2)
- `WHISPER_COMPUTE_TYPE`: Precision (float16/int8)
- `HF_TOKEN`: HuggingFace token for diarization
- `ENABLE_DIARIZATION`: Toggle diarization on/off

### Script Standards
All scripts include:
- Header comment explaining purpose
- `set -euo pipefail` for safety
- Sourcing `common-library.sh`
- `start_logging` for log files
- `print_status` for colored output

## Model Options

| Model | Speed | Accuracy | VRAM | GPU Type |
|-------|-------|----------|------|----------|
| tiny | Fastest | Lowest | ~1GB | RTX A4000 |
| base | Fast | Low | ~1GB | RTX A4000 |
| small | Medium | Good | ~2GB | RTX A4000 |
| medium | Slower | Better | ~5GB | RTX A4000 |
| large-v2 | Slow | Best | ~8GB | RTX A5000 |
| large-v3 | Slowest | Best | ~10GB | RTX A6000 |

## Security Notes

- Never commit `.env` file (contains secrets)
- Only `.env.template` should be in version control
- HF_TOKEN is sensitive - don't log it
- RunPod API key is sensitive - don't log it
