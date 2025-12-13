"""
WhisperX Transcriber Wrapper
============================
Provides a clean interface to WhisperX for transcription with alignment and diarization.

WHAT THIS MODULE DOES:
    1. Loads and caches WhisperX model
    2. Transcribes audio using faster-whisper backend
    3. Aligns transcription for word-level timestamps
    4. Optionally performs speaker diarization
    5. Returns structured result with segments and speakers
"""
import os
import gc
import logging
from typing import Optional, Dict, Any, List

# =============================================================================
# PyTorch 2.6+ Compatibility Patch
# =============================================================================
# PyTorch 2.6 changed torch.load default to weights_only=True, which breaks
# loading pyannote models. Apply monkey-patch before importing whisperx.
# Force weights_only=False for all torch.load calls.
import torch

_original_torch_load = torch.load

def _patched_torch_load(*args, **kwargs):
    """Patched torch.load forcing weights_only=False for pyannote compatibility."""
    kwargs['weights_only'] = False
    return _original_torch_load(*args, **kwargs)

torch.load = _patched_torch_load
# =============================================================================

import whisperx

logger = logging.getLogger(__name__)


class WhisperXTranscriber:
    """
    WhisperX transcription wrapper with alignment and diarization support.

    Attributes:
        model_name: Whisper model size (tiny/base/small/medium/large-v2/large-v3)
        compute_type: Precision (float16/int8)
        batch_size: Batch size for inference
        hf_token: HuggingFace token for diarization models
        enable_diarization: Whether to load diarization pipeline
    """

    def __init__(
        self,
        model_name: str = "small",
        compute_type: str = "float16",
        batch_size: int = 16,
        hf_token: Optional[str] = None,
        enable_diarization: bool = True
    ):
        """Initialize WhisperX transcriber with models."""
        self.model_name = model_name
        self.compute_type = compute_type
        self.batch_size = batch_size
        self.hf_token = hf_token
        self.enable_diarization = enable_diarization

        # Determine device
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        logger.info(f"Using device: {self.device}")

        if self.device == "cpu":
            logger.warning("Running on CPU - performance will be significantly slower")

        # Load whisper model
        logger.info(f"Loading Whisper model: {model_name}")
        self.model = whisperx.load_model(
            model_name,
            device=self.device,
            compute_type=compute_type
        )
        logger.info("Whisper model loaded")

        # Diarization pipeline (loaded lazily)
        self.diarize_model = None
        if enable_diarization and hf_token:
            self._load_diarization_model()
        elif enable_diarization and not hf_token:
            logger.warning("Diarization enabled but HF_TOKEN not provided - diarization will be skipped")

    def _load_diarization_model(self) -> None:
        """Load pyannote diarization pipeline."""
        try:
            from whisperx.diarize import DiarizationPipeline
            logger.info("Loading diarization pipeline...")
            self.diarize_model = DiarizationPipeline(
                use_auth_token=self.hf_token,
                device=self.device
            )
            logger.info("Diarization pipeline loaded")
        except Exception as e:
            logger.error(f"Failed to load diarization model: {e}")
            logger.warning("Diarization will be disabled")
            self.diarize_model = None

    def transcribe(
        self,
        audio_path: str,
        language: Optional[str] = None,
        diarize: bool = True,
        min_speakers: Optional[int] = None,
        max_speakers: Optional[int] = None
    ) -> Dict[str, Any]:
        """
        Transcribe audio file with optional diarization.

        Args:
            audio_path: Path to audio file
            language: Language code (e.g., 'en') or None for auto-detect
            diarize: Whether to perform speaker diarization
            min_speakers: Minimum number of speakers (hint)
            max_speakers: Maximum number of speakers (hint)

        Returns:
            Dict containing:
                - segments: List of transcription segments with timing and text
                - language: Detected or specified language
                - speakers: List of unique speaker IDs (if diarization enabled)
        """
        logger.info(f"Transcribing: {audio_path}")

        # =================================================================
        # Step 1: Load Audio
        # =================================================================
        logger.info("Loading audio...")
        audio = whisperx.load_audio(audio_path)
        logger.info(f"Audio loaded: {len(audio)/16000:.1f} seconds")

        # =================================================================
        # Step 2: Transcribe
        # =================================================================
        logger.info("Transcribing with Whisper...")
        result = self.model.transcribe(
            audio,
            batch_size=self.batch_size,
            language=language
        )
        detected_language = result.get("language", language or "unknown")
        logger.info(f"Transcription complete, language: {detected_language}")

        # =================================================================
        # Step 3: Align for Word-Level Timestamps
        # =================================================================
        logger.info("Aligning for word-level timestamps...")
        try:
            model_a, metadata = whisperx.load_align_model(
                language_code=detected_language,
                device=self.device
            )
            result = whisperx.align(
                result["segments"],
                model_a,
                metadata,
                audio,
                self.device,
                return_char_alignments=False
            )
            logger.info("Alignment complete")

            # Clean up alignment model
            del model_a
            gc.collect()
            if self.device == "cuda":
                torch.cuda.empty_cache()

        except Exception as e:
            logger.warning(f"Alignment failed: {e} - continuing without word-level timestamps")

        # =================================================================
        # Step 4: Diarization (Optional)
        # =================================================================
        speakers = []
        if diarize and self.diarize_model is not None:
            logger.info("Performing speaker diarization...")
            try:
                diarize_segments = self.diarize_model(
                    audio,
                    min_speakers=min_speakers,
                    max_speakers=max_speakers
                )
                result = whisperx.assign_word_speakers(diarize_segments, result)

                # Extract unique speakers
                speakers = self._extract_speakers(result.get("segments", []))
                logger.info(f"Diarization complete: {len(speakers)} speakers found")

            except Exception as e:
                logger.warning(f"Diarization failed: {e} - returning without speaker labels")
        elif diarize:
            logger.info("Diarization requested but not available (missing HF_TOKEN or model)")

        # =================================================================
        # Step 5: Format Output
        # =================================================================
        output = {
            "segments": result.get("segments", []),
            "language": detected_language,
        }

        if speakers:
            output["speakers"] = speakers

        return output

    def _extract_speakers(self, segments: List[Dict]) -> List[str]:
        """Extract unique speaker IDs from segments."""
        speakers = set()
        for segment in segments:
            if "speaker" in segment:
                speakers.add(segment["speaker"])
            # Also check words
            for word in segment.get("words", []):
                if "speaker" in word:
                    speakers.add(word["speaker"])
        return sorted(list(speakers))
