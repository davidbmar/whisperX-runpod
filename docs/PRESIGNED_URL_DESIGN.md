# S3 Presigned URL Transcription Design

## Overview

This document describes the architecture for using S3 presigned URLs to transfer audio files to RunPod GPU workers and upload transcription results back to S3, completely bypassing the Cloudflare proxy timeout limitation.

---

## Problem Statement

### Current Architecture (Broken)

```
Edge Box                    Cloudflare Proxy           RunPod GPU
    │                            │                         │
    ├──[Download from S3]────────│                         │
    │  (142MB audio file)        │                         │
    │                            │                         │
    ├──────────[Upload file]─────┼─────────────────────────►
    │                            │                         │
    │         ⛔ TIMEOUT         │                         │
    │    (Cloudflare 100s max)   │                         │
```

**Issues:**
1. Cloudflare proxy has ~100 second HTTP timeout
2. Large audio files (74+ minutes = 142MB) take longer to upload
3. Transcription takes 15+ minutes, exceeding timeout
4. Result: `error code: 524` (Cloudflare timeout)

---

## Solution: S3 Presigned URLs

### New Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           S3 PRESIGNED URL FLOW                              │
└─────────────────────────────────────────────────────────────────────────────┘

Edge Box                    RunPod GPU                 S3 Bucket
    │                            │                         │
    │  ┌─────────────────────────────────────────────────┐ │
    │  │ STEP 1: Generate Presigned URLs                 │ │
    │  │ - GET URL for audio.wav (download, 1hr expiry)  │ │
    │  │ - PUT URL for transcription.json (upload, 1hr)  │ │
    │  └─────────────────────────────────────────────────┘ │
    │                            │                         │
    ├──[POST /transcribe]────────►                         │
    │  {                         │                         │
    │    "audio_url": "s3://..?sig",                       │
    │    "result_url": "s3://..?sig",                      │
    │    "diarize": true         │                         │
    │  }                         │                         │
    │  (tiny JSON, <2KB)         │                         │
    │                            │                         │
    │  ┌─────────────────────────────────────────────────┐ │
    │  │ STEP 2: GPU Downloads Audio                     │ │
    │  └─────────────────────────────────────────────────┘ │
    │                            │                         │
    │                            ├───[GET audio.wav]───────►
    │                            │   (142MB direct from S3) │
    │                            │   No proxy! No timeout!  │
    │                            │                         │
    │  ┌─────────────────────────────────────────────────┐ │
    │  │ STEP 3: GPU Processes (15+ minutes OK)          │ │
    │  │ - WhisperX transcription                        │ │
    │  │ - Pyannote diarization                          │ │
    │  │ - Word-level alignment                          │ │
    │  └─────────────────────────────────────────────────┘ │
    │                            │                         │
    │  ┌─────────────────────────────────────────────────┐ │
    │  │ STEP 4: GPU Uploads Result                      │ │
    │  └─────────────────────────────────────────────────┘ │
    │                            │                         │
    │                            ├───[PUT transcription.json]►
    │                            │   (2-3MB direct to S3)  │
    │                            │   No proxy! No timeout! │
    │                            │                         │
    │  ┌─────────────────────────────────────────────────┐ │
    │  │ STEP 5: GPU Returns Status                      │ │
    │  └─────────────────────────────────────────────────┘ │
    │                            │                         │
    │◄───[{"status": "ok"}]──────┤                         │
    │    (tiny response, <1KB)   │                         │
    │                            │                         │
```

---

## S3 Path Structure

```
s3://clouddrive-app-bucket/
└── users/
    └── {cognito_user_id}/
        └── audio/
            └── sessions/
                └── {session_id}/
                    │
                    │── audio.wav              ← INPUT: Merged audio file
                    │                            (presigned GET URL)
                    │
                    │── transcription.json     ← OUTPUT: Transcription result
                    │                            (presigned PUT URL)
                    │
                    │── chunk-001.webm         ← Original chunks (optional)
                    │── chunk-002.webm
                    │── ...
                    │
                    └── metadata.json          ← Session metadata
```

### Example Paths

```bash
# User ID
USER_ID="512b3590-30b1-707d-ed46-bf68df7b52d5"

# Session ID
SESSION_ID="session_2025-12-15T02_47_34_213Z"

# Full paths
AUDIO_PATH="s3://clouddrive-app-bucket/users/${USER_ID}/audio/sessions/${SESSION_ID}/audio.wav"
RESULT_PATH="s3://clouddrive-app-bucket/users/${USER_ID}/audio/sessions/${SESSION_ID}/transcription.json"
```

---

## Security Model

### Presigned URL Security

| Security Layer | Protection | Implementation |
|---------------|------------|----------------|
| **Time-limited** | URLs expire | 1-hour expiry (configurable) |
| **Operation-scoped** | Read OR Write, not both | Separate GET and PUT URLs |
| **Path-scoped** | Single file access | Each URL accesses exactly one S3 object |
| **Signature-verified** | Cryptographically signed | AWS Signature Version 4 |
| **No credentials shared** | RunPod never sees AWS keys | Only receives signed URLs |
| **HTTPS enforced** | Encrypted in transit | S3 requires HTTPS for presigned URLs |

### What an Attacker CANNOT Do

Even if an attacker intercepts a presigned URL:

| Attack Vector | Protected? | Reason |
|--------------|------------|--------|
| Access other files | ✅ | URL is path-scoped to single file |
| Modify audio file | ✅ | GET URL is read-only |
| Upload to wrong location | ✅ | PUT URL is path-scoped |
| Use after expiry | ✅ | 1-hour expiry enforced by AWS |
| Extract AWS credentials | ✅ | Signature ≠ credentials |
| Replay attack | ✅ | Timestamp in signature |

### Presigned URL Anatomy

```
https://clouddrive-app-bucket.s3.us-east-2.amazonaws.com/
  users/512b3590.../audio/sessions/session_2025-12-15.../audio.wav
  ?X-Amz-Algorithm=AWS4-HMAC-SHA256
  &X-Amz-Credential=AKIA.../20251215/us-east-2/s3/aws4_request
  &X-Amz-Date=20251215T213705Z
  &X-Amz-Expires=3600              ← 1 hour = 3600 seconds
  &X-Amz-SignedHeaders=host
  &X-Amz-Signature=b2c81ca3...     ← Cryptographic signature (NOT the secret key)
```

### IAM Permissions Required

The Edge Box needs these IAM permissions to generate presigned URLs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GeneratePresignedURLs",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::clouddrive-app-bucket/users/*/audio/sessions/*/audio.wav",
        "arn:aws:s3:::clouddrive-app-bucket/users/*/audio/sessions/*/transcription.json"
      ]
    }
  ]
}
```

---

## API Contract

### Request: POST /transcribe

```json
{
  "audio_url": "https://clouddrive-app-bucket.s3.us-east-2.amazonaws.com/...?X-Amz-Signature=...",
  "result_url": "https://clouddrive-app-bucket.s3.us-east-2.amazonaws.com/...?X-Amz-Signature=...",
  "language": "en",
  "diarize": true,
  "min_speakers": null,
  "max_speakers": null
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `audio_url` | string | Yes | Presigned GET URL for audio file |
| `result_url` | string | No | Presigned PUT URL for result (if omitted, returns JSON) |
| `language` | string | No | Language code (auto-detect if null) |
| `diarize` | bool | No | Enable speaker diarization (default: true) |
| `min_speakers` | int | No | Minimum speakers hint |
| `max_speakers` | int | No | Maximum speakers hint |

### Response (when result_url provided)

```json
{
  "status": "ok",
  "message": "Transcription uploaded to S3",
  "segments_count": 1117,
  "speakers_count": 2,
  "duration_seconds": 4447.5,
  "processing_time_seconds": 892.3
}
```

### Response (when result_url NOT provided - legacy mode)

```json
{
  "segments": [...],
  "language": "en",
  "speakers": ["SPEAKER_00", "SPEAKER_01"],
  "processing_time_seconds": 892.3
}
```

---

## Implementation

### 1. Edge Box: Generate Presigned URLs

```bash
#!/bin/bash
# Function to generate presigned URLs for a session

generate_presigned_urls() {
    local session_path="$1"
    local expiry="${2:-3600}"  # Default 1 hour

    local audio_s3="s3://${S3_BUCKET}/${session_path}/audio.wav"
    local result_s3="s3://${S3_BUCKET}/${session_path}/transcription.json"

    # Generate GET URL for audio (download)
    local audio_url=$(aws s3 presign "$audio_s3" --expires-in "$expiry")

    # Generate PUT URL for result (upload)
    # Note: AWS CLI presign defaults to GET, need to use SDK for PUT
    # Alternative: Use aws s3api with --request-payer
    local result_url=$(python3 -c "
import boto3
s3 = boto3.client('s3')
url = s3.generate_presigned_url(
    'put_object',
    Params={
        'Bucket': '${S3_BUCKET}',
        'Key': '${session_path}/transcription.json',
        'ContentType': 'application/json'
    },
    ExpiresIn=${expiry}
)
print(url)
")

    echo "AUDIO_URL=$audio_url"
    echo "RESULT_URL=$result_url"
}
```

### 2. Edge Box: Call RunPod API

```bash
#!/bin/bash
# Function to transcribe using presigned URLs

transcribe_with_presigned_urls() {
    local session_path="$1"

    # Generate URLs
    eval $(generate_presigned_urls "$session_path")

    # Call RunPod API
    local response=$(curl -s -X POST "${RUNPOD_URL}/transcribe" \
        -H "Content-Type: application/json" \
        -d "{
            \"audio_url\": \"${AUDIO_URL}\",
            \"result_url\": \"${RESULT_URL}\",
            \"diarize\": true
        }" \
        --max-time 7200)  # 2 hour timeout for very long audio

    # Check response
    local status=$(echo "$response" | jq -r '.status')
    if [ "$status" = "ok" ]; then
        echo "Transcription successful"
        echo "Segments: $(echo "$response" | jq -r '.segments_count')"
        echo "Speakers: $(echo "$response" | jq -r '.speakers_count')"
        return 0
    else
        echo "Transcription failed: $response"
        return 1
    fi
}
```

### 3. RunPod API: Updated Handler

```python
# handler_pod.py - Updated /transcribe endpoint

import requests
import json

class TranscribeRequest(BaseModel):
    """Transcription request body."""
    audio_url: Optional[str] = None
    audio_base64: Optional[str] = None
    result_url: Optional[str] = None  # NEW: Presigned PUT URL for result
    language: Optional[str] = None
    diarize: bool = True
    min_speakers: Optional[int] = None
    max_speakers: Optional[int] = None


@app.post("/transcribe")
async def transcribe(request: TranscribeRequest):
    """
    Transcribe audio from presigned S3 URL.

    If result_url is provided, uploads result to S3 and returns status.
    Otherwise, returns full transcription JSON in response.
    """
    try:
        if not request.audio_url and not request.audio_base64:
            raise HTTPException(400, "Must provide audio_url or audio_base64")

        model = load_model()

        # Determine file extension from URL
        ext = ".wav"
        if request.audio_url:
            for e in [".mp3", ".wav", ".m4a", ".flac", ".ogg", ".opus", ".webm"]:
                if e in request.audio_url.split("?")[0].lower():
                    ext = e
                    break

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            audio_path = f.name

        try:
            # Download audio from presigned URL
            if request.audio_url:
                logger.info(f"Downloading audio from presigned URL...")
                response = requests.get(request.audio_url, stream=True, timeout=600)
                response.raise_for_status()

                with open(audio_path, 'wb') as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        f.write(chunk)

                file_size = os.path.getsize(audio_path)
                logger.info(f"Downloaded {file_size / 1024 / 1024:.1f} MB")

            elif request.audio_base64:
                audio_bytes = base64.b64decode(request.audio_base64)
                with open(audio_path, 'wb') as f:
                    f.write(audio_bytes)

            # Transcribe
            logger.info(f"Transcribing with diarize={request.diarize}")
            start = time.time()

            result = model.transcribe(
                audio_path=audio_path,
                language=request.language,
                diarize=request.diarize and ENABLE_DIARIZATION,
                min_speakers=request.min_speakers,
                max_speakers=request.max_speakers
            )

            elapsed = time.time() - start
            logger.info(f"Transcription complete in {elapsed:.1f}s")

            result["processing_time_seconds"] = round(elapsed, 2)

            # If result_url provided, upload to S3
            if request.result_url:
                logger.info("Uploading result to S3...")
                upload_response = requests.put(
                    request.result_url,
                    data=json.dumps(result),
                    headers={"Content-Type": "application/json"},
                    timeout=300
                )
                upload_response.raise_for_status()
                logger.info("Result uploaded to S3")

                # Return summary instead of full result
                return {
                    "status": "ok",
                    "message": "Transcription uploaded to S3",
                    "segments_count": len(result.get("segments", [])),
                    "speakers_count": len(result.get("speakers", [])),
                    "duration_seconds": result["segments"][-1]["end"] if result.get("segments") else 0,
                    "processing_time_seconds": result["processing_time_seconds"]
                }

            # Otherwise return full result
            return result

        finally:
            if os.path.exists(audio_path):
                os.unlink(audio_path)
            gc.collect()

    except requests.exceptions.RequestException as e:
        logger.error(f"S3 request error: {e}")
        raise HTTPException(502, f"S3 error: {str(e)}")
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Transcription error: {e}", exc_info=True)
        raise HTTPException(500, str(e))
```

---

## Batch Processing Script

### 515-runpod--batch-transcribe.sh (Updated)

```bash
#!/bin/bash
#===============================================================================
# 515-runpod--batch-transcribe.sh
#
# Batch transcribe audio sessions using RunPod GPU with S3 presigned URLs.
# Completely bypasses Cloudflare proxy timeout by having GPU download/upload
# directly from/to S3.
#
# Usage:
#   ./scripts/515-runpod--batch-transcribe.sh              # All pending sessions
#   ./scripts/515-runpod--batch-transcribe.sh --session X  # Specific session
#   ./scripts/515-runpod--batch-transcribe.sh --dry-run    # Show what would run
#
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_ROOT}/../transcription-realtime-whisper-cognito-s3-lambda-ver4/.env"

# Load environment
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

S3_BUCKET="${COGNITO_S3_BUCKET:-clouddrive-app-bucket}"
RUNPOD_URL="https://${RUNPOD_HOST:-localhost}:${RUNPOD_PORT:-8000}"
URL_EXPIRY=3600  # 1 hour

#-------------------------------------------------------------------------------
# Generate presigned PUT URL for uploading result
#-------------------------------------------------------------------------------
generate_put_url() {
    local s3_path="$1"
    local expiry="${2:-$URL_EXPIRY}"

    python3 << PYTHON
import boto3
s3 = boto3.client('s3', region_name='${AWS_REGION:-us-east-2}')
url = s3.generate_presigned_url(
    'put_object',
    Params={
        'Bucket': '${S3_BUCKET}',
        'Key': '${s3_path}',
        'ContentType': 'application/json'
    },
    ExpiresIn=${expiry}
)
print(url)
PYTHON
}

#-------------------------------------------------------------------------------
# Transcribe a single session using presigned URLs
#-------------------------------------------------------------------------------
transcribe_session() {
    local session_path="$1"
    local audio_key="${session_path}/audio.wav"
    local result_key="${session_path}/transcription.json"

    log_info "Processing: $session_path"

    # Check if audio.wav exists
    if ! aws s3 ls "s3://${S3_BUCKET}/${audio_key}" &>/dev/null; then
        log_warn "No audio.wav found, skipping"
        return 1
    fi

    # Generate presigned URLs
    log_info "Generating presigned URLs (${URL_EXPIRY}s expiry)..."
    local audio_url=$(aws s3 presign "s3://${S3_BUCKET}/${audio_key}" --expires-in "$URL_EXPIRY")
    local result_url=$(generate_put_url "$result_key" "$URL_EXPIRY")

    # Call RunPod API
    log_info "Sending to RunPod for transcription..."
    local start_time=$(date +%s)

    local response=$(curl -s -X POST "${RUNPOD_URL}/transcribe" \
        -H "Content-Type: application/json" \
        -d "{
            \"audio_url\": $(echo "$audio_url" | jq -Rs .),
            \"result_url\": $(echo "$result_url" | jq -Rs .),
            \"diarize\": true
        }" \
        --max-time 7200)

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Check response
    local status=$(echo "$response" | jq -r '.status // "error"')

    if [ "$status" = "ok" ]; then
        local segments=$(echo "$response" | jq -r '.segments_count // 0')
        local speakers=$(echo "$response" | jq -r '.speakers_count // 0')
        log_success "Transcribed in ${elapsed}s: ${segments} segments, ${speakers} speakers"
        return 0
    else
        log_error "Transcription failed: $response"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Find sessions needing transcription
#-------------------------------------------------------------------------------
find_pending_sessions() {
    log_info "Scanning for sessions with audio.wav but no transcription.json..."

    # List all sessions with audio.wav
    aws s3 ls "s3://${S3_BUCKET}/users/" --recursive \
        | grep "audio\.wav$" \
        | awk '{print $4}' \
        | sed 's|/audio\.wav$||' \
        | while read session_path; do
            # Check if transcription.json exists
            if ! aws s3 ls "s3://${S3_BUCKET}/${session_path}/transcription.json" &>/dev/null; then
                echo "$session_path"
            fi
        done
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    log_info "RunPod Batch Transcription (Presigned URL Mode)"
    log_info "RunPod URL: $RUNPOD_URL"
    log_info "S3 Bucket: $S3_BUCKET"

    # Check RunPod is accessible
    if ! curl -s "${RUNPOD_URL}/health" | grep -q '"status":"ok"'; then
        log_error "RunPod not accessible at $RUNPOD_URL"
        exit 1
    fi

    # Get sessions to process
    local sessions=()
    if [ "${1:-}" = "--session" ] && [ -n "${2:-}" ]; then
        sessions=("$2")
    else
        mapfile -t sessions < <(find_pending_sessions)
    fi

    if [ ${#sessions[@]} -eq 0 ]; then
        log_info "No sessions pending transcription"
        exit 0
    fi

    log_info "Found ${#sessions[@]} sessions to transcribe"

    # Process each session
    local success=0
    local failed=0

    for session in "${sessions[@]}"; do
        if transcribe_session "$session"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    log_info "Complete: $success succeeded, $failed failed"
}

# Logging helpers
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*"; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*"; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

main "$@"
```

---

## Timeout Analysis

### Before (Proxy Upload)

| Audio Duration | File Size | Upload Time | Transcription | Total | Proxy Limit | Result |
|---------------|-----------|-------------|---------------|-------|-------------|--------|
| 5 min | 9 MB | 5s | 30s | 35s | 100s | ✅ OK |
| 30 min | 57 MB | 30s | 180s | 210s | 100s | ❌ TIMEOUT |
| 74 min | 142 MB | 90s | 450s | 540s | 100s | ❌ TIMEOUT |

### After (Presigned URLs)

| Audio Duration | File Size | Request Size | Transcription | Response | Proxy Limit | Result |
|---------------|-----------|--------------|---------------|----------|-------------|--------|
| 5 min | 9 MB | <2 KB | 30s | <1 KB | 100s | ✅ OK |
| 30 min | 57 MB | <2 KB | 180s | <1 KB | 100s | ✅ OK |
| 74 min | 142 MB | <2 KB | 450s | <1 KB | 100s | ✅ OK |
| 4 hours | 700 MB | <2 KB | 1800s | <1 KB | 100s | ✅ OK |

**Key insight:** The only data through the proxy is the tiny JSON request (<2KB) and response (<1KB). The heavy audio/result transfer happens directly between GPU and S3.

---

## Error Handling

### Possible Errors and Recovery

| Error | Cause | Recovery |
|-------|-------|----------|
| `403 Forbidden` on audio download | Presigned URL expired | Regenerate URLs, retry |
| `403 Forbidden` on result upload | Presigned URL expired | Regenerate PUT URL, download result from RunPod response |
| `404 Not Found` on audio | Audio file deleted | Skip session, log error |
| `502 Bad Gateway` | S3 temporarily unavailable | Retry with backoff |
| RunPod timeout | Very long audio | Increase --max-time, or process in chunks |

### Retry Logic

```bash
transcribe_with_retry() {
    local session_path="$1"
    local max_retries=3
    local retry_delay=30

    for ((i=1; i<=max_retries; i++)); do
        if transcribe_session "$session_path"; then
            return 0
        fi

        if [ $i -lt $max_retries ]; then
            log_warn "Retry $i/$max_retries in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        fi
    done

    log_error "Failed after $max_retries retries"
    return 1
}
```

---

## Testing Checklist

- [ ] Generate presigned GET URL for audio.wav
- [ ] Generate presigned PUT URL for transcription.json
- [ ] Verify URLs work with curl (manual test)
- [ ] Update handler_pod.py with result_url support
- [ ] Build and push new Docker image
- [ ] Start RunPod pod with new image
- [ ] Test /health endpoint
- [ ] Test transcription with presigned URLs
- [ ] Verify result uploaded to S3
- [ ] Test with 74-minute audio file
- [ ] Shutdown pod after testing

---

## Configuration

### Environment Variables

```bash
# .env additions for presigned URL support

# S3 bucket for audio storage
COGNITO_S3_BUCKET=clouddrive-app-bucket

# AWS region
AWS_REGION=us-east-2

# Presigned URL expiry (seconds)
PRESIGNED_URL_EXPIRY=3600

# RunPod configuration
RUNPOD_HOST=xxx-8000.proxy.runpod.net
RUNPOD_PORT=443
```

---

## Future Enhancements

1. **Webhook callback**: RunPod POSTs to Edge Box when complete
2. **Progress tracking**: RunPod updates S3 progress file during processing
3. **Chunked processing**: For 4+ hour files, process in overlapping chunks
4. **Speaker clustering**: Match speakers across chunks using embeddings
