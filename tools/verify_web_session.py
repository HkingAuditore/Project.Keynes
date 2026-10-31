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
import atexit
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


def _tail_lines(path: pathlib.Path, count: int) -> list[str]:
    """只读文件尾部，避免每轮把整份事件日志读进内存。"""
    try:
        with path.open("rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - 65536))
            raw = handle.read().decode("utf-8", "replace")
    except OSError:
        return ["<cannot read events>"]
    return raw.splitlines()[-count:]


def _latest_beat_state(path: pathlib.Path) -> tuple[int, float]:
    """返回 (最新 beat 的 day, speed)。"""
    day = -1
    speed = 0.0
    for line in _tail_lines(path, 200):
        if '"e": "beat"' not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        day = int(obj.get("day", -1))
        speed = float(obj.get("speed", 0.0))
    return day, speed

def _drain_alerts(driver) -> list[str]:
    """把页面上挂着的 JS alert 取下来（内容同时返回，便于诊断）。

    Godot 在 WebGL2 不可用时会 alert("Your browser seems not to support WebGL 2.")，
    这会让后续每个 execute_script 直接抛 UnexpectedAlertPresentException。
    """
    texts: list[str] = []
    try:
        from selenium.common.exceptions import NoAlertPresentException
    except Exception:
        return texts
    for _ in range(4):
        try:
            alert = driver.switch_to.alert
            texts.append(alert.text)
            alert.accept()
        except NoAlertPresentException:
            break
        except Exception:
            break
    return texts


def _save_profile(driver, out: pathlib.Path) -> None:
    """把 Chrome Profiler 结果落盘（卡死路径也必须调用，否则什么都拿不到）。"""
    try:
        prof = driver.execute_cdp_cmd("Profiler.stop", {})
        (out / "profile.cpuprofile").write_text(
            json.dumps(prof.get("profile", {}), ensure_ascii=False), encoding="utf-8")
        print("PROFILER: saved profile.cpuprofile", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"PROFILER: stop failed {exc}", flush=True)


def _quit_quietly(driver) -> None:
    """关浏览器时吞掉一切异常：清理阶段不该再把进程带崩。"""
    try:
        driver.quit()
    except Exception:
        pass

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8060/ProjectKeynes.html")
    ap.add_argument("--out", default="artifacts/web_export_verify")
    ap.add_argument("--seconds", type=float, default=240.0)
    ap.add_argument("--events", default="tmp/web_events.jsonl",
                    help="事件通道文件（serve_web.py 写入）；用于等 ready 后再点开始")
    ap.add_argument("--unpause", action="store_true",
                    help="等 web 端 ready 事件后点一次顶栏的开始/暂停按钮")
    ap.add_argument("--unpause-at", default="0.851,0.066",
                    help="开始/暂停按钮的 canvas 相对坐标 fx,fy")
    ap.add_argument("--no-headless", action="store_true",
                    help="run a visible window on the real GPU (needed for a full load)")
    ap.add_argument("--software-gl", action="store_true",
                    help="force SwiftShader; boot checks only, world load will crawl")
    ap.add_argument("--user-data-dir", default="tmp/chrome_profile_pk",
                    help="稳定的 --user-data-dir。默认给一个持久目录：浏览器/驱动的 shader "
                         "磁盘缓存存在 profile 里、跨进程复用，所以「冷 profile 首次」与"
                         "「热 profile」的预热耗时差一个量级（实测 30 102 vs 2 548 ms）。"
                         "传空串 = 每次全新临时 profile（只用于测冷启动）。")
    ap.add_argument("--gpu", default="high", choices=["high", "low", "default"],
                    help="混合显卡机器上钉住用哪块 GPU（默认 high = 独显）。"
                         "不钉住的话 Chrome 会在两轮之间换卡，shader 编译耗时差一个量级，"
                         "两轮数据不可比。事件流/控制台里的 `renderer=` 行会记录实际用的卡。")
    ap.add_argument("--chrome", default="")
    ap.add_argument("--chromedriver", default="")
    ap.add_argument("--stall-timeout", type=float, default=40.0,
                    help="事件流静默超过这个秒数就判定卡死：截图、打印现场、退出（不再干等）")
    ap.add_argument("--max-seconds", type=float, default=240.0,
                    help="整轮硬上限；到点无条件收尾，绝不无限期占着浏览器")
    ap.add_argument("--speed-clicks", type=int, default=0,
                    help="进世界后点几次速度按钮（HUD 档位 1/2/5/10，3 次=10×）")
    ap.add_argument("--speed-at", default="0.897,0.028", help="速度按钮的画布相对坐标")
    ap.add_argument("--profile", action="store_true",
                    help="用 Chrome DevTools Profiler 采样，输出 profile.cpuprofile（定位卡帧）")
    ap.add_argument("--no-click", action="store_true",
                    help="URL 驱动的 autotest 模式：完全不点画布，只观察事件流")
    ap.add_argument("--target-day", type=int, default=0,
                    help="达到这个 game day 就判定成功并提前收尾（0=不启用）")
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
             "--ignore-gpu-blocklist", "--autoplay-policy=no-user-gesture-required",
             # Chrome 会把"被其它窗口遮挡"的页面降频/冻结 rAF：本地跑验证时浏览器
             # 几乎立刻被终端盖住，于是出现 30~45 秒完全不出帧的"假卡死"。
             "--disable-backgrounding-occluded-windows",
             "--disable-renderer-backgrounding",
             "--disable-background-timer-throttling"]
    # [GPU 钉死] 这台机器是混合显卡：同一份包实测过 ANGLE 落在 Intel UHD 770 与
    # NVIDIA RTX 4080 两种情形，而 shader 首次编译耗时差一个量级、加载期单帧
    # 也差 4 倍（125ms vs 31ms）。不钉住 GPU，两轮数据根本不可比。
    if args.gpu == "high":
        flags += ["--force_high_performance_gpu"]
    elif args.gpu == "low":
        flags += ["--force_low_power_gpu"]
    if not args.no_headless:
        flags.insert(0, "--headless=new")
    if args.software_gl:
        flags += ["--enable-unsafe-swiftshader", "--use-angle=swiftshader"]
    if args.user_data_dir:
        prof = pathlib.Path(args.user_data_dir)
        if not prof.is_absolute():
            prof = pathlib.Path(__file__).resolve().parent.parent / prof
        prof.mkdir(parents=True, exist_ok=True)
        flags.append(f"--user-data-dir={prof}")
    for flag in flags:
        opts.add_argument(flag)
    opts.set_capability("goog:loggingPrefs", {"browser": "ALL"})
    # 页面可能弹出 JS alert（例如 "Your browser seems not to support WebGL 2"）。
    # 有 alert 时任何 execute_script 都会抛 UnexpectedAlertPresentException，
    # 以前表现为 chromedriver 崩溃 + 永远没有 canvas。
    opts.set_capability("unhandledPromptBehavior", "accept")

    driver = webdriver.Chrome(service=Service(executable_path=str(driver_bin)), options=opts)
    # 任何退出路径（含异常/未捕获栈）都必须关掉浏览器：以前异常退出会在桌面上
    # 留下一个卡在 98% 的 Chrome 窗口。
    atexit.register(_quit_quietly, driver)
    driver.set_window_size(1600, 900)
    driver.get(args.url)

    rect = None
    alerts_seen: list[str] = []
    deadline = time.time() + 180
    while time.time() < deadline:
        alerts_seen += _drain_alerts(driver)
        if alerts_seen:
            print(f"ALERT: {alerts_seen[-1]}", flush=True)
        rect = driver.execute_script(
            "const c=document.querySelector('canvas');"
            "if(!c) return null;"
            "const r=c.getBoundingClientRect();"
            "return {x:r.x,y:r.y,width:r.width,height:r.height};")
        if rect and rect["width"] > 600:
            break
        time.sleep(1)
    if not rect:
        # 失败也要留证据：截图 + 控制台全量，否则只能看到一句 no canvas。
        print("no canvas appeared", flush=True)
        try:
            driver.save_screenshot(str(out / "no_canvas.png"))
        except Exception:
            pass
        try:
            entries = driver.get_log("browser")
        except Exception:
            entries = []
        for entry in entries:
            print(f"boot [{entry.get('level')}] {str(entry.get('message', ''))[:220]}", flush=True)
        (out / "session_console.json").write_text(
            __import__("json").dumps(entries, ensure_ascii=False, indent=2),
            encoding="utf-8")
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

    if not args.no_click:
        click(*NEW_GAME)
        time.sleep(3)
    driver.save_screenshot(str(out / "session_01_new_game.png"))

    # 「开始游戏」的点击是画布相对坐标，窗口尺寸/DPI 变化时会擦边点空。
    # 点完必须验证真的开工（事件流有新增），否则重点一次再放弃。
    boot_events = pathlib.Path(args.events)

    def _boot_size() -> int:
        try:
            return boot_events.stat().st_size if boot_events.exists() else -1
        except OSError:
            return -1

    for attempt in (() if args.no_click else (1, 2)):
        before = _boot_size()
        click(*START_GAME)
        print(f"clicked 开始游戏 (attempt {attempt})", flush=True)
        waited = 0.0
        while waited < 10.0:
            time.sleep(1.0)
            waited += 1.0
            pump("boot-wait")
            if _boot_size() > before:
                break
        else:
            driver.save_screenshot(str(out / f"start_game_miss_{attempt}.png"))
            print(f"开始游戏 点击未生效（第 {attempt} 次），重试", flush=True)
            continue
        break

    if args.unpause and not args.no_click:
        events_path = pathlib.Path(args.events)

        def _events_size() -> int:
            try:
                return events_path.stat().st_size if events_path.exists() else -1
            except OSError:
                return -1

        def _last_lines(count: int = 4) -> str:
            try:
                data = events_path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                return "<cannot read events>"
            return "\n".join(f"    {line[:160]}" for line in data[-count:])

        deadline = time.time() + min(args.max_seconds, 180.0)
        ready = False
        shot_idx = 0
        last_size = _events_size()
        last_growth = time.time()
        while time.time() < deadline:
            time.sleep(2.0)
            pump("wait-ready")
            shot_idx += 1
            if shot_idx % 5 == 0:
                driver.save_screenshot(str(out / f"ready_wait_{shot_idx:03d}.png"))
            size = _events_size()
            if size != last_size:
                last_size = size
                last_growth = time.time()
            elif time.time() - last_growth >= args.stall_timeout:
                driver.save_screenshot(str(out / "HUNG_ready_wait.png"))
                print(f"HUNG: 事件流静默 {int(time.time() - last_growth)}s，主线程卡住。"
                      f"最后一次事件：", flush=True)
                print(_last_lines(), flush=True)
                print("（不再等待，直接收尾）", flush=True)
                return 2
            try:
                text = events_path.read_text(encoding="utf-8") if events_path.exists() else ""
            except OSError:
                text = ""
            if '"e": "ready"' in text or '"e":"ready"' in text:
                ready = True
                break
        if ready:
            time.sleep(2.0)
            fx, fy = (float(v) for v in args.unpause_at.split(","))
            click(fx, fy)
            print(f"clicked start/play at ({fx},{fy}) after ready", flush=True)
            if args.speed_clicks > 0:
                sx, sy = (float(v) for v in args.speed_at.split(","))
                for step in range(args.speed_clicks):
                    click(sx, sy)
                    time.sleep(1.2)
                    print(f"clicked speed ({step + 1}/{args.speed_clicks})", flush=True)
        else:
            print("ready event not seen; not clicking play", flush=True)

    last_shot = 0.0
    if args.profile:
        try:
            driver.execute_cdp_cmd("Profiler.enable", {})
            driver.execute_cdp_cmd("Profiler.setSamplingInterval", {"interval": 1000})
            driver.execute_cdp_cmd("Profiler.start", {})
            print("PROFILER: started", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"PROFILER: start failed {exc}", flush=True)
            args.profile = False
    run_events = pathlib.Path(args.events)
    run_size = run_events.stat().st_size if run_events.exists() else -1
    run_growth = time.time()
    while time.time() - t0 < min(args.seconds, args.max_seconds):
        time.sleep(5)
        pump(f"t={int(time.time() - t0):3d}s")
        elapsed = time.time() - t0
        # 长帧往往持续 30-45s，60s 一次的截图可能整段错过；改成 10s 一次，
        # 卡顿期间的画面（弹窗？黑屏？加载条？）就能被抓到。
        if elapsed - last_shot >= 10:
            last_shot = elapsed
            driver.save_screenshot(str(out / f"session_{int(elapsed):03d}s.png"))
        # 事件流静默 = 主线程卡住（beats 每 2s 一次）。不干等，立刻判定并收尾。
        now_size = run_events.stat().st_size if run_events.exists() else -1
        if now_size != run_size:
            run_size = now_size
            run_growth = time.time()
        elif time.time() - run_growth >= args.stall_timeout:
            driver.save_screenshot(str(out / "HUNG_session.png"))
            print(f"HUNG: 进世界后事件流静默 {int(time.time() - run_growth)}s，主线程卡住。"
                  f"最后一次事件：", flush=True)
            if getattr(args, "profile", False):
                _save_profile(driver, out)
            for line in _tail_lines(run_events, 4):
                print(f"    {line[:160]}", flush=True)
            (out / "session_console.json").write_text(
                json.dumps(all_logs, ensure_ascii=False, indent=2), encoding="utf-8")
            return 2
        # 目标天数达成 → 提前成功收尾（soak 验收用）
        if args.target_day > 0:
            reached, speed = _latest_beat_state(run_events)
            if reached >= args.target_day:
                driver.save_screenshot(str(out / "session_target_day.png"))
                print(f"TARGET: reached day {reached} (>= {args.target_day}) "
                      f"at {int(time.time() - t0)}s, speed={speed}", flush=True)
                (out / "session_console.json").write_text(
                    json.dumps(all_logs, ensure_ascii=False, indent=2), encoding="utf-8")
                return 0

    if getattr(args, "profile", False):
        try:
            prof = driver.execute_cdp_cmd("Profiler.stop", {})
            (out / "profile.cpuprofile").write_text(
                json.dumps(prof.get("profile", {}), ensure_ascii=False), encoding="utf-8")
            print("PROFILER: saved profile.cpuprofile", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"PROFILER: stop failed {exc}", flush=True)
    driver.save_screenshot(str(out / "session_final.png"))
    (out / "session_console.json").write_text(
        json.dumps(all_logs, ensure_ascii=False, indent=2), encoding="utf-8")
    driver.quit()
    print("done", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
