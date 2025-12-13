# =============================================================================
# WhisperX with Diarization for RunPod Serverless
# =============================================================================
# Build with: docker build --build-arg WHISPER_MODEL=small -t whisperx-runpod .
#
# WHAT THIS DOCKERFILE DOES:
#   1. Sets up CUDA 12.4 runtime with Python 3.11
#   2. Installs WhisperX and RunPod SDK
#   3. Pre-downloads the specified Whisper model
#   4. Configures the serverless handler entry point
#
# Build arguments:
#   WHISPER_MODEL - Model to pre-download (tiny/base/small/medium/large-v2)
# =============================================================================

# Use cudnn variant for deep learning support
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG WHISPER_MODEL=small

# =============================================================================
# System Dependencies
# =============================================================================
RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    python3-pip \
    ffmpeg \
    curl \
    git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.11 as default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# Upgrade pip
RUN python3 -m pip install --no-cache-dir --upgrade pip

# =============================================================================
# Python Dependencies
# =============================================================================
WORKDIR /app

# Install dependencies first (for better caching)
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Install WhisperX and RunPod SDK
RUN pip install --no-cache-dir whisperx runpod

# =============================================================================
# Pre-download Whisper Model (for faster cold starts)
# =============================================================================
# Download model at build time so it's cached in the image
# Note: Patch torch.load for PyTorch 2.6+ compatibility with pyannote models
# Force weights_only=False to allow loading pyannote checkpoints
RUN echo "Pre-downloading Whisper model: ${WHISPER_MODEL}" && \
    python3 -c "import torch; _orig = torch.load; torch.load = lambda *a, **k: _orig(*a, **{**k, 'weights_only': False}); import whisperx; whisperx.load_model('${WHISPER_MODEL}', device='cpu', compute_type='int8'); print('Model downloaded successfully')"

# =============================================================================
# Application Code
# =============================================================================
COPY src/ /app/src/

# =============================================================================
# Environment
# =============================================================================
ENV PYTHONUNBUFFERED=1
ENV WHISPER_MODEL=${WHISPER_MODEL}

# =============================================================================
# Entry Point
# =============================================================================
# Run the RunPod serverless handler
CMD ["python3", "-u", "src/handler.py"]
