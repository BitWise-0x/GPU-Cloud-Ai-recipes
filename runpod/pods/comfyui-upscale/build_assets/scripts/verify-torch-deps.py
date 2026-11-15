#!/usr/bin/env python3
"""Build-time guard for the Dockerfile's torch CUDA-layer split.

The CUDA wheels (nvidia-*, cuda-toolkit, cuda-bindings) and triton install in
their own RUN layers before torch, so torch's layer holds only its own .so
files. That holds only while every CUDA dep torch declares is already satisfied;
otherwise torch pulls a second copy into its layer.

torch 2.14+ declares most CUDA libs through `cuda-toolkit[<extras>]==X`, whose
extras pin the nvidia-* wheels, so this walks torch's Requires-Dist and those
extras, checks each specifier against the installed version, then imports torch.
It checks only torch's CUDA deps: `pip check` also fails on base-image packages
outside this build's control (pygobject missing pycairo). `packaging` comes from
pip's vendored copy.

Exits non-zero, failing the build, on any mismatch or import failure.
"""
import importlib.metadata as md
import sys

from pip._vendor.packaging.requirements import Requirement

CUDA_PREFIXES = ("nvidia-", "triton", "cuda-")


def deps_of(dist, extras=()):
    """`dist`'s Requires-Dist entries whose markers match one of `extras`."""
    out = []
    for raw in md.metadata(dist).get_all("Requires-Dist") or []:
        req = Requirement(raw)
        envs = [{"extra": e} for e in extras] or [{"extra": ""}]
        if req.marker is None or any(req.marker.evaluate(env) for env in envs):
            out.append(req)
    return out


mismatches = []
checked = 0
queue = [r for r in deps_of("torch") if r.name.lower().startswith(CUDA_PREFIXES)]
seen = set()
while queue:
    req = queue.pop()
    key = (req.name.lower(), str(req.specifier), tuple(sorted(req.extras)))
    if key in seen:
        continue
    seen.add(key)
    try:
        have = md.version(req.name)
    except md.PackageNotFoundError:
        mismatches.append(f"{req}: NOT INSTALLED")
        continue
    checked += 1
    if not req.specifier.contains(have, prereleases=True):
        mismatches.append(f"{req}: installed {have}")
    if req.extras:
        queue += [r for r in deps_of(req.name, req.extras)
                  if r.name.lower().startswith(CUDA_PREFIXES)]

if mismatches:
    print("TORCH CUDA-DEP MISMATCH (duplicate wheel / layer split defeated):",
          file=sys.stderr)
    for line in mismatches:
        print("  -", line, file=sys.stderr)
    print("Re-derive the versions from the torch wheel METADATA after a torch bump.",
          file=sys.stderr)
    sys.exit(1)

import torch  # noqa: E402  (after the cheap metadata check)
print(f"torch CUDA deps OK: {checked} requirements satisfied single-copy; "
      f"torch {torch.__version__} imports OK")
