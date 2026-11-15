# Shows the SSH tunnel's drops and reconnects in ComfyUI's Logs panel.
#
# The pod is reached only through an SSH tunnel that pod-kit/pod.sh keeps up
# from the machine running the browser. Its watcher rewrites this file with
# every drop and reconnect; new lines are logged, which ComfyUI's log capture
# sends to the Logs panel. The file is absent when no watcher runs, and then
# this does nothing (docs/access.md, "When the connection drops").
import logging
import os
import threading
import time

EVENTS_PATH = "/workspace/.tunnel-events.log"
POLL_SECONDS = 2


def follow_events():
    seen = 0
    while True:
        try:
            with open(EVENTS_PATH) as events_file:
                lines = events_file.read().splitlines()
        except OSError:
            lines = None
        if lines is not None:
            # a shorter file means a new watcher started over
            if len(lines) < seen:
                seen = 0
            for line in lines[seen:]:
                logging.warning("connection: %s", line)
            seen = len(lines)
        time.sleep(POLL_SECONDS)


if os.path.isdir(os.path.dirname(EVENTS_PATH)):
    threading.Thread(target=follow_events, name="connection-events", daemon=True).start()

NODE_CLASS_MAPPINGS = {}
