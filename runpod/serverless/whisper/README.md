# Whisper serverless worker

Speech to text on a RunPod serverless endpoint with
[faster-whisper](https://github.com/SYSTRAN/faster-whisper) large-v3. It scales
to zero, and the weights are baked into the image. A job sends an audio URL and
gets back the text and timed segments.

The worker is a small example on purpose. The parts worth copying into your own
worker are:

- **Weights baked into the image** in their own `--link` layer, pinned by
  commit (`Dockerfile`). Changing the code never re-downloads them.
- **The model loads at import**, once per worker. If it cannot load, the worker
  fails at start and you see that in RunPod's worker logs, instead of every job
  failing.
- **Input validated at the edge** (`validation.py`, unit-tested without a GPU).
  A bad input returns an `error` and does not retry.
- **Out-of-memory errors replace the worker** (`refresh_worker`). CUDA can be
  left broken after an out-of-memory error, and every later job on that worker
  would fail the same way.
- **The build checks that the model loads** (on the CPU), so a broken model
  fails the image build, not a billed worker.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | CUDA 12.8 + cuDNN 9 base, Python 3.12 venv, the model in its own layer |
| `handler.py` | the job handler: download, transcribe, return segments |
| `validation.py` | input parsing and limits |
| `requirements.txt` | pinned `runpod`, `faster-whisper`, `ctranslate2` |
| `test_input.json` | a sample job (a short public-domain clip) |
| `endpoint.example.json` | template and endpoint spec for `deploy/runpod_deploy.py` (pools checked against `GET /v2/catalog/gpus`) |
| `build-and-pin.example.yml` | GitHub Actions: build, push, pin the digest |
| `tests/` | validation unit tests |

## Input and output

```json
{"input": {"audio_url": "https://...", "language": "en", "task": "transcribe",
           "beam_size": 5, "vad_filter": true, "word_timestamps": false}}
```

Only `audio_url` is required. Leave `language` out to detect it, and set
`task` to `translate` to get English text from another language.

```json
{"language": "en", "language_probability": 0.99, "duration": 11.0,
 "text": "And so my fellow Americans ...",
 "segments": [{"start": 0.0, "end": 10.9, "text": "...", "words": [...]}],
 "processing_s": 0.8}
```

The worker fetches whatever URL a job names. Put the endpoint behind your own
service if untrusted callers can submit jobs, and do not give the worker
credentials it does not need.

| Env (template) | Default | |
|---|---|---|
| `MAX_AUDIO_MB` | 500 | refuse larger downloads |
| `DOWNLOAD_TIMEOUT_S` | 120 | per download |
| `WHISPER_COMPUTE_TYPE` | float16 | `int8_float16` halves VRAM at a small accuracy cost |

## Deploy

```bash
cd runpod/serverless/whisper

# 1. build and push (linux/amd64; on an ARM Mac this emulates and is slow)
docker buildx build --platform linux/amd64 --provenance=false \
  -t ghcr.io/your-user/whisper-worker:v1 --push .

# 2. spec: copy and set the image (and registryName for a private image:
#    a registry auth created once in the RunPod console, Settings > Container
#    Registry Auth). Commit it; secrets never go in it (envFromShell takes
#    their names, and the values come from your shell at create time).
cp endpoint.example.json endpoint.json

# 3. create the template and the endpoint
export RUNPOD_API_KEY=...        # from a secret store, not your shell history
python3 ../deploy/runpod_deploy.py apply endpoint.json

# 4. a test job (the first one waits for a cold worker to pull the image)
python3 ../deploy/runpod_deploy.py run endpoint.json test_input.json

# 5. later builds: pin the endpoint to the pushed digest
python3 ../deploy/runpod_deploy.py pin endpoint.json \
  ghcr.io/your-user/whisper-worker@sha256:<digest>
python3 ../deploy/runpod_deploy.py status endpoint.json
```

`apply` creates a missing template or endpoint. On an existing endpoint it
updates `workers`, `scaling`, `timeout`, `flashboot` and `gpu`. It never
changes the image (that is `pin`) and never rewrites a template's env (change
env values in the console, on the template and on the endpoint).

To run locally against the RunPod SDK's test server, you need an NVIDIA GPU and
the image: `docker run --gpus all -p 8000:8000 <image> python -u /app/handler.py --rp_serve_api --rp_api_host 0.0.0.0`.

[docs/serverless.md](../../docs/serverless.md) covers how templates,
endpoints, releases, GPU pools and cold starts behave.

## Status

Unbuilt. The Dockerfile, handler and deploy script have not run against RunPod
yet. The validation tests pass.
