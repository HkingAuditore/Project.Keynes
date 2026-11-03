#!/usr/bin/env python3
"""Serve the Godot web build with the headers a threaded build needs, and capture
the page's console output into a file.

Godot's web export with `variant/thread_support=true` uses SharedArrayBuffer, which
browsers only expose to cross-origin-isolated pages:

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp

Console capture: the Web preset injects a small `<script>` (html/head_include) that
POSTs every console.* call to `/__log`; this server appends it to
`tmp/fmod_multi/web_console.log`. That is how a headless browser run can be verified
without a WebSocket client.

Usage:
    python tools/serve_web_threads.py WebBuild 8099
"""

from __future__ import annotations

import functools
import http.server
import pathlib
import socketserver
import sys

LOG_PATH = pathlib.Path(__file__).resolve().parents[1] / "tmp" / "fmod_multi" / "web_console.log"


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        if self.path != "/__log":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write(body + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:  # quiet
        pass


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1] if len(argv) > 1 else "WebBuild").resolve()
    port = int(argv[2]) if len(argv) > 2 else 8099
    if not root.is_dir():
        raise SystemExit(f"missing directory: {root}")
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOG_PATH.write_text("", encoding="utf-8")
    handler = functools.partial(Handler, directory=str(root))
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", port), handler) as server:
        print(f"[serve] http://127.0.0.1:{port}/  root={root}  log={LOG_PATH}", flush=True)
        server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
