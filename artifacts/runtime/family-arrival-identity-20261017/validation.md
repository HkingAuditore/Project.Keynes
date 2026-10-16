# 母族后续迁入身份修正（2026-10-17）

按玩家明确规则取消 reunite_split_family_branches 的实现、声明与调用。
A 在乙地独立为 A1 后，后来迁入乙地的 A 成员仍属于 A；A 与 A1 可同格共存。
A 的新分支满足条件时再走独立的三选一。分家选择只转移选择时的本地分支。

_family_split_parents 仅作亲缘元数据保留，继续兼容既有 PKEC v56 存档和哈希格式。
此次不改存档格式，不对历史人口或归属做批量逆向恢复。

验证：
- 新回归在旧 r2 库上明确失败：后续迁入保留身份、存读档保留两族，共2个失败。
- 新 r3 库：family_split_choice_runtime_test.gd 0 failures，含 A/A1 共存与完整存读档哈希。
- family_founding_offer_runtime_test.gd PASS。
- Windows Debug/Release 构建成功；加载目标 dots_ext_family_choice_v56_r3。
- 修改文件 git diff --check 通过。

先前家族修正的其他验收与集成限制见 ../family-choice-20261017/validation.md。
