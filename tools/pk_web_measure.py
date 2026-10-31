#!/usr/bin/env python3
"""Project.Keynes Web 性能测量闭环（唯一入口，避免手工拉服务/残留浏览器互相干扰）。

做五件事，全部幂等：
  1) 杀掉上一次残留（只杀 **Selenium 自带** chrome/chromedriver 与 serve_web/verify_web
     的 python 进程，绝不碰用户自己的浏览器）；
  2) 清空事件文件；
  3) 起一个全新的 serve_web.py（端口固定），确认 HTTP 200；
  4) 用 verify_web_session.py 跑一次 URL 驱动的 autotest 会话（进程外看门狗）；
  5) 解析事件流，打印本次的关键指标。

用法：
  python tools/pk_web_measure.py --days 60 --speed 10 --tag baseline
  python tools/pk_web_measure.py --days 365 --speed 10 --seconds 900 --tag year
  python tools/pk_web_measure.py --skip-session --events tmp/ev_foo.jsonl   # 只解析已有事件
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
PORT = 8060
EVENTS = REPO / "tmp" / "ev_measure.jsonl"
ARTIFACTS = REPO / "artifacts"


# ─── 清理 ────────────────────────────────────────────────────────────────────
def _kill_leftovers() -> None:
    ps = r"""
$killed = 0
Get-CimInstance Win32_Process | Where-Object {
  ($_.Name -in @('chrome.exe','chromedriver.exe') -and $_.ExecutablePath -match 'selenium')
} | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {} }
Get-CimInstance Win32_Process | Where-Object {
  $_.Name -eq 'python.exe' -and $_.CommandLine -match 'serve_web|verify_web|web_verify_cycle'
} | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {} }
$killed
"""
    try:
        subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       capture_output=True, text=True, timeout=90)
    except Exception as exc:
        print(f"[measure] cleanup skipped: {exc}")
    time.sleep(1.5)


# ─── 服务器 ──────────────────────────────────────────────────────────────────
def _start_server(events: pathlib.Path, port: int) -> subprocess.Popen:
    events.parent.mkdir(parents=True, exist_ok=True)
    if events.exists():
        events.unlink()
    out = open(REPO / "tmp" / "measure_server.out", "w", encoding="utf-8")
    err = open(REPO / "tmp" / "measure_server.err", "w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, str(REPO / "tools" / "serve_web.py"),
         "--port", str(port), "--root", "WebBuild",
         "--events", str(events.relative_to(REPO)).replace("\\", "/")],
        cwd=REPO, stdout=out, stderr=err)
    url = f"http://127.0.0.1:{port}/ProjectKeynes.html"
    for _ in range(40):
        time.sleep(0.5)
        if proc.poll() is not None:
            print("[measure] server exited early; see tmp/measure_server.err")
            return proc
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                if resp.status == 200:
                    print(f"[measure] server ready on {port}")
                    return proc
        except Exception:
            continue
    print("[measure] server did not answer HTTP 200 in 20s")
    return proc


# ─── 会话 ────────────────────────────────────────────────────────────────────
def _run_session(url: str, seconds: int, stall_timeout: float,
                 out_dir: pathlib.Path, events: pathlib.Path,
                 profile: str = "") -> int:
    cmd = [
        sys.executable, str(REPO / "tools" / "verify_web_session.py"),
        "--url", url,
        "--no-headless",
        "--seconds", str(seconds),
        "--max-seconds", str(seconds + 30),
        "--stall-timeout", str(stall_timeout),
        "--unpause",
        "--out", str(out_dir),
        "--events", str(events),
        "--no-click",
        "--user-data-dir", profile,
    ]
    print(f"[measure] session: url={url} seconds={seconds} stall={stall_timeout}s")
    proc = subprocess.Popen(cmd, cwd=REPO)
    t0 = time.time()
    last_size = events.stat().st_size if events.exists() else -1
    grown = time.time()
    saw = False
    boot_grace = max(150.0, stall_timeout * 3.0)
    try:
        while proc.poll() is None:
            time.sleep(2.0)
            size = events.stat().st_size if events.exists() else -1
            if size != last_size:
                last_size = size
                grown = time.time()
                saw = True
            silent = time.time() - grown
            elapsed = time.time() - t0
            if saw and silent >= stall_timeout:
                print(f"[measure] watchdog: events silent {int(silent)}s -> kill")
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                               capture_output=True, timeout=30)
                return 2
            if not saw and elapsed >= boot_grace:
                print(f"[measure] watchdog: no events in {int(elapsed)}s -> kill")
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                               capture_output=True, timeout=30)
                return 2
        return proc.returncode or 0
    finally:
        if proc.poll() is None:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                           capture_output=True, timeout=30)


# ─── 解析 ────────────────────────────────────────────────────────────────────
def _read(events: pathlib.Path) -> list[dict]:
    if not events.exists():
        return []
    out = []
    for line in events.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _report(rows: list[dict]) -> None:
    if not rows:
        print("[report] 没有事件")
        return
    by = {}
    for r in rows:
        by.setdefault(r.get("e"), []).append(r)

    # 1. shader 预热（分项 + 合计 + 指纹对账）
    per = by.get("warmup_shader", [])
    if per:
        print("\n=== shader warmup (per shader) ===")
        total = 0
        for r in per:
            dur = int(r.get("dur", 0))
            total += dur
            print(f"  {dur:7d} ms  {str(r.get('label')):24s} fp={r.get('fp')}")
        print(f"  {total:7d} ms  --- sum")
    warm = by.get("warmup", [])
    if warm:
        print(f"  warmup total: {warm[-1].get('shaders')} shaders, "
              f"sum={warm[-1].get('sum_shader_ms', warm[-1].get('dur'))} ms")
    plan = by.get("warmup_plan", [])
    variants = by.get("material_variant", [])
    if plan:
        warned = {e.get("label"): e.get("fp") for e in plan[-1].get("entries", [])}
        print("\n=== variant fingerprint reconciliation ===")
        if not variants:
            print("  no material_variant events (runtime side not instrumented yet)")
        seen = set()
        for v in variants:
            label, fp = v.get("label"), v.get("fp")
            if label in seen:
                continue
            seen.add(label)
            hit = warned.get(label) == fp
            print(f"  {'HIT ' if hit else 'MISS'} {str(label):24s} fp={fp} "
                  f"warmed={warned.get(label)}")

    # 2. 进世界耗时（页面→ready 与 点开始→ready 分开看）
    # 目标①的正确口径：引擎启动 → 主菜单可见（不含世界生成、不含预热，因为预热
    # 是后台跑的且菜单不等它）。
    boot = by.get("boot", [])
    menu = by.get("menu_ready", [])
    if menu:
        print("\n=== 主菜单（目标①口径） ===")
        print(f"  引擎启动 -> 菜单可见: {int(menu[-1].get('ms', 0)) / 1000.0:.1f} s"
              f"   (warmup_done={menu[-1].get('warmup_done')}"
              f" done={menu[-1].get('warmup_done_count')})")
        if boot:
            print(f"  其中 引擎/wasm 启动: {int(boot[-1].get('ms', 0)) / 1000.0:.1f} s")
    st = by.get("autotest_start", [])
    rd = by.get("autotest_ready", [])
    if rd:
        print("\n=== enter new game ===")
        r = rd[-1]
        print(f"  page -> in-world : {int(r.get('ms', 0)) / 1000.0:.1f} s")
        if st:
            print(f"  click -> in-world: "
                  f"{(int(r.get('ms', 0)) - int(st[-1].get('ms', 0))) / 1000.0:.1f} s")
        print(f"  (autotest_ready.elapsed_ms={r.get('elapsed_ms')} measured from page start)")

    # 3. 卡顿（>2s 的帧 + slow_frame_trace 的标记）
    slow = [r for r in by.get("slow_frame_trace", []) if int(r.get("dt", 0)) >= 2000]
    print("\n=== 长帧 ===")
    if slow:
        for r in slow:
            print(f"  dt={r.get('dt')} ms  marks={r.get('marks')}")
    else:
        print("  无 >2s 长帧")
    frames = [r for r in by.get("frame", []) if int(r.get("dt", 0)) >= 2000]
    for r in frames:
        print(f"  frame i={r.get('i')} day={r.get('day')} dt={r.get('dt')} ms "
              f"proc={r.get('proc')} setup={r.get('setup')} objs={r.get('objs')}")

    # 4. 日历速率
    beats = by.get("beat", [])
    if beats:
        first, last = beats[0], beats[-1]
        span = (int(last.get("ms", 0)) - int(first.get("ms", 0))) / 1000.0
        days = int(last.get("day", 0)) - int(first.get("day", 0))
        print("\n=== 日历 ===")
        print(f"  末次 beat: day={last.get('day')} fast_ticks={last.get('fast_ticks')} "
              f"paused={last.get('paused')} speed={last.get('speed')} "
              f"frames={last.get('frames')}")
        if span > 0 and days > 0:
            print(f"  速率 {days} 天 / {span:.1f}s = {days / span:.2f} 天/秒")
        peaks = []
        for a, b in zip(beats, beats[1:]):
            gap = int(b.get("ms", 0)) - int(a.get("ms", 0))
            peak = int(b.get("frames", 0)) - int(a.get("frames", 0))
            if gap >= 2500:
                peaks.append((gap, peak))
        if peaks:
            worst = max(peaks)
            print(f"  beat 间隔最大 {worst[0]} ms（其间 {worst[1]} 帧）")
        else:
            print("  beat 间隔恒定（无 >2.5s 停顿）")

    passed = by.get("autotest_pass", [])
    failed = by.get("autotest_fail", [])
    print("\n=== 结果 ===")
    if passed:
        p = passed[-1]
        print(f"  PASS day={p.get('day')} days_per_s={p.get('days_per_s')} "
              f"wall_s={p.get('wall_s')}")
    if failed:
        print(f"  FAIL {failed[-1]}")
    # 5. 故障
    diags = by.get("diag", [])
    if diags:
        d = diags[-1]
        keys = ["fault_code", "simulation_thread_mode", "simulation_worker_ready",
                "graph_coverage_state", "missing_domain_mask",
                "domain_authority_planned_mask", "domain_authority_committed_mask"]
        print("  diag: " + " ".join(f"{k}={d.get(k)}" for k in keys if k in d))


def _gpu_of(out_dir: pathlib.Path) -> str:
    """从这一轮的浏览器控制台里读出实际用的 GPU。

    混合显卡机器上 Chrome 会在两轮之间换卡，而 shader 首次编译耗时与加载期单帧
    都差一个量级 —— 不记录 GPU 的话，两轮数据根本不可比。
    """
    console = out_dir / "session_console.json"
    if not console.exists():
        return "?"
    try:
        rows = json.loads(console.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return "?"
    for r in rows:
        msg = str(r.get("message", ""))
        if "Using Device:" in msg:
            tail = msg.split("Using Device:", 1)[1]
            return tail.strip().strip('"')[:60]
        if "renderer=ANGLE" in msg:
            return msg.split("renderer=", 1)[1][:60]
    return "?"


def _summary(by: dict) -> dict:
    """把一次会话的关键指标抽成一行，供 --repeat 汇总。"""
    out = {}
    per = by.get("warmup_shader", [])
    if per:
        out["warmup_sum_ms"] = sum(int(r.get("dur", 0)) for r in per)
        worst = max(per, key=lambda r: int(r.get("dur", 0)))
        out["warmup_worst"] = f"{worst.get('label')}={worst.get('dur')}"
    menu = by.get("menu_ready", [])
    if menu:
        out["page_to_menu_s"] = round(int(menu[-1].get("ms", 0)) / 1000.0, 1)
    st = by.get("autotest_start", [])
    rd = by.get("autotest_ready", [])
    if rd:
        out["page_to_world_s"] = round(int(rd[-1].get("ms", 0)) / 1000.0, 1)
        if st:
            out["click_to_world_s"] = round(
                (int(rd[-1].get("ms", 0)) - int(st[-1].get("ms", 0))) / 1000.0, 1)
    # 只统计**帧**耗时。beat 是每 ~2 s 一次的心跳，它的间隔原本就 ≥2000 ms，
    # 把它混进 worst_frame 会凭空造出"4–6 s 长帧"（实测踩过一次）。心跳停顿单独报，
    # 并且只报"超过一个心跳周期 + 1.5 s"的那些。
    slow = [int(r.get("dt", 0)) for r in by.get("slow_frame_trace", [])]
    frames = [int(r.get("dt", 0)) for r in by.get("frame", [])]
    out["worst_frame_ms"] = max(slow + frames) if (slow or frames) else 0
    gaps = [int(b.get("ms", 0)) - int(a.get("ms", 0))
            for a, b in zip(by.get("beat", []), by.get("beat", [])[1:])]
    stalls = [g for g in gaps if g >= 3500]
    out["worst_beat_stall_ms"] = max(stalls) if stalls else 0
    # 稳态速率优先取 clock_rate 的中位数：beat 跨度会把启动阶段（预热 + 进世界）
    # 一起平均进去，实测会低估 5 倍（同一次运行 beat 口径 1.78、稳态 9.86 天/秒）。
    rates = sorted(float(r.get("dps", 0.0)) for r in by.get("clock_rate", [])
                   if float(r.get("dps", 0.0)) > 0.0)
    if rates:
        out["days_per_s"] = round(rates[len(rates) // 2], 2)
        out["days_per_s_min"] = round(rates[0], 2)
    beats = by.get("beat", [])
    if beats:
        span = (int(beats[-1].get("ms", 0)) - int(beats[0].get("ms", 0))) / 1000.0
        days = int(beats[-1].get("day", 0)) - int(beats[0].get("day", 0))
        if span > 0 and days > 0:
            out["days_per_s_beat"] = round(days / span, 2)
        out["max_day"] = int(beats[-1].get("day", 0))
    passed = by.get("autotest_pass", [])
    out["pass"] = bool(passed)
    failed = by.get("autotest_fail", [])
    out["fail_reason"] = str(failed[-1].get("reason")) if failed else ""
    return out


def _print_matrix(rows: list[dict]) -> None:
    if not rows:
        return
    keys: list[str] = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    print("\n=== repeat summary (per-run, then min/median/max over runs) ===")
    for k in keys:
        vals = [r.get(k) for r in rows]
        nums = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
        if nums:
            nums_sorted = sorted(nums)
            median = nums_sorted[len(nums_sorted) // 2]
            print(f"  {k:20s} runs={vals}  min={min(nums)} median={median} max={max(nums)}")
        else:
            print(f"  {k:20s} runs={vals}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--speed", type=float, default=10.0)
    ap.add_argument("--size", default="60x40")
    ap.add_argument("--seed", type=int, default=20260101)
    ap.add_argument("--seconds", type=int, default=240)
    ap.add_argument("--stall-timeout", type=float, default=75.0)
    ap.add_argument("--tag", default="measure")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--events", default=str(EVENTS))
    ap.add_argument("--skip-session", action="store_true")
    ap.add_argument("--keep-server", action="store_true")
    ap.add_argument("--extra", default="",
                    help="附加查询串，例如 \"worker=1\"（同包 A/B 用；见 web_autotest.gd）")
    ap.add_argument("--cold-profile", action="store_true",
                    help="用全新临时 profile 跑（= 用户第一次访问，会付一次 ~18 s 的驱动 "
                         "shader 磁盘缓存构建）。默认用持久 profile（= 用户第二次及以后）。")
    ap.add_argument("--repeat", type=int, default=1,
                    help="同一 build 连跑 N 次并输出 min/median/max —— 单次测量在这台机器上"
                         "会有 3x 级离群值（见过同一份源码 27.4 s vs 6.9 s），别用单次下结论。")
    args = ap.parse_args()

    port = int(args.port)
    events = pathlib.Path(args.events)
    if not events.is_absolute():
        events = REPO / events

    if args.skip_session:
        _report(_read(events))
        return 0

    url = (f"http://127.0.0.1:{port}/ProjectKeynes.html?autotest=1&days={args.days}"
           f"&speed={int(args.speed) if float(args.speed).is_integer() else args.speed}"
           f"&seed={args.seed}&size={args.size}")
    if args.extra:
        url += "&" + args.extra.lstrip("&")

    runs: list[dict] = []
    _kill_leftovers()
    for run_idx in range(max(1, int(args.repeat))):
        # 每次都换一个事件文件 + 新 server，避免跨 run 串事件。
        run_events = events if args.repeat <= 1 else events.with_name(
            f"{events.stem}_r{run_idx + 1}{events.suffix}")
        server = _start_server(run_events, port)
        if server.poll() is not None:
            return 1
        out_dir = ARTIFACTS / f"measure_{args.tag}_{time.strftime('%H%M%S')}_r{run_idx + 1}"
        try:
            # 默认热 profile（真实用户第二次及以后）；--cold-profile 时每轮全新临时 profile。
            if args.cold_profile:
                run_profile = f"tmp/chrome_profile_cold_{time.strftime('%H%M%S')}_r{run_idx + 1}"
            else:
                run_profile = f"tmp/chrome_profile_{args.tag}"
            code = _run_session(url, args.seconds, args.stall_timeout, out_dir,
                                run_events, run_profile)
            if code == 2:
                print(f"[measure] run {run_idx + 1}: 判定卡死/超时")
        finally:
            _kill_leftovers()
            if not args.keep_server:
                try:
                    server.terminate()
                    server.wait(timeout=10)
                except Exception:
                    try:
                        server.kill()
                    except Exception:
                        pass
        rows = _read(run_events)
        print(f"\n[measure] run {run_idx + 1}/{args.repeat}: 事件 {len(rows)} 条, "
              f"artifacts={out_dir.name}")
        if args.repeat <= 1:
            print(f"[measure] gpu: {_gpu_of(out_dir)}")
            _report(rows)
        else:
            by = {}
            for r in rows:
                by.setdefault(r.get("e"), []).append(r)
            s = _summary(by)
            s["gpu"] = _gpu_of(out_dir)
            runs.append(s)
    if args.repeat > 1:
        _print_matrix(runs)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
