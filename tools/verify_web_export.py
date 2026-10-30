"""Boot-check the exported Godot Web build in a real browser.

Serves nothing itself: point it at a running static server (tools/serve_web.py).

    python tools/verify_web_export.py --url http://127.0.0.1:8060/ProjectKeynes.html

It launches headless Chrome (cached Selenium browser), waits for the engine to
create its canvas / log a boot line, dumps the browser console, and saves a
screenshot next to the log so the HUD can be eyeballed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service

CACHE = pathlib.Path.home() / ".cache" / "selenium"


def find_cached(pattern: str) -> pathlib.Path | None:
    hits = sorted(CACHE.glob(pattern), reverse=True)
    return hits[0] if hits else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8060/ProjectKeynes.html")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--out", default="artifacts/web_export_verify")
    ap.add_argument("--chrome", default="")
    ap.add_argument("--chromedriver", default="")
    args = ap.parse_args()

    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    chrome = pathlib.Path(args.chrome) if args.chrome else find_cached(
        "chrome/win64/*/chrome.exe")
    driver_bin = pathlib.Path(args.chromedriver) if args.chromedriver else find_cached(
        "chromedriver/win64/*/chromedriver.exe")
    if not chrome or not chrome.exists():
        print(f"no cached chrome found under {CACHE}", file=sys.stderr)
        return 2
    if not driver_bin or not driver_bin.exists():
        print(f"no cached chromedriver found under {CACHE}", file=sys.stderr)
        return 2

    opts = Options()
    opts.binary_location = str(chrome)
    for flag in (
        "--headless=new",
        "--window-size=1600,960",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--ignore-gpu-blocklist",
        "--enable-unsafe-swiftshader",
        "--use-angle=swiftshader",
        "--autoplay-policy=no-user-gesture-required",
        "--disable-features=Translate",
    ):
        opts.add_argument(flag)
    opts.set_capability("goog:loggingPrefs", {"browser": "ALL"})
    opts.set_capability("pageLoadStrategy", "eager")

    driver = webdriver.Chrome(service=Service(executable_path=str(driver_bin)), options=opts)
    driver.set_window_size(1600, 960)

    logs: list[dict] = []
    seen = 0
    booted = False
    started = time.time()
    try:
        driver.get(args.url)
        while time.time() - started < args.timeout:
            time.sleep(3.0)
            try:
                entries = driver.get_log("browser")
            except Exception:  # noqa: BLE001 - log retrieval is best effort
                entries = []
            if len(entries) > seen:
                logs.extend(entries[seen:])
                seen = len(entries)
            try:
                state = driver.execute_script(
                    """
                    const c = document.querySelector('canvas');
                    return {
                        canvas: c ? [c.width, c.height] : null,
                        title: document.title,
                        status: (document.querySelector('#status') || {}).textContent || '',
                        bodyText: (document.body.innerText || '').slice(0, 400)
                    };
                    """)
            except Exception:  # noqa: BLE001
                state = {}
            canvas = state.get("canvas")
            if canvas and canvas[0] > 8 and canvas[1] > 8:
                booted = True
            text = json.dumps(logs, ensure_ascii=False).lower()
            if "godot engine" in text or booted:
                # keep sampling a little longer so runtime errors surface too
                if booted and time.time() - started > 25:
                    break

        driver.save_screenshot(str(out_dir / "web_boot.png"))
        (out_dir / "console.json").write_text(
            json.dumps(logs, ensure_ascii=False, indent=2), encoding="utf-8")
        (out_dir / "state.json").write_text(
            json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    finally:
        driver.quit()

    print(json.dumps({"booted": booted, "elapsed": round(time.time() - started, 1),
                      "console_entries": len(logs), "state": state},
                     ensure_ascii=False, indent=2))
    for entry in logs:
        print(f"[{entry.get('level')}] {entry.get('message')}")
    return 0 if booted else 1


if __name__ == "__main__":
    raise SystemExit(main())
