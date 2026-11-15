# RunPod serverless: how endpoints behave

What to know before putting a GPU worker on a RunPod serverless endpoint. The
worker in `serverless/whisper/` and the script in `serverless/deploy/` follow
these rules. Everything here uses the management API v2
(`https://api.runpod.io/v2`, OpenAPI at `/v2/openapi.json`).

## Pod or serverless

| | Pod (`pods/`) | Serverless (`serverless/`) |
|---|---|---|
| Billing | per second while the pod runs, idle or not | per second while a worker runs, zero when scaled to zero |
| Shape | an interactive app you drive in a browser | an API: a job goes in, a result comes out |
| State | one container disk for the session | none between jobs; each job brings its inputs |
| Start | you start and stop it | RunPod starts workers on demand |

## Templates and endpoints

- **An endpoint keeps its own copy of the container settings** (`image`,
  `disk`, `registry`, `env`). The template is copied into the endpoint once,
  when the endpoint is created. Editing the template later never reaches the
  endpoint. To change what workers run, PATCH the endpoint
  (`/v2/serverless/{id}`).
- **A change to the container cuts a new endpoint release**, which rolls out
  as workers are replaced. Workers on the old release keep serving until then,
  and `GET /v2/serverless/{id}/workers` marks them `isStale`.
  `GET /v2/serverless/{id}/releases` lists releases with a field-level diff
  and how far the rollout has got. `workers`, `scaling` and `timeout` changes
  reach the autoscaler without a release.
- **Env values on an endpoint are its own copy too.** Change a value on the
  template and on the endpoint. To keep a secret out of plain env, use a RunPod
  secret and set the value to `{{ RUNPOD_SECRET_<name> }}`.

## Pin images by digest, not by tag

Pushing a new image under the same tag does not make RunPod pull it. RunPod
resolves the tag when it cuts a release, and a PATCH that sends the value
already stored changes nothing and cuts no release. After every push:

1. read the pushed digest (`docker/build-push-action` returns it as an output),
2. PATCH `image` to `<repo>@sha256:<digest>` on the template, then on the
   endpoint. The template stays a true record of what runs; the endpoint PATCH
   is what rolls the workers.
3. check that each response echoes the pinned image.

`runpod_deploy.py pin` does this, and `whisper/build-and-pin.example.yml` runs
it from CI. To check that a change is live, compare the endpoint's `image` with
the digest you pushed, and look for `isStale` on the worker that ran your test
job. A job sent right after a push often runs on a stale worker.

## GPU selection

- An endpoint's GPUs are **pools** (`gpu.pools`, the `pool` field of
  `GET /v2/catalog/gpus`, for example `ADA_24`), minus **excluded types**
  (`gpu.excludedTypes`, GPU type ids). There is no list of individual GPU
  types to allow.
- The pool order is the rent priority: with few workers, RunPod uses the first
  pool that has capacity. Order pools by current stock for your CUDA floor,
  not by price alone. RunPod honors up to three choices.
- **Send `pools` and `excludedTypes` together.** A PATCH that carries `pools`
  alone clears the exclusions.
- **CUDA: use `minCudaVersion`.** It is a floor: any host whose driver
  supports that version or newer qualifies. For an endpoint, a non-empty
  `allowedCudaVersions` without the floor matches hosts that report exactly
  those versions, which can starve the endpoint of workers. v2 refuses a PATCH
  that carries both a non-empty list and a floor. `runpod_deploy.py` sends the
  floor with an empty list.
- A torch wheel runs only on the compute capabilities it was built for. cu124
  wheels have no Blackwell (sm_120) kernels; cu128 and later do. Do not add a
  Blackwell pool to an endpoint whose image predates cu128. Those workers crash
  with `no kernel image is available` before your handler loads.

## Cold starts

A cold start is: a host is picked, the image is pulled and extracted, the
container starts, your handler imports and loads the model. With weights baked
in (`docs/images.md`), the pull is the cost that grows with image size.

- **FlashBoot** (`flashboot`) keeps a finished worker's container around for
  reuse. A follow-up job on the same machine starts in seconds. It does not
  help the first job after a quiet period, and RunPod does not document how
  long the warm window lasts.
- **`workers.min > 0` keeps workers running, and they bill.** It does not
  reserve GPU capacity: when the pool is out of stock, an "always warm" worker
  sits throttled and can block the scaler from starting workers for real jobs.
  For bursty traffic, `workers.min: 0` with the `REQUEST_COUNT` scaler is the
  predictable choice.
- **Idle workers in the dashboard are reserved slots, not running
  containers**, and they do not bill.
- **Cached Models** (the endpoint's "Model" field in the console) has RunPod
  pre-seed one Hugging Face repo on hosts and prefer those hosts for new
  workers. It is not in the REST API. A worker does not start until that
  transfer has landed, and a transfer that hangs leaves every new worker in
  `initializing` (the worker's log ends at `model pending download`), so a
  rollout can stall with no error anywhere. Baking the weights avoids that
  dependency.

## Inside the handler

- **Load the model at import**, not per job.
- **Validate input and return `{"error": ...}`** for a bad request. Raise only
  for real failures. RunPod marks a raised exception FAILED.
- **After a CUDA out-of-memory error, replace the worker**: return
  `"refresh_worker": True`. CUDA can stay broken after an out-of-memory error,
  and every later job on that worker fails the same way. Do not call
  `sys.exit()` from the handler: `SystemExit` is not an `Exception`, and the
  job may never be reported as failed.
- **Cancelling a job stops billing but does not stop your handler.**
  `POST /v2/{endpoint}/cancel/{job}` marks the job cancelled, but the handler
  runs to completion and the result is discarded. A long job that must
  actually stop has to check a cancel signal of its own (for example a flag
  your API sets, polled between steps) and raise.
- **Not every failure reaches your webhook.** A worker that dies before the
  handler loads (the image is refused at the prestart hook, or the model fails
  to load) sends no callback. If your app waits on webhooks, also poll
  `GET /v2/{endpoint}/status/{job}` for jobs that have gone quiet. A single
  404 from `/status` can also appear briefly while a job moves from queued to
  running, so do not treat one 404 as a terminal state.
- **Return a storage key or URL, not the bytes**, for anything large: upload
  the output to object storage from the worker and return its location.

## Limits worth knowing

- The total number of workers across all your endpoints is capped by your
  account's balance tier. RunPod refuses an endpoint update that would go over
  it.
- Rate limits are per account and shared by every caller using its keys. On
  HTTP 429, honor `Retry-After`.
- v2 errors are RFC 9457 problem objects (`title`, `status`, `detail`,
  `errors`). An unknown field in a request body is a 422 that names the field.
