#!/usr/bin/env python3
"""Web 导出 + 浏览器复验的一体化循环（供 agent 串行验证用）。

做四件事：
  1) 记下 tmp/web_events.jsonl 当前长度（这样只解析本次运行产生的事件）；
  2) 跑 Build-Web.cmd（默认跳过 native 重建，传 --native 则连 scons 一起跑）；
  3) 跑 tools/verify_web_session.py 打开真机浏览器会话；
  4) 解析本次新增事件，打印结论：进世界耗时、日历推进、fault/diag 关键字段。

用法：
  python tools/web_verify_cycle.py                 # 只导出 + 复验
  python tools/web_verify_cycle.py --native        # 先重建 wasm 再导出
  python tools/web_verify_cycle.py --seconds 120 --tag weather
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
EVENTS = REPO / "tmp" / "web_events.jsonl"
URL = "http://127.0.0.1:8060/ProjectKeynes.html"


def _events_len() -> int:
    return EVENTS.stat().st_size if EVENTS.exists() else 0


def _read_since(offset: int) -> list[dict]:
    if not EVENTS.exists():
        return []
    with EVENTS.open("rb") as handle:
        handle.seek(min(offset, EVENTS.stat().st_size))
        raw = handle.read()
    out: list[dict] = []
    for line in raw.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _reap(verbose: bool = False) -> None:
    """清掉绑定到本工具的 Chrome / chromedriver 残留。

    验证脚本被强杀（job_kill）时 atexit 不会跑，桌面上就会留下一个卡在 98% 的
    浏览器窗口。这里按命令行里是否含 8060 精确匹配，不碰用户自己的浏览器。
    """
    script = (
        "$ids = Get-CimInstance Win32_Process "
        "| Where-Object { $_.Name -in @('chrome.exe','chromedriver.exe') "
        "-and $_.CommandLine -match '8060' } "
        "| Select-Object -ExpandProperty ProcessId; "
        "foreach ($id in $ids) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }; "
        "$ids.Count"
    )
    try:
        done = subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            capture_output=True, text=True, timeout=60,
            encoding="utf-8", errors="replace")
        count = (done.stdout or "").strip().splitlines()
        if verbose and count:
            print(f"[cycle] reaped {count[-1]} stray browser processes")
    except Exception as exc:  # 清理失败不该影响验证
        if verbose:
            print(f"[cycle] reap skipped: {exc}")


def _build_web(with_native: bool) -> int:
    cmd = [str(REPO / "Build-Web.cmd")]
    if not with_native:
        cmd.append("skip-native")
    print(f"[cycle] build: {' '.join(cmd)}")
    # Build-Web.cmd 是 cmd 脚本，必须经 cmd /c
    return subprocess.call(["cmd", "/c", *cmd], cwd=REPO)


def _run_session(seconds: int, out_dir: pathlib.Path, stall_timeout: float,
                 speed_clicks: int = 0, target_day: int = 0,
                 url: str = URL, events: pathlib.Path = EVENTS,
                 no_click: bool = False) -> int:
    """跑一次真机会话，带**进程外硬看门狗**。

    子进程内部的静默检测依赖 Selenium 还能返回（`get_log`/截图在页面卡死时也可能
    自己挂住）。所以这里在父进程里再盯一遍事件文件：只要超过 stall_timeout 秒没有
    新事件，直接杀掉子进程 + 清理浏览器，绝不等待。

    返回 0 正常 / 2 判定卡死。
    """
    print(f"[cycle] session: {seconds}s (stall-timeout {stall_timeout}s) -> {out_dir.name}")
    hard_cap = seconds + 90
    cmd = [
        sys.executable,
        str(REPO / "tools" / "verify_web_session.py"),
        "--url", url,
        "--no-headless",
        "--seconds", str(seconds),
        "--max-seconds", str(seconds + 30),
        "--stall-timeout", str(stall_timeout),
        "--unpause",
        "--out", str(out_dir),
        "--events", str(events),
        *(["--no-click"] if no_click else []),
        "--speed-clicks", str(speed_clicks),
        "--target-day", str(target_day),
    ]
    started = time.time()
    proc = subprocess.Popen(cmd, cwd=REPO)
    size = events.stat().st_size if events.exists() else -1
    grown = time.time()
    # 启动阶段（页面加载 + wasm 实例化 + 生成世界）本来就没有事件，不能算"静默"。
    # 只有出现过至少一次事件之后，静默才意味着卡死；启动阶段由 boot_grace 兜底。
    saw_any_event = False
    boot_grace = max(120.0, stall_timeout * 3.0)
    try:
        while proc.poll() is None:
            time.sleep(2.0)
            now_size = events.stat().st_size if events.exists() else -1
            if now_size != size:
                size = now_size
                grown = time.time()
                saw_any_event = True
            silent = time.time() - grown
            elapsed = time.time() - started
            if saw_any_event and silent >= stall_timeout:
                print(f"[cycle] 看门狗：事件流静默 {int(silent)}s，强杀会话")
                _kill_process_tree(proc)
                _dump_tail(5, events)
                return 2
            if not saw_any_event and elapsed >= boot_grace:
                print(f"[cycle] 看门狗：启动 {int(elapsed)}s 仍无任何事件（窗口 {int(boot_grace)}s），强杀会话")
                _kill_process_tree(proc)
                _dump_tail(5, events)
                return 2
            if elapsed >= hard_cap:
                print(f"[cycle] 看门狗：超过硬上限 {hard_cap}s，强杀会话")
                _kill_process_tree(proc)
                _dump_tail(5, events)
                return 2
        return proc.returncode
    finally:
        if proc.poll() is None:
            _kill_process_tree(proc)


def _kill_process_tree(proc: subprocess.Popen) -> None:
    """杀进程树，并且**等到它真的死**：taskkill 只发信号，不等就会留下孤儿进程。"""
    try:
        if sys.platform.startswith("win"):
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                           capture_output=True, timeout=30)
        else:
            proc.kill()
    except Exception:
        pass
    try:
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass


def _dump_tail(count: int, events: pathlib.Path = EVENTS) -> None:
    try:
        lines = events.read_text(encoding="utf-8", errors="replace").splitlines()[-count:]
    except OSError:
        return
    print("[cycle] 卡死前最后事件：")
    for line in lines:
        print(f"    {line[:160]}")


def _summarize(events: list[dict]) -> None:
    ready = next((e for e in events if e.get("e") == "ready"), None)
    day0 = next((e for e in events if e.get("e") == "day"), None)
    if ready and day0:
        print(f"[result] 进世界: {ready['ms'] - day0['ms']} ms "
              f"(day0 {day0['ms']} -> ready {ready['ms']})")
    elif ready:
        print(f"[result] ready at {ready['ms']} ms（缺 day0 基线）")
    else:
        print("[result] 没有 ready 事件（未进世界）")

    days = [e for e in events if e.get("e") == "day"]
    if days:
        series = [int(e.get("day", -1)) for e in days]
        print(f"[result] day 事件 {len(days)} 个，范围 {min(series)}..{max(series)}")
        print(f"[result] day 序列尾部: {series[-8:]}")

    beats = [e for e in events if e.get("e") == "beat"]
    if beats:
        last = beats[-1]
        print(f"[result] 末次 beat: day={last.get('day')} fast_ticks={last.get('fast_ticks')} "
              f"paused={last.get('paused')} worker={last.get('worker')} "
              f"speed={last.get('speed')} frames={last.get('frames')}")
        gaps = []
        for prev, cur in zip(beats, beats[1:]):
            gap = int(cur.get("ms", 0)) - int(prev.get("ms", 0))
            if gap >= 2000:
                gaps.append((gap, int(cur.get("frames", 0))))
        if gaps:
            worst = max(gaps)
            print(f"[result] 最大帧间隔 {worst[0]} ms（累计 {worst[1]} 帧）")
        # 日历速率：首末 beat 之间的 day 增量 / 墙钟秒
        first, final = beats[0], beats[-1]
        span_s = (int(final.get("ms", 0)) - int(first.get("ms", 0))) / 1000.0
        grown = int(final.get("day", 0)) - int(first.get("day", 0))
        if span_s > 0 and grown > 0:
            print(f"[result] 日历速率 {grown} 天 / {span_s:.1f}s = {grown / span_s:.2f} 天/秒"
                  f"（day {first.get('day')} → {final.get('day')}）")
        speeds = sorted({float(b.get("speed", 0.0)) for b in beats})
        print(f"[result] 出现过的速度档: {speeds}")

    diags = [e for e in events if e.get("e") == "diag"]
    if diags:
        d = diags[-1]
        keys = ["fault_code", "simulation_thread_mode", "simulation_worker_ready",
                "graph_coverage_state", "domain_authority_planned_mask",
                "domain_authority_committed_mask", "domain_authority_fallback_reason",
                "missing_domain_mask", "pod_completed_domain_mask"]
        parts = [f"{k}={d.get(k)}" for k in keys if k in d]
        print("[result] diag: " + " ".join(parts))
    else:
        print("[result] 没有 diag 事件")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true", help="先重建 wasm（很慢）")
    parser.add_argument("--seconds", type=int, default=75)
    parser.add_argument("--stall-timeout", type=float, default=40.0,
                        help="事件流静默超过这个秒数即判定卡死（不干等）")
    parser.add_argument("--speed-clicks", type=int, default=0,
                        help="进世界后点几次速度按钮（HUD 档位 1/2/5/10，3 次=10×）")
    parser.add_argument("--target-day", type=int, default=0,
                        help="达到该 game day 即判定成功并提前收尾（0=不启用）")
    parser.add_argument("--tag", default="cycle")
    parser.add_argument("--no-click", action="store_true",
                        help="autotest URL 模式：不点画布，只看事件流")
    parser.add_argument("--url", default=URL)
    parser.add_argument("--events", default=str(EVENTS))
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()

    offset = _events_len()
    _reap(verbose=True)
    if not args.skip_build:
        code = _build_web(args.native)
        if code != 0:
            print(f"[cycle] build 失败 exit={code}")
            return code

    out_dir = REPO / "artifacts" / f"web_{args.tag}_{time.strftime('%H%M%S')}"
    try:
        code = _run_session(args.seconds, out_dir, args.stall_timeout,
                            args.speed_clicks, args.target_day,
                            args.url, pathlib.Path(args.events),
                            args.no_click)
    finally:
        _reap(verbose=True)
    if code == 2:
        print("[cycle] 判定卡死（已强杀并清理），下面只解析卡死前的事件")
    elif code != 0:
        print(f"[cycle] session 退出码 {code}（继续解析已产生的事件）")

    events = _read_since(offset)
    print(f"[cycle] 本次新增事件 {len(events)} 条")
    _summarize(events)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
