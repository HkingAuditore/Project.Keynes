#!/usr/bin/env python3
"""Static server for the Godot Web export in WebBuild/.

Plain `python -m http.server` is not enough for a Godot web build:

1. Cross-origin isolation. A threads-enabled export needs SharedArrayBuffer,
   which browsers only hand out to pages served with both
   `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp`. Without them the engine
   aborts on startup with "Cross-Origin Isolation ... SharedArrayBuffer".
   The current Web preset is nothreads and does not strictly need these, but
   sending them anyway keeps the threads variant working from the same server.

2. MIME types. Python's default map has no entry for .wasm or .pck, so the
   browser refuses the streaming WebAssembly instantiation path and Godot
   falls back to a slower one — or fails outright.

Usage:
    python tools/serve_web.py [--port 8060] [--root WebBuild]
"""

from __future__ import annotations

import argparse
import functools
import http.server
import pathlib
import socketserver

EXTRA_MIME_TYPES = {
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".worklet.js": "text/javascript",
}


class GodotWebRequestHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        **EXTRA_MIME_TYPES,
    }

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        # The export is rebuilt constantly during bring-up and the .wasm/.pck
        # filenames never change, so a cached copy would silently mask a fresh
        # build.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8060)
    parser.add_argument("--root", default=str(repo_root / "WebBuild"))
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    if not root.is_dir():
        parser.error(f"root directory does not exist: {root}")

    handler = functools.partial(GodotWebRequestHandler, directory=str(root))
    with ReusableTCPServer(("127.0.0.1", args.port), handler) as httpd:
        entry = next(iter(sorted(root.glob("*.html"))), None)
        url = f"http://127.0.0.1:{args.port}/"
        print(f"Serving {root}")
        print(f"  {url}{entry.name if entry else ''}")
        print("  cross-origin isolation: on")
        print("Ctrl-C to stop.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
