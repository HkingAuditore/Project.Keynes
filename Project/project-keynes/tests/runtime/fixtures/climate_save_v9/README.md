# 保存续跑样本（CLM2 v9 / ECP2 60 / PKSR5 / PKMI3）

固定 ACTIVE worker，seed=20260727、40×28、clock RNG=150015，非空军事 target 命令，第2日保存。目录保留原名，实际格式以 manifest 为准。

本次合并用当前实现重建样本：上游增加国有建筑和军事装备、运输继续态，ECP2 从59升到60，PKMI从2升到3。沿用原有格式校验，未新增旧版拒绝检查或迁移代码；经济内部 PKEC 原有迁移路径保留。原分支已有的 OSOA3 块12、PKMI section22、PKSR5 TCQ1 和 MDJ1 保留；它们不是本次新增。CLM2 v9、CPD2 revision1、MILB3 版本不变。

本次生成命令：

```sh
HOME=/tmp/keynes-merge/merge/home /Users/herh/.local/bin/python3 tools/ci/check_climate_archive.py --godot /opt/homebrew/bin/godot --log-dir /tmp/keynes-merge/merge/climate-archive-1
```

该次运行因旧样本版本被拒绝而失败，但已完成新的 checkpoint 捕获。将其 `saves/manual_3.pksv` 复制为 `day2.pksv`，从保存的各段字节重算 manifest 后，在新目录 `climate-archive-3` 运行同一检查并通过。manifest 保留生成时库的 SHA、存档 SHA、版本、各继续态长度和 SHA。

对比合并前样本，publication、resources、mobility、population、military-index、military-forwarder 的字节哈希不变；兼容快照、Host 传输、CLM2完整字节和周期测量值改变。第3至10日的气候逻辑哈希不变。完整字节和逻辑投影是不同的检查，不能互相代替。

`check_climate_archive.py` 验证加载后 CLM2 的1,901,228字节精确往返，以及第3至10日的八域、完整经济、军事和资源继续结果。它也核对发布、资源、兼容Country、就业冷却、实物收入、Host传输、军事索引和转发游标的字节。完整PKSV/ECP2仍有既存AUDIT/Modifier重编码差异，不能称整档幂等。

此短例零士兵；不能代替非零军事与年度矩阵。五条黄金基线未修改。
