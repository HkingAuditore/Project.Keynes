# 打包分发（一键编译 + 出包）

一条命令：编译当前工作区的代码 → 导出 → 校验 → 生成可直接分发的 zip。

```bat
scripts\Pack.cmd                        :: Windows release（默认）
scripts\Pack.cmd -Mode debug            :: Windows debug
scripts\Pack.cmd -Targets web           :: Web 包
scripts\Pack.cmd -Targets windows,web   :: 两个都要
scripts\Pack.cmd -SkipNative -NoZip     :: 复用已有原生库，只出目录不压缩
```

底层是 `tools/pack.ps1`，参数与上面一致（`Get-Help tools\pack.ps1 -Full` 有说明）。

---

## 1. 产物在哪

```
Build\pack\<时间戳>\win64\        ← 原始产物（每次新建，不覆盖旧的）
  ProjectKeynes.exe               416 MB，pck 已内嵌（Windows 模板行为，没有独立 .pck）
  dots_ext_*.windows.template_release.x86_64.dll
  addons\FmodGodot\bin\windows\x86_64\*.dll
  README.txt                      给拿到包的人看
  build_info.json                 版本/提交/脏标记 + 每个文件的 sha256

Build\dist\ProjectKeynes-<版本>-win64-<mode>-<时间戳>.zip   ← 拿去分发的就是它
Build\dist\LATEST.txt                                        ← 最近一次的版本与哈希
```

`<版本>` 默认是 `git rev-parse --short HEAD`，工作区不干净时加 `-dirty`；要自定义用
`-Version v0.3`。

## 2. 它比旧的 `Build-Windows.cmd` 多做了什么

| 项 | 旧流程 | 现在 |
| --- | --- | --- |
| 输出目录 | 固定 `Build\ProjectKeynes-<mode>`，每次覆盖 | `Build\pack\<时间戳>`，旧的永远留着 |
| 分发包 | 手工压缩、手工命名 | 自动出 zip 并打印 sha256 |
| 可追溯 | 无 | `build_info.json`：提交、脏标记、Godot 版本、逐文件哈希 |
| 外部进程退出码 | `&` 调 exe，拿不到码；崩溃（负码）判不到 | 走 `cmd` runner 文件 + 哨兵文件，取到真实退出码 |
| 音频 | 依赖当时目录状态，容易静音 | 导出前注册 FmodGodot，**FMOD 运行库必随包**，缺了直接报错 |
| 产物校验 | 无 | 必须找到 exe（或 pck）+ dots_ext DLL；FMOD 模式下必须找到 `libFmodGodot.template_*.dll` |
| 启动自检 | 有（`--headless --quit`） | 保留，仍是硬门 |

## 3. 为什么要"注册 FMOD"这一步

`addons/FmodGodot/.gdignore` 会把 addon 挡在 `.godot/extension_list.cfg` 之外，而引擎启动时
**只加载列在这个文件里的扩展**。带着 `.gdignore` 导出，结果是：包里既没有 FMOD 运行库，
启动也不会去加载它——**静音**，而且从日志上看不出来（只是没有声音）。

所以打包器在导出前：去掉 `.gdignore` → `--import`（让列表收录）→ 导出 → **无论成功失败**都
把 `.gdignore` 和 `extension_list.cfg` 还原（`--import` 只会往列表里追加，不还原就会让桌面/
编辑器下次启动多认一个扩展）。还原状态记在 `tmp\pack_export_state.json`，中途被打断时下次
运行会先自愈。

不想带音频：`scripts\Pack.cmd -NoFmod`（会明确打印"导出不含音频"）。

## 4. 这台机器上的两个坑（已处理，别再踩）

1. **`Start-Process -Wait` 会挂住。** 本机的 `scons.exe` 是 shim，构建结束后进程树里仍有残留，
   `-Wait` 会一直等下去——本次实测挂了 6 分钟且没有任何进程在跑。打包器改为生成一个 `.cmd`
   runner 文件、用 `cmd /d /c` 执行、**靠 `.rc` 哨兵文件判定结束**并读取真实退出码，
   设 3600 s 上限。
2. **`& $exe` 取不到退出码。** 旧脚本全部是 `& $exe` + `$LASTEXITCODE`；0xC0000005 这类崩溃
   在 cmd 里是负码，`if errorlevel 1` 判不到，会把失败当成功。`tools/build_windows.ps1`
   已一并改掉（`Invoke-BuildExe`）。

## 5. 校验与已知边界

已验证（2026-11-27，release）：
- 原生库编译（scons `platform=windows target=template_release`）→ 导出 → `--headless --quit`
  自检 exit 0；
- 包内 14 个文件，含 FMOD 运行库与 `addons/FmodGodot/...` 整棵树；
- zip 343.8 MB，`build_info.json` 与 `LATEST.txt` 均已生成。

未验证 / 已知：
- **Windows 包没有在第二台机器上跑过**（自检只证明本机能启动）；
- 包体 344 MB（exe 416 MB）偏大，主要是 pck 内嵌了 Desktop FMOD bank（约 91 MB）与全部纹理。
  要小包可以裁 bank（会没音乐）或改导出预设排除不需要的目录；
- **Android 不在本工具里**：仍用 `scripts\build_install_android.bat`（那个会装到设备上并抓
  logcat，是测试链路，不是分发链路）。需要分发 APK 时另说（还要签名配置）。
- 工作区不干净时包名带 `-dirty`，**这是刻意保留的信息**：分发出的包能对回一个提交，
  但对不回干净状态。
