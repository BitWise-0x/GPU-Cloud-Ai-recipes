# FaceFusion pod

[FaceFusion](https://github.com/facefusion/facefusion) 3.9.2, upstream and
unmodified, on a RunPod GPU pod. The Gradio UI is reached through the SSH
tunnel or a Cloudflare Tunnel. The face models are baked into the image, so
the first job starts without downloads.

FaceFusion is a face swapper. Use it only on faces you have consent to use,
and follow FaceFusion's OpenRAIL-AS license, whose use restrictions apply to
your image. Upstream's content analyser stays on, and its models are baked in
with the rest.

## What is in the image

| | |
|---|---|
| FaceFusion | 3.9.2, cloned at the tag |
| onnxruntime-gpu | 1.31.0 (CUDA 13), no torch |
| Models (baked) | face swappers (hyperswap 1a/1b/1c, simswap 512, inswapper 128), detectors (yoloface, retinaface, scrfd), landmarker, recognizer, occluder and parser masks, enhancers (gfpgan, gpen 2048, codeformer), the support models every run loads, and the content analyser |
| FFmpeg | 8.1 with NVENC (Ubuntu 22.04's 4.4 is too old for FaceFusion 3.9) |
| sshd, cloudflared | access (`docs/access.md`) |

Model licenses vary, and several face swappers are non-commercial. The
recipe downloads them into your own image: check each model's terms, and keep
the image private.

## Run it

```bash
cd runpod/pods/facefusion
cp pod.env.example pod.env          # set RUNPOD_IMAGE to your registry
../../pod-kit/build.sh .
../../pod-kit/pod.sh . setup
../../pod-kit/pod.sh . start photo  # stills: cheapest card first
../../pod-kit/pod.sh . start video  # video: NVENC cards, 24+ vCPUs per GPU
# open http://127.0.0.1:17860
../../pod-kit/pod.sh . stop
```

Outputs go to `/workspace/output`. Copy them off with `scp` (`pod.sh . status`
prints the command) before you stop the pod.

## Photo and video lists

A still is one frame: no encode, little CPU work. The cheapest card with
enough VRAM wins. A video job decodes, processes and encodes every frame:

- Face detection, masks and paste-back run on the CPU, so on a host with few
  vCPUs the GPU waits. `start video` asks for 24 vCPUs per GPU first
  (`docs/gpu-selection.md`).
- On an NVENC card the encode runs on the GPU and leaves the cores to the face
  work. `start.sh` makes `h264_nvenc` the UI's default encoder when the GPU has
  one. A100 and H100 have no NVENC, so they come last in the video list.

## Uploads

Upstream's Gradio UI sends each upload as one request. Through the SSH tunnel
that works at any size, but a dropped tunnel restarts it. Through Cloudflare a
request over 100 MB is refused. For large videos, copy them in with scp and
use the path:

```bash
scp -P <port> clip.mp4 root@<host>:/workspace/
```

## Tuning for hard video

Starting points to try on the worst frames with `face_debugger` on (not
measured results):

| Problem | Try |
|---|---|
| Side profiles, detection drops out | `--face-detector-model many`, `--face-detector-score 0.35`, `--face-tracker-score 0.25` |
| Hands, hair, glasses or a mic over the face | `--face-mask-types box occlusion` |
| Swap bleeds into hair or background | add `region` to the mask types; raise `--face-mask-padding` |
| Visible seam at the edge | `--face-mask-blur 0.4` to `0.5` |
| Flicker or identity jumping between frames | `--face-tracker-score 0.2` to `0.3` |
| Wrong person swapped | `--face-selector-mode reference`, a clear frontal reference frame, lower `--reference-face-distance` |
| Soft swap on a close face | `--face-swapper-pixel-boost 512x512` or higher |
| Restored face looks plastic | lower `--face-enhancer-blend` to 50 to 60 |

`face_detector_angles` rotates the frame in-plane: it finds tilted or
upside-down heads, not profiles.

Source photos: 3 to 8 sharp, well-lit photos of the same person, frontal to
three-quarter view, nothing over the face, with some variety in light and
expression. Leave out profiles, blurred shots and beauty filters.

## Status

Built from a pod setup in regular use. This copy has not been built yet.
Check the first build and a first photo and video job before relying on it.
