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
PYANNOTE_CACHE_URL = os.getenv("PYANNOTE_CACHE_URL", "")

# =============================================================================
# Logging
# =============================================================================
logger = setup_logging("whisperx-pod")


# =============================================================================
# Download Pyannote Models from S3
# =============================================================================
def download_pyannote_models():
    """Download pyannote models from S3 presigned URL if provided."""
    if not PYANNOTE_CACHE_URL:
        logger.info("No PYANNOTE_CACHE_URL provided - skipping model download")
        return False

    import subprocess
    import tarfile

    cache_dir = os.path.expanduser("~/.cache/huggingface")
    os.makedirs(cache_dir, exist_ok=True)

    tar_path = "/tmp/huggingface-cache.tar.gz"

    logger.info("Downloading pyannote models from S3...")
    try:
        # Download using curl (handles presigned URLs well)
        result = subprocess.run(
            ["curl", "-s", "-L", "-o", tar_path, PYANNOTE_CACHE_URL],
            capture_output=True,
            text=True,
            timeout=300
        )
        if result.returncode != 0:
            logger.error(f"Download failed: {result.stderr}")
            return False

        # Check file size
        file_size = os.path.getsize(tar_path)
        logger.info(f"Downloaded {file_size / 1024 / 1024:.1f} MB")

        if file_size < 1000000:  # Less than 1MB probably means error
            logger.error("Downloaded file too small - likely an error response")
            return False

        # Extract to cache directory
        logger.info(f"Extracting to {cache_dir}...")
        with tarfile.open(tar_path, "r:gz") as tar:
            tar.extractall(cache_dir)

        # Move contents if nested in 'huggingface' folder
        nested_dir = os.path.join(cache_dir, "huggingface")
        if os.path.exists(nested_dir):
            import shutil
            for item in os.listdir(nested_dir):
                src = os.path.join(nested_dir, item)
                dst = os.path.join(cache_dir, item)
                if os.path.exists(dst):
                    shutil.rmtree(dst)
                shutil.move(src, dst)
            os.rmdir(nested_dir)

        # Clean up
        os.remove(tar_path)

        logger.info("Pyannote models downloaded and extracted successfully")
        return True

    except Exception as e:
        logger.error(f"Failed to download pyannote models: {e}")
        return False

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

    # Download pyannote models from S3 if URL provided
    if ENABLE_DIARIZATION and PYANNOTE_CACHE_URL:
        download_pyannote_models()

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
    result_url: Optional[str] = None  # Presigned PUT URL for uploading result to S3
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
    """Health check endpoint - returns actual model status."""
    import torch
    # Check if diarization model actually loaded (not just if it's enabled)
    diarization_ready = (
        ENABLE_DIARIZATION and
        transcriber is not None and
        transcriber.diarize_model is not None
    )
    return HealthResponse(
        status="ok",
        model=WHISPER_MODEL,
        device="cuda" if torch.cuda.is_available() else "cpu",
        diarization=diarization_ready
    )


@app.get("/")
async def root():
    """Root endpoint with API info."""
    return {
        "service": "WhisperX Transcription API",
        "version": "1.0.0",
        "endpoints": {
            "/health": "GET - Health check",
            "/debug": "GET - Debug status (detailed)",
            "/transcribe": "POST - Transcribe audio (JSON body)",
            "/transcribe/upload": "POST - Transcribe uploaded file"
        }
    }


@app.get("/debug")
async def debug():
    """Debug endpoint - shows detailed model status."""
    import torch
    import os

    # Check cache directories
    hf_home = os.environ.get("HF_HOME", "~/.cache/huggingface")
    hf_home = os.path.expanduser(hf_home)
    hub_dir = os.path.join(hf_home, "hub")

    pyannote_models = []
    if os.path.exists(hub_dir):
        for item in os.listdir(hub_dir):
            if "pyannote" in item:
                pyannote_models.append(item)

    return {
        "whisper_model": WHISPER_MODEL,
        "device": "cuda" if torch.cuda.is_available() else "cpu",
        "enable_diarization_env": ENABLE_DIARIZATION,
        "transcriber_loaded": transcriber is not None,
        "diarize_model_loaded": transcriber is not None and transcriber.diarize_model is not None,
        "hf_token_provided": bool(HF_TOKEN),
        "pyannote_cache_url_provided": bool(PYANNOTE_CACHE_URL),
        "hf_home": hf_home,
        "pyannote_models_in_cache": pyannote_models,
        "cuda_available": torch.cuda.is_available(),
        "cuda_device_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
    }


@app.post("/transcribe")
async def transcribe(request: TranscribeRequest):
    """
    Transcribe audio from URL or base64.

    Request body:
    - audio_url: URL to audio file (or presigned S3 GET URL)
    - audio_base64: Base64 encoded audio
    - result_url: Presigned S3 PUT URL to upload result (optional)
    - language: Language code (optional, auto-detect if not provided)
    - diarize: Enable speaker diarization (default: true)
    - min_speakers: Minimum speakers hint
    - max_speakers: Maximum speakers hint

    If result_url is provided:
    - Result JSON is uploaded directly to S3
    - Response contains only summary (status, counts, timing)
    - Bypasses proxy timeout issues for large files

    If result_url is NOT provided:
    - Full result JSON is returned in response (legacy mode)
    """
    import requests
    import json

    try:
        if not request.audio_base64 and not request.audio_url:
            raise HTTPException(400, "Must provide audio_base64 or audio_url")

        model = load_model()

        # Determine file extension from URL (strip query params for presigned URLs)
        ext = ".wav"
        if request.audio_url:
            url_path = request.audio_url.split("?")[0].lower()
            for e in [".mp3", ".wav", ".m4a", ".flac", ".ogg", ".opus", ".webm"]:
                if url_path.endswith(e):
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
                # Use requests for better handling of presigned URLs
                logger.info(f"Downloading audio from URL...")
                download_start = time.time()
                response = requests.get(request.audio_url, stream=True, timeout=600)
                response.raise_for_status()

                with open(audio_path, 'wb') as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        f.write(chunk)

                file_size = os.path.getsize(audio_path)
                download_elapsed = time.time() - download_start
                logger.info(f"Downloaded {file_size / 1024 / 1024:.1f} MB in {download_elapsed:.1f}s")

            logger.info(f"Transcribing: diarize={request.diarize}")
            transcribe_start = time.time()

            result = model.transcribe(
                audio_path=audio_path,
                language=request.language,
                diarize=request.diarize and ENABLE_DIARIZATION,
                min_speakers=request.min_speakers,
                max_speakers=request.max_speakers
            )

            transcribe_elapsed = time.time() - transcribe_start
            total_elapsed = time.time() - (download_start if request.audio_url else transcribe_start)

            segments = result.get("segments", [])
            speakers = result.get("speakers", [])
            duration = segments[-1]["end"] if segments else 0

            logger.info(f"Transcription complete in {transcribe_elapsed:.1f}s: {len(segments)} segments, {len(speakers)} speakers")

            result["processing_time_seconds"] = round(transcribe_elapsed, 2)

            # If result_url provided, upload to S3 and return summary
            if request.result_url:
                logger.info("Uploading result to S3...")
                upload_start = time.time()

                upload_response = requests.put(
                    request.result_url,
                    data=json.dumps(result),
                    headers={"Content-Type": "application/json"},
                    timeout=300
                )
                upload_response.raise_for_status()

                upload_elapsed = time.time() - upload_start
                result_size = len(json.dumps(result))
                logger.info(f"Uploaded {result_size / 1024:.1f} KB to S3 in {upload_elapsed:.1f}s")

                # Return summary instead of full result
                return {
                    "status": "ok",
                    "message": "Transcription uploaded to S3",
                    "segments_count": len(segments),
                    "speakers_count": len(speakers),
                    "duration_seconds": round(duration, 2),
                    "processing_time_seconds": round(transcribe_elapsed, 2),
                    "total_time_seconds": round(total_elapsed, 2)
                }

            # Otherwise return full result (legacy mode)
            return result

        finally:
            if os.path.exists(audio_path):
                os.unlink(audio_path)
            gc.collect()

    except requests.exceptions.RequestException as e:
        logger.error(f"HTTP request error: {e}")
        raise HTTPException(502, f"HTTP error: {str(e)}")
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
