#!/usr/bin/env python3
"""Self-test for tools/serve_web.py.

Starts the real handler on an ephemeral port against a throwaway fixture
directory plus a couple of real WebBuild files, then asserts the wire contract:

  (a) Accept-Encoding: br/gzip -> Content-Encoding matches, Content-Length is
      exact, and the body decodes back to the bytes on disk;
  (b) a second request carrying If-None-Match -> 304 with no body;
  (c) the /_log POST -> 204 / GET -> JSON channel still works;
  (d) COOP/COEP/CORP are present on 200, 304, 404 and /_log responses;
  (e) sidecar handling: a fresh .gz sidecar wins for .pck, a stale one is
      ignored, --no-compress sends no Content-Encoding, ?v= is immutable.

Usage:
    python tools/serve_web_selftest.py [-v]
Exit code 0 means every check passed.
"""

from __future__ import annotations

import functools
import gzip
import http.client
import io
import json
import os
import pathlib
import shutil
import sys
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))

import serve_web as sw  # noqa: E402

FAILURES: list[str] = []
CHECKS = 0


def check(condition: bool, label: str, detail: str = "") -> bool:
    global CHECKS
    CHECKS += 1
    if condition:
        print(f"  PASS  {label}")
        return True
    message = f"{label}{(' — ' + detail) if detail else ''}"
    print(f"  FAIL  {message}")
    FAILURES.append(message)
    return False


class Client:
    def __init__(self, port: int) -> None:
        self.port = port

    def request(self, method: str, path: str, headers: dict | None = None,
                body: bytes | None = None) -> tuple[int, dict, bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            payload = response.read()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, payload
        finally:
            conn.close()


def decode(body: bytes, encoding: str | None) -> bytes:
    if encoding == "br":
        import brotli  # only reachable when the server had it too
        return brotli.decompress(body)
    if encoding == "gzip":
        return gzip.decompress(body)
    return body


def start(root: pathlib.Path, event_log: pathlib.Path, **flags) -> tuple[sw.ReusableTCPServer, int]:
    handler_cls = sw.GodotWebRequestHandler
    # Access logs go to stderr, which shells/CI wrappers turn into "command failed"
    # noise (and drown the PASS/FAIL lines). The self-test asserts on the wire
    # contract, not on the log, so keep it quiet.
    handler_cls.log_message = lambda *a, **k: None
    handler_cls.event_log = event_log
    handler_cls.compress_enabled = flags.get("compress", True)
    handler_cls.compress_quality = flags.get("quality", 5)
    handler_cls.inline_max_bytes = flags.get("inline_max", sw.INLINE_MAX_BYTES)
    handler_cls.inline_pck = flags.get("inline_pck", False)
    handler_cls.cache_control_enabled = flags.get("cache_control", True)
    handler_cls.immutable = flags.get("immutable", False)
    handler_cls.manifest = flags.get("manifest", None)
    handler_cls.memo.clear()
    server = sw.ReusableTCPServer(
        ("127.0.0.1", 0), functools.partial(handler_cls, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def make_fixture(root: pathlib.Path) -> dict[str, bytes]:
    root.mkdir(parents=True, exist_ok=True)
    text = ("// fixture\n" + "var x := 1\n" * 4000 +
            "".join(f"# line {i}\n" for i in range(2000))).encode()
    wasm = bytes((i * 37) % 251 for i in range(300_000))
    pck = bytes((i * 11) % 256 for i in range(512 * 1024))
    stale = b"x" * 1000
    (root / "app.js").write_bytes(text)
    (root / "engine.wasm").write_bytes(wasm)
    (root / "data.pck").write_bytes(pck)
    (root / "data.pck.gz").write_bytes(gzip.compress(pck, compresslevel=9, mtime=0))
    (root / "stale.wasm").write_bytes(wasm)
    (root / "stale.wasm.gz").write_bytes(gzip.compress(stale, compresslevel=9, mtime=0))
    old = 1_600_000_000
    os.utime(root / "stale.wasm.gz", (old, old))
    (root / "index.html").write_bytes(b"<!doctype html><title>fixture</title>\n")
    return {"app.js": text, "engine.wasm": wasm, "data.pck": pck}


def main() -> int:
    verbose = "-v" in sys.argv
    repo = pathlib.Path(__file__).resolve().parent.parent
    fixture = repo / "tmp" / "serve_web_selftest_root"
    if fixture.exists():
        shutil.rmtree(fixture)
    files = make_fixture(fixture)
    event_log = repo / "tmp" / "serve_web_selftest_events.jsonl"
    if event_log.exists():
        event_log.unlink()

    print(f"brotli available: {sw._brotli is not None}")

    # ---------------- phase 1: compression + conditional caching --------------
    print("\n[phase 1] compression, ETag, /_log, isolation headers")
    server, port = start(fixture, event_log)
    client = Client(port)
    try:
        offer = "br, gzip" if sw._brotli else "gzip"
        status, headers, body = client.request("GET", "/app.js", {"Accept-Encoding": offer})
        check(status == 200, "GET /app.js -> 200", str(status))
        encoding = headers.get("content-encoding")
        check(encoding in ("br", "gzip"), "compressible file gets brotli/gzip", str(encoding))
        check(int(headers.get("content-length", "-1")) == len(body),
              "Content-Length matches the encoded body",
              f"{headers.get('content-length')} vs {len(body)}")
        check(headers.get("vary", "").lower().find("accept-encoding") >= 0,
              "Vary: Accept-Encoding present", headers.get("vary", ""))
        check(decode(body, encoding) == files["app.js"],
              "decoded body equals the file on disk")
        check(headers.get("cache-control") == "no-cache",
              "Cache-Control: no-cache (revalidate, not immutable)",
              str(headers.get("cache-control")))
        etag = headers.get("etag", "")
        check(etag.startswith('"') and len(etag) > 6, "strong ETag emitted", etag)

        status2, headers2, body2 = client.request(
            "GET", "/app.js", {"Accept-Encoding": offer, "If-None-Match": etag})
        check(status2 == 304, "If-None-Match -> 304", str(status2))
        check(body2 == b"", "304 carries no body", repr(body2[:20]))
        check(headers2.get("etag") == etag, "304 repeats the ETag", str(headers2.get("etag")))

        status3, headers3, body3 = client.request("GET", "/engine.wasm",
                                                  {"Accept-Encoding": offer})
        check(status3 == 200 and headers3.get("content-encoding") in ("br", "gzip"),
              ".wasm is compressed", f"{status3} {headers3.get('content-encoding')}")
        check(decode(body3, headers3.get("content-encoding")) == files["engine.wasm"],
              ".wasm decodes to the original bytes")

        content_type = headers3.get("content-type", "")
        check(content_type.startswith("application/wasm"),
              ".wasm keeps its MIME type", content_type)

        # /_log channel
        record = json.dumps({"e": "selftest", "ms": 1}).encode()
        status4, _, _ = client.request("POST", "/_log", {"Content-Type": "application/json"},
                                       record)
        check(status4 == 204, "POST /_log -> 204", str(status4))
        status5, headers5, body5 = client.request("GET", "/_log")
        ok = False
        if status5 == 200:
            try:
                ok = json.loads(body5)[-1].get("e") == "selftest"
            except (json.JSONDecodeError, IndexError, KeyError):
                ok = False
        check(ok, "GET /_log returns the posted event", body5[:80].decode("utf-8", "replace"))
        check(headers5.get("cache-control") == "no-store",
              "/_log stays no-store", str(headers5.get("cache-control")))
        check(event_log.exists() and '"selftest"' in event_log.read_text(encoding="utf-8"),
              "event landed in the jsonl file")

        # isolation headers on every response class
        for label, (status, hdrs, _) in {
            "200": (status, headers, body),
            "304": (status2, headers2, body2),
            "/_log": (status5, headers5, body5),
            "404": client.request("GET", "/nope.bin"),
        }.items():
            check(hdrs.get("cross-origin-opener-policy") == "same-origin"
                  and hdrs.get("cross-origin-embedder-policy") == "require-corp"
                  and hdrs.get("cross-origin-resource-policy") == "same-origin",
                  f"COOP/COEP/CORP on {label}")

        # pck: sidecar wins even though inline is off
        status6, headers6, body6 = client.request("GET", "/data.pck",
                                                  {"Accept-Encoding": offer})
        check(status6 == 200, "GET .pck -> 200", str(status6))
        check(headers6.get("content-encoding") in ("gzip", "br"),
              ".pck uses the sidecar encoding", str(headers6.get("content-encoding")))
        check(decode(body6, headers6.get("content-encoding")) == files["data.pck"],
              ".pck sidecar decodes to the original bytes")
        check(int(headers6.get("content-length", "-1")) == len(body6),
              ".pck Content-Length is the sidecar size")

        # stale sidecar must be ignored; the source still has to decode correctly
        status7, headers7, body7 = client.request("GET", "/stale.wasm",
                                                  {"Accept-Encoding": offer})
        check(status7 == 200, "GET stale.wasm -> 200", str(status7))
        if headers7.get("content-encoding"):
            check(decode(body7, headers7["content-encoding"]) == files["engine.wasm"],
                  "stale .gz sidecar ignored (body is the current file)")
        else:
            check(body7 == files["engine.wasm"], "stale .gz sidecar ignored (raw body)")

        # ?v= makes the response immutable
        status8, headers8, _ = client.request("GET", "/app.js?v=deadbeef",
                                             {"Accept-Encoding": offer})
        check(status8 == 200 and "immutable" in (headers8.get("cache-control") or ""),
              "?v=<hash> -> immutable caching", str(headers8.get("cache-control")))
        check(headers8.get("etag") != "", "versioned response still has an ETag")
    finally:
        server.shutdown()
        server.server_close()

    # ---------------- phase 2: --no-compress ---------------------------------
    print("\n[phase 2] --no-compress")
    server, port = start(fixture, event_log, compress=False)
    client = Client(port)
    try:
        status, headers, body = client.request("GET", "/app.js", {"Accept-Encoding": "br, gzip"})
        check(status == 200 and "content-encoding" not in headers,
              "no Content-Encoding when compression is off")
        check(body == files["app.js"], "raw body equals the file on disk")
    finally:
        server.shutdown()
        server.server_close()

    # ---------------- phase 3: manifest ETag + immutable mode ----------------
    print("\n[phase 3] manifest.json ETag, --immutable")
    import hashlib
    app = fixture / "app.js"
    st = app.stat()
    manifest_path = fixture / "manifest.json"
    manifest_path.write_text(json.dumps({
        "files": {"app.js": {"sha256": hashlib.sha256(files["app.js"]).hexdigest(),
                             "size": st.st_size, "mtime_ns": st.st_mtime_ns}},
    }), encoding="utf-8")
    server, port = start(fixture, event_log, immutable=True,
                         manifest=sw.Manifest(manifest_path))
    client = Client(port)
    try:
        status, headers, _ = client.request("GET", "/app.js", {"Accept-Encoding": "gzip"})
        expected = '"' + hashlib.sha256(files["app.js"]).hexdigest() + '"'
        check(headers.get("etag") == expected, "ETag comes from manifest.json",
              f"{headers.get('etag')} vs {expected}")
        check("immutable" in (headers.get("cache-control") or ""),
              "--immutable sets the long policy", str(headers.get("cache-control")))
        # A file that does not match the manifest falls back to the stat ETag.
        status, headers, _ = client.request("GET", "/engine.wasm", {"Accept-Encoding": "gzip"})
        check(headers.get("etag", "").startswith('"') and "immutable" in headers.get("cache-control", ""),
              "unlisted file still gets a stat ETag")
    finally:
        server.shutdown()
        server.server_close()

    # ---------------- phase 4: real WebBuild files ---------------------------
    print("\n[phase 4] real WebBuild sample")
    web = repo / "WebBuild"
    sample = web / "ProjectKeynes.js"
    if sample.is_file():
        server, port = start(web, event_log)
        client = Client(port)
        try:
            offer = "br, gzip" if sw._brotli else "gzip"
            status, headers, body = client.request("GET", "/ProjectKeynes.js",
                                                   {"Accept-Encoding": offer})
            original = sample.read_bytes()
            check(status == 200, "real ProjectKeynes.js -> 200", str(status))
            check(decode(body, headers.get("content-encoding")) == original,
                  "real engine js decodes to the file on disk")
            print(f"        {len(original)/1048576:.2f} MB -> "
                  f"{len(body)/1048576:.2f} MB ({100.0*len(body)/len(original):.1f}%)"
                  f" via {headers.get('content-encoding')}")
        finally:
            server.shutdown()
            server.server_close()
    else:
        print("  SKIP  WebBuild/ProjectKeynes.js not present")

    # ---------------- summary ------------------------------------------------
    print(f"\n{CHECKS - len(FAILURES)}/{CHECKS} checks passed")
    if FAILURES:
        print("\nFAILED:")
        for failure in FAILURES:
            print(f"  - {failure}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    # A closed stdout (e.g. `... | Select-Object -First 5`) must not turn a green
    # run into a non-zero exit: CI reads the exit code, humans read the first lines.
    try:
        exit_code = main()
    except BrokenPipeError:
        exit_code = 0 if not FAILURES else 1
    try:
        sys.stdout.flush()
    except (BrokenPipeError, ValueError):
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except OSError:
            pass
    raise SystemExit(exit_code)
