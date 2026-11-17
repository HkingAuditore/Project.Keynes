# 獅尾腿圓體 / Swei Gothic Leg CJK SC

## 来源

Regular 和 Bold 的**母版**为 ToyEmpires `Assets/Arts/Fonts/Swei/` 中的完整版
`[FULL DONT REF].ttf`，原样复制，未修改字形或内部名称，存放于 `source/`。
该目录带 `.gdignore`，不参与 Godot 资源扫描与导出，仅作为子集生成工具的输入。

作者项目：[max32002/swei-gothic-leg](https://github.com/max32002/swei-gothic-leg)。
授权：SIL Open Font License 1.1，随附 `OFL.txt`（从字体 name ID 13 原文提取）。

## 项目内改动：子集化

移动端包体吃紧，随包分发的是**子集字体**（`SweiGothicLegCJKsc-Regular.woff2` /
`-Bold.woff2`），由 `tools/fonts/subset_swei.py` 生成：

- 字形集合 = GB2312 汉字（6763）∪ 仓库文本实际用字 ∪ 常用标点与符号码段；
- 格式为 WOFF2（无损容器，字形轮廓逐点保留，仅做 brotli 压缩与 glyf 变换）；
- 完整版 44936 字形 → 子集 8002 字形；两字重经 Godot 导入后 19.97 MiB → 2.17 MiB。

这是 OFL 意义上的 **Modified Version**：字形轮廓未改，仅裁掉未使用的字形。
改版名称不含保留字体名（`Untitled6`）。

子集外的生僻字由 `allow_system_fallback` 交给系统字体渲染。内容里出现新的
GB2312 之外汉字时，用 `python tools/fonts/subset_swei.py` 重新生成，
`--check` 可检查仓库用字是否已被覆盖。
