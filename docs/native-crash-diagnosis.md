# 原生崩溃诊断手册（GDExtension / dots_ext）

> 首次成型于 2026-07-27，配套案例：经济 worker 线程堆损坏导致进入游戏必闪退。

## 1. 什么时候用这套流程

当出现下列任一现象时，**Godot 日志帮不上忙**，必须走本文流程：

- 游戏闪退，`godot.log` 没有任何 `ERROR`，日志在某一行**戛然而止**
- 时而闪退、时而卡死，同样的操作结果不一致
- 崩溃点看起来和最后一条日志毫无关系

原因：这类崩溃发生在 C++ 扩展里，进程被操作系统直接终止，GDScript 层没有机会打印任何东西。
更麻烦的是**堆损坏**——写坏内存的代码和最终崩溃的位置可以相隔很远、隔很久，日志最后一行几乎
总是无辜的。

## 2. 三个查看层次

| 层次 | 位置 | 能看到什么 |
| --- | --- | --- |
| Godot 日志 | `%APPDATA%\Godot\app_userdata\ProjectKeynes\logs\godot.log` | 崩溃前执行到哪，仅此而已 |
| 事件查看器 | `eventvwr.msc` → Windows 日志 → 应用程序，事件 ID 1000 | 出错模块、异常码、模块内偏移 |
| 崩溃转储 | 需先配置（见下） | 完整调用栈、所有线程、内存 |

常见异常码：

- `0xc0000005` 访问违规。指针无效或越界。
- `0xc0000374` **堆损坏**。堆的内部结构已被破坏，走 fast-fail 路径，**绕过 Godot 的 SEH 处理器，
  所以不会打印任何堆栈**。看到这个码基本可以断定是内存错误，且崩溃点不是第一现场。

## 3. 前置准备（一次性）

### 3.1 带符号构建

没有 pdb，堆栈只有一串地址。`debug_symbols=yes` 只加调试信息，**不改变代码生成**：

```powershell
cd gdext
scons platform=windows target=template_debug dev_build=no debug_symbols=yes -j8
```

产出的 `dots_ext.windows.template_debug.x86_64.pdb` 必须和 dll 放在同一目录。

> 构建前先确认没有残留的 Godot 进程占着 dll。卡死的 headless 测试进程会静默导致
> 「dll 更新了但 pdb 没更新」这种诡异状态。`Get-Process *odot* | Stop-Process -Force`。

### 3.2 调试器

Windows SDK 的调试工具组件（约 100MB，不必装整套 SDK）：

```powershell
Invoke-WebRequest "https://go.microsoft.com/fwlink/?linkid=2196241" -OutFile winsdksetup.exe
.\winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart
```

装完得到 `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\` 下的 `cdb.exe` 与 `gflags.exe`。

### 3.3 自动保留崩溃转储（一次性配置，需管理员）

```powershell
& .\tools\setup_godot_crash_dumps.ps1
```

脚本会自行请求管理员权限，并仅为 Godot 的常用可执行文件名注册 WER LocalDumps。转储自动保存到：

```text
%LOCALAPPDATA%\ProjectKeynes\CrashDumps
```

配置完成后仍然直接在编辑器里按 F5/F6。发生原生闪退时 Windows 自动生成 full dump，不需要从
命令行启动游戏。脚本可重复执行；升级 Godot 且可执行文件名发生变化时，把新名称加入脚本中的
`$godotExecutableNames` 后再运行一次。

项目已经在 `project.godot` 中启用 Godot 文件日志和 10 份轮转，普通错误与崩溃前输出位于：

```text
%APPDATA%\Godot\app_userdata\ProjectKeynes\logs
```

## 4. 关键一步：用 headless 复现

**不要在图形模式里反复试。** 先把问题挪到 headless：

```powershell
$exe = "<Godot>\Godot_v4.6.2-stable_win64_console.exe"
& $exe --headless --path <项目路径> --script res://tests/headless_perf_record.gd -- `
    days=10 speed=20 seed=20260719 width=50 height=40 `
    population_scale=0 use_saved_setup=false label=repro
```

收益极大：

- 一轮 16 秒，而不是每次手动点菜单
- 如果 headless 也崩，**立刻排除全部渲染/GPU 路径**，范围缩小一个数量级
- 可以脚本化跑几十轮，把概率性问题变成统计数据

> PowerShell 陷阱：仓库里的封装脚本设了 `$ErrorActionPreference='Stop'`，Godot 往 stderr 打一条
> 普通 WARNING 就会被当成致命错误中断，看起来像「崩了」。排查时直接用 `Start-Process` 调
> Godot 并重定向输出，绕开封装。

### 4.1 概率性问题要跑矩阵

内存损坏是否发作取决于堆布局，**单次结果没有意义**。本案例中同样参数的 60×40 地图，一轮崩、
下一轮就过。务必固定其他变量、每个配置跑 6 次以上再下结论。

「大地图不崩、中地图崩」这类现象通常**不是**尺寸的确定性 bug，而是并发窗口或堆布局的概率差异。

## 5. 抓第一现场：Page Heap

堆损坏的难点是崩溃点不是案发点。Application Verifier 的 page heap 会给每个堆块加保护页并校验
块头，让越界和重复释放**在发生的瞬间**就崩：

```powershell
$gf = "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\gflags.exe"
& $gf /p /enable Godot_v4.6.2-stable_win64.exe /full          # 检测越界写（块后保护页）
& $gf /p /enable Godot_v4.6.2-stable_win64.exe /full /backwards # 检测负索引写（块前保护页）
& $gf /p /disable Godot_v4.6.2-stable_win64.exe               # 用完务必关闭
```

注意事项：

- 目标是**主程序** `Godot_v4.6.2-stable_win64.exe`，不是 console wrapper
- 运行速度会慢 20 倍以上（16 秒的用例变 6 分钟），内存暴涨，full dump 可达 3GB
- 内存吃紧时 page heap 配额会耗尽并回退普通堆，导致保护页失效。可用大小区间只保护关心的块：
  `PageHeapSizeRangeStart` / `PageHeapSizeRangeEnd`（DWORD，字节）
- **用完一定要关**，否则用户正常玩游戏会以为电脑坏了

## 6. 分析转储

```powershell
$cdb = "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"
$sym = "srv*C:\symbols*https://msdl.microsoft.com/download/symbols;<dll 与 pdb 所在目录>"
& $cdb -z <dump.dmp> -y $sym -c ".ecxr;kb 30;!analyze -v;q" > analyze.txt
& $cdb -z <dump.dmp> -y $sym -c "~*kb 8;q" > threads.txt   # 所有线程，判断并发问题必看
```

读法要点：

- `!analyze -v` 的 `STACK_TEXT` 给出崩溃线程的调用链
- **`~*kb` 是判断数据竞争的关键**：看是否有多个线程同时停在同一个子系统里
- Verifier 的 `Arg4` 是块头标记值。`0xabcdbbbb` 表示该块**已处于已释放状态**，即重复释放或
  写坏了块头
- 块大小能反推是谁：844 字节 = 211 个 `int`，而 211 正落在 MSVC vector 1.5 倍增长序列
  （…94, 141, 211, 316…）上，据此可锁定具体是哪个容器

## 7. AddressSanitizer 为什么不可用

MSVC 的 `/fsanitize=address` **不支持只插桩扩展 DLL 而主程序未插桩**的混合进程。ASan 的 thunk
会在未插桩的 Godot 主程序里查找 `__asan_wrap_*` 导出并失败：

```text
==xxxxx==ERROR: Failed to find sanitizer DLL export '__asan_wrap_atoi'
```

`gdext/SConstruct` 保留了 `pk_asan=yes` 开关（默认关，不影响正常构建），仅在将来能整进程插桩时
可用。当前 Windows 上请用 page heap。

## 8. 案例：经济 worker 线程堆损坏（2026-07-27）

**现象**：进入游戏必闪退，日志停在 `[terrain_horizon] GPU bake applied`（无辜的最后一行）。
时而闪退时而卡死。大地图似乎正常，中地图必崩。

**定位过程**：headless 复现（16 秒）→ 排除 GPU → 尺寸矩阵发现结果不可复现，判定为概率性内存
错误 → full page heap + cdb 拿到第一现场 → `~*kb` 发现主线程与 WorkerThread 5 同时在
`NativeEconomyRuntime` 内。

**根因**：`stage_cell_summary()` 会向共享的 `_staging_touched_cells` 执行 `push_back`，而它被
市场结算并行段从多个 worker 线程并发调用。两个线程同时扩容 vector，同一块旧缓冲区被释放两次，
堆结构损坏；进程可能立刻挂，也可能拖到后面某次无关的内存操作才崩——这就是"时而闪退时而卡死"
的来源。

**修复**：引入 `thread_local` 的 `_staging_touched_sink`，worker 任务写各自的
`_staging_touched_task_scratch[task]`，并行结束后合并回共享列表。与同文件审计段
`_audit_task_totals_scratch` 是同一模式。消费者只做幂等回滚赋值，与顺序无关，因此合并顺序不
影响状态哈希。

**验证**：

| 配置 | 修复前 | 修复后 |
| --- | --- | --- |
| `worker_mode=OFF` ×6 | 0 崩溃 | 0 崩溃 |
| `worker_mode=ON` ×6 | **3 崩溃** | 0 崩溃 |
| full page heap ×1 | 崩溃并产生转储 | 完整通过，无转储 |

经济测试套件在修复前后失败项完全一致（均为工作区未提交经济改动带来的既有失败），确认无回归。

**教训**：

1. 日志最后一行对堆损坏几乎没有参考价值，不要从那里开始查
2. 概率性崩溃必须跑矩阵，单次结果会把人带偏（此案例一度误判为"和地图尺寸有关"）
3. 判断并发问题一定要看 `~*kb` 的全部线程，只看崩溃线程会漏掉另一半证据
4. 重编译解决不了代码 bug。若怀疑构建不一致，先比对 dll 字节数——本案例重编译前后
   完全一致，直接排除了这条路
