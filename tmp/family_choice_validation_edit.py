from pathlib import Path
p=Path('artifacts/runtime/family-choice-20261017/validation.md')
p.write_text('''# 家族扶持与分支立族修正验收

已完成：取消日常首都创始家族补建；玩家选择门同时尊重日初与已提交领土归属；
玩家异地分支保留姓氏、三套家风／效果候选、确认后整支统一转入子族；持久化真实母子关系，
后续母族迁入并入当地子族。家族可变权威仍为 NativeEconomyRuntime，GDScript 只编译文案和交互。

## 通过

- Windows Debug、Release 原生构建；当前加载目标为 dots_ext_family_choice_v56_r2。
- family_founding_offer_runtime_test.gd：PASS。
- family_split_choice_runtime_test.gd：0 failures；涵盖真实迁入、等待、三选一、整支归属、
  母族保留、后续迁入合并、冻结家风兑现、待决及完成状态哈希和周期内领土转归玩家。
- family_founding_dialog_ui_test.gd：0 failures。
- player_controller_contract_test.gd：0 failures。
- 实际 v55 DLL 写出的待决卡组存档经 v56 reader 恢复，原 state hash 一致。
- gda 验证修改的 facade、dialog、card 三个脚本均 valid=true。
- 分家界面 1280×720、1366×768、1920×1080、2560×1440 截图；人工检查 1280×720。
- 修改文件 git diff --check 通过。

## 未通过的综合检查

- family_runtime_test.gd：夹具 population=50、owner operators=10，期望形成至少20人普通家族，
  实际无家族，测试在该断言后提前返回。未将该综合测试算作通过。
- goods_storage_schema_test.gd：244 checks / 2 failures，分别是单周期库存价格压力、
  出生人口聚合到零资金同民族无业 cohort；v56 save 断言通过。未宣称这些失败由本改动修复。
- 完整项目加载仍报 resource_default.tres 第9行构造格式错误以及其依赖的脚本编译错误；
  此文件属于工作区其他进行中的修改，本任务未改写。
- Headless 退出还包含 Godot dummy renderer/resource 清理告警。

## 兼容与限制

PKEC writer=56，显式兼容55；其他旧 schema 保留原拒绝规则。v55 补空分家来源与 lineage，
不猜测已存在家族之间的亲缘，因此不会批量合并历史同姓记录。现有运行中的编辑器／游戏
未被终止；需重新启动以加载当前原生库。正式开局 bootstrap 仍创建最初的创始家族。

首都日常补建入口的取消经过调用点静态核对；未声称存在独立的迁空首都端到端通过记录。
''',encoding='utf-8')
p=Path('docs/cpp-dots-runtime/runtime-deletion-inventory.md')
s=p.read_text(encoding='utf-8').rstrip()+'''\n\n## 2026-10-17 家族首都补建入口移除

`NativeEconomyRuntime::repair_forced_capital_founder` 及 FAMILY_COMMIT 日常调用已删除。
原0..30天兼容逻辑只以当地是否仍有家族判断是否补建，会在首都原族迁出或消亡后绕过玩家扶持
再造 Starter。正式 bootstrap 的 v3 创始声明与 v2 forced_named_cells + gathering_ground
兼容仍保留；后续普通家族走正常里程碑／玩家选择。分家另走同一待决队列。参见
[家族运行时](notable-family-runtime.md) 的 v56 说明。此删除依据玩家明确要求修正静默立族。
'''
p.write_text(s,encoding='utf-8')
