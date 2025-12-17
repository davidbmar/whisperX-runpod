# Async Request-Reply Pattern for Long Audio Transcription

## Problem Statement

The current synchronous API fails for audio files that take >100 seconds to process due to Cloudflare's proxy idle timeout.

```
Client                    Cloudflare Proxy           RunPod GPU
    │                            │                         │
    ├──[POST /transcribe]────────┼────────────────────────►│
    │                            │                         │
    │    [HTTP connection open]  │   [Processing...]       │
    │                            │                         │
    │    ⛔ CONNECTION TIMEOUT   │   [Still processing...] │
    │    (100 seconds idle)      │                         │
    │                            │                         │
    │    Client receives 502/524 │   [Completes, but       │
    │                            │    no one to respond to]│
```

**Observed Behavior:**
- 17-minute audio (116s processing) - Works (barely within timeout)
- 45-minute audio (~300s processing) - Fails with HTTP 502/524
- 74-minute audio (~450s processing) - Fails with HTTP 502/524

## Solution: Async Request-Reply Pattern

Return a job ID immediately, process in background, allow polling for status.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ASYNC PATTERN FLOW                                 │
└─────────────────────────────────────────────────────────────────────────────┘

Client                      RunPod GPU                     S3 Bucket
    │                            │                              │
    │  STEP 1: Submit Job        │                              │
    ├──[POST /transcribe]────────►                              │
    │  { audio_url, result_url } │                              │
    │                            │                              │
    │◄──{"job_id": "abc123"}─────┤  (returns in <1 second)      │
    │                            │                              │
    │                            │  [Download audio from S3]    │
    │                            ├──────────────────────────────►
    │                            │                              │
    │  STEP 2: Poll Status       │  [Processing in background]  │
    ├──[GET /status/abc123]──────►                              │
    │◄──{"status":"processing"}──┤                              │
    │                            │                              │
    │  ... (repeat every 30s)    │                              │
    │                            │                              │
    │  STEP 3: Get Result        │                              │
    ├──[GET /status/abc123]──────►                              │
    │◄──{"status":"completed"}───┤                              │
    │                            │                              │
    │                            │  [Upload result to S3]       │
    │                            ├──────────────────────────────►
    │                            │                              │
```

---

## API Contract

### POST /transcribe - Submit Job

Accepts the same parameters as before, but now returns immediately with a job ID.

**Request:**
```json
{
    "audio_url": "https://bucket.s3.region.amazonaws.com/.../audio.wav?X-Amz-Signature=...",
    "result_url": "https://bucket.s3.region.amazonaws.com/.../transcription.json?X-Amz-Signature=...",
    "diarize": true,
    "language": "en",
    "min_speakers": null,
    "max_speakers": null
}
```

**Response (immediate, <1 second):**
```json
{
    "job_id": "abc123-def456-ghi789",
    "status": "queued",
    "message": "Job queued for processing"
}
```

### GET /status/{job_id} - Check Status

**Response (while processing):**
```json
{
    "job_id": "abc123-def456-ghi789",
    "status": "processing",
    "progress": 45,
    "message": "Transcribing audio...",
    "started_at": "2025-12-17T04:30:00Z"
}
```

**Response (when complete):**
```json
{
    "job_id": "abc123-def456-ghi789",
    "status": "completed",
    "progress": 100,
    "message": "Transcription uploaded to S3",
    "started_at": "2025-12-17T04:30:00Z",
    "completed_at": "2025-12-17T04:35:00Z",
    "segments_count": 1117,
    "speakers_count": 4,
    "duration_seconds": 2700,
    "processing_time_seconds": 300
}
```

**Response (on failure):**
```json
{
    "job_id": "abc123-def456-ghi789",
    "status": "failed",
    "error": "Failed to download audio: 403 Forbidden (presigned URL expired)",
    "started_at": "2025-12-17T04:30:00Z",
    "failed_at": "2025-12-17T04:30:05Z"
}
```

### Status Values

| Status | Description |
|--------|-------------|
| `queued` | Job received, waiting to start |
| `downloading` | Downloading audio from S3 |
| `processing` | Transcribing with WhisperX |
| `uploading` | Uploading result to S3 |
| `completed` | Job finished successfully |
| `failed` | Job failed with error |

---

## Implementation

### 1. handler_pod.py Changes

```python
import uuid
import threading
from datetime import datetime
from typing import Dict, Any, Optional
from dataclasses import dataclass, field

# =============================================================================
# Job State Management
# =============================================================================
@dataclass
class Job:
    """Represents a transcription job."""
    job_id: str
    status: str = "queued"
    progress: int = 0
    message: str = ""
    error: Optional[str] = None
    started_at: Optional[str] = None
    completed_at: Optional[str] = None
    failed_at: Optional[str] = None
    # Result summary (populated on completion)
    segments_count: int = 0
    speakers_count: int = 0
    duration_seconds: float = 0
    processing_time_seconds: float = 0

# In-memory job storage (consider Redis for persistence across restarts)
jobs: Dict[str, Job] = {}
jobs_lock = threading.Lock()

def get_job(job_id: str) -> Optional[Job]:
    with jobs_lock:
        return jobs.get(job_id)

def update_job(job_id: str, **kwargs):
    with jobs_lock:
        if job_id in jobs:
            for key, value in kwargs.items():
                setattr(jobs[job_id], key, value)

def create_job() -> Job:
    job_id = str(uuid.uuid4())
    job = Job(job_id=job_id)
    with jobs_lock:
        jobs[job_id] = job
    return job


# =============================================================================
# Background Processing
# =============================================================================
def process_transcription_async(job_id: str, request: TranscribeRequest):
    """Process transcription in background thread."""
    try:
        update_job(job_id,
                   status="downloading",
                   message="Downloading audio from S3...",
                   started_at=datetime.utcnow().isoformat() + "Z")

        # Download audio
        ext = get_extension_from_url(request.audio_url)
        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            audio_path = f.name

        try:
            response = requests.get(request.audio_url, stream=True, timeout=600)
            response.raise_for_status()
            with open(audio_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    f.write(chunk)

            update_job(job_id,
                       status="processing",
                       progress=10,
                       message="Transcribing audio...")

            # Transcribe
            model = load_model()
            start_time = time.time()

            result = model.transcribe(
                audio_path=audio_path,
                language=request.language,
                diarize=request.diarize,
                min_speakers=request.min_speakers,
                max_speakers=request.max_speakers
            )

            elapsed = time.time() - start_time

            update_job(job_id,
                       status="uploading",
                       progress=90,
                       message="Uploading result to S3...")

            # Upload result
            if request.result_url:
                result["processing_time_seconds"] = round(elapsed, 2)
                upload_response = requests.put(
                    request.result_url,
                    data=json.dumps(result),
                    headers={"Content-Type": "application/json"},
                    timeout=300
                )
                upload_response.raise_for_status()

            # Mark complete
            segments = result.get("segments", [])
            speakers = result.get("speakers", [])
            duration = segments[-1]["end"] if segments else 0

            update_job(job_id,
                       status="completed",
                       progress=100,
                       message="Transcription uploaded to S3",
                       completed_at=datetime.utcnow().isoformat() + "Z",
                       segments_count=len(segments),
                       speakers_count=len(speakers),
                       duration_seconds=duration,
                       processing_time_seconds=round(elapsed, 2))

        finally:
            if os.path.exists(audio_path):
                os.unlink(audio_path)
            gc.collect()

    except Exception as e:
        logger.error(f"Job {job_id} failed: {e}", exc_info=True)
        update_job(job_id,
                   status="failed",
                   error=str(e),
                   failed_at=datetime.utcnow().isoformat() + "Z")


# =============================================================================
# API Endpoints
# =============================================================================
@app.post("/transcribe")
async def transcribe(request: TranscribeRequest):
    """
    Submit transcription job (async).
    Returns immediately with job_id.
    """
    if not request.audio_url and not request.audio_base64:
        raise HTTPException(400, "Must provide audio_url or audio_base64")

    # Create job
    job = create_job()
    logger.info(f"Created job {job.job_id}")

    # Start background processing
    thread = threading.Thread(
        target=process_transcription_async,
        args=(job.job_id, request)
    )
    thread.daemon = True
    thread.start()

    # Return immediately
    return {
        "job_id": job.job_id,
        "status": "queued",
        "message": "Job queued for processing"
    }


@app.get("/status/{job_id}")
async def get_status(job_id: str):
    """Get job status."""
    job = get_job(job_id)
    if not job:
        raise HTTPException(404, f"Job {job_id} not found")

    response = {
        "job_id": job.job_id,
        "status": job.status,
        "progress": job.progress,
        "message": job.message,
    }

    if job.started_at:
        response["started_at"] = job.started_at

    if job.status == "completed":
        response["completed_at"] = job.completed_at
        response["segments_count"] = job.segments_count
        response["speakers_count"] = job.speakers_count
        response["duration_seconds"] = job.duration_seconds
        response["processing_time_seconds"] = job.processing_time_seconds

    if job.status == "failed":
        response["failed_at"] = job.failed_at
        response["error"] = job.error

    return response
```

### 2. Batch Script Changes (515-runpod--batch-transcribe.sh)

```bash
#-------------------------------------------------------------------------------
# Transcribe with async polling
#-------------------------------------------------------------------------------
transcribe_session_async() {
    local session_path="$1"
    local audio_key="${session_path}/audio.wav"
    local result_key="${session_path}/transcription-diarized.json"

    log_info "Processing: $session_path"

    # Generate presigned URLs
    local audio_url=$(aws s3 presign "s3://${S3_BUCKET}/${audio_key}" --expires-in "$URL_EXPIRY")
    local result_url=$(generate_put_url "$result_key" "$URL_EXPIRY")

    # Submit job
    log_info "Submitting job to RunPod..."
    local submit_response=$(curl -s -X POST "${RUNPOD_URL}/transcribe" \
        -H "Content-Type: application/json" \
        -d "{
            \"audio_url\": $(echo "$audio_url" | jq -Rs .),
            \"result_url\": $(echo "$result_url" | jq -Rs .),
            \"diarize\": true
        }" \
        --max-time 30)

    local job_id=$(echo "$submit_response" | jq -r '.job_id // empty')
    if [ -z "$job_id" ]; then
        log_error "Failed to submit job: $submit_response"
        return 1
    fi

    log_info "Job submitted: $job_id"

    # Poll for completion
    local poll_interval=30
    local max_polls=120  # 1 hour max
    local poll_count=0

    while [ $poll_count -lt $max_polls ]; do
        sleep $poll_interval
        ((poll_count++))

        local status_response=$(curl -s "${RUNPOD_URL}/status/${job_id}" --max-time 10)
        local status=$(echo "$status_response" | jq -r '.status // "unknown"')
        local progress=$(echo "$status_response" | jq -r '.progress // 0')
        local message=$(echo "$status_response" | jq -r '.message // ""')

        log_info "  [$job_id] Status: $status ($progress%) - $message"

        case "$status" in
            "completed")
                local segments=$(echo "$status_response" | jq -r '.segments_count // 0')
                local speakers=$(echo "$status_response" | jq -r '.speakers_count // 0')
                local time=$(echo "$status_response" | jq -r '.processing_time_seconds // 0')
                log_success "Completed in ${time}s: ${segments} segments, ${speakers} speakers"
                return 0
                ;;
            "failed")
                local error=$(echo "$status_response" | jq -r '.error // "unknown error"')
                log_error "Job failed: $error"
                return 1
                ;;
            "queued"|"downloading"|"processing"|"uploading")
                # Still running, continue polling
                ;;
            *)
                log_warn "Unknown status: $status"
                ;;
        esac
    done

    log_error "Job timed out after $((poll_count * poll_interval)) seconds"
    return 1
}
```

---

## Timeout Analysis: Async Pattern

| Audio Duration | Submit Time | Processing | Polls | Total Client Time | Result |
|---------------|-------------|------------|-------|-------------------|--------|
| 5 min | <1s | 30s | 1 | ~31s | ✅ OK |
| 17 min | <1s | 120s | 4 | ~121s | ✅ OK |
| 45 min | <1s | 300s | 10 | ~301s | ✅ OK |
| 74 min | <1s | 450s | 15 | ~451s | ✅ OK |
| 4 hours | <1s | 1800s | 60 | ~1801s | ✅ OK |

**Key improvement:** Each HTTP request (submit and poll) completes in <10 seconds, well within Cloudflare's 100-second limit.

---

## Job Cleanup

Jobs should be cleaned up after a retention period to prevent memory leaks.

```python
import time

JOB_RETENTION_SECONDS = 3600  # Keep completed jobs for 1 hour

def cleanup_old_jobs():
    """Remove jobs older than retention period."""
    now = datetime.utcnow()
    with jobs_lock:
        to_delete = []
        for job_id, job in jobs.items():
            if job.status in ("completed", "failed"):
                # Parse completion time
                completed = job.completed_at or job.failed_at
                if completed:
                    completed_dt = datetime.fromisoformat(completed.rstrip("Z"))
                    age = (now - completed_dt).total_seconds()
                    if age > JOB_RETENTION_SECONDS:
                        to_delete.append(job_id)

        for job_id in to_delete:
            del jobs[job_id]

        if to_delete:
            logger.info(f"Cleaned up {len(to_delete)} old jobs")

# Run cleanup periodically (e.g., via background thread or APScheduler)
```

---

## Future Enhancements

1. **Webhook Callbacks**: Notify client when job completes instead of polling
2. **Redis Persistence**: Store jobs in Redis for persistence across container restarts
3. **Job Cancellation**: `DELETE /jobs/{job_id}` to cancel running jobs
4. **Batch Submission**: Submit multiple jobs in one request
5. **Progress Streaming**: WebSocket endpoint for real-time progress updates

---

## Related Documents

- `PRESIGNED_URL_DESIGN.md` - S3 presigned URL architecture (this repo)
- `docs/PRESIGNED_URL_TRANSCRIPTION.md` - Integration documentation (transcription-realtime-whisper-cognito-s3-lambda-ver4 repo)
