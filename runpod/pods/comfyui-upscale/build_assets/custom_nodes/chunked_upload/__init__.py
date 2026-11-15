# Resumable chunked uploads (upload_routes.py, web/chunked_upload.js).
import os
from typing import Optional, Tuple

import folder_paths
from server import PromptServer

from .upload_routes import create_routes

WEB_DIRECTORY = './web'
NODE_CLASS_MAPPINGS = {}


def get_parts_directory() -> str:
    # in ComfyUI's user directory, which git ignores, not in input/, so a node that lists its
    # files never sees a part
    return os.path.join(folder_paths.get_user_directory(), '.upload_parts')


def resolve_directory(upload_type: Optional[str]) -> Tuple[Optional[str], str]:
    # ComfyUI's get_dir_by_type: input unless the upload names temp or output
    upload_type = upload_type or 'input'
    return folder_paths.get_directory_by_type(upload_type), upload_type


# PromptServer adds every route here under /api too, where the frontend sends its uploads
for route in create_routes(get_parts_directory, resolve_directory):
    PromptServer.instance.routes.route(route.method, route.path)(route.handler)
