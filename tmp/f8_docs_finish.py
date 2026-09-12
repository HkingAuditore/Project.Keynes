# -*- coding: utf-8 -*-
import sys
from pathlib import Path
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

def rep(path: str, pairs: list[tuple[str, str]]) -> None:
    p = Path(path)
    t = p.read_text(encoding="utf-8")
    for old, new in pairs:
        c = t.count(old)
        print(f"{path}: {c} x {old[:48]!r}")
        if c:
            t = t.replace(old, new)
    p.write_text(t, encoding="utf-8", newline="\n")

rep("docs/cpp-dots-runtime/authority-migration.md", [
    ("| **F** | EFFECT | \U0001f536 F2–F7 完成；F8 未执行，仍为 SHADOW |",
     "| **F** | EFFECT | \u2705 F2–F8 完成（生产 ACTIVE，`0x866`） |"),
    ("- [ ] F8 放行",
     "- [x] F8 放行（`0x866`；Host ACTIVE 唯一写者；snapshot 回灌 `EffectRuntime`；抑制 `run_effect_daily`；跨域 intent 主线程 pump）"),
    ("**当前边界（F7）**：Host SHADOW 日循环已真实驱动 `RuntimeEffectPodAuthority`；\nF8 前不做主线程 `EffectRuntime` 抑制、不做 Effect ACTIVE grant、不改 mask。",
     "**当前边界（F8）**：`implemented`/`request` 均为 `CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866`；worker 为 Effect 唯一写者；snapshot 回灌 legacy `EffectRuntime`；主线程抑制 effect daily；MODIFIER intents 在 worker 内 ACK，其它 intents 主线程 pump+ACK。"),
    ("F EFFECT         █████████░░░ F2-F7 完成，F8 未做（SHADOW）",
     "F EFFECT         ████████████ F2-F8 完成；生产 ACTIVE（0x866）"),
    ("| **第 1 类：生产 ACTIVE** | CLIMATE、COUNTRY、MODIFIER、COMMIT | 生产 request `0x846`；Effect 仍 SHADOW | 已放行 |",
     "| **第 1 类：生产 ACTIVE** | CLIMATE、COUNTRY、MODIFIER、EFFECT、COMMIT | 生产 request `0x866` | 已放行 |"),
    ("`implemented_domain_mask` 现为 `0x846`（不含 EFFECT）",
     "`implemented_domain_mask` 现为 `0x866`（含 EFFECT）"),
    ("现为 `0x846`（含 MODIFIER）；E8 已放行",
     "现为 `0x866`（含 MODIFIER|EFFECT）；F8 已放行"),
    ("生产 request `0x846`、", "生产 request `0x866`、"),
    ("authoritative_domain_mask=0x846`（Climate|Country|Modifier|COMMIT）",
     "authoritative_domain_mask=0x866`（Climate|Country|Modifier|Effect|COMMIT）"),
    ("Climate|Country|Modifier ACTIVE → `authoritative_domain_mask=0x846`",
     "Climate|Country|Modifier|Effect ACTIVE → `authoritative_domain_mask=0x866`"),
    ("implemented/request 均为 CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846；主线程只抑制 modifier_daily。Effect 仍为 F7 SHADOW，未抑制 EffectRuntime。",
     "implemented/request 均为 CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866；主线程抑制 modifier_daily 与 effect daily；Effect 为 F8 ACTIVE。"),
    ("Modifier E2–E8 完成。Effect F7 已把真实 POD stage 接入 Host 日循环（仍为 SHADOW，mask 不含\nEFFECT）；F8 未做。",
     "Modifier E2–E8 与 Effect F8 完成。生产 mask 含 EFFECT；worker 为 Effect 唯一写者，snapshot 回灌 EffectRuntime。"),
    ("Ideology G2-G7、Trigger H2-H6、Effect F2-F7 的 SHADOW 现状不变（F8/G8/H7/H8 未执行）。",
     "Ideology G2-G7、Trigger H2-H6 的 SHADOW 现状不变（G8/H7/H8 未执行）。"),
    ("`CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`",
     "`CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866`"),
])

rep("docs/cpp-dots-runtime/native-simulation-host.md", [
    ("当前 `implemented_domain_mask()` 为 `CLIMATE | COUNTRY | MODIFIER | COMMIT = 0x846`。Effect、Economy 等仍不在 ACTIVE authority mask。因此：",
     "当前 `implemented_domain_mask()` 为 `CLIMATE | COUNTRY | MODIFIER | EFFECT | COMMIT = 0x866`。Economy 等仍不在 ACTIVE authority mask。因此："),
    ("`implemented_domain_mask() == 0x846`.",
     "`implemented_domain_mask() == 0x866`."),
    ("生产 ACTIVE（mask `0x846`）在 Country 之后、Climate park 日跳过对齐 Country：可选 Effect POD 上游 → Modifier plan/ACK/snapshot/commit；成功日写入 `completed_domain_mask` 的 MODIFIER 位。失败隔离，不撤销已提交 Climate/Country。\n\ngrant 后：Host 为命令唯一写者；主线程抑制 `run_modifier_daily` / `modifier_daily_system`；`world_runtime_host` 非阻塞消费 snapshot 并 `ModifierRuntime.apply_pod_snapshot`；`main_wait_on_sim_us` 保持 0。Effect 仍为 F7 SHADOW，不抑制 `EffectRuntime`。",
     "生产 ACTIVE（mask `0x866`）在 Country 之后、Climate park 日跳过对齐 Country：独立 Effect stage → Modifier；成功日写入 EFFECT/MODIFIER 位。失败隔离。\n\ngrant 后：Host 为 Modifier/Effect 唯一写者；主线程抑制 modifier/effect daily；非阻塞 snapshot 回灌；非 Modifier Effect intents 主线程 pump+ACK；`main_wait_on_sim_us` 保持 0。"),
    ("## Effect POD shadow stage (F7)\n\nF7 在 Ideology 之后、Modifier 之前接入真实 `RuntimeEffectPodAuthority` 日 stage：\n\n1. 主线程 best-effort 镜像 declarative instance/metric/remove 到 Host transport 队列。\n2. Worker drain 队列 → `apply_acks` → `plan_day` → 发布 outbound intents → `commit_day`。\n3. 当 Effect POD catalog 非空且 stage 成功时，Modifier 只消费 Effect POD 的 MODIFIER\n   intents，并忽略 diagnostic `RuntimeDomainAuthorityRunner::run_effect` fixture intents；\n   Modifier ACK 回灌 `_effect_pod_authority.apply_acks`。\n4. 空冷启动 catalog 不启用该 stage，Modifier E7 继续使用 fixture 上游。\n5. `implemented_domain_mask` 现为 `CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`（仍不含 EFFECT）；legacy\n   `EffectRuntime` 仍是生产权威。F8 前不抑制主线程 Effect、不授予 ACTIVE。\n\nReport 暴露 `effect_pod_ready/plan_ms/replay_ms/state_hash/snapshot_generation/ack_count/intent_count/fallback_reason`。",
     "## Effect POD ACTIVE stage (F8)\n\nF8 在 Ideology 之后、Modifier 之前跑独立 ACTIVE Effect stage：\n\n1. grant `0x020` 后 submit/retire 只走 Host transport（sole-writer）。\n2. Worker：drain → apply_acks → plan_day → intents → commit_day → snapshot ring。\n3. MODIFIER intents 同日 Modifier stage ACK；COUNTRY/ECONOMY/GAMEPLAY 由主线程非阻塞 poll→ACK。\n4. Behavior 经 EffectRuntime 注册表桥接；缺实现 hard-fail。\n5. 主线程回灌 EffectRuntime；graph/SUS 抑制 evaluate+dispatch。\n\nReport 暴露 `effect_pod_*` 与 `effect_worker_authoritative`。"),
])

rep("docs/cpp-dots-runtime/runtime-authority-matrix.md", [
    ("`CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846` mask; Economy remains synchronous production",
     "`CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866` mask; Economy remains synchronous production"),
    ("an Ideology bit to the current `implemented_domain_mask() == 0x846`",
     "an Ideology bit to the current `implemented_domain_mask() == 0x866`"),
    ("| Effect 仍 SHADOW（F8 未做）。 |",
     "| Effect 已 F8 ACTIVE（`0x020`）。 |"),
    ("现为 `0x846`，Economy 仍不在 ACTIVE grant 中。",
     "现为 `0x866`，Economy 仍不在 ACTIVE grant 中。"),
    ("`COMMIT | CLIMATE | COUNTRY | MODIFIER (0x846)`; Effect remains SHADOW-only and is not\ngranted ACTIVE authority.",
     "`COMMIT | CLIMATE | COUNTRY | MODIFIER | EFFECT (0x866)`; Economy remains outside ACTIVE."),
    ("Modifier E2-E8 已完成：生产 ACTIVE 唯一写者、snapshot 回灌 `ModifierRuntime`、抑制 `modifier_daily`。当前 Host mask 为 `CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`。Effect 仍为 F7 SHADOW。",
     "Modifier E2-E8 与 Effect F8 已完成：生产 ACTIVE 唯一写者、snapshot 回灌 legacy runtime、抑制对应 daily。当前 Host mask 为 `CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866`。"),
])
print("done")
