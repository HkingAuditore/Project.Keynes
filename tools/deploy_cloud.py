"""Push the Web export to the Windows/IIS server and swap it in place.

Why: the export is one fixed-name payload of ~120 MB and the server is a plain
Windows/IIS box reachable only over plain HTTP (no SSH/SMB/WinRM from here).
`tools/remote/pk_web_receiver.ps1` runs on the server, accepts a resumable
chunked upload on one TCP port and swaps the IIS application directory
atomically, keeping the previous version as `<dir>.bak-<stamp>`.

**Nothing site-specific lives in this repository.** Host, port, token and the
IIS application name are read from a local file, and every one of them is
required - there are no fallback defaults, so a missing entry fails loudly
instead of guessing:

    ~/.pk_cloud_deploy.json
    {
      "host":  "<server public IP or name>",
      "port":  8099,
      "token": "<token printed by pk_web_receiver.ps1 -Install>",
      "app":   "web-debug",
      "url":   "http://<host>/web-debug/"
    }

Environment overrides: PK_CLOUD_HOST, PK_CLOUD_PORT, PK_CLOUD_TOKEN,
PK_CLOUD_APP, PK_CLOUD_URL.

Usage (from the repository root):

    python tools/deploy_cloud.py --init       # write the config interactively
    python tools/deploy_cloud.py --health     # is the receiver reachable?
    python tools/deploy_cloud.py              # zip + upload + swap
    python tools/deploy_cloud.py --dry-run    # build the zip, print the plan
    python tools/deploy_cloud.py --root WebBuildDebug --app web-debug

The zip deliberately leaves out `.br` / `.gz` sidecars: IIS compresses static
content itself, and the sidecars are ~100 MB of upload the server would never
read. `--with-sidecars` restores them for a server that serves them directly.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
import zipfile

CONFIG_FILE = pathlib.Path.home() / ".pk_cloud_deploy.json"
SIDECAR_SUFFIXES = {".gz", ".br"}
DEFAULT_ROOT = "WebBuild"
CHUNK_MB = 8


# --------------------------------------------------------------------- config
def read_config(path: pathlib.Path = CONFIG_FILE) -> dict:
    cfg: dict = {}
    if path.exists():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                cfg = loaded
        except (OSError, ValueError) as exc:
            print(f"[config] {path} is not readable JSON: {exc}", file=sys.stderr)
            cfg = {}

    def pick(env: str, key: str, default: str = "") -> str:
        return os.environ.get(env, "").strip() or str(cfg.get(key, default)).strip()

    return {
        "host": pick("PK_CLOUD_HOST", "host"),
        "port": pick("PK_CLOUD_PORT", "port", "8099"),
        "token": pick("PK_CLOUD_TOKEN", "token"),
        "app": pick("PK_CLOUD_APP", "app", "web-debug"),
        "url": pick("PK_CLOUD_URL", "url"),
    }


def require_config(cfg: dict) -> dict:
    missing = [k for k in ("host", "port", "token") if not cfg[k]]
    if missing:
        raise SystemExit(
            "缺少本机配置项 %s：先运行 python tools/deploy_cloud.py --init，"
            "或在环境变量里给 PK_CLOUD_HOST / PK_CLOUD_PORT / PK_CLOUD_TOKEN" % ", ".join(missing)
        )
    return cfg


def cmd_init(args) -> int:
    print("配置写到哪里：" + str(CONFIG_FILE))
    current = read_config()
    host = input(f"服务器地址 [{current['host']}]: ").strip() or current["host"]
    port = input(f"接收器端口 [{current['port']}]: ").strip() or current["port"]
    token = input("token（服务器上 -Install 打印的那串；留空则复用已有）: ").strip() or current["token"]
    app = input(f"IIS 应用名/目录名 [{current['app']}]: ").strip() or current["app"]
    url = input(f"访问 URL [{current['url'] or 'http://%s/%s/' % (host, app)}]: ").strip()
    if not url:
        url = current["url"] or f"http://{host}/{app}/"
    payload = {"host": host, "port": int(port), "token": token, "app": app, "url": url}
    CONFIG_FILE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"[config] wrote {CONFIG_FILE}")
    print("[config] token 长度 %d" % len(token))
    return 0


# ------------------------------------------------------------------- packaging
def collect(root: pathlib.Path, with_sidecars: bool) -> list[pathlib.Path]:
    out = []
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        if not with_sidecars and p.suffix.lower() in SIDECAR_SUFFIXES:
            continue
        if p.name.startswith("."):
            continue
        out.append(p)
    return out


def build_zip(root: pathlib.Path, out: pathlib.Path, level: int, with_sidecars: bool) -> tuple[int, int, str]:
    files = collect(root, with_sidecars)
    if not files:
        raise SystemExit(f"no files under {root} - run scripts\\Build-Web.cmd first")
    if not any(p.suffix.lower() == ".pck" for p in files):
        raise SystemExit(f"no .pck under {root} - that does not look like a Godot web export")
    raw = sum(p.stat().st_size for p in files)
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=level) as z:
        for p in files:
            z.write(p, p.relative_to(root).as_posix())
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    return len(files), raw, digest


# ---------------------------------------------------------------------- http
class Client:
    def __init__(self, cfg: dict, timeout: float):
        self.base = f"http://{cfg['host']}:{cfg['port']}"
        self.token = cfg["token"]
        self.timeout = timeout
        # The receiver answers with Connection: close anyway; a fresh opener with
        # no proxy is deliberate - the host reaches the server directly.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, method: str, path: str, data: bytes | None = None,
             ctype: str | None = None, timeout: float | None = None) -> tuple[int, dict]:
        headers = {"X-PK-Token": self.token}
        if ctype:
            headers["Content-Type"] = ctype
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=timeout or self.timeout) as r:
                body = r.read()
                code = r.status
        except urllib.error.HTTPError as exc:
            # The status line is what matters; the body is best effort. Reading it
            # can fail with ECONNRESET when the peer closed early.
            code = exc.code
            try:
                body = exc.read()
            except Exception:
                body = b""
        try:
            payload = json.loads(body.decode("utf-8", "replace") or "{}")
        except ValueError:
            payload = {"ok": False, "error": body.decode("utf-8", "replace")[:400]}
        return code, payload


def explain(code: int, payload: dict, what: str) -> None:
    detail = payload.get("error") or json.dumps(payload, ensure_ascii=False)[:400]
    if code == 401:
        raise SystemExit(f"{what}: 401 - token 不对（去服务器跑 pk_web_receiver.ps1 -Status 看 token）\n{detail}")
    raise SystemExit(f"{what}: HTTP {code}\n{detail}")


# --------------------------------------------------------------------- upload
def upload(cfg: dict, zip_path: pathlib.Path, chunk_bytes: int, retries: int,
           timeout: float) -> dict:
    client = Client(cfg, timeout)
    size = zip_path.stat().st_size
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    code, info = client.call(
        "POST",
        f"/upload/begin?app={cfg['app']}&size={size}&name={zip_path.name}&sha256={digest}",
        timeout=60,
    )
    if code != 200 or not info.get("ok"):
        explain(code, info, "begin")
    session = info["session"]
    print(f"[upload] session={session} size={size / 1048576:.1f} MB chunk={chunk_bytes / 1048576:.0f} MB")

    sent = 0
    started = time.time()
    with open(zip_path, "rb") as fh:
        while sent < size:
            piece = fh.read(chunk_bytes)
            if not piece:
                break
            base = sent
            data = piece
            attempt = 0
            while True:
                try:
                    code, res = client.call(
                        "PUT", f"/upload/chunk?session={session}&offset={base}", data=data,
                        ctype="application/octet-stream",
                    )
                except Exception as exc:  # noqa: BLE001 - a dropped chunk is a retry, not a crash
                    code, res = 0, {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
                if code == 200 and res.get("ok"):
                    sent = int(res.get("received", base + len(data)))
                    break
                if code == 409 and res.get("conflict"):
                    expected = int(res.get("expected_offset", -1))
                    if base <= expected <= base + len(piece):
                        # The server already has a prefix of this chunk (a dropped
                        # connection mid-chunk); resend only the missing tail.
                        data = piece[expected - base:]
                        base = expected
                        continue
                    raise SystemExit(
                        f"upload: 服务器已有 {expected} 字节，与本地 {base} 对不上；"
                        "删掉这次会话（DELETE /upload?session=）后重跑"
                    )
                attempt += 1
                if attempt > retries:
                    explain(code, res, "chunk")
                print(f"  [retry {attempt}/{retries}] offset={base} HTTP {code}: "
                      f"{res.get('error', 'network')}")
                time.sleep(min(2 * attempt, 8))
            done = sent / size * 100
            rate = sent / 1048576 / max(time.time() - started, 1e-6)
            print(f"  [chunk] {sent / 1048576:7.1f} / {size / 1048576:.1f} MB "
                  f"({done:5.1f}%) {rate:5.1f} MB/s")

    code, res = client.call("POST", f"/upload/finish?session={session}", timeout=max(timeout, 600))
    if code == 409 and res.get("incomplete"):
        raise SystemExit(
            f"finish: 服务器只收到 {res.get('received')} / {res.get('size')} 字节，"
            "这次会话作废，重跑即可"
        )
    if code != 200 or not res.get("ok"):
        explain(code, res, "finish")
    return res


def cmd_health(cfg: dict, timeout: float) -> int:
    client = Client(cfg, timeout)
    code, info = client.call("GET", "/health", timeout=min(timeout, 30))
    if code != 200 or not info.get("ok"):
        explain(code, info, "health")
    print("[health] receiver ok")
    print(f"  app       : {info.get('app')}")
    targets = info.get("targets") or []
    if targets:
        for item in targets:
            flag = "https" if item.get("HasHttps") else "http only"
            print(f"  target    : {item.get('Target')}  ({item.get('Site')}, {flag})")
    else:
        print(f"  target    : {info.get('target')}")
    print(f"  max bytes : {info.get('max_bytes')}")
    print(f"  powershell: {info.get('ps')}")
    return 0


def report_sites(result: dict, cfg: dict) -> None:
    sites = result.get("sites") or []
    if not sites:
        return
    insecure = []
    for item in sites:
        url = item.get("url") or f"http://{cfg['host']}/{cfg['app']}/"
        print(f"  site      : {item.get('site')}  ->  {item.get('target')}")
        print(f"    url       : {url}")
        print(f"    probe     : {item.get('probe')}")
        print(f"    backup    : {item.get('backup')}")
        if not item.get("https"):
            insecure.append(url)
    if insecure:
        print("  [warn] 以下入口没有 https 绑定：threads 版需要 secure context，")
        print("         用明文 http 开 IP 拿不到 crossOriginIsolated；先打开 check.html 确认")
        for url in insecure:
            print(f"         {url}check.html")


# ----------------------------------------------------------------------- main
def main(argv: list[str] | None = None) -> int:
    # Print UTF-8 regardless of the console code page; the wrapper raises the
    # console to 65001 as well, so Chinese messages are readable in cmd.exe.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="Deploy the Web export to the Windows/IIS server")
    ap.add_argument("--root", default=DEFAULT_ROOT, help=f"export dir (default {DEFAULT_ROOT})")
    ap.add_argument("--zip", dest="zip_path", default=None, help="zip path (default tmp/pk-web-<name>.zip)")
    ap.add_argument("--skip-zip", action="store_true", help="reuse an existing --zip")
    ap.add_argument("--level", type=int, default=6, help="deflate level (default 6)")
    ap.add_argument("--chunk-mb", type=int, default=CHUNK_MB, help=f"chunk size in MB (default {CHUNK_MB})")
    ap.add_argument("--retries", type=int, default=4, help="retries per chunk (default 4)")
    ap.add_argument("--timeout", type=float, default=120.0, help="per-request timeout seconds")
    ap.add_argument("--with-sidecars", action="store_true", help="keep .br/.gz sidecars in the upload")
    ap.add_argument("--app", default=None, help="IIS application name (overrides the config)")
    ap.add_argument("--host", default=None, help="server host (overrides the config)")
    ap.add_argument("--port", default=None, help="receiver port (overrides the config)")
    ap.add_argument("--token", default=None, help="receiver token (overrides the config)")
    ap.add_argument("--init", action="store_true", help="write ~/.pk_cloud_deploy.json and exit")
    ap.add_argument("--health", action="store_true", help="probe the receiver and exit")
    ap.add_argument("--dry-run", action="store_true", help="build the zip and print the plan only")
    args = ap.parse_args(argv)

    if args.init:
        return cmd_init(args)

    cfg = read_config()
    for key, value in (("host", args.host), ("port", args.port), ("token", args.token), ("app", args.app)):
        if value:
            cfg[key] = str(value)
    require_config(cfg)

    if args.health:
        return cmd_health(cfg, args.timeout)

    root = pathlib.Path(args.root)
    if not root.is_dir():
        raise SystemExit(f"{root} 不存在 - 先跑 scripts\\Build-Web.cmd")

    zip_path = pathlib.Path(args.zip_path) if args.zip_path else pathlib.Path("tmp") / f"pk-web-{root.name}.zip"
    if args.skip_zip and zip_path.exists():
        digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        print(f"[zip] 复用 {zip_path} ({zip_path.stat().st_size / 1048576:.1f} MB) sha256={digest[:12]}")
    else:
        t0 = time.time()
        count, raw, digest = build_zip(root, zip_path, args.level, args.with_sidecars)
        print(f"[zip] {zip_path}  {count} files  raw={raw / 1048576:.1f} MB  "
              f"zip={zip_path.stat().st_size / 1048576:.1f} MB  "
              f"sha256={digest[:12]}  ({time.time() - t0:.1f}s)")

    target_url = cfg["url"] or f"http://{cfg['host']}/{cfg['app']}/"
    if args.dry_run:
        print(f"[plan] PUT <{cfg['host']}:{cfg['port']}>/upload/*  ({zip_path.stat().st_size} B, "
              f"{max(1, -(-zip_path.stat().st_size // (args.chunk_mb * 1048576)))} chunks)")
        print(f"[plan] 服务器把 {cfg['app']} 目录原子换新，旧目录留成 .bak-<timestamp>")
        print(f"[plan] 目标 {target_url}")
        return 0

    t0 = time.time()
    result = upload(cfg, zip_path, args.chunk_mb * 1048576, args.retries, args.timeout)
    print(f"[deploy] ok in {time.time() - t0:.1f}s")
    print(f"  sites     : {result.get('site_count', 1)}")
    print(f"  files     : {result.get('file_count')}")
    print(f"  bytes     : {result.get('bytes')}")
    print(f"  build id  : {result.get('build_id')}")
    report_sites(result, cfg)
    print(f"[deploy] {target_url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
