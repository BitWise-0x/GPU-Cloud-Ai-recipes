# ComfyUI video upscale pod

ComfyUI on a RunPod GPU pod, set up for upscaling old, low-resolution video:
camcorder and VHS captures, DVD rips, small web video. Two workflows are baked
in:

| Workflow | What it does | Speed |
|---|---|---|
| `upscale-video-fast` | per-frame upscale model (SPAN, RealPLKSR, Real-ESRGAN), optional H.264 clean-up pass, resize to the output height | fast; whole films are fine |
| `upscale-video-seedvr2` | SeedVR2 diffusion restore: redraws detail with temporal consistency | slow; for short clips and the shots that matter |

Both take a video, process it in chunks of frames (VideoHelperSuite's Meta
Batch Manager, so a film never sits in RAM at once) and encode with the source
audio. The encode uses `h264_nvenc` when the GPU has an encoder and falls back
to `libx264` when it does not. `start.sh` picks one at boot and writes the
`auto-h264-mp4` format the workflows use.

## What is in the image

| | |
|---|---|
| ComfyUI | v0.45.2, upstream, core nodes only plus VideoHelperSuite 1.7.9 |
| torch | 2.14.1 + CUDA 13.0 (cu130), Python 3.12 |
| Upscale models (baked, sha256-checked) | 2xLiveActionV1_SPAN, 2xVHS2HD-RealPLKSR, 1xDeH264_realplksr, RealESRGAN x2plus / x4plus, realesr-general-x4v3, RIFE 4.26 (frame interpolation) |
| SeedVR2 | downloaded at boot (3B fp16 by default, sha256-checked), `COMFYUI_SEEDVR2_MODEL` picks another or `none` |
| FFmpeg | 8.1 with NVENC, for VideoHelperSuite |
| `chunked_upload` node | browser uploads go in resumable chunks: they survive a dropped tunnel and stay under Cloudflare's 100 MB request cap |
| `connection_events.py` | shows the SSH tunnel's drops and reconnects in ComfyUI's Logs panel |
| sshd, cloudflared | access (`docs/access.md`) |

The upscale models carry their own licenses, listed in the Dockerfile. Some
(SPAN, VHS2HD) are non-commercial or share-alike.

## Run it

```bash
cd runpod/pods/comfyui-upscale
cp pod.env.example pod.env          # set RUNPOD_IMAGE to your registry
../../pod-kit/build.sh .            # build for linux/amd64 and push
../../pod-kit/pod.sh . setup        # registry auth + RunPod template
../../pod-kit/pod.sh . start        # allocate, wait, open the tunnel
# open http://127.0.0.1:18188, load a workflow from the Workflows panel,
# upload a clip, queue it
../../pod-kit/pod.sh . stop         # billing stops
```

Outputs land in `/workspace/ComfyUI/output/` as `upscaled-*-audio.mp4`.
Download them from the UI's queue, or with `scp` (`pod.sh . status` prints
the command), before you stop the pod.

## Tips

- Interlaced sources (480i/576i, combing on motion) need deinterlacing first:
  `ffmpeg -i in.mkv -vf bwdif -c:v libx264 -crf 14 -c:a copy out.mp4`.
- Output quality: crf 16 to 20 with libx264 looks the same as the source to
  most eyes. On NVENC use cq about crf + 6 (the workflows default to cq 24,
  about crf 18).
- SeedVR2 7B or 2160p output needs an 80 GB card. Set
  `COMFYUI_SEEDVR2_MODEL=seedvr2_7b_fp16.safetensors`, run `setup`, point the
  workflow's model loader at it, and start on an 80 GB list (see the comment
  in `pod.env.example`).
- `frames_per_batch` in the SeedVR2 workflow is how many frames the model sees
  at once. Larger runs smoother across cuts but needs more RAM. Keep it 4n+1
  (81, 97, 121).

## Status

Built from a pod setup in regular use. This upstream-only copy has not been
built yet. Check the first build and the first run of each workflow before
relying on it.
