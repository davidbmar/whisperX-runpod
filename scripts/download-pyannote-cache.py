#!/usr/bin/env python3
"""
Download complete pyannote models for diarization.

PREREQUISITES:
1. Create HuggingFace account at https://huggingface.co/join
2. Accept pyannote model terms at:
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0
   - https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM
3. Create access token at https://huggingface.co/settings/tokens
4. Run: HF_TOKEN=hf_xxx python3 scripts/download-pyannote-cache.py

This downloads models to ~/.cache/huggingface/ which can then be copied
to the Docker image for offline use.
"""
import os
import sys

HF_TOKEN = os.environ.get("HF_TOKEN")
if not HF_TOKEN:
    print("ERROR: HF_TOKEN environment variable not set")
    print()
    print("To get a token:")
    print("  1. Go to https://huggingface.co/settings/tokens")
    print("  2. Create a new token with 'read' access")
    print("  3. Accept terms for pyannote models:")
    print("     - https://huggingface.co/pyannote/speaker-diarization-3.1")
    print("     - https://huggingface.co/pyannote/segmentation-3.0")
    print("  4. Run: HF_TOKEN=hf_xxx python3 scripts/download-pyannote-cache.py")
    sys.exit(1)

print("Downloading pyannote models...")
print("This may take a few minutes on first run.")
print()

# Patch torch.load for PyTorch 2.6+ compatibility
import torch
_original_torch_load = torch.load
def _patched_torch_load(*args, **kwargs):
    kwargs['weights_only'] = False
    return _original_torch_load(*args, **kwargs)
torch.load = _patched_torch_load

try:
    from pyannote.audio import Pipeline

    print("Loading speaker-diarization-3.1...")
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=HF_TOKEN
    )
    print("  ✓ speaker-diarization-3.1 loaded")

    # The pipeline automatically downloads:
    # - pyannote/segmentation-3.0
    # - pyannote/wespeaker-voxceleb-resnet34-LM

    print()
    print("SUCCESS! All models downloaded to ~/.cache/huggingface/")
    print()
    print("Next steps:")
    print("  1. Copy the cache to the Docker image:")
    print("     cp -r ~/.cache/huggingface/hub huggingface-cache/")
    print("  2. Rebuild the Docker image:")
    print("     docker build -f docker/Dockerfile.pod -t davidbmar/whisperx-runpod:latest .")
    print("  3. Push to Docker Hub:")
    print("     docker push davidbmar/whisperx-runpod:latest")

except Exception as e:
    print(f"ERROR: {e}")
    print()
    print("Make sure you have:")
    print("  1. Accepted the model terms on HuggingFace")
    print("  2. A valid HF_TOKEN with read access")
    sys.exit(1)
