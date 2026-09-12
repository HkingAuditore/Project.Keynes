# -*- coding: utf-8 -*-
import sys
sys.stdout.reconfigure(encoding="utf-8")
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def patch(path, replacements):
    text = path.read_text(encoding="utf-8")
    for old, new in replacements:
        if old not in text:
            print("MISS", path.name, old[:50])
            continue
        text = text.replace(old, new)
        print("OK", path.name)
    path.write_text(text, encoding="utf-8")


def main():
    # Continue docs from where previous run may have partially applied
    am = ROOT / "docs/cpp-dots-runtime/authority-migration.md"
    at = am.read_text(encoding="utf-8")
    reps = [
        ("| **E** | MODIFIER | ✅ E2–E7 完成；E8 未执行，仍为 SHADOW |",
         "| **E** | MODIFIER | ✅ E2–E8 完成（生产 ACTIVE，`0x846`） |"),
        ("## 阶段 E：MODIFIER（第三个域）✅（E2–E7；E8 未执行）",
         "## 阶段 E：MODIFIER（第三个域）✅（E2–E8 完成）"),
        ("- [ ] E8 放行",
         "- [x] E8 放行（`0x846`；Host ACTIVE 唯一写者；snapshot 回灌 `ModifierRuntime`；抑制 `modifier_daily`）"),
        ("`CLIMATE|COUNTRY|COMMIT = 0x806`（不含 MODIFIER），legacy ModifierRuntime 仍是生产\n"
         "authority，E8 前不做 snapshot 回灌或 ACTIVE 放行。",
         "`CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`；worker 为 Modifier 唯一写者，snapshot 回灌\n"
         "legacy `ModifierRuntime`（非 MapData）；主线程仅抑制 `modifier_daily`。"),
        ("E MODIFIER       ████████░░░░ E2-E7 完成，E8 未做（SHADOW）",
         "E MODIFIER       ████████████ E2-E8 完成；生产 ACTIVE（0x846）"),
        ("按逐域模板算，未完成的 E8、F8、G8、H7/H8、I8 和阶段 J 仍是这轮迁移剩余工作量的主体；",
         "按逐域模板算，未完成的 F8、G8、H7/H8、I8 和阶段 J 仍是这轮迁移剩余工作量的主体；"),
        ("| **第 3 类：SHADOW/POD 迁移中** | MODIFIER、EFFECT、IDEOLOGY、TRIGGER_INPUT、ECONOMY、EVENTS | Modifier/EFFECT/Ideology/Trigger 已有真实 POD 组件，Events 已有独立 SHADOW/PROBE authority；Economy 仍主要是诊断投影 | 阶段 E–J |",
         "| **第 1 类：生产 ACTIVE** | CLIMATE、COUNTRY、MODIFIER、COMMIT | 生产 request `0x846`；Effect 仍 SHADOW | 已放行 |\n"
         "| **第 3 类：SHADOW/POD 迁移中** | EFFECT、IDEOLOGY、TRIGGER_INPUT、ECONOMY、EVENTS | Effect/Ideology/Trigger 已有真实 POD 组件，Events 已有独立 SHADOW/PROBE authority；Economy 仍主要是诊断投影 | 阶段 F–J |"),
        ("E2-E7 已完成，E8 未执行。Modifier POD 已具备 worker-side plan/replay authority、四域隔离、五个 legacy opcode、真实 Effect -> Modifier ACK barrier、immutable snapshot ring 和独立 MDF2 存档 section。implemented_domain_mask 现为 CLIMATE|COUNTRY|COMMIT = 0x806；Modifier 不进入 ACTIVE authority，legacy ModifierRuntime 继续是主线程生产 authority，worker snapshot 不回灌 legacy store。",
         "E2-E8 已完成。Modifier POD 在生产 ACTIVE 下为唯一写者：日循环 plan/replay、四域隔离、Effect POD intents ACK、immutable snapshot ring、MDF2，以及回灌 legacy ModifierRuntime。implemented/request 均为 CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846；主线程只抑制 modifier_daily。Effect 仍为 F7 SHADOW，未抑制 EffectRuntime。"),
        ("`implemented_domain_mask()` 现为 `0x806`（不含 MODIFIER），E8 未执行。",
         "`implemented_domain_mask()` 现为 `0x846`（含 MODIFIER）；E8 已放行。"),
        ("`implemented_domain_mask` 仍为 `0x806`（不含 EFFECT）",
         "`implemented_domain_mask` 现为 `0x846`（不含 EFFECT）"),
        ("当前硬门禁改为 D12 `implemented_domain_mask`、生产 request `0x806`",
         "当前硬门禁改为 E8 `implemented_domain_mask`、生产 request `0x846`"),
        ("worker 生命周期、模式决策（Climate|Country ACTIVE → `authoritative_domain_mask=0x806`）",
         "worker 生命周期、模式决策（Climate|Country|Modifier ACTIVE → `authoritative_domain_mask=0x846`）"),
        ("true → 以 ACTIVE + `authoritative_domain_mask=0x806`（Climate\\|Country\\|COMMIT）启动；false → SHADOW。**Climate+Country 的总开关与回退路径**",
         "true → 以 ACTIVE + `authoritative_domain_mask=0x846`（Climate\\|Country\\|Modifier\\|COMMIT）启动；false → SHADOW。**Climate+Country+Modifier 的总开关与回退路径**"),
    ]
    for old, new in reps:
        if old in at:
            at = at.replace(old, new)
            print("OK am")
        else:
            print("MISS am", old[:40])
    am.write_text(at, encoding="utf-8")

    patch(ROOT / "docs/cpp-dots-runtime/native-simulation-host.md", [
        ("当前 `implemented_domain_mask()` 为 `CLIMATE | COUNTRY | COMMIT = 0x806`。Modifier、Economy 等仍不在 ACTIVE authority mask。因此：",
         "当前 `implemented_domain_mask()` 为 `CLIMATE | COUNTRY | MODIFIER | COMMIT = 0x846`。Effect、Economy 等仍不在 ACTIVE authority mask。因此："),
        ("`implemented_domain_mask() == 0x806`.",
         "`implemented_domain_mask() == 0x846`."),
        ("## Modifier POD shadow stage\n\n阶段 E2-E7 的 Modifier stage 位于 EFFECT -> MODIFIER -> ... -> COMMIT，执行完整 POD plan/replay、expiry、五个 opcode、ACK 校验和 snapshot publish。Modifier commit 前必须先成功预留 snapshot slot；ACK 缺失、容量溢出、身份不匹配或 snapshot shape/catalog hash 错误都会 discard plan，不 swap current、不发布 snapshot、不推进 generation，并写入 modifier_pod_fallback_reason。\n\nModifier 不改变 implemented_domain_mask == 0x806。legacy ModifierRuntime 仍负责生产 daily，Host 只运行 SHADOW 对照；capture 后 ingress 自动延迟至下一安全日边界，main_wait_on_sim_us 保持为零。",
         "## Modifier POD ACTIVE stage (E8)\n\nModifier stage 位于 EFFECT -> MODIFIER -> ... -> COMMIT，SHADOW 与 ACTIVE 共用 `execute_modifier_worker_stage`。生产 ACTIVE（mask `0x846`）在 Country 之后、Climate park 日跳过对齐 Country：可选 Effect POD 上游 → Modifier plan/ACK/snapshot/commit；成功日写入 `completed_domain_mask` 的 MODIFIER 位。失败隔离，不撤销已提交 Climate/Country。\n\ngrant 后：Host 为命令唯一写者；主线程抑制 `run_modifier_daily` / `modifier_daily_system`；`world_runtime_host` 非阻塞消费 snapshot 并 `ModifierRuntime.apply_pod_snapshot`；`main_wait_on_sim_us` 保持 0。Effect 仍为 F7 SHADOW，不抑制 `EffectRuntime`。"),
        ("5. `implemented_domain_mask` 仍为 `CLIMATE|COUNTRY|COMMIT = 0x806`；legacy",
         "5. `implemented_domain_mask` 现为 `CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`（仍不含 EFFECT）；legacy"),
    ])

    patch(ROOT / "docs/cpp-dots-runtime/runtime-authority-matrix.md", [
        ("`CLIMATE|COUNTRY|COMMIT = 0x806` mask; Economy remains synchronous production",
         "`CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846` mask; Economy remains synchronous production"),
        ("an Ideology bit to the current `implemented_domain_mask() == 0x806`; its `IDP1`",
         "an Ideology bit to the current `implemented_domain_mask() == 0x846`; its `IDP1`"),
        ("| `modifier_daily` | `ModifierRuntime` 持有四域 SoA、bucket、expiry heap、命令排序与 snapshot version。 | 不写领域 base slot；发布只读 effective 聚合。 | `MODIFIER_GRAPH` report、command result、journal；PKCM/PKGP 与 PKCN/PKEC 内嵌 domain。 | GDScript fallback 只消费同一 `evaluate_modifier_stat` 公式；无第二份可变 store。 | ACTIVE，priority 90、单 slice、无工作时零 slice。 | 独立 SHADOW 双算和目标规模性能门禁尚未完成。 |",
         "| `modifier_daily` | Host ACTIVE Modifier POD 为唯一写者；legacy `ModifierRuntime` 经 snapshot 回灌作只读视图。 | 不写领域 base slot；发布只读 effective 聚合。 | `MODIFIER_GRAPH` / `modifier_worker_authoritative` report、MDF2；PKCM/PKGP 与 PKCN/PKEC 内嵌 domain。 | grant 后 SUS/`run_modifier_daily` 无生产写入。 | Host ACTIVE（`0x040`），主线程抑制。 | Effect 仍 SHADOW（F8 未做）。 |"),
        ("仍为 `0x806`，Economy 仍不在 ACTIVE grant 中。",
         "现为 `0x846`，Economy 仍不在 ACTIVE grant 中。"),
        ("`COMMIT | CLIMATE | COUNTRY (0x806)`; Modifier remains SHADOW-only and is not",
         "`COMMIT | CLIMATE | COUNTRY | MODIFIER (0x846)`; Effect remains SHADOW-only and is not"),
        ("Modifier E2-E7 已完成 worker-side SHADOW plan/replay，但未执行 E8。它拥有 numeric catalog、四域 store、稳定 replay、真实 ACK、immutable snapshot 和 MDF2 persistence；生产 authority 仍是主线程 legacy ModifierRuntime。因此 Modifier 不授予 ACTIVE grant，snapshot 只能在下一安全日边界被消费。该结论只描述 Modifier；D12 已将独立的 Country bit 加入当前 Host mask，使当前 mask 为 `0x806`。",
         "Modifier E2-E8 已完成：生产 ACTIVE 唯一写者、snapshot 回灌 `ModifierRuntime`、抑制 `modifier_daily`。当前 Host mask 为 `CLIMATE|COUNTRY|MODIFIER|COMMIT = 0x846`。Effect 仍为 F7 SHADOW。"),
    ])

    # Fix modifier pod test wording
    mt = ROOT / "Project/project-keynes/tests/runtime_modifier_pod_test.gd"
    mtext = mt.read_text(encoding="utf-8")
    mtext = mtext.replace(
        '_expect("Modifier remains outside ACTIVE authority mask",\n'
        '\t\tint(self_test.get("implemented_domain_mask", 0)) == 0x846)',
        '_expect("Modifier is inside ACTIVE authority mask (E8 0x846)",\n'
        '\t\tint(self_test.get("implemented_domain_mask", 0)) == 0x846)',
    )
    mt.write_text(mtext, encoding="utf-8")
    print("modifier pod test wording ok")


if __name__ == "__main__":
    main()
