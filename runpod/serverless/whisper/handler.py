"""RunPod serverless worker: speech to text with faster-whisper.

The model is baked into the image (Dockerfile) and loaded once per worker, at
import, so a warm worker answers a job without touching disk or the network for
weights. Input:

    {"audio_url": "https://...", "language": "en", "task": "transcribe",
     "beam_size": 5, "vad_filter": true, "word_timestamps": false}

Only audio_url is required. Output: the detected language, the duration, the
full text and the segments (with words when word_timestamps is true).
"""

import os
import tempfile
import time
import urllib.request
from typing import Any, Dict

import runpod
from faster_whisper import WhisperModel

from validation import InputError, TranscribeRequest, parse_input

MODEL_DIR = os.environ.get("WHISPER_MODEL_DIR", "/models/whisper")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "float16")
MAX_AUDIO_BYTES = int(os.environ.get("MAX_AUDIO_MB", "500")) * 1024 * 1024
DOWNLOAD_TIMEOUT_S = int(os.environ.get("DOWNLOAD_TIMEOUT_S", "120"))

_t0 = time.monotonic()
# Loaded at import: a model that cannot load fails the worker at start, where
# RunPod's worker logs show it, instead of failing every job one by one.
MODEL = WhisperModel(MODEL_DIR, device="cuda", compute_type=COMPUTE_TYPE)
print(f"model loaded from {MODEL_DIR} ({COMPUTE_TYPE}) in {time.monotonic() - _t0:.1f}s", flush=True)


def _download(url: str, dest: str) -> None:
    """Stream url to dest, refusing anything over MAX_AUDIO_BYTES."""
    request = urllib.request.Request(url, headers={"User-Agent": "whisper-worker"})
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_S) as response, open(dest, "wb") as out:
        declared = response.headers.get("Content-Length")
        if declared and int(declared) > MAX_AUDIO_BYTES:
            raise InputError(f"audio is {int(declared) // (1024 * 1024)} MB, over the {MAX_AUDIO_BYTES // (1024 * 1024)} MB limit")
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > MAX_AUDIO_BYTES:
                raise InputError(f"audio is over the {MAX_AUDIO_BYTES // (1024 * 1024)} MB limit")
            out.write(chunk)


def _sec(value: Any) -> float:
    # faster-whisper returns numpy floats; plain floats keep the output clean JSON
    return round(float(value), 3)


def _transcribe(req: TranscribeRequest, path: str) -> Dict[str, Any]:
    segments, info = MODEL.transcribe(
        path,
        language=req.language,
        task=req.task,
        beam_size=req.beam_size,
        vad_filter=req.vad_filter,
        word_timestamps=req.word_timestamps,
    )
    # segments is a generator: the decoding happens while it is consumed
    out_segments = []
    for seg in segments:
        item: Dict[str, Any] = {"start": _sec(seg.start), "end": _sec(seg.end), "text": seg.text.strip()}
        if req.word_timestamps and seg.words:
            item["words"] = [
                {"start": _sec(w.start), "end": _sec(w.end), "word": w.word, "probability": _sec(w.probability)}
                for w in seg.words
            ]
        out_segments.append(item)
    return {
        "language": info.language,
        "language_probability": _sec(info.language_probability),
        "duration": _sec(info.duration),
        "text": " ".join(s["text"] for s in out_segments),
        "segments": out_segments,
    }


def _is_cuda_oom(exc: BaseException) -> bool:
    msg = str(exc).lower()
    return "out of memory" in msg or ("cuda" in msg and "memory" in msg)


def handler(job: Dict[str, Any]) -> Dict[str, Any]:
    try:
        req = parse_input(job.get("input"))
    except InputError as exc:
        return {"error": f"invalid input: {exc}"}

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "audio")
        try:
            _download(req.audio_url, path)
        except InputError as exc:
            return {"error": f"invalid input: {exc}"}
        except OSError as exc:
            return {"error": f"could not download audio_url: {exc}"}

        t0 = time.monotonic()
        try:
            result = _transcribe(req, path)
        except RuntimeError as exc:
            if _is_cuda_oom(exc):
                # CUDA can be left in a bad state after an out-of-memory error,
                # and every later job on this worker would fail the same way.
                # refresh_worker has RunPod replace the worker after this job.
                return {"error": f"GPU out of memory: {exc}", "refresh_worker": True}
            raise
        result["processing_s"] = round(time.monotonic() - t0, 3)
        return result


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
