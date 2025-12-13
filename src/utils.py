"""
Utility Functions for WhisperX RunPod Handler
==============================================
Provides logging setup and helper functions.
"""
import os
import logging
import re
from typing import Optional


def setup_logging(name: str = "whisperx", level: Optional[str] = None) -> logging.Logger:
    """
    Configure structured JSON logging.

    Args:
        name: Logger name
        level: Log level (DEBUG/INFO/WARNING/ERROR) or from LOG_LEVEL env var

    Returns:
        Configured logger instance
    """
    log_level = level or os.getenv("LOG_LEVEL", "INFO")

    # Parse log level
    numeric_level = getattr(logging, log_level.upper(), logging.INFO)

    # JSON format for structured logging
    log_format = (
        '{"ts":"%(asctime)s",'
        '"level":"%(levelname)s",'
        '"logger":"%(name)s",'
        '"msg":"%(message)s"}'
    )

    logging.basicConfig(
        level=numeric_level,
        format=log_format,
        datefmt="%Y-%m-%dT%H:%M:%S"
    )

    logger = logging.getLogger(name)

    # Reduce noise from other libraries
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("whisperx").setLevel(logging.WARNING)
    logging.getLogger("faster_whisper").setLevel(logging.WARNING)

    return logger


def sanitize_for_logging(value: str) -> str:
    """
    Sanitize sensitive values for safe logging.

    - Truncates long strings
    - Masks potential tokens/keys

    Args:
        value: String to sanitize

    Returns:
        Sanitized string safe for logging
    """
    if not value:
        return ""

    # Truncate long strings (like base64)
    if len(value) > 100:
        return f"{value[:50]}...({len(value)} chars)"

    # Mask potential tokens (hf_xxx, sk_xxx, etc.)
    token_pattern = r'(hf_|sk_|api_|key_)[a-zA-Z0-9]{10,}'
    masked = re.sub(token_pattern, r'\1***MASKED***', value)

    return masked


def format_duration(seconds: float) -> str:
    """
    Format duration in human-readable format.

    Args:
        seconds: Duration in seconds

    Returns:
        Formatted string like "1h 30m 45s"
    """
    if seconds < 60:
        return f"{seconds:.1f}s"

    minutes, secs = divmod(int(seconds), 60)
    hours, mins = divmod(minutes, 60)

    if hours > 0:
        return f"{hours}h {mins}m {secs}s"
    else:
        return f"{mins}m {secs}s"


def get_audio_duration(audio_path: str) -> Optional[float]:
    """
    Get audio file duration in seconds.

    Args:
        audio_path: Path to audio file

    Returns:
        Duration in seconds or None if unable to determine
    """
    try:
        import whisperx
        audio = whisperx.load_audio(audio_path)
        return len(audio) / 16000  # 16kHz sample rate
    except Exception:
        return None
