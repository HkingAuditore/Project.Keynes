"""Drive the exported Godot Web build through a real new-game session.

Complements tools/verify_web_export.py (which only checks that the page boots):
this script clicks 新游戏 → 开始游戏 on the canvas, watches the console while the
world loads, and writes screenshots so the in-game HUD can be eyeballed.

    python tools/verify_web_session.py --url http://127.0.0.1:8060/ProjectKeynes.html

Notes
-----
* The Godot UI is canvas-rendered, so clicks are canvas-relative fractions, not
  DOM selectors. 新游戏 ≈ (0.16, 0.43), 开始游戏 ≈ (0.919, 0.91) of the canvas.
* A threads-enabled Web build blocks the browser main thread while the native
  simulation host does work, so give it time; SwiftShader (software WebGL) is
  far too slow to finish loading — run windowed on a real GPU instead:
  `--no-headless`.
* Chrome/Edge must be reachable through the Selenium cache; pass --chrome /
  --chromedriver to override.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import time

from selenium import webdriver
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service

CACHE = pathlib.Path.home() / ".cache" / "selenium"
NEW_GAME = (0.16, 0.43)
START_GAME = (0.919, 0.909)
INTEREST = re.compile(
    r"loading-substep|loading-renderer-step|native_generation|native_daily|"
    r"MapGenerator|MapBaker|ERROR|WARNING: shader|Build configuration|renderer",
    re.IGNORECASE)


def newest(pattern: str) -> pathlib.Path | None:
    hits = sorted(CACHE.glob(pattern), reverse=True)
    return hits[0] if hits else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8060/ProjectKeynes.html")
    ap.add_argument("--out", default="artifacts/web_export_verify")
    ap.add_argument("--seconds", type=float, default=240.0)
    ap.add_argument("--no-headless", action="store_true",
                    help="run a visible window on the real GPU (needed for a full load)")
    ap.add_argument("--software-gl", action="store_true",
                    help="force SwiftShader; boot checks only, world load will crawl")
    ap.add_argument("--chrome", default="")
    ap.add_argument("--chromedriver", default="")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    chrome = pathlib.Path(args.chrome) if args.chrome else newest("chrome/win64/*/chrome.exe")
    driver_bin = pathlib.Path(args.chromedriver) if args.chromedriver \
        else newest("chromedriver/win64/*/chromedriver.exe")
    if not chrome or not chrome.exists() or not driver_bin or not driver_bin.exists():
        print(f"no cached Chrome/chromedriver under {CACHE}; pass --chrome/--chromedriver")
        return 2

    opts = Options()
    opts.binary_location = str(chrome)
    flags = ["--window-size=1600,900", "--no-sandbox", "--disable-dev-shm-usage",
             "--ignore-gpu-blocklist", "--autoplay-policy=no-user-gesture-required"]
    if not args.no_headless:
        flags.insert(0, "--headless=new")
    if args.software_gl:
        flags += ["--enable-unsafe-swiftshader", "--use-angle=swiftshader"]
    for flag in flags:
        opts.add_argument(flag)
    opts.set_capability("goog:loggingPrefs", {"browser": "ALL"})

    driver = webdriver.Chrome(service=Service(executable_path=str(driver_bin)), options=opts)
    driver.set_window_size(1600, 900)
    driver.get(args.url)

    rect = None
    deadline = time.time() + 180
    while time.time() < deadline:
        rect = driver.execute_script(
            "const c=document.querySelector('canvas');"
            "if(!c) return null;"
            "const r=c.getBoundingClientRect();"
            "return {x:r.x,y:r.y,width:r.width,height:r.height};")
        if rect and rect["width"] > 600:
            break
        time.sleep(1)
    if not rect:
        print("no canvas appeared")
        driver.quit()
        return 1

    time.sleep(12)  # menu intro
    rect = driver.execute_script(
        "const c=document.querySelector('canvas');const r=c.getBoundingClientRect();"
        "return {x:r.x,y:r.y,width:r.width,height:r.height};")
    renderer = driver.execute_script(
        "const c=document.querySelector('canvas');"
        "const gl=c.getContext('webgl2')||c.getContext('webgl');"
        "if(!gl) return 'no-webgl';"
        "const e=gl.getExtension('WEBGL_debug_renderer_info');"
        "return e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);")
    print(f"canvas={rect}\nrenderer={renderer}", flush=True)

    canvas = driver.find_element("css selector", "canvas")

    def click(fx: float, fy: float) -> None:
        dx = rect["width"] * fx - rect["width"] / 2
        dy = rect["height"] * fy - rect["height"] / 2
        ActionChains(driver).move_to_element(canvas).move_by_offset(dx, dy).click().perform()
        time.sleep(0.8)

    seen = 0
    all_logs: list[dict] = []

    def pump(tag: str) -> None:
        nonlocal seen
        try:
            entries = driver.get_log("browser")
        except Exception:  # noqa: BLE001 - a crashed tab has no log buffer
            return
        for entry in entries[seen:]:
            msg = entry.get("message", "")
            all_logs.append(entry)
            if INTEREST.search(msg):
                safe = msg[:220]
                try:
                    print(f"{tag} [{entry.get('level')}] {safe}", flush=True)
                except UnicodeEncodeError:
                    print(f"{tag} [{entry.get('level')}] <unencodable>", flush=True)
        seen = len(entries)

    t0 = time.time()
    driver.save_screenshot(str(out / "session_00_menu.png"))
    pump("boot")

    click(*NEW_GAME)
    time.sleep(3)
    driver.save_screenshot(str(out / "session_01_new_game.png"))
    click(*START_GAME)
    print("clicked 开始游戏", flush=True)

    last_shot = 0.0
    while time.time() - t0 < args.seconds:
        time.sleep(5)
        pump(f"t={int(time.time() - t0):3d}s")
        elapsed = time.time() - t0
        if elapsed - last_shot >= 60:
            last_shot = elapsed
            driver.save_screenshot(str(out / f"session_{int(elapsed):03d}s.png"))

    driver.save_screenshot(str(out / "session_final.png"))
    (out / "session_console.json").write_text(
        json.dumps(all_logs, ensure_ascii=False, indent=2), encoding="utf-8")
    driver.quit()
    print("done", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
