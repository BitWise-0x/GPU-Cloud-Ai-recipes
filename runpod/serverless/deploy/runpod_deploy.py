#!/usr/bin/env python3
"""Create and update a RunPod serverless endpoint from a JSON spec.

    runpod_deploy.py apply  <spec.json>                      create or update the template + endpoint
    runpod_deploy.py pin    <spec.json> <repo@sha256:...>    point template and endpoint at an image digest
    runpod_deploy.py status <spec.json>                      image, latest release, workers
    runpod_deploy.py run    <spec.json> <input.json>         submit a job and wait for its result

RUNPOD_API_KEY comes from the environment. Standard library only. Uses the
management API v2 (https://api.runpod.io/v2) and the job API
(https://api.runpod.ai/v2/{endpoint_id}).

The spec (see whisper/endpoint.example.json):
  template.name, image, disk, registryName (a registry auth name, or null for a
    public image), env (plain values), envFromShell (names whose values are
    read from this shell at create time and never printed)
  endpoint.name, workers, scaling, timeout, flashboot, gpu
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional

API = "https://api.runpod.io/v2"
JOB_API = "https://api.runpod.ai/v2"
# endpoint fields `apply` owns on an existing endpoint; reach the autoscaler
# without a new release, except gpu, which cuts one
ENDPOINT_FIELDS = ("workers", "scaling", "timeout", "flashboot", "gpu")


class ApiError(RuntimeError):
    pass


def _api_key() -> str:
    key = os.environ.get("RUNPOD_API_KEY")
    if not key:
        sys.exit("error: RUNPOD_API_KEY is not set")
    return key


def request(method: str, url: str, body: Optional[Dict[str, Any]] = None) -> Any:
    """One API call. Retries 429 and 5xx with backoff, honoring Retry-After.
    Errors carry the problem detail (title, detail), never the request body,
    which can hold env secrets."""
    data = json.dumps(body).encode() if body is not None else None
    delay = 2.0
    for attempt in range(6):
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {_api_key()}",
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                text = resp.read().decode()
                return json.loads(text) if text else None
        except urllib.error.HTTPError as exc:
            text = exc.read().decode(errors="replace")
            if (exc.code == 429 or exc.code >= 500) and attempt < 5:
                wait = float(exc.headers.get("Retry-After") or delay)
                print(f"  {method} {urllib.parse.urlparse(url).path}: HTTP {exc.code}, retrying in {wait:.0f}s", file=sys.stderr)
                time.sleep(wait)
                delay *= 2
                continue
            raise ApiError(f"{method} {urllib.parse.urlparse(url).path} -> HTTP {exc.code}: {_problem(text)}") from None
        except urllib.error.URLError as exc:
            if attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise ApiError(f"{method} {url}: {exc.reason}") from None
    raise ApiError(f"{method} {url}: gave up after retries")


def _problem(text: str) -> str:
    try:
        d = json.loads(text)
    except ValueError:
        return text[:300]
    if not isinstance(d, dict):
        return text[:300]
    parts = [str(d[k]) for k in ("title", "detail") if d.get(k)]
    parts += [str(e) for e in d.get("errors") or []]
    return ": ".join(parts) or text[:300]


def list_all(path: str, key: str) -> List[Dict[str, Any]]:
    """Every item of a v2 list, following pagination.nextCursor."""
    items: List[Dict[str, Any]] = []
    cursor = None
    while True:
        url = f"{API}{path}" + (f"?cursor={urllib.parse.quote(cursor)}" if cursor else "")
        page = request("GET", url) or {}
        items.extend(page.get(key) or [])
        pagination = page.get("pagination") or {}
        if not pagination.get("hasNextPage"):
            return items
        cursor = pagination.get("nextCursor")


def find_by_name(path: str, key: str, name: str) -> Optional[str]:
    return next((it["id"] for it in list_all(path, key) if it.get("name") == name), None)


def load_spec(path: str) -> Dict[str, Any]:
    with open(path) as fh:
        spec = json.load(fh)
    for section, fields in (("template", ("name", "image", "disk")), ("endpoint", ("name", "workers", "gpu"))):
        missing = [f for f in fields if f not in spec.get(section, {})]
        if missing:
            sys.exit(f"error: {path}: {section} is missing {', '.join(missing)}")
    gpu = spec["endpoint"]["gpu"]
    if gpu.get("allowedCudaVersions") and gpu.get("minCudaVersion"):
        sys.exit("error: gpu has both allowedCudaVersions and minCudaVersion; v2 refuses that pair. "
                 "Keep minCudaVersion (a floor); the list alone is an exact host match.")
    return spec


def endpoint_id(spec: Dict[str, Any]) -> str:
    eid = find_by_name("/serverless", "endpoints", spec["endpoint"]["name"])
    if not eid:
        sys.exit(f"error: no endpoint named {spec['endpoint']['name']!r}; run apply first")
    return eid


def _gpu_body(gpu: Dict[str, Any]) -> Dict[str, Any]:
    # pools and excludedTypes always go together: a PATCH with pools alone
    # clears the exclusions
    body = {"count": gpu.get("count", 1), "pools": gpu["pools"], "excludedTypes": gpu.get("excludedTypes", [])}
    if gpu.get("minCudaVersion"):
        body.update({"minCudaVersion": gpu["minCudaVersion"], "allowedCudaVersions": []})
    else:
        body["allowedCudaVersions"] = gpu.get("allowedCudaVersions", [])
    return body


def cmd_apply(spec: Dict[str, Any]) -> None:
    t, e = spec["template"], spec["endpoint"]

    tpl_id = find_by_name("/templates", "templates", t["name"])
    if tpl_id:
        print(f"template {t['name']} exists ({tpl_id}); its env is left as it is")
    else:
        missing = [k for k in t.get("envFromShell", []) if not os.environ.get(k)]
        if missing:
            sys.exit(f"error: set these in the shell for the template env: {', '.join(missing)}")
        env = dict(t.get("env", {}))
        env.update({k: os.environ[k] for k in t.get("envFromShell", [])})
        registry = None
        if t.get("registryName"):
            registry = find_by_name("/registries", "registries", t["registryName"])
            if not registry:
                sys.exit(f"error: no registry auth named {t['registryName']!r} (GET /v2/registries)")
        created = request("POST", f"{API}/templates", {
            "name": t["name"], "image": t["image"], "disk": t["disk"], "env": env,
            "registry": registry, "ports": [], "serverless": True, "category": "NVIDIA",
        })
        tpl_id = created["id"]
        print(f"created template {t['name']} ({tpl_id})")

    eid = find_by_name("/serverless", "endpoints", e["name"])
    desired = {k: e[k] for k in ENDPOINT_FIELDS if k in e}
    desired["gpu"] = _gpu_body(e["gpu"])
    if eid:
        request("PATCH", f"{API}/serverless/{eid}", desired)
        print(f"updated endpoint {e['name']} ({eid}): {', '.join(desired)}")
    else:
        created = request("POST", f"{API}/serverless", {"name": e["name"], "type": "QUEUE", "templateId": tpl_id, **desired})
        eid = created["id"]
        print(f"created endpoint {e['name']} ({eid})")
    print(f"job URL: {JOB_API}/{eid}/run")


def cmd_pin(spec: Dict[str, Any], image: str) -> None:
    """Point the template and the endpoint at an image digest. The endpoint
    holds its own copy of the image (a template is copied into an endpoint once,
    at create), so the endpoint PATCH is what rolls workers; the template is set
    first so it stays a true record of what runs. A tag would not do: PATCHing
    the same tag again is no change, so RunPod cuts no release and keeps
    running whatever that tag resolved to before."""
    if "@sha256:" not in image:
        sys.exit("error: pin takes repo@sha256:<digest>, not a tag")
    tpl_id = find_by_name("/templates", "templates", spec["template"]["name"])
    if not tpl_id:
        sys.exit("error: no template; run apply first")
    eid = endpoint_id(spec)
    for path in (f"/templates/{tpl_id}", f"/serverless/{eid}"):
        resp = request("PATCH", f"{API}{path}", {"image": image})
        if (resp or {}).get("image") != image:
            raise ApiError(f"PATCH {path} did not echo the pinned image")
        print(f"pinned {path} -> {image}")
    _print_latest_release(eid)


def _print_latest_release(eid: str) -> None:
    rel = request("GET", f"{API}/serverless/{eid}/releases?limit=1") or {}
    latest = (rel.get("releases") or [{}])[0]
    print(json.dumps({"rollout": rel.get("rollout"), "latest": {k: latest.get(k) for k in ("version", "createdAt", "diff")}}, indent=2))


def cmd_status(spec: Dict[str, Any]) -> None:
    eid = endpoint_id(spec)
    ep = request("GET", f"{API}/serverless/{eid}") or {}
    print(f"endpoint {ep.get('name')} ({eid})")
    print(f"  image    {ep.get('image')}")
    print(f"  workers  {ep.get('workers')}")
    _print_latest_release(eid)
    workers = request("GET", f"{API}/serverless/{eid}/workers") or {}
    for w in workers.get("workers") or []:
        print(f"  worker {w.get('id')} v{w.get('version')} stale={w.get('isStale')} {w.get('status', '')}")


def cmd_run(spec: Dict[str, Any], input_path: str) -> None:
    with open(input_path) as fh:
        payload = json.load(fh)
    if "input" not in payload:
        payload = {"input": payload}
    eid = endpoint_id(spec)
    job = request("POST", f"{JOB_API}/{eid}/run", payload)
    job_id = job["id"]
    print(f"job {job_id} submitted; a cold worker pulls the image first")
    t0 = time.monotonic()
    while True:
        st = request("GET", f"{JOB_API}/{eid}/status/{job_id}") or {}
        status = st.get("status")
        if status in ("COMPLETED", "FAILED", "CANCELLED", "TIMED_OUT"):
            print(f"{status} after {time.monotonic() - t0:.0f}s")
            print(json.dumps(st.get("output") if status == "COMPLETED" else st, indent=2))
            if status != "COMPLETED":
                sys.exit(1)
            return
        print(f"  {time.monotonic() - t0:4.0f}s {status}", end="\r", flush=True)
        time.sleep(3)


def main(argv: List[str]) -> None:
    if len(argv) < 3 or argv[1] not in ("apply", "pin", "status", "run"):
        sys.exit(__doc__)
    cmd, spec = argv[1], load_spec(argv[2])
    try:
        if cmd == "apply":
            cmd_apply(spec)
        elif cmd == "status":
            cmd_status(spec)
        elif len(argv) < 4:
            sys.exit(__doc__)
        elif cmd == "pin":
            cmd_pin(spec, argv[3])
        else:
            cmd_run(spec, argv[3])
    except ApiError as exc:
        sys.exit(f"error: {exc}")


if __name__ == "__main__":
    main(sys.argv)
