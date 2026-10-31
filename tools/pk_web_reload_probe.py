#!/usr/bin/env python3
"""同一次浏览器会话里**连续加载两次**页面，比较两次的 shader 预热耗时。

为什么需要：真机实测发现「本进程第一次编译 shader」有一次约 16 s 的固定成本 ——
把一个 64 字符的最简 shader 排到预热清单第一位，它自己吃掉 15 968 ms，而紧跟其后的
world_map 只要 1 943 ms。也就是说这 16 秒属于 Chrome GPU 进程 / ANGLE / 驱动的冷启动，
不属于任何一张 shader。

那么"用户第二次进游戏还慢吗"就取决于：**同一会话里 reload 之后，GPU 进程是否复用**。
本脚本回答这一个问题：加载 → 等菜单就绪 → reload → 再等，然后从事件流里分别取出
两次加载的 `warmup_shader` 分项。

用法：
  python tools/pk_web_reload_probe.py --wait 60
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
CACHE = pathlib.Path.home() / ".cache" / "selenium"
PORT = 8060


def _chrome_paths() -> tuple[pathlib.Path, pathlib.Path]:
    """与 verify_web_session.py 同一个解析口径（selenium 缓存是 chrome/win64/<ver>/...）。"""
    chrome = sorted(CACHE.glob("chrome/win64/*/chrome.exe"), reverse=True)
    driver = sorted(CACHE.glob("chromedriver/win64/*/chromedriver.exe"), reverse=True)
    if not chrome or not driver:
        raise SystemExit("selenium chrome/chromedriver not found under ~/.cache/selenium")
    return chrome[0], driver[0]


def _start_server(events: pathlib.Path) -> subprocess.Popen:
    if events.exists():
        events.unlink()
    out = open(REPO / "tmp" / "reload_server.out", "w", encoding="utf-8")
    err = open(REPO / "tmp" / "reload_server.err", "w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, str(REPO / "tools" / "serve_web.py"),
         "--port", str(PORT), "--root", "WebBuild",
         "--events", str(events.relative_to(REPO)).replace("\\", "/")],
        cwd=REPO, stdout=out, stderr=err)
    for _ in range(40):
        time.sleep(0.5)
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/ProjectKeynes.html", timeout=3) as r:
                if r.status == 200:
                    return proc
        except Exception:
            continue
    return proc


def _warmups(events: pathlib.Path) -> list[list[dict]]:
    """把所有 warmup 事件按"连续的一段"切分：一段 = 一次页面加载。"""
    if not events.exists():
        return []
    groups: list[list[dict]] = []
    cur: list[dict] = []
    for line in events.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("e") == "warmup_shader":
            cur.append(r)
        elif r.get("e") == "warmup":
            cur.append(r)
            groups.append(cur)
            cur = []
    if cur:
        groups.append(cur)
    return groups


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wait", type=float, default=60.0,
                    help="每次加载后等多久（要覆盖引擎启动 + 预热）")
    ap.add_argument("--url", default=f"http://127.0.0.1:{PORT}/ProjectKeynes.html")
    ap.add_argument("--events", default="tmp/ev_reload.jsonl")
    ap.add_argument("--profile", default="",
                    help="稳定的 --user-data-dir。给了它才能验证「真实用户的第二次访问」："
                         "同一 profile 下 D3D/驱动磁盘缓存可跨浏览器进程复用。")
    args = ap.parse_args()

    events = pathlib.Path(args.events)
    if not events.is_absolute():
        events = REPO / events
    chrome, driver_bin = _chrome_paths()
    server = _start_server(events)
    time.sleep(1.0)

    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.chrome.service import Service
    opts = Options()
    opts.binary_location = str(chrome)
    for flag in ["--window-size=1600,900", "--no-sandbox",
                 "--ignore-gpu-blocklist", "--force_high_performance_gpu",
                 "--disable-backgrounding-occluded-windows",
                 "--disable-renderer-backgrounding",
                 "--disable-background-timer-throttling"]:
        opts.add_argument(flag)
    if args.profile:
        prof = pathlib.Path(args.profile)
        prof.mkdir(parents=True, exist_ok=True)
        opts.add_argument(f"--user-data-dir={prof}")
    driver = webdriver.Chrome(service=Service(executable_path=str(driver_bin)), options=opts)
    try:
        for load in (1, 2):
            driver.get(args.url)
            print(f"[reload] load {load}: waiting {args.wait:.0f}s ...", flush=True)
            time.sleep(args.wait)
            got = _warmups(events)
            print(f"[reload]   warmup groups so far: {len(got)}", flush=True)
        groups = _warmups(events)
        print(f"\n=== {len(groups)} 次页面加载的预热对比 ===")
        for idx, g in enumerate(groups, 1):
            total = sum(int(r.get("dur", 0)) for r in g if r.get("e") == "warmup_shader")
            first = next((r for r in g if r.get("e") == "warmup_shader"), {})
            print(f"  load {idx}: shader_sum={total} ms   first={first.get('label')}"
                  f"={first.get('dur')} ms")
            top = sorted((r for r in g if r.get("e") == "warmup_shader"),
                         key=lambda r: -int(r.get("dur", 0)))[:4]
            for r in top:
                print(f"      {int(r.get('dur', 0)):7d} ms  {r.get('label')}")
    finally:
        try:
            driver.quit()
        except Exception:
            pass
        try:
            server.terminate()
            server.wait(timeout=10)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
