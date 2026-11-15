# Resumable chunked uploads for ComfyUI, the server half of web/chunked_upload.js.
#
# ComfyUI takes an upload as one multipart POST to /upload/image. Through the SSH
# tunnel a large video takes minutes and a dropped tunnel restarts it from zero;
# through Cloudflare a request over 100 MB is refused. The browser sends every
# upload here instead, in chunks, resumed from the server's offset after a drop,
# then commits the finished file into ComfyUI's input, temp or output directory
# with ComfyUI's own naming, and answers what /upload/image answers.
import asyncio
import filecmp
import glob
import json
import os
import re
import shutil
from typing import Any, AsyncIterator, Callable, Dict, List, Optional, Tuple

from aiohttp import ClientConnectionError, ClientPayloadError, web

UPLOAD_KEY_PATTERN = re.compile('^[0-9a-f]{8,64}$')
INVALID_FILE_NAME_PATTERN = re.compile(r'[\x00-\x1f<>:"/\\|?*]')
# keep this much disk free so a large upload cannot starve a running job of disk
DISK_RESERVE_SIZE = 2 * 1024 ** 3
UPLOAD_LOCKS: Dict[str, asyncio.Lock] = {}
# a chunk that sends nothing for this long is abandoned: a tunnel that died mid-chunk can leave
# its request open on the server, holding the upload's lock against every retry
CHUNK_IDLE_TIMEOUT = 60.0
# an aborted chunk lets go of the upload's lock within moments; a discard waits that long
DISCARD_LOCK_TIMEOUT = 5.0
READ_SIZE = 1024 * 1024

# (type) -> (directory, type), ComfyUI's get_dir_by_type
ResolveDirectory = Callable[[Optional[str]], Tuple[Optional[str], str]]


def get_part_path(parts_directory: str, upload_key: str) -> str:
    return os.path.join(parts_directory, upload_key)


def get_meta_path(parts_directory: str, upload_key: str) -> str:
    return get_part_path(parts_directory, upload_key) + '.json'


def get_done_path(parts_directory: str, upload_key: str) -> str:
    # a committed upload leaves a marker naming its file, so the same file dropped again,
    # even after ComfyUI restarted, is committed without sending it twice
    return get_part_path(parts_directory, upload_key) + '.done'


def get_part_size(parts_directory: str, upload_key: str) -> int:
    part_path = get_part_path(parts_directory, upload_key)
    return os.path.getsize(part_path) if os.path.isfile(part_path) else 0


def sanitize_file_name(name: str) -> Optional[str]:
    file_name = INVALID_FILE_NAME_PATTERN.sub('', os.path.basename(name.replace('\\', '/'))).strip()

    if file_name and not file_name.startswith('.'):
        return file_name
    return None


def write_part_meta(parts_directory: str, upload_key: str, file_name: str, file_size: int) -> None:
    # the name and size of an upload in progress, so a reloaded page can list what is
    # unfinished and offer to discard it
    os.makedirs(parts_directory, exist_ok=True)
    with open(get_meta_path(parts_directory, upload_key), 'w') as meta_file:
        json.dump({ 'name': file_name, 'size': file_size }, meta_file)


def list_partial_uploads(parts_directory: str) -> List[Dict[str, Any]]:
    partial_uploads = []

    for meta_path in glob.glob(os.path.join(parts_directory, '*.json')):
        upload_key = os.path.basename(meta_path)[:-len('.json')]
        try:
            with open(meta_path) as meta_file:
                meta = json.load(meta_file)
        except (OSError, ValueError):
            continue
        partial_uploads.append({ 'key': upload_key, 'name': meta.get('name'), 'size': meta.get('size'), 'received': get_part_size(parts_directory, upload_key) })
    return partial_uploads


def remove_partial_upload(parts_directory: str, upload_key: str) -> None:
    for path in (get_part_path(parts_directory, upload_key), get_meta_path(parts_directory, upload_key)):
        if os.path.isfile(path):
            os.remove(path)


def get_completed_path(parts_directory: str, upload_key: str) -> Optional[str]:
    done_path = get_done_path(parts_directory, upload_key)

    if os.path.isfile(done_path):
        with open(done_path) as done_file:
            completed_path = done_file.read()
        if os.path.isfile(completed_path):
            return completed_path
    return None


def is_complete(parts_directory: str, upload_key: str, size: int) -> bool:
    return get_completed_path(parts_directory, upload_key) is not None or os.path.isfile(get_part_path(parts_directory, upload_key)) and get_part_size(parts_directory, upload_key) == size


def resolve_commit_path(source_path: str, directory: str, file_name: str, overwrite: bool) -> Tuple[str, bool]:
    # ComfyUI's naming: overwrite takes the name as it is; otherwise a file with the same
    # name and the same bytes is the same upload (kept, not written twice) and a different
    # one gets "name (1).ext", "name (2).ext". Returns the path and whether it already holds
    # these bytes
    file_path = os.path.join(directory, file_name)
    base_name, extension = os.path.splitext(file_name)
    index = 1

    if overwrite:
        return file_path, os.path.exists(file_path) and os.path.abspath(file_path) == os.path.abspath(source_path)
    while os.path.exists(file_path):
        if filecmp.cmp(source_path, file_path, shallow=False):
            return file_path, True
        file_path = os.path.join(directory, base_name + ' (' + str(index) + ')' + extension)
        index += 1
    return file_path, False


def commit_upload(parts_directory: str, upload_key: str, file_name: str, directory: str, overwrite: bool) -> str:
    # the finished part moves into place; a file committed before is linked (or copied) from
    # where it went, so the same bytes are never sent twice
    part_path = get_part_path(parts_directory, upload_key)
    completed_path = get_completed_path(parts_directory, upload_key)
    source_path = part_path if os.path.isfile(part_path) else completed_path
    file_path, is_present = resolve_commit_path(source_path, directory, file_name, overwrite)

    os.makedirs(directory, exist_ok=True)
    if source_path == part_path:
        if is_present:
            os.remove(part_path)
        else:
            os.replace(part_path, file_path)
    elif not is_present:
        temp_path = file_path + '.part'
        try:
            os.link(source_path, temp_path)
        except OSError:
            shutil.copyfile(source_path, temp_path)
        os.replace(temp_path, file_path)
    meta_path = get_meta_path(parts_directory, upload_key)
    if os.path.isfile(meta_path):
        os.remove(meta_path)
    with open(get_done_path(parts_directory, upload_key), 'w') as done_file:
        done_file.write(file_path)
    return file_path


async def iterate_with_idle_timeout(stream: AsyncIterator[bytes], idle_timeout: float) -> AsyncIterator[bytes]:
    iterator = stream.__aiter__()

    while True:
        try:
            data = await asyncio.wait_for(iterator.__anext__(), idle_timeout)
        except StopAsyncIteration:
            return
        yield data


def create_routes(get_parts_directory: Callable[[], str], resolve_directory: ResolveDirectory) -> web.RouteTableDef:
    routes = web.RouteTableDef()

    def validate(upload_key: str, name: str, size: str) -> Tuple[Optional[str], int]:
        try:
            file_size = int(size)
        except ValueError:
            return None, -1
        if not UPLOAD_KEY_PATTERN.match(upload_key) or file_size < 0:
            return None, -1
        return sanitize_file_name(name), file_size

    @routes.get('/media_library/upload/{upload_key}')
    async def get_upload(request: web.Request) -> web.Response:
        parts_directory = get_parts_directory()
        upload_key = request.match_info['upload_key']
        file_name, size = validate(upload_key, request.query.get('name', ''), request.query.get('size', ''))

        if not file_name:
            return web.json_response({ 'error': 'invalid upload' }, status=400)
        if is_complete(parts_directory, upload_key, size):
            return web.json_response({ 'done': True })
        os.makedirs(parts_directory, exist_ok=True)
        offset = get_part_size(parts_directory, upload_key)

        if size - offset > shutil.disk_usage(parts_directory).free - DISK_RESERVE_SIZE:
            return web.json_response({ 'error': 'not enough disk space on the server for ' + file_name }, status=507)
        write_part_meta(parts_directory, upload_key, file_name, size)
        return web.json_response({ 'offset': offset })

    @routes.get('/media_library/partials')
    async def get_partials(request: web.Request) -> web.Response:
        return web.json_response({ 'partials': list_partial_uploads(get_parts_directory()) })

    # discarding an upload the browser cancelled, or one a reload left unfinished; the chunk
    # the browser just aborted holds the lock for a moment, so the discard waits for it
    @routes.delete('/media_library/upload/{upload_key}')
    async def delete_upload(request: web.Request) -> web.Response:
        upload_key = request.match_info['upload_key']

        if not UPLOAD_KEY_PATTERN.match(upload_key):
            return web.json_response({ 'error': 'invalid upload' }, status=400)
        upload_lock = UPLOAD_LOCKS.setdefault(upload_key, asyncio.Lock())

        try:
            await asyncio.wait_for(upload_lock.acquire(), DISCARD_LOCK_TIMEOUT)
        except asyncio.TimeoutError:
            return web.json_response({ 'error': 'a chunk of this upload is still arriving' }, status=409)
        try:
            remove_partial_upload(get_parts_directory(), upload_key)
        finally:
            upload_lock.release()
        return web.json_response({})

    @routes.put('/media_library/upload/{upload_key}')
    async def put_upload(request: web.Request) -> web.Response:
        parts_directory = get_parts_directory()
        upload_key = request.match_info['upload_key']
        file_name, size = validate(upload_key, request.query.get('name', ''), request.query.get('size', ''))

        if not file_name or not request.query.get('offset', '').isdigit():
            return web.json_response({ 'error': 'invalid upload' }, status=400)
        offset = int(request.query.get('offset'))

        if is_complete(parts_directory, upload_key, size):
            return web.json_response({ 'done': True })
        upload_lock = UPLOAD_LOCKS.setdefault(upload_key, asyncio.Lock())

        # a second tab sending the same file would interleave its chunks into the part file;
        # it backs off and retries instead
        if upload_lock.locked():
            return web.json_response({ 'offset': get_part_size(parts_directory, upload_key) }, status=429)
        async with upload_lock:
            part_path = get_part_path(parts_directory, upload_key)
            os.makedirs(parts_directory, exist_ok=True)
            current_offset = get_part_size(parts_directory, upload_key)

            if offset != current_offset:
                return web.json_response({ 'offset': current_offset }, status=409)
            # bytes are appended as they arrive, so a chunk cut off by a dropped tunnel still
            # keeps what reached the server and the client resumes from there
            with open(part_path, 'ab') as part_file:
                try:
                    async for data in iterate_with_idle_timeout(request.content.iter_chunked(READ_SIZE), CHUNK_IDLE_TIMEOUT):
                        if part_file.tell() + len(data) > size:
                            part_file.truncate(current_offset)
                            return web.json_response({ 'error': 'chunk exceeds the declared size' }, status=400)
                        part_file.write(data)
                except (ClientConnectionError, ClientPayloadError, ConnectionResetError):
                    return web.json_response({ 'offset': part_file.tell() }, status=499)
                except asyncio.TimeoutError:
                    return web.json_response({ 'offset': part_file.tell() }, status=408)
            current_offset = get_part_size(parts_directory, upload_key)

            if current_offset == size:
                return web.json_response({ 'done': True })
            return web.json_response({ 'offset': current_offset })

    # a finished upload goes where /upload/image would have put it, and the answer is the one
    # /upload/image gives, so the node that asked for the file takes it as its own upload
    @routes.post('/media_library/commit/{upload_key}')
    async def commit(request: web.Request) -> web.Response:
        parts_directory = get_parts_directory()
        upload_key = request.match_info['upload_key']
        file_name, size = validate(upload_key, request.query.get('name', ''), request.query.get('size', ''))
        post = await request.post()
        subfolder = str(post.get('subfolder') or '')
        overwrite = str(post.get('overwrite') or '') in ('true', '1')
        upload_directory, upload_type = resolve_directory(str(post.get('type') or '') or None)

        if not file_name or not upload_directory:
            return web.json_response({ 'error': 'invalid upload' }, status=400)
        upload_directory = os.path.abspath(upload_directory)
        directory = os.path.abspath(os.path.join(upload_directory, os.path.normpath(subfolder)))

        if os.path.commonpath((upload_directory, directory)) != upload_directory:
            return web.json_response({ 'error': 'invalid subfolder' }, status=400)
        if not is_complete(parts_directory, upload_key, size):
            return web.json_response({ 'offset': get_part_size(parts_directory, upload_key) }, status=409)
        upload_lock = UPLOAD_LOCKS.setdefault(upload_key, asyncio.Lock())

        async with upload_lock:
            file_path = await asyncio.to_thread(commit_upload, parts_directory, upload_key, file_name, directory, overwrite)
        UPLOAD_LOCKS.pop(upload_key, None)
        return web.json_response({ 'name': os.path.basename(file_path), 'subfolder': subfolder, 'type': upload_type })

    return routes
