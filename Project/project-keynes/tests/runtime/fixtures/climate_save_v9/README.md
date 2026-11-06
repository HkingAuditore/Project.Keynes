# 保存续跑金样（CLM2 v9 / ECP2 59 / PKSR5 / PKMI2）

固定 ACTIVE worker，seed=20260727、40×28、clock RNG=150015，非空军事 target 命令，第2日保存。目录保留原名，实际格式以 manifest 为准。

生成命令：

```sh
/usr/bin/env PK_COMMITTED_REPLAY_ROUNDTRIP=1 PK_COMMITTED_REPLAY_EXPORT=1 /Users/herh/.local/bin/python3 /Users/herh/MyFiles/games/keynes/tools/ci/check_committed_replay.py --godot /opt/homebrew/bin/godot --checkpoint --trace --days 10 --log-dir /tmp/keynes-arch-phase1/stage26/l-final-fixture
```

四进程全部 valid、first_difference=None 后，将 `saves/manual_3.pksv` 复制为 `day2.pksv`。manifest 保存库/存档 SHA、版本、各继续态长度和 SHA。

本次变更：ECP2 58→59，OSOA3 追加块12（完整槽位实物收入累计列）；PKMI1→2 追加 section22（包含 inactive 的 lot payload、索引链、空闲顺序、army generation 与待接纳状态）；PKSR4→5 追加 TCQ1（Trigger请求/ACK/发布游标、Host请求编号游标）。军事provider另追加MDJ1保存事件转发游标（28字节），避免重复转发旧宣战。旧版明确拒绝。CLM2 v9、CPD2 revision1、MILB3 不变。

对比改前金样：32个比较单元中28个逐字节不变；变化仅为 ECP2、PKSR 内嵌 ECP2、PKSR 头和 PKMI。ECP2 其他15个域 payload、原OSOA块1–10、PKMI原section1–21均不变。块11为真实测量耗时，不同进程生成的数值可以不同；加载该金样后立即重存的48字节必须完全相同。该区别不影响测试周期注入或黄金投影。

`check_climate_archive.py` 验证八日全域继续，以及CLM2、发布/资源/兼容Country/就业冷却/实物收入/Host传输/军事索引继续态的精确字节。完整PKSV/ECP2仍有既存AUDIT/Modifier重编码差异，不能称整档幂等。

此短例零士兵。真实非零军事与年度覆盖由矩阵的 military20 / military365 场景负责；不能用短例代替年度闭环。五条既有黄金基线未修改。
