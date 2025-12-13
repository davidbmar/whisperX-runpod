"""
WhisperX RunPod Serverless Handler
==================================
Handles transcription requests with optional speaker diarization.

WHAT THIS MODULE DOES:
    1. Receives audio via base64 or URL
    2. Transcribes using WhisperX (faster-whisper backend)
    3. Aligns for word-level timestamps (wav2vec2)
    4. Optionally adds speaker diarization (pyannote)
    5. Returns structured JSON result

Input format:
{
    "input": {
        "audio_base64": "...",           # Base64 encoded audio file
        "audio_url": "https://...",      # OR URL to audio file
        "language": "en",                # Optional: force language code
        "diarize": true,                 # Optional: enable speaker diarization
        "min_speakers": 1,               # Optional: minimum speakers hint
        "max_speakers": 10               # Optional: maximum speakers hint
    }
}

Output format:
{
    "segments": [...],
    "language": "en",
    "speakers": ["SPEAKER_00", "SPEAKER_01"]
}
"""
import os
import sys
import base64
import tempfile
import logging
import gc
from typing import Optional, Dict, Any

import runpod

# Add src directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from transcribe import WhisperXTranscriber
from utils import setup_logging, sanitize_for_logging

# =============================================================================
# Configuration from Environment
# =============================================================================
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")
COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "float16")
BATCH_SIZE = int(os.getenv("WHISPER_BATCH_SIZE", "16"))
HF_TOKEN = os.getenv("HF_TOKEN")
ENABLE_DIARIZATION = os.getenv("ENABLE_DIARIZATION", "true").lower() == "true"

# =============================================================================
# Logging Setup
# =============================================================================
logger = setup_logging("whisperx-handler")

# =============================================================================
# Global Model (loaded once, reused across requests)
# =============================================================================
transcriber: Optional[WhisperXTranscriber] = None


def load_model() -> WhisperXTranscriber:
    """
    Load WhisperX model on cold start.
    Model is cached globally for reuse across requests.
    """
    global transcriber
    if transcriber is None:
        logger.info(f"Loading WhisperX model: {WHISPER_MODEL}")
        logger.info(f"Compute type: {COMPUTE_TYPE}, Batch size: {BATCH_SIZE}")
        logger.info(f"Diarization enabled: {ENABLE_DIARIZATION}")

        transcriber = WhisperXTranscriber(
            model_name=WHISPER_MODEL,
            compute_type=COMPUTE_TYPE,
            batch_size=BATCH_SIZE,
            hf_token=HF_TOKEN,
            enable_diarization=ENABLE_DIARIZATION
        )
        logger.info("Model loaded successfully")
    return transcriber


def download_audio_from_url(url: str, temp_path: str) -> None:
    """Download audio file from URL to temporary path."""
    import urllib.request
    logger.info(f"Downloading audio from URL: {sanitize_for_logging(url)}")
    urllib.request.urlretrieve(url, temp_path)
    logger.info(f"Downloaded to: {temp_path}")


def decode_base64_audio(audio_base64: str, temp_path: str) -> None:
    """Decode base64 audio to temporary file."""
    logger.info(f"Decoding base64 audio ({len(audio_base64)} chars)")
    audio_bytes = base64.b64decode(audio_base64)
    with open(temp_path, 'wb') as f:
        f.write(audio_bytes)
    logger.info(f"Decoded to: {temp_path} ({len(audio_bytes)} bytes)")


# =============================================================================
# RunPod Handler
# =============================================================================
def handler(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Process transcription request.

    Args:
        event: RunPod event with 'input' dict containing:
            - audio_base64 OR audio_url: Audio source
            - language: Optional language code
            - diarize: Optional boolean to enable diarization
            - min_speakers: Optional minimum speaker count
            - max_speakers: Optional maximum speaker count

    Returns:
        Transcription result with segments and optional speaker labels
    """
    try:
        # =================================================================
        # Parse Input
        # =================================================================
        input_data = event.get("input", {})

        audio_base64 = input_data.get("audio_base64")
        audio_url = input_data.get("audio_url")

        # Validate input
        if not audio_base64 and not audio_url:
            logger.error("No audio source provided")
            return {"error": "Must provide audio_base64 or audio_url"}

        # Get options
        language = input_data.get("language")
        diarize = input_data.get("diarize", True) and ENABLE_DIARIZATION
        min_speakers = input_data.get("min_speakers")
        max_speakers = input_data.get("max_speakers")

        logger.info(f"Processing request: language={language}, diarize={diarize}")
        if min_speakers or max_speakers:
            logger.info(f"Speaker hints: min={min_speakers}, max={max_speakers}")

        # =================================================================
        # Load Model (cached after first call)
        # =================================================================
        model = load_model()

        # =================================================================
        # Handle Audio Input
        # =================================================================
        # Determine file extension from URL if available
        ext = ".wav"
        if audio_url:
            url_lower = audio_url.lower()
            for e in [".mp3", ".wav", ".m4a", ".flac", ".ogg", ".opus"]:
                if e in url_lower:
                    ext = e
                    break

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            audio_path = f.name

        try:
            if audio_base64:
                decode_base64_audio(audio_base64, audio_path)
            elif audio_url:
                download_audio_from_url(audio_url, audio_path)

            # =================================================================
            # Transcribe
            # =================================================================
            result = model.transcribe(
                audio_path=audio_path,
                language=language,
                diarize=diarize,
                min_speakers=min_speakers,
                max_speakers=max_speakers
            )

            logger.info(f"Transcription complete: {len(result.get('segments', []))} segments")

            return result

        finally:
            # Cleanup temp file
            if os.path.exists(audio_path):
                os.unlink(audio_path)
                logger.debug(f"Cleaned up temp file: {audio_path}")

            # Force garbage collection to free GPU memory
            gc.collect()

    except Exception as e:
        logger.error(f"Handler error: {str(e)}", exc_info=True)
        return {"error": str(e)}


# =============================================================================
# Start RunPod Serverless
# =============================================================================
if __name__ == "__main__":
    logger.info("=" * 60)
    logger.info("Starting WhisperX RunPod Serverless Handler")
    logger.info(f"Model: {WHISPER_MODEL}, Compute: {COMPUTE_TYPE}")
    logger.info(f"Diarization: {ENABLE_DIARIZATION}")
    logger.info("=" * 60)

    runpod.serverless.start({"handler": handler})
