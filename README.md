# GPU Cloud Recipes

Working setups for running GPU workloads on rented cloud GPUs: Dockerfiles that
bake the models in, scripts that place, reach and tear down the machines, and
notes on what the providers' docs leave out.

| Provider | Recipes |
|---|---|
| [RunPod](runpod/) | ComfyUI video upscaling pod, FaceFusion pod, a Whisper serverless worker, the pod CLI and the serverless deploy script |

The repo has Dockerfiles only, no built images. You build each image into your
own registry, which keeps model licenses and image contents under your control.

## What the recipes have in common

- **Models baked into the image**, pinned and checksummed, so a cold start pays
  for the image pull and never for a download inside billed time.
- **Nothing exposed by default.** Pods publish SSH only; apps listen on
  loopback and are reached through an SSH tunnel or a Cloudflare Tunnel with
  Access in front.
- **Placement that copes with the market.** Ordered GPU lists, CPU floors,
  CUDA filters, country fallback, and machines that never start are detected
  and replaced.
- **Broken images fail the build**, not a billed GPU: each image checks its own
  CUDA stack at build time and again at start.

## Layout

```
runpod/
  pod-kit/        pod.sh (setup/start/status/tunnel/pause/stop), build.sh, tests
  pods/           comfyui-upscale, facefusion
  serverless/     whisper worker, deploy script
  docs/           GPU selection, images, access, serverless
```

## License

MIT for the code in this repo (see [LICENSE](LICENSE)). The software and model
weights the Dockerfiles download keep their own licenses, and some are
non-commercial. Check them before you use an image beyond personal use.
