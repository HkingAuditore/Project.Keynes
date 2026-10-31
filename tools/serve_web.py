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
import json
import time
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

    # 浏览器→agent 的单向事件通道：页面把 JSON 事件 POST 到 /_log，
    # 这里追加到 tmp/web_events.jsonl。agent 侧 `tail` 这个文件即可实时看到
    # 加载进度/日历推进/卡死告警，不需要截图轮询。
    event_log: pathlib.Path | None = None
    _event_seq = 0

    def do_POST(self) -> None:  # noqa: N802 - http.server naming
        if not self.path.startswith("/_log"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        payload = self.rfile.read(length) if length > 0 else b"{}"
        if self.event_log is not None:
            try:
                record = json.loads(payload.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                record = {"raw": payload.decode("utf-8", "replace")}
            record["t_wall"] = time.strftime("%H:%M:%S")
            with self.event_log.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802 - http.server naming
        if self.path.startswith("/_log"):
            records: list[str] = []
            if self.event_log is not None and self.event_log.exists():
                records = self.event_log.read_text(encoding="utf-8").splitlines()
            body = ("[" + ",".join(records) + "]").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

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
    parser.add_argument("--events", default=str(repo_root / "tmp" / "web_events.jsonl"),
                        help="事件流落盘位置；debug/release 两个服务各用一份，避免交织")
    parser.add_argument("--no-truncate", action="store_true",
                        help="启动时不清空事件流（多服务共用同一个文件时用）")
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    if not root.is_dir():
        parser.error(f"root directory does not exist: {root}")

    log_dir = repo_root / "tmp"
    log_dir.mkdir(parents=True, exist_ok=True)
    event_path = pathlib.Path(args.events)
    if not event_path.is_absolute():
        event_path = repo_root / event_path
    event_path.parent.mkdir(parents=True, exist_ok=True)
    GodotWebRequestHandler.event_log = event_path
    if not args.no_truncate:
        GodotWebRequestHandler.event_log.write_text("", encoding="utf-8")
    handler = functools.partial(GodotWebRequestHandler, directory=str(root))
    with ReusableTCPServer(("127.0.0.1", args.port), handler) as httpd:
        entry = next(iter(sorted(root.glob("*.html"))), None)
        url = f"http://127.0.0.1:{args.port}/"
        print(f"Serving {root}")
        print(f"  {url}{entry.name if entry else ''}")
        print("  cross-origin isolation: on")
        print(f"  event log: {GodotWebRequestHandler.event_log}")
        print("Ctrl-C to stop.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
