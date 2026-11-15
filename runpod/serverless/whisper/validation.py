"""Input validation for the Whisper worker, kept free of GPU imports so it can
be unit-tested anywhere."""

from dataclasses import dataclass
from typing import Any, Mapping, Optional
from urllib.parse import urlparse

MAX_BEAM_SIZE = 10


class InputError(ValueError):
    """The job input is invalid. Reported to the caller, never retried."""


@dataclass(frozen=True)
class TranscribeRequest:
    audio_url: str
    language: Optional[str]
    task: str
    beam_size: int
    vad_filter: bool
    word_timestamps: bool


def parse_input(raw: Any) -> TranscribeRequest:
    if not isinstance(raw, Mapping):
        raise InputError("input must be a JSON object")

    audio_url = raw.get("audio_url")
    if not isinstance(audio_url, str) or not audio_url:
        raise InputError("audio_url is required")
    parsed = urlparse(audio_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise InputError("audio_url must be an http(s) URL")

    language = raw.get("language")
    if language is not None and (not isinstance(language, str) or not 2 <= len(language) <= 5):
        raise InputError("language must be a language code such as 'en', or omitted to detect it")

    task = raw.get("task", "transcribe")
    if task not in ("transcribe", "translate"):
        raise InputError("task must be 'transcribe' or 'translate'")

    beam_size = raw.get("beam_size", 5)
    # bool is an int subclass; reject it explicitly
    if isinstance(beam_size, bool) or not isinstance(beam_size, int) or not 1 <= beam_size <= MAX_BEAM_SIZE:
        raise InputError(f"beam_size must be an integer from 1 to {MAX_BEAM_SIZE}")

    return TranscribeRequest(
        audio_url=audio_url,
        language=language,
        task=task,
        beam_size=beam_size,
        vad_filter=_flag(raw, "vad_filter", True),
        word_timestamps=_flag(raw, "word_timestamps", False),
    )


def _flag(raw: Mapping, key: str, default: bool) -> bool:
    value = raw.get(key, default)
    if not isinstance(value, bool):
        raise InputError(f"{key} must be true or false")
    return value
