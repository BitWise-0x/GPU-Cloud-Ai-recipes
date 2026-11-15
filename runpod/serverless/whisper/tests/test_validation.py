"""Unit tests for the worker's input validation (no GPU, no network).

Run: python3 -m unittest discover -s runpod/serverless/whisper/tests
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from validation import MAX_BEAM_SIZE, InputError, parse_input  # noqa: E402

URL = "https://example.com/a.wav"


class ParseInputTest(unittest.TestCase):
    def test_defaults(self):
        req = parse_input({"audio_url": URL})
        self.assertEqual(req.audio_url, URL)
        self.assertIsNone(req.language)
        self.assertEqual(req.task, "transcribe")
        self.assertEqual(req.beam_size, 5)
        self.assertTrue(req.vad_filter)
        self.assertFalse(req.word_timestamps)

    def test_all_fields(self):
        req = parse_input({"audio_url": URL, "language": "de", "task": "translate",
                           "beam_size": 1, "vad_filter": False, "word_timestamps": True})
        self.assertEqual((req.language, req.task, req.beam_size, req.vad_filter, req.word_timestamps),
                         ("de", "translate", 1, False, True))

    def test_rejects(self):
        cases = [
            None,
            [],
            {},
            {"audio_url": ""},
            {"audio_url": "file:///etc/passwd"},
            {"audio_url": "ftp://example.com/a.wav"},
            {"audio_url": "https://"},
            {"audio_url": URL, "language": 5},
            {"audio_url": URL, "language": "english-us"},
            {"audio_url": URL, "task": "summarize"},
            {"audio_url": URL, "beam_size": 0},
            {"audio_url": URL, "beam_size": MAX_BEAM_SIZE + 1},
            {"audio_url": URL, "beam_size": "5"},
            {"audio_url": URL, "beam_size": True},
            {"audio_url": URL, "vad_filter": "yes"},
            {"audio_url": URL, "word_timestamps": 1},
        ]
        for raw in cases:
            with self.subTest(raw=raw), self.assertRaises(InputError):
                parse_input(raw)


if __name__ == "__main__":
    unittest.main()
