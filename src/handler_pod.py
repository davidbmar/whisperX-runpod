"""
WhisperX Pod Handler (FastAPI)
==============================
HTTP API for WhisperX transcription on RunPod Pods.

Endpoints:
    GET  /health       - Health check
    POST /transcribe   - Transcribe audio

Usage:
    python handler_pod.py
    # Runs on http://0.0.0.0:8000
"""
import os
import sys
import base64
import tempfile
import logging
import gc
import time
from typing import Optional, Dict, Any
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import uvicorn

# Add src directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from transcribe import WhisperXTranscriber
from utils import setup_logging, sanitize_for_logging

# =============================================================================
# Configuration
# =============================================================================
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")
COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "float16")
BATCH_SIZE = int(os.getenv("WHISPER_BATCH_SIZE", "16"))
HF_TOKEN = os.getenv("HF_TOKEN")
ENABLE_DIARIZATION = os.getenv("ENABLE_DIARIZATION", "true").lower() == "true"
PORT = int(os.getenv("PORT", "8000"))

# =============================================================================
# Logging
# =============================================================================
logger = setup_logging("whisperx-pod")

# =============================================================================
# Global Model
# =============================================================================
transcriber: Optional[WhisperXTranscriber] = None


def load_model() -> WhisperXTranscriber:
    """Load WhisperX model (cached globally)."""
    global transcriber
    if transcriber is None:
        logger.info(f"Loading WhisperX model: {WHISPER_MODEL}")
        logger.info(f"Compute type: {COMPUTE_TYPE}, Batch size: {BATCH_SIZE}")
        logger.info(f"Diarization enabled: {ENABLE_DIARIZATION}")

        start = time.time()
        transcriber = WhisperXTranscriber(
            model_name=WHISPER_MODEL,
            compute_type=COMPUTE_TYPE,
            batch_size=BATCH_SIZE,
            hf_token=HF_TOKEN,
            enable_diarization=ENABLE_DIARIZATION
        )
        elapsed = time.time() - start
        logger.info(f"Model loaded in {elapsed:.1f}s")
    return transcriber


# =============================================================================
# FastAPI App
# =============================================================================
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model on startup."""
    logger.info("=" * 60)
    logger.info("Starting WhisperX Pod API")
    logger.info(f"Model: {WHISPER_MODEL}, Compute: {COMPUTE_TYPE}")
    logger.info(f"Diarization: {ENABLE_DIARIZATION}")
    logger.info("=" * 60)

    # Pre-load model on startup
    load_model()
    logger.info(f"API ready on port {PORT}")

    yield

    logger.info("Shutting down...")


app = FastAPI(
    title="WhisperX Transcription API",
    description="Audio transcription with speaker diarization",
    version="1.0.0",
    lifespan=lifespan
)


# =============================================================================
# Request/Response Models
# =============================================================================
class TranscribeRequest(BaseModel):
    """Transcription request body."""
    audio_base64: Optional[str] = None
    audio_url: Optional[str] = None
    language: Optional[str] = None
    diarize: bool = True
    min_speakers: Optional[int] = None
    max_speakers: Optional[int] = None


class HealthResponse(BaseModel):
    """Health check response."""
    status: str
    model: str
    device: str
    diarization: bool


# =============================================================================
# Endpoints
# =============================================================================
@app.get("/health", response_model=HealthResponse)
async def health():
    """Health check endpoint."""
    import torch
    return HealthResponse(
        status="ok",
        model=WHISPER_MODEL,
        device="cuda" if torch.cuda.is_available() else "cpu",
        diarization=ENABLE_DIARIZATION
    )


@app.get("/")
async def root():
    """Root endpoint with API info."""
    return {
        "service": "WhisperX Transcription API",
        "version": "1.0.0",
        "endpoints": {
            "/health": "GET - Health check",
            "/transcribe": "POST - Transcribe audio (JSON body)",
            "/transcribe/upload": "POST - Transcribe uploaded file"
        }
    }


@app.post("/transcribe")
async def transcribe(request: TranscribeRequest):
    """
    Transcribe audio from URL or base64.

    Request body:
    - audio_url: URL to audio file
    - audio_base64: Base64 encoded audio
    - language: Language code (optional, auto-detect if not provided)
    - diarize: Enable speaker diarization (default: true)
    - min_speakers: Minimum speakers hint
    - max_speakers: Maximum speakers hint
    """
    try:
        if not request.audio_base64 and not request.audio_url:
            raise HTTPException(400, "Must provide audio_base64 or audio_url")

        model = load_model()

        # Determine file extension
        ext = ".wav"
        if request.audio_url:
            for e in [".mp3", ".wav", ".m4a", ".flac", ".ogg", ".opus"]:
                if e in request.audio_url.lower():
                    ext = e
                    break

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            audio_path = f.name

        try:
            if request.audio_base64:
                logger.info(f"Decoding base64 audio ({len(request.audio_base64)} chars)")
                audio_bytes = base64.b64decode(request.audio_base64)
                with open(audio_path, 'wb') as f:
                    f.write(audio_bytes)
            else:
                import urllib.request
                logger.info(f"Downloading: {sanitize_for_logging(request.audio_url)}")
                urllib.request.urlretrieve(request.audio_url, audio_path)

            logger.info(f"Transcribing: diarize={request.diarize}")
            start = time.time()

            result = model.transcribe(
                audio_path=audio_path,
                language=request.language,
                diarize=request.diarize and ENABLE_DIARIZATION,
                min_speakers=request.min_speakers,
                max_speakers=request.max_speakers
            )

            elapsed = time.time() - start
            logger.info(f"Transcription complete in {elapsed:.1f}s: {len(result.get('segments', []))} segments")

            result["processing_time_seconds"] = round(elapsed, 2)
            return result

        finally:
            if os.path.exists(audio_path):
                os.unlink(audio_path)
            gc.collect()

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Transcription error: {e}", exc_info=True)
        raise HTTPException(500, str(e))


@app.post("/transcribe/upload")
async def transcribe_upload(
    file: UploadFile = File(...),
    language: Optional[str] = Form(None),
    diarize: bool = Form(True),
    min_speakers: Optional[int] = Form(None),
    max_speakers: Optional[int] = Form(None)
):
    """
    Transcribe uploaded audio file.

    Form fields:
    - file: Audio file to transcribe
    - language: Language code (optional)
    - diarize: Enable speaker diarization (default: true)
    - min_speakers: Minimum speakers hint
    - max_speakers: Maximum speakers hint
    """
    try:
        model = load_model()

        # Get extension from filename
        ext = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            content = await file.read()
            f.write(content)
            audio_path = f.name

        try:
            logger.info(f"Transcribing upload: {file.filename} ({len(content)} bytes)")
            start = time.time()

            result = model.transcribe(
                audio_path=audio_path,
                language=language,
                diarize=diarize and ENABLE_DIARIZATION,
                min_speakers=min_speakers,
                max_speakers=max_speakers
            )

            elapsed = time.time() - start
            logger.info(f"Transcription complete in {elapsed:.1f}s")

            result["processing_time_seconds"] = round(elapsed, 2)
            result["filename"] = file.filename
            return result

        finally:
            if os.path.exists(audio_path):
                os.unlink(audio_path)
            gc.collect()

    except Exception as e:
        logger.error(f"Upload transcription error: {e}", exc_info=True)
        raise HTTPException(500, str(e))


# =============================================================================
# Main
# =============================================================================
if __name__ == "__main__":
    uvicorn.run(
        "handler_pod:app",
        host="0.0.0.0",
        port=PORT,
        log_level="info"
    )
