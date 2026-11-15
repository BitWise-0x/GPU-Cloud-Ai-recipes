# RunPod recipes

GPU pods and serverless workers on [RunPod](https://www.runpod.io), with the
images built by you and the models baked in.

| Path | What |
|---|---|
| [`pod-kit/`](pod-kit/) | `pod.sh`: one CLI that runs any recipe in `pods/` (setup, start, status, tunnel, pause, stop), plus `build.sh` |
| [`pods/comfyui-upscale/`](pods/comfyui-upscale/) | ComfyUI for upscaling old video: per-frame models and SeedVR2 |
| [`pods/facefusion/`](pods/facefusion/) | FaceFusion 3.9.2 with its models baked |
| [`serverless/whisper/`](serverless/whisper/) | a scale-to-zero speech-to-text worker (faster-whisper large-v3) |
| [`serverless/deploy/`](serverless/deploy/) | `runpod_deploy.py`: template and endpoint from a JSON spec, digest pinning, test jobs |
| [`docs/`](docs/) | what decides placement, image layout, access, and how serverless behaves |

## Prerequisites

- A RunPod account with an API key and **your SSH public key in Settings >
  SSH Public Keys**. The pods are reachable only over SSH.
- Docker with buildx, and a registry (GHCR, Docker Hub). RunPod hosts are
  x86_64, so images build for `linux/amd64`.
- bash 4.4 or newer, `python3`, `curl`, `ssh`. macOS ships bash 3.2:
  `brew install bash`.
- Optional: `cloudflared` and a domain on Cloudflare for the Cloudflare Tunnel
  (`docs/access.md`).

## Secrets

`pod.sh` reads `runpod/.secrets.env` (gitignored), or the file named by
`RUNPOD_SECRETS_FILE`:

```bash
RUNPOD_API_KEY=...
# only for a private image: a read-only registry token
REGISTRY_USER=your-user
REGISTRY_TOKEN=...
```

`setup` stores the registry token in RunPod's registry auth once, and the
template refers to it by id. The API key reaches `curl` as a header file,
never as an argument a process listing would show.

## A pod session

```bash
cd runpod/pods/<recipe>
cp pod.env.example pod.env      # edit RUNPOD_IMAGE, GPU lists, ports
../../pod-kit/build.sh .        # build and push a new tag
../../pod-kit/pod.sh . setup    # registry auth + template (re-run after an image change)
../../pod-kit/pod.sh . start    # or: start <list>, e.g. start video
../../pod-kit/pod.sh . status
../../pod-kit/pod.sh . stop
```

What `start` does:

1. Walks the GPU list: a vCPU floor first (if set), preferred countries
   first, then everywhere (if fallback is on), and retries on capacity
   errors.
2. Watches the pod's system log during the image pull, and replaces a machine
   that never starts the container.
3. Opens the SSH tunnel, waits for the app to answer through it, and checks
   that only SSH is published.
4. Starts the tunnel watcher and, if configured, the pod's Cloudflare Tunnel.

Any `RUNPOD_*`, `CF_*`, `POD_*` or `REGISTRY_*` value, and any variable under
the recipe's `POD_ENV_PREFIX` (e.g. `COMFYUI_*`), can be overridden for one run
inline:

```bash
RUNPOD_GPU_TYPES="NVIDIA L40S|NVIDIA L40" ../../pod-kit/pod.sh . start
RUNPOD_MIN_VCPU_PER_GPU= ../../pod-kit/pod.sh . start video
RUNPOD_CLOUD_TYPE=COMMUNITY ../../pod-kit/pod.sh . start
```

A pod bills until you stop it. The kit never stops one for you.

## A new recipe

A recipe is a directory with a `Dockerfile`, a `start.sh` and a
`pod.env.example`. For it to work with `pod.sh`, the image has to:

- run sshd with key auth from `PUBLIC_KEY`, and refuse to start without a key;
- have its app listen on `127.0.0.1:POD_APP_PORT` and answer `GET /` with 200
  or 302 once ready;
- optionally write one line about itself to `/workspace/.pod-banner`, which
  `start` shows;
- optionally include `cloudflared`, for the Cloudflare Tunnel.

The two pod recipes show all of it.

## Tests

```bash
for t in pod-kit/tests/test_*.sh; do bash "$t"; done
python3 -m unittest discover -s serverless/whisper/tests
```

The pod-kit tests run the real `pod.sh` functions against scripted API answers.
They never call RunPod.
