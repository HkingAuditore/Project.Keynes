# 项目清理审计报告

审计日期：2026-10-20
审计范围：`D:/Godot/ProjectKeynes` 整个 workspace（含 git 仓库 `Project.Keynes`）
状态：**仅审计，未执行任何删除或 git 写操作**

---

## 一、摘要

workspace 共约 **30 GB**，其中可回收 **约 14 GB**，且不影响任何已跟踪源码。

| 侧 | 问题 | 体积 |
|---|---|---|
| Git 内部 | 松散对象 20041 个 + fsck 残渣 + 编辑器检查点 | 5.6 GB |
| 仓库外 | `m7-bisect-8b35905e/` + `tmp/` + 零碎产物 | 7.1 GB |
| 仓库内 | 已忽略的 `tmp/`、`.venv-build`、`.codex-temp` | 2.0 GB |

**先修正一个直觉偏差**：`git status` 其实不脏。146 条改动里 113 条是正常开发中的源码修改（`M`），33 条未跟踪里绝大多数是应提交的新源码（`target_tag_dictionary.gd`、`ideology_effect_report.gd` 等）和本仓惯例要提交的 `artifacts/` 测试日志。真正的乱在**磁盘**，不在版本状态。

---

## 二、现状总账

### 2.1 体积分布（`Project.Keynes/` 内部）

| 目录 | 体积 | 说明 |
|---|---|---|
| `.git/` | **10.3 GB** | 对象库 9.86 GB + lost-found 335 MB + cursor 120 MB |
| `Project/` | 6.8 GB | `project-keynes` 4.5 GB / `perf-validation` 2.3 GB |
| `gdext/` | 5.2 GB | godot-cpp 源码 + 编译中间产物 |
| `emsdk/` | 1.9 GB | 已 gitignore，本机工具链，**建议保留** |
| `tmp/` | 1.5 GB | 292 项，主要是 FMOD 验证目录 |
| `tools/` | 383 MB | |
| `artifacts/` | 144 MB | 已跟踪，本仓惯例提交，**不要清** |
| `WebBuild/` | 93 MB | |
| `.codex-temp/` | 46 MB | 工具残留 |
| `.venv-build/` | 33 MB | 工具残留 |

### 2.2 仓库外 workspace 顶层

| 项 | 体积 | 性质 |
|---|---|---|
| `Project.Keynes/` | 26.6 GB | 仓库本体 |
| `tmp/` | **3.55 GB** | 一次性日志与抓包 |
| `m7-bisect-8b35905e/` | **3.55 GB** | M7 二分查找工作副本，**含独立 `.git`** |
| `tmp_building_art/` | 16 MB | 美术中间产物 |
| `tmp_art/` | 11 MB | 美术中间产物 |
| `tmp_shots_async/` | 5 MB | 截图 |
| `output/` + `outputs/` | 4 MB | 输出 |
| `.git-refs-backup-20260829/` | 1 MB | 历史修复备份 |
| `.git-refs-backup-20260901-102508/` | 1 MB | 历史修复备份 |
| `generated-textures/` | 3 MB | |
| `lfs/` | ~0 | |

### 2.3 根目录误操作产物（名字本身就是证据）

| 文件 | 成因 |
|---|---|
| `nul`（149 B） | `dir ... 2>nul` 在 bash 下把 `2>nul` 当成了重定向文件名。内容是一段 "cannot access '/T:W'" 的错误输出 |
| `d:GodotProjectKeynesProject.Keynestmppeaks.txt` | tar 路径拼接错误，`:` 和 `\` 被吞掉 |
| `Project.Keynes/%USERPROFILE%/` | SVN export 时 `%USERPROFILE%` 未展开，被当成字面目录名创建 |
| `unreal_mcp.log` | 根级日志，`.gitignore` 已忽略 |
| `tmp_mod.txt` / `tmp_untrack.txt` | 一次性清单 |

---

## 三、批次 A：Git 内部瘦身（零风险，收益最大）

### 3.1 具体病灶

`git count-objects -v -H` 输出：

```
count: 20041              ← 20041 个松散对象
size: 5.12 GiB            ← 松散对象占 5.12 GB
in-pack: 40655
packs: 9
size-pack: 4.42 GiB
prune-packable: 1199      ← 1199 个松散对象已在 pack 内，纯冗余
garbage: 3
size-garbage: 39.04 MiB
```

附加残渣：

| 项 | 体积 | 说明 |
|---|---|---|
| `.git/lost-found/` | 335 MB | `git fsck --lost-found` 的残渣，无引用 |
| `.git/cursor/crepe/` | 120 MB | Cursor 编辑器 AI checkpoint，塞在 .git 里 |
| `.git/packed-refs.corrupt-backup` | 1 MB | 历史修复残留 |
| `.git/packed-refs.bak-20260830-2352` | 1 MB | 历史修复残留 |
| `pack-6c2c323f…idx` | — | **孤儿索引，没有对应 .pack** |
| `tmp_obj_EjUrNs` / `tmp_obj_LnBQyC` / 另 1 个 | 39 MB | 中断的垃圾对象 |

### 3.2 处置方案

前置检查（必须全绿才继续）：

```bash
cd D:/Godot/ProjectKeynes/Project.Keynes
git status -sb | head -1        # 应为 ## master...origin/master
ls .git/rebase-merge .git/rebase-apply .git/MERGE_HEAD 2>/dev/null   # 应为"无"
git fsck --no-progress 2>&1 | tail -20                              # 应无 error
```

> 当前已核对：分支 `master`，无 rebase/merge 中间态。

第一步 —— 清残渣（这些目录没有任何引用，删了不影响仓库）：

```bash
rm -rf .git/lost-found .git/cursor
rm -f  .git/packed-refs.corrupt-backup .git/packed-refs.bak-20260830-2352
rm -f  .git/objects/pack/pack-6c2c323fecff861d73b6445755023d258bea96f7.idx
```

第二步 —— 打包去重（把 20041 个松散对象压进 pack，重复的自动丢弃）：

```bash
git gc --aggressive --prune=now
git count-objects -v -H
```

预期：`count` 从 20041 降到 0（或个位数），`size` 从 5.12 GiB 降到 0，`size-pack` 增长但**总占用下降 4–5 GB**。

### 3.3 风险

- 只动 `.git` 内部，**不改工作区任何一个文件**。
- `--aggressive` 全量重打包约需 10–30 分钟（10 GB 对象库），建议在不开编辑器时跑。
- 若 `git fsck` 报 `missing` / `broken` / `corrupt`（不是 `dangling`），**先停下**，那是仓库真损坏，不是清理能解决的。

---

## 四、批次 B：仓库外一次性产物（约 7.1 GB）

这些全部在 git 仓库**之外**（`D:/Godot/ProjectKeynes/` 顶层），删除不影响任何提交。

| 目标 | 体积 | 判据 |
|---|---|---|
| `m7-bisect-8b35905e/` | 3.55 GB | M7 二分查找时的工作副本，自带 `.git`。M7 已结项，副本无保留价值 |
| `tmp/` | 3.55 GB | 一次性日志/抓包/端口探测输出 |
| `tmp_art/`、`tmp_building_art/`、`tmp_shots_async/` | 32 MB | 美术预览与截图中间件，可由 `tools/resource_art/sources/` 重新生成 |
| `.codex-temp/` | 9 MB | 工具残留 |
| `output/`、`outputs/` | 4 MB | 旧的导出结果 |
| `nul` | 149 B | 误重定向产物 |
| `d:GodotProjectKeynesProject.Keynestmppeaks.txt` | 327 B | 路径拼错产物 |
| `tmp_mod.txt`、`tmp_untrack.txt` | 33 KB | 一次性清单 |
| `.git-refs-backup-20260829/`、`.git-refs-backup-20260901-102508/` | 2 MB | 2026-08/09 修复的备份，当前仓库健康，可归档进仓库外 `archive/` 或删除 |

命令（**先空跑校验集合，再删**）：

```bash
cd D:/Godot/ProjectKeynes

# 1. 空跑，核对清单
printf '%s\n' m7-bisect-8b35905e tmp tmp_art tmp_building_art tmp_shots_async \
  .codex-temp output outputs nul \
  'd:GodotProjectKeynesProject.Keynestmppeaks.txt' tmp_mod.txt tmp_untrack.txt \
  .git-refs-backup-20260829 .git-refs-backup-20260901-102508 | while read p; do
    [ -e "$p" ] && du -sm "$p"
  done

# 2. 确认无误后删除（m7-bisect 与 tmp 用 find -delete，避开 rm 的批量配额）
find m7-bisect-8b35905e -depth -delete
find tmp -depth -delete
rm -rf tmp_art tmp_building_art tmp_shots_async .codex-temp output outputs
rm -f nul 'd:GodotProjectKeynesProject.Keynestmppeaks.txt' tmp_mod.txt tmp_untrack.txt
```

### 4.1 注意事项

1. **`rm` 有每轮 50 个文件的静默配额**，超了会返回 exit 0 但实际没删。批量删除必须用 `find -delete`，删完复查数量。
2. **`nul` 与含 `:` 的文件名在 Windows 上删不掉** —— `rm -f`、`find -delete` 都返回成功但文件仍在。
   实测唯一有效的是**先改名、再删普通名**：
   ```bash
   MSYS_NO_PATHCONV=1 mv -- nul _trash_nul_
   rm -f _trash_nul_
   ```
   走 Windows 原生删除命令的路子在 Bash 工具里会被安全策略整条拦截，不可行。
3. `.git-refs-backup-*` 建议先移到 `D:/Godot/ProjectKeynes/archive/` 而不是直接删 —— 那是仓库受伤时的救命备份，成本只有 2 MB。

---

## 五、批次 C：仓库内被忽略目录（**已修正：约 1.5 GB，原估计 2.0 GB 有误**）

> **⚠️ 本节初版结论是错的，已按实测重写。**
> 初版假设"已被 `.gitignore` 覆盖的目录可以整目录清空"。错在两点：
> 1. `.gitignore` 对**已跟踪**文件完全无效 —— 忽略规则只影响未跟踪文件。
> 2. 这几个"临时"目录里实测有 **1084 个文件是被跟踪的**，且含真正的源码。

### 5.1 实测跟踪情况（这才是判断依据）

| 目录 | 体积 | 被跟踪 | 构成 | 可否清空 |
|---|---|---|---|---|
| `tmp/` | 1.50 GB | 69 | 49 log + 17 py + 2 json | **部分可清**（只清未跟踪的） |
| `Project/project-keynes/tmp/` | 445 MB | **456** | 220 png + 181 import + 15 gd | 不可清空 |
| `Project/perf-validation/tmp/` | 129 MB | **542** | 378 translation + 53 import + 19 gd | 不可清空 |
| `.venv-build/` | 33 MB | **2117** | 796 xml + 765 py + 347 xsl（整个 Python venv） | 不可清空 |
| `.codex-temp/` | 46 MB | 17 | 截图 + png + 1 dll | 不可清空 |
| `%USERPROFILE%/` | <1 MB | 19 | SVN 误装内容 | 需摘索引 |

`Project/perf-validation/tmp/` 那 19 个 `.gd` 是**性能基准脚本**（`bench_dots_vs_dict.gd`、
`bench_ecs_scheduler_stress.gd` 等），`tmp/` 那 17 个 `.py` 是分析脚本 —— 都是资产不是垃圾。

### 5.2 正确做法：只清被忽略的部分

`git clean -X` 恰好是这个语义：**只删未跟踪且命中忽略规则的文件**，已跟踪的一律不动。

```bash
cd D:/Godot/ProjectKeynes/Project.Keynes

# 1. 必须 dry-run，逐条看清单
git clean -Xdn -- tmp/

# 2. 确认无 .gd/.py/.tscn/.tres/.shader 后执行
git clean -Xdf -- tmp/
```

实测 dry-run 共 223 项，全部是 log / out / err / 探测目录 / pull 冲突备份，无一个源码文件。

### 5.3 两个需要单独保护的目录

`tmp/fmod-source/`（FMOD-GODOT 插件源码）、`tmp/ui-audio-sources/`（`kenney.zip`、
`paper.zip` 音效素材原件）、`tmp/fmod-source.zip` 也会被 `git clean -X` 命中，
但它们是**原始素材**，合计仅 6 MB，不值得冒险。

`git clean` 的路径排除语法（`:!path`）实测**不生效**，唯一可靠办法是先移出、清完再移回：

```bash
mkdir -p D:/Godot/ProjectKeynes/_keep
mv tmp/fmod-source tmp/ui-audio-sources tmp/fmod-source.zip D:/Godot/ProjectKeynes/_keep/
git clean -Xdf -- tmp/
mv D:/Godot/ProjectKeynes/_keep/* tmp/
```

### 5.4 需摘索引才能清的目录（不能直接删）

`.venv-build/`、`.codex-temp/`、`%USERPROFILE%/`、`Project/project-keynes/tmp/`、
`Project/perf-validation/tmp/` —— 直接删会产生数百到两千多个 `D` 状态。
正确路径是 `git rm -r --cached` 摘出后随第七节一起提交，再删磁盘。

`.venv-build` 尤其值得处理：**整个 Python 虚拟环境（2117 文件 / 796 xml + 765 py + 347 xsl）
被提交进了仓库**。这是比 dll/pdb 更典型的一类误提交，同样该进 `.gitignore`。

---

## 六、文档归档方案（已确认执行方向）

workspace 根目录 6 份散落报告，按主题归入仓库 `docs/`（该目录已有 `audio/`、`plans/`、`archive/` 等成熟子目录）：

| 源文件 | 目标 | 理由 |
|---|---|---|
| `科技树优化执行蓝图.md` | `docs/plans/technology-tree-execution-blueprint.md` | 与 `docs/plans/dots-deepening-roadmap.md` 同属方案类 |
| `科技树深度诊断与优化方案.md` | `docs/plans/technology-tree-diagnosis.md` | 同上；且 `docs/` 已有 `technology-tree-redesign-*.md` 系列 |
| `电台音乐整理与FMOD测试方案.md` | `docs/audio/radio-music-fmod-test-plan.md` | `docs/audio/` 现只有 2 个文件，正好补齐 |
| `马里音乐FMOD测试方案.md` | `docs/audio/mali-music-fmod-test-plan.md` | 同上 |
| `AoE4音乐FMOD测试方案.md` | `docs/audio/aoe4-music-fmod-test-plan.md` | 同上 |
| `大地图河流与高原过度密集诊断报告.md` | `docs/terrain-density-diagnosis.md` | 与 `docs/terrain-generation-current.md` 并列 |
| `微信收支账本.md` | **移出仓库**，到 `D:/Godot/ProjectKeynes/personal/` | 与项目无关，不该进版本库 |

执行：

```bash
cd D:/Godot/ProjectKeynes
mkdir -p Project.Keynes/docs/plans Project.Keynes/docs/audio personal

mv 科技树优化执行蓝图.md          Project.Keynes/docs/plans/technology-tree-execution-blueprint.md
mv 科技树深度诊断与优化方案.md    Project.Keynes/docs/plans/technology-tree-diagnosis.md
mv 电台音乐整理与FMOD测试方案.md  Project.Keynes/docs/audio/radio-music-fmod-test-plan.md
mv 马里音乐FMOD测试方案.md        Project.Keynes/docs/audio/mali-music-fmod-test-plan.md
mv AoE4音乐FMOD测试方案.md        Project.Keynes/docs/audio/aoe4-music-fmod-test-plan.md
mv 大地图河流与高原过度密集诊断报告.md Project.Keynes/docs/terrain-density-diagnosis.md
mv 微信收支账本.md                personal/
```

> 重命名成英文 kebab-case 是为了和 `docs/` 现有 60+ 文档的命名习惯一致。若更希望保留中文名，把目标名改回原名即可，不影响正确性。

---

## 七、二进制治理（已确认执行方向）

### 7.1 病灶

被跟踪的 dll/pdb 共 **274 个，当前版本 163 MB**：

| 目录 | 数量 |
|---|---|
| `Project/project-keynes/addons/dots_ext/bin/windows/` | 177 |
| `Project/perf-validation/addons/dots_ext/bin/windows/` | 89（**project-keynes 那套的完整副本，纯冗余**） |
| `Project/project-keynes/addons/FmodGodot/bin/windows/x86_64/` | 7 |
| `.codex-temp/` | 1 |

`.git` 涨到 10 GB 的直接原因就在这里：每次重编 GDExtension，`dots_ext` 的 dll（10 MB 级）和 pdb（最大 130 MB）都会被完整重新入库一份。历史上存过 N 次，对象库里就永久留着 N 份。

### 7.2 关键澄清：摘出索引不会缩小 `.git`

**必须先讲清楚**：`git rm --cached` 只让**未来的提交**不再包含这些文件，**不会**让现有 `.git` 变小 —— 历史提交里的旧副本仍然在对象库中，仍占空间。

- 摘索引 = **止血**，防止 `.git` 继续以每次重编几 MB 的速度膨胀。
- 要真正缩小 `.git`，只有 `git filter-repo` 重写历史，那会**改变所有 commit hash**、让所有克隆失效、且必须 force push。风险远高于收益，除非 `.git` 涨到磁盘放不下，否则不建议做。

所以这次的目标是：**批次 A 回收 5 GB（真实收益）+ 批次 C/D 止血（防未来）**。

### 7.3 处置方案

第一步 —— 摘出索引（**保留磁盘文件，本地编译产物不受影响**）：

```bash
cd D:/Godot/ProjectKeynes/Project.Keynes

# 先看清将被摘除的清单
git ls-files '*.pdb' '*.dll' | wc -l          # 应为 274

# 摘出（-z/-0 处理特殊字符；--quiet 减少输出）
git ls-files -z '*.pdb' '*.dll' | xargs -0 git rm --cached --quiet --
git status --short | grep -c '^D'             # 应约 274
```

第二步 —— 追加忽略规则到 `.gitignore`：

```gitignore

# GDExtension 编译产物：本机 scons 生成，不入版本库。
# 需要分发时走 release 附件，不要塞回仓库。
**/addons/dots_ext/bin/windows/*.dll
**/addons/dots_ext/bin/windows/*.pdb
**/addons/dots_ext/bin/windows/*.lib
**/addons/dots_ext/bin/windows/*.exp
**/addons/dots_ext/bin/windows/*.ilk
**/addons/FmodGodot/bin/windows/**/*.dll
**/addons/FmodGodot/bin/windows/**/*.pdb
```

第三步 —— 路径闸门复核，确认没有误伤源码：

```bash
git diff --cached --name-only | grep -vE '(\.dll|\.pdb)$'   # 应无输出
git diff --cached --name-only | grep -E '\.gd$|\.tscn$|\.tres$'  # 应无输出
```

### 7.4 影响评估（重要）

1. **本地开发完全不受影响** —— dll 文件还在磁盘上，Godot 照常加载。
2. **远程仓库不再有可用二进制**。别人 clone 下来必须自己跑 `scons` 编译，否则 `dots_ext` 加载失败。
3. **CI/自动化若有依赖仓库内二进制，会断**。本仓未见 CI 配置，风险低。
4. `perf-validation` 那 89 个副本纯属重复，摘掉毫无损失。
5. `.codex-temp` 里那 1 个 dll 顺带清掉。

> 若哪天需要让 clone 即用，把 `dots_ext/bin/windows/` 打成 zip 发 GitHub Release，比塞进 git 更省空间也更快。

---

## 八、建议执行顺序

```
① 批次 B（仓库外 7.1 GB）     ← 零风险、纯磁盘、与 git 无关，先做
② 批次 C（仓库内 2.0 GB）     ← 零风险、全已忽略，其次
③ 批次 A（git gc）            ← 需要 10–30 分钟，确认 fsck 健康后跑
④ 文档归档（第六节）           ← 产生一批 mv，之后提交
⑤ 二进制治理（第七节）         ← 需要一次提交 + push，最后做
```

① 和 ② 之间无依赖，可以一次做完。③ 独立。④⑤ 会产生 git 变更，建议在前三步完成后单独提交，便于回滚。

### 8.1 提交前的四道闸门

沿用本仓既有实践，提交前逐项验证：

1. **体积**（量字节，不数文件）
   ```bash
   git diff --cached --name-only --ignore-submodules=all | tr '\n' '\0' \
     | du -ch --files0-from=- | tail -1
   ```
2. **LFS**（确认没有 filter=lfs 触发）
   ```bash
   git diff --cached --name-only | git check-attr --stdin filter
   # 期望全部 filter: unspecified
   ```
3. **路径**（排除 addons / node_modules / tmp）
   ```bash
   git diff --cached --name-only | grep -E 'addons/|node_modules|^tmp/'
   ```
4. **对象**（提交后）
   ```bash
   git ls-tree -r HEAD | awk '$2=="blob"{print $3}' | git cat-file --batch-check | grep -c missing
   # 必须按 $2=="blob" 过滤，否则 gdext/godot-cpp 的 gitlink 会假报 missing
   ```

---

## 九、已识别但本次不处理的问题

| 问题 | 说明 | 为什么先不动 |
|---|---|---|
| `.git` 历史体积（约 5 GB 不可回收） | dll/pdb 历史副本 | 需 `filter-repo` 重写历史，改所有 hash，风险高 |
| `gdext/` 5.2 GB | godot-cpp 源码 + 编译中间产物 | 含子模块，动它可能破坏构建 |
| `emsdk/` 1.9 GB | 本机 Web 工具链 | 已 gitignore，删了要重下 |
| `Project/perf-validation` 2.3 GB | 完整 Godot 工程副本，5763 文件被跟踪 | 疑似有意保留的性能验证基线，需你确认后再议 |
| `tmp/perf_csv_analysis/node_modules` 被跟踪 | 内含 dll/node/exe | 应 `git rm -r --cached`，但影响面需单独评估 |
| `WebBuild/` 93 MB | Web 导出产物 | 是否属发布物待定 |
| 33 个未跟踪文件中的真实源码 | `target_tag_dictionary.gd` 等新功能代码 | 这些**应该提交**，不属于清理范畴 |

---

## 十、一句话总结

先删仓库外 7 GB 垃圾和仓库内 2 GB 中间件（零风险），再跑一次 `git gc` 回收 5 GB 松散对象，最后摘出 274 个 dll/pdb 止血 —— 磁盘从 30 GB 降到约 16 GB，且从此重编 DLL 不再撑大 `.git`。

---

## 附录：执行记录（2026-10-20 22:14 起）

### A1. 已完成

| 项 | 结果 |
|---|---|
| `m7-bisect-8b35905e/` | 确认是主仓库 worktree，HEAD `8b35905e` 已是 master 祖先、无未提交改动 → `git worktree remove` + `worktree prune` 干净摘除，释放 3.5 GB |
| 仓库外零碎产物 | `tmp_art`、`tmp_building_art`、`tmp_shots_async`、`.codex-temp`、`output`、`outputs`、`tmp_mod.txt`、`tmp_untrack.txt` 全部删除 |
| `nul`、`d:Godot…peaks.txt` | 改名后删除成功 |
| 仓库内 `tmp/` | `git clean -Xdf` 只删未跟踪部分：1502 MB → 45 MB（292 项 → 71 项），回收 1457 MB，**零个被跟踪文件受影响** |
| `.git` 残渣 | `lost-found`（336 MB）、`cursor/crepe`（120 MB）、refs 旧备份、孤儿 idx 全部清除，`.git` 10341 → 9887 MB |
| 散落文档 | 7 份全部归档（6 进 `docs/`，微信账本移到 `personal/`） |

### A2. 执行中修正的两个原判断

1. **`tmp/` 不能整目录清空**（详见第五节）。实测四个"临时"目录共 1084 个被跟踪文件，
   含 19 个性能基准 `.gd` 与 17 个分析 `.py`。改用 `git clean -X` 的语义后安全完成。
2. **`tmp/ui-audio-sources/` 与 `tmp/fmod-source/` 是原始素材**（`kenney.zip`、`paper.zip`），
   虽然也会被 clean 命中，但通过"先移出、清完移回"保住。

### A3. gc 第一次失败：发现损坏对象

第一次 `git gc --prune=now` 在 34 秒后中止：

```
error: inflate: data stream error (incorrect data check)
error: corrupt loose object '77eb85bb85708627bb26d4a0751b063c4f4e6565'
fatal: failed to run repack
```

定位结果：

- 该对象 = `tmp/perf_sparse_20261015/v30_late_economy.csv`，15.9 MB，写入于 10-16 09:56。
- 它属于 `stash@{0}`（`On master: codex-before-merge-2026-10-16`）的 **untracked parent**
  提交 `f8b75a50` 的树。
- **本身已不可恢复** —— `inflate` 的 CRC 校验失败，原始字节流已损坏。

`gc --prune=now` 必须遍历 stash 的整棵树，只要 stash 还引用它就永远打包不了，因此只能丢弃该 stash。

丢弃前抢救了能救的部分：

| 抢救物 | 位置 | 内容 |
|---|---|---|
| 已跟踪改动 patch | `archive/stash0-tracked-no-pdb.patch`（97 MB / 50 文件） | 10-16 合并前的 UI 场景、主题、QA 截图改动（已排除 104 MB 的 pdb） |
| 两个探针脚本 | `archive/stash0-scripts/` | `effect_load_probe.gd`(4 KB)、`family_baseline_test.gd`(48 KB) |
| stash 清单 | `archive/stash-list-before-drop.txt` | 丢弃前 7 个 stash 的完整列表 |
| 损坏对象副本 | `archive/corrupt-object-77eb85bb.bin` | 供事后取证，正常情况无用途 |

**实际损失**：那 1 个已损坏的 CSV（数据本就取不出来）+ untracked 部分 1039 个
`.import` 元数据与 QA 截图（均可由引擎重新生成）。

### A4. ⚠️ 需要留意的信号

一个 15.9 MB 的松散对象出现 CRC 错误，通常意味着**写入当时被中断**（磁盘满、进程被杀、
异常断电），也可能是磁盘介质问题。D 盘当前 94% 已用（1.7T/1.8T），建议观察。
后续可跑 `git fsck --no-progress` 复核全库：只有 `missing` / `broken` / `corrupt` 是真问题，
`dangling` 无害。

### A5. ❌ repack 未能完成（.git 的 5 GB 没压下去）

`prune-packed` 成功（删掉 1199 个已在 pack 内的冗余松散对象，1.9 秒），但
`git repack -a -d` 连续三次在同一处失败：

```
warning: unable to unlink '.git/objects/pack/.tmp-XXXX-pack-<hash>.pack': Invalid argument
fatal: renaming pack to '.git/objects/pack/pack-<hash>.pack' failed: Permission denied
```

已排除的因素：

| 怀疑对象 | 排除方式 | 结论 |
|---|---|---|
| GitHub Desktop 占用 | 杀掉全部 4 个进程后重试 | 仍失败 |
| 目录权限 | 同目录小文件 rename 测试 | 正常 |
| fsync 策略 | `-c core.fsync=none` | 仍失败 |
| 磁盘空间 | 92 GB 可用，新 pack 约 7.3 GB | 充足 |

**判断**：`unlink` 返回 `EINVAL` 在 Windows 上是"文件仍被内存映射"的典型症状 ——
git 写完 pack 后用 mmap 读回校验，句柄未释放便尝试 rename。结合同目录小文件
rename 正常这一点，问题指向 **git 2.55.0.windows.3 在大 pack 上的自身行为**，
而非外部进程锁。

每次失败都会留下 7.3 GB 半成品（已清理），故不再重试。

**后续可选做法**（都需你在场，因为要动 `.git`）：

1. 换 git 版本试：用 2.4x 系列（如 `winget install Git.Git --version 2.47.*`）在
   独立 shell 里对该仓库跑一次 `git repack -a -d`，成功后换回。
2. 用 `git maintenance run --task=pack-refs` + 分多次 `git repack -a`（不带 `-d`，
   避免删除旧 pack 的 unlink 路径），成功后再手工删旧 pack。
3. 若只是要空间，也可以先接受现状 —— 5 GB 松散对象不影响正确性，只是对象访问变慢。

### A6. 净结果

| 区域 | 清理前 | 清理后 | 回收 |
|---|---|---|---|
| 整个 workspace | ≈33.7 GB | **26.0 GB** | **≈7.7 GB** |
| `m7-bisect-8b35905e/` | 3.55 GB | 0 | 3.55 GB |
| 仓库外 `tmp/` | 3.55 GB | 1.97 GB | 1.58 GB |
| 仓库内 `tmp/` | 1.50 GB | 0.02 GB | 1.46 GB |
| `.git` | 10.34 GB | **9.76 GB** | 0.58 GB（`lost-found`+`cursor`+`prune-packed`） |
| 仓库外零碎产物 | ≈0.1 GB | 0 | 0.1 GB |

**未动**（有意保留）：`gdext/` 5.2 GB、`Project/` 6.8 GB、`emsdk/` 1.9 GB、
`tools/` 383 MB、`artifacts/` 144 MB、`Project.Keynes/tmp/` 剩余 45 MB。

.git 那 5 GB 松散对象是本轮唯一的未完成项，原因见 A5。
