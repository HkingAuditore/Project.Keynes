# 保存续跑样本（CLM2 v9 / ECP2 60 / OSOA4 / PKSR5 / PKMI3）

固定 ACTIVE worker，seed=20260727、40×28、clock RNG=150015，非空军事 target 命令，第2日保存。目录保留原名，实际格式以 manifest 为准。

当前样本使用 OSOA4。新增的块 13 保存本日已经采样的降雨标记和冻结门槛，避免读档后重复采样或丢失结果。旧 OSOA3 存档会被拒绝。`legacy_catalog.pkcm` 来自前一个固定档，仍用于验证旧规则内容被拒绝且不会改变当前状态。

在 macOS arm64 上运行以下命令生成候选，候选目录和日志目录都应为新目录。

```sh
/Users/herh/.local/bin/python3 tools/ci/capture_climate_archive.py \
  --godot /opt/homebrew/bin/godot \
  --candidate /tmp/keynes-climate-candidate \
  --log-dir /tmp/keynes-climate-candidate-logs
```

候选先通过八域继续比较和固定样本校验，再由维护者审查并安装。`manifest.json` 记录生成时程序库、存档和各段的版本、长度及摘要。使用当前内容对照，修复前后第 1 至 10 日的气候逻辑结果一致。

`check_climate_archive.py` 验证 CLM2 的 1,901,228 字节精确往返，以及第 3 至 10 日的八域、完整经济、军事和资源继续结果。它也核对发布、资源、兼容 Country、就业冷却、实物收入、降雨、Host 传输、军事索引和转发游标的字节。完整 PKSV/ECP2 仍有既存 AUDIT/Modifier 重编码差异。

非零部队与年度自动存档由各自的矩阵用例验证。
