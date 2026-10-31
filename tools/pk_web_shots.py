#!/usr/bin/env python3
"""在指定 Web 产物目录上跑一次"只截图"的会话（视觉 QA / 画质取证）。

用途：拿到"当前 Web 包能呈现的最高画质"的实际画面。常用组合是
`?autotest=1&days=3&speed=1&fog=off&tier=high` —— 关掉全部战争迷雾、把运行期
`visual_quality` 拉到高档、低速跑几天让植被/建筑/天气都出现。

与 pk_web_measure.py 的分工：那个是**性能**闭环（只解析事件流），这个是**视觉**
闭环（复用 verify_web_session 的定期截图）。

用法：
  python tools/pk_web_shots.py --root WebBuildDebug --out artifacts/shots_debug
  python tools/pk_web_shots.py --root WebBuild --extra "fog=off&tier=high&speed=1&days=5"
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent


def _kill_selenium() -> None:
    ps = r"""
Get-CimInstance Win32_Process | Where-Object {
  ($_.Name -in @('chrome.exe','chromedriver.exe') -and $_.ExecutablePath -match 'selenium') -or
  ($_.Name -eq 'python.exe' -and $_.CommandLine -match 'serve_web|verify_web')
} | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
"""
    try:
        subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       capture_output=True, text=True, timeout=90)
    except Exception as exc:
        print(f"[shots] cleanup skipped: {exc}")
    time.sleep(1.5)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="WebBuildDebug", help="Web 产物目录（含 ProjectKeynes.html）")
    ap.add_argument("--port", type=int, default=8062)
    ap.add_argument("--out", default="artifacts/shots")
    ap.add_argument("--days", type=int, default=5)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--size", default="60x40")
    ap.add_argument("--extra", default="fog=off&tier=high",
                    help="附加查询串（fog=off / tier=high 是诊断开关，见 web_autotest.gd）")
    ap.add_argument("--seconds", type=float, default=95.0)
    ap.add_argument("--stall-timeout", type=float, default=120.0)
    args = ap.parse_args()

    root = REPO / args.root
    if not (root / "ProjectKeynes.html").exists():
        print(f"[shots] {root}/ProjectKeynes.html 不存在；先导出该产物")
        return 1
    out_dir = REPO / args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    events = REPO / "tmp" / "ev_shots.jsonl"
    if events.exists():
        events.unlink()

    _kill_selenium()
    server_out = open(REPO / "tmp" / "shots_server.out", "w", encoding="utf-8")
    server_err = open(REPO / "tmp" / "shots_server.err", "w", encoding="utf-8")
    server = subprocess.Popen(
        [sys.executable, str(REPO / "tools" / "serve_web.py"),
         "--port", str(args.port), "--root", str(root),
         "--events", "tmp/ev_shots.jsonl"],
        cwd=REPO, stdout=server_out, stderr=server_err)
    base = f"http://127.0.0.1:{args.port}/ProjectKeynes.html"
    for _ in range(40):
        time.sleep(0.5)
        try:
            with urllib.request.urlopen(base, timeout=3) as r:
                if r.status == 200:
                    break
        except Exception:
            continue
    else:
        print("[shots] server 未就绪")
        server.terminate()
        return 1

    speed = int(args.speed) if float(args.speed).is_integer() else args.speed
    url = (f"{base}?autotest=1&days={args.days}&speed={speed}"
           f"&size={args.size}&{args.extra}")
    print(f"[shots] url={url}")
    cmd = [
        sys.executable, str(REPO / "tools" / "verify_web_session.py"),
        "--url", url, "--no-headless",
        "--seconds", str(int(args.seconds)),
        "--max-seconds", str(int(args.seconds) + 60),
        "--stall-timeout", str(args.stall_timeout),
        "--unpause",
        "--out", str(out_dir),
        "--events", str(events),
        "--no-click",
        "--user-data-dir", "tmp/chrome_profile_shots",
    ]
    code = subprocess.call(cmd, cwd=REPO)
    try:
        server.terminate()
        server.wait(timeout=10)
    except Exception:
        pass
    _kill_selenium()

    shots = sorted(out_dir.glob("session_*.png"), key=lambda p: p.stat().st_mtime)
    print(f"\n[shots] exit={code}  截图 {len(shots)} 张 -> {out_dir}")
    for p in shots:
        print(f"    {p.name}  {p.stat().st_size/1024:.0f} KB")
    # 顺手把这一轮的 fog / 画质日志捞出来，作为"画质档位确实生效"的证据
    console = out_dir / "session_console.json"
    if console.exists():
        txt = console.read_text(encoding="utf-8", errors="replace")
        for pat in (r"\[vision\][^\"\\]{0,120}", r"\[hex_renderer/variant\][^\"\\]{0,160}",
                    r"web_world_min=\w+"):
            for m in re.finditer(pat, txt):
                print(f"    log: {m.group(0)[:170]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
