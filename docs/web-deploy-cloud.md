# Web 包推送到自建 Windows/IIS 服务器

另一条发布链（OA Pages 静态托管）见 [`web-export.md`](./web-export.md) §2。
这里描述的是：把 `WebBuild/` 一键推到自己的 Windows Server + IIS 站点上，
就地覆盖 `/web-debug/`，旧版本留在旁边可一条命令切回。

仓库里**不含任何站点信息**（地址、端口、token、目录都在本机配置里）。理由同
`deploy_pages.py` 那套：仓库是公开的，站点地址与凭据一旦进 git 就收不回来。

---

## 1. 两块，各管一端

| 位置 | 文件 | 作用 |
| --- | --- | --- |
| 服务器 | `tools/remote/pk_web_receiver.ps1` | 单个 HTTP 监听器，收分块上传、校验 sha256、原子换站点目录、留旧版备份。一次性安装，之后常驻 |
| 服务器 | `tools/remote/Setup-Receiver.cmd` | 双击即装（自动提权），与旧部署包的 `一键部署.cmd` 同一套习惯 |
| 本机 | `scripts/Deploy-Cloud.cmd` → `tools/deploy_cloud.py` | 打 zip、分块推送、触发服务器换目录、打印结果 |
| 本机 | `~/.pk_cloud_deploy.json` | host / port / token / app / url，由 `--init` 交互生成 |

为什么不是 SSH/scp：这类机器的网络路径常常只转发明文 HTTP（实测到目标的
SSH/SMB/WinRM 在 TCP 三次握手后拿不到任何数据，`ssh` 报
`Connection timed out during banner exchange`），而 IIS 本身没有上传端点。
监听器 + 分块 HTTP 是唯一不依赖服务器改配置、也不依赖云安全组放行新协议的走法。

## 2. 服务器端一次性安装

把 `tools/remote/pk_web_receiver.ps1` 和 `tools/remote/Setup-Receiver.cmd` 一起拷到服务器
（RDP 剪贴板或任意方式），**右键 `Setup-Receiver.cmd` → 以管理员身份运行**即可；它自己提权，
参数与 ps1 一致（`Setup-Receiver.cmd -Diagnose -NoProbe`）。等价的手工方式是管理员 PowerShell 里：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\pk_web_receiver.ps1 -Install
```

它会：

1. 生成 token，存到 `%ProgramData%\pk-web-receiver\token.txt`（同时打印到屏幕）；
2. 检查 `Schedule` / `KtmRm` 两个服务，未运行就先启动（`KtmRm` 被禁用时会尝试
   `sc config ... start= demand` 再启，见下）；
3. 注册计划任务 `PKWebReceiver`（SYSTEM，开机自启）并立刻启动——先试
   `Register-ScheduledTask`，失败再退回 `schtasks /create`；
4. 加 Windows 防火墙入站规则（TCP 8099）。

**一台机器上可能不止一个站点。** `-Status` / `-Diagnose` 与每次部署都会列出**全部**目标：
凡是 `appcmd list vdir` 里路径以 `/web-debug` 结尾的站点都算（解析规则与旧
`deploy-web-debug.ps1` 一致；一个都没有时退回 80 端口站点根目录下的 `web-debug`）。
IP 站点和域名站点是两个 site、两个物理目录，只更一个就会出现"IP 上是新包、域名上还是旧包"
——旧部署包的 `部署说明.md` 专门警告过这一点，这里按同样口径处理：**一次全更**。

它**不能**替你在云控制台放行端口——同一端口要在安全组里开一次。

> **老系统上的坑（Server 2012 R2 实测）**：`schtasks /create` 可能返回
> `错误: 请求的操作是在不再活动的事务的上下文中进行的`（`0x1A2F`
> `ERROR_TRANSACTION_NOT_ACTIVE`）。任务计划在那一代 Windows 上是**用 TxF 写任务文件**的，
> TxF 依赖 `KtmRm` 服务；`KtmRm` 被停/禁用时就是这个错。脚本会先把它拉起来；
> 如果仍然建不了任务，用降级模式（见下），不必和计划任务死磕。

常用参数与模式：

```powershell
... -Install -Port 8099 -AppName web-debug    # 换端口/换应用名
... -Status                                    # 任务状态、监听端口、解析到的目录、token
... -Diagnose                                  # PowerShell/OS/服务/schtasks/任务模块体检
... -Diagnose -NoProbe                         # 同上但不创建临时任务（无副作用）
... -StartHidden                               # 立刻后台跑监听器（关窗口不死，重启不活）
... -Stop                                      # 停掉监听器
... -RegisterAutostart / -UnregisterAutostart  # 计划任务不可用时的降级自启（用户登录时启动）
... -Uninstall                                 # 删任务 + 防火墙规则 + 自启 + 未完成会话
... -Foreground                                # 前台跑（调试用，等于计划任务里的那个子进程）
```

日志：`%ProgramData%\pk-web-receiver\receiver.log`。

### 2.1 计划任务建不起来时

`-Install` 在两种注册方式都失败时不会假装成功，它会说明失败原因并保持监听器**未启动**，
然后给两条路：

1. `-StartHidden` 立刻把监听器跑起来（本机已实测可用），再 `-RegisterAutostart`
   写 `HKLM\...\Run`，登录时自启；
2. 修好计划任务（`-Diagnose` 看 `Schedule`/`KtmRm` 状态）后重跑 `-Install`。

降级模式的区别只有一个：**重启后要有人登录**才会起来；`-Install` 那条是开机即起、
不需要登录。

## 3. 本机一键推送

首次配置（只需一次）：

```bat
python tools\deploy_cloud.py --init
```

依次填 host（服务器公网地址）、port（默认 8099）、token（服务器 `-Install` 打印的那串）、
app（IIS 应用名，默认 `web-debug`）、url（不填则拼 `http://<host>/<app>/`）。

之后每次发版：

```bat
scripts\Deploy-Cloud.cmd            :: 打 zip + 推送 + 换目录
scripts\Deploy-Cloud.cmd --health   :: 先确认接收器活着（第一次配置完必跑）
scripts\Deploy-Cloud.cmd --dry-run  :: 只打 zip，打印计划，不上传
```

其它参数：`--root WebBuildDebug`（换源目录）、`--chunk-mb 4`（网关限制请求体时调小）、
`--retries 6`、`--with-sidecars`（连 `.br/.gz` 一起传）、`--host/--port/--token/--app`
（临时覆盖配置，不落盘）。

## 4. 一次推送实际做了什么

1. **打 zip**：从 `WebBuild/` 取全部文件，**默认丢掉 `.br/.gz` 边车**——IIS 自己压
   静态内容，边车是 ~100 MB 永不读取的上传量。要求至少有一个 `.pck`，否则直接拒绝。
2. **分块上传**：8 MB 一块，每块带 `offset`。任何一块失败单独重试；服务器已有的字节数
   比客户端多时返回 `409 + expected_offset`，客户端只补发缺的尾巴，不重传整包。
   `begin` 时带整个 zip 的 sha256，服务器在换目录前比对，不一致直接拒绝。
3. **换目录（在服务器上，原子；有几个站点就做几次）**：
   - 解压一次到 `<状态目录>\staging-<timestamp>`，校验包里有 `.html` 和 `.pck` 才继续；
   - 往包里补三个文件：`web.config`（COOP/COEP/CORP 三个头 + `.wasm` / `.pck` /
     `.worklet.js` 的 MIME）、`index.html`（跳转到 `ProjectKeynes.html`，与现网一致）、
     `check.html`（浏览器端 COI 自检页，见 §4.1）；
   - 每个目标各拷一份到 `<目标>.new-<timestamp>`；旧目录改名为
     `<目标>.bak-<timestamp>`，新目录改名上位；换失败自动把旧目录改回来；
   - `icacls` 给 `IIS_IUSRS` 读权限（目录是 SYSTEM 新建的）；
   - 备份只留**最新 2 份**，更早的自动删。
4. **回报**：每个站点的目录、访问 URL、备份、探测状态，加上文件数、总字节数，以及从
   `manifest.json` 读出的 `build_id`（可以和本机 `WebBuild\manifest.json` 对一下是不是同一版）。

### 4.1 `check.html` 与 https

部署后每个站点目录里都会多一个 `check.html`，打开它会直接告出 `isSecureContext` /
`crossOriginIsolated` / `SharedArrayBuffer` 三项——threads 版三样缺一不可。

关键点：**`SharedArrayBuffer` 只在 secure context 里可用**，所以用
`http://<公网 IP>/web-debug/` 这种明文地址打开时，即使 COOP/COEP 头都对，浏览器也不会给
`crossOriginIsolated = true`，表现就是白屏或引擎报 Cross-Origin Isolation。真正能玩的入口
必须是**带证书的域名**（走 https）。工具会为每个站点打印 URL，若该站点没有 https 绑定会
单独警告并给出它的 `check.html` 地址。

部署过程中的本地探测（`http://127.0.0.1/<app>/index.html`）只用于两件事：识别 500.19 并
自动 `appcmd add app` 重试一次、以及把每站的状态回报给你。**探测失败不判部署失败**
（服务器上若 IIS 只绑域名、127.0.0.1 打不到，就会显示 `no response ...`）。

## 5. 回滚

服务器上把最近一份备份改回原名即可（在服务器上执行）：

```powershell
Rename-Item .\web-debug .\web-debug.failed-<stamp>
Rename-Item .\web-debug.bak-<stamp> .\web-debug
```

备份在站点目录的同级，不在包里，所以回滚不需要重新上传。

## 6. 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `-Install` 报 `请求的操作是在不再活动的事务的上下文中进行的` | 计划任务走 TxF，`KtmRm` 未运行/被禁用。脚本会尝试拉起并改启动类型；仍不行就用 `-StartHidden` + `-RegisterAutostart` |
| `-Install` 之后 `-Status` 显示 task 有、`listening` 没有 | 任务已注册但子进程没起来：看 `%ProgramData%\pk-web-receiver\receiver.log`；多半是端口被占或脚本被杀软拦 |
| `--health` 连不上（超时） | 安全组没放行该端口，或 Windows 防火墙规则被删；`-Status` 看监听是否在 |
| `401` | token 不对；服务器 `-Status` 看真实 token，本机 `--init` 重填 |
| `409` 且提示"服务器已有 N 字节，与本地 M 对不上" | 上一次会话残留或包被换过；按提示 `DELETE /upload?session=` 后重跑 |
| `500 package checksum mismatch` | 传输中被改写（代理/断点）；重跑一次即可 |
| 某一块反复失败 | 网关限制请求体大小：`--chunk-mb 4` 或 `2` |
| 页面 500.19 | 服务器的 IIS 不允许 `web.config` 覆盖该节；确认只保留了 receiver 写的那份 `web.config` |
| 游戏白屏但 html 200 | 缺 COOP/COEP（`web.config` 被覆盖）或 `libdots_ext…wasm` 没上传；比对 `manifest.json` |
| 白屏，`check.html` 里 `crossOriginIsolated=false` 但头都在 | 你用的是 `http://IP/...`：明文 IP 不是 secure context，`SharedArrayBuffer` 不给。换 https 域名入口 |
| 只更了一个站点（IP 新、域名旧） | 该站点的 `web-debug` 不是通过 `appcmd` 可见的虚拟目录；`-Status` 看解析结果，必要时用 `-AppName` 对齐目录名 |

## 7. 已验证 / 未验证（2026-11-27）

已在本机回环上跑通完整链路（真实 116.8 MB 包，15 块，2–3 s）：

- 分块上传 + 服务器侧拼接，最终 `ProjectKeynes.pck` 与 `WebBuild/` 逐字节一致；
- `409` 续传路径：重复发送同一块返回 `expected_offset`，客户端只补尾巴；
- `401`：错误 token 被拒且不再出现连接重置（响应前先把未读请求体排空）；
- sha256 不匹配被拒，站点目录保持原样；
- 换目录后旧文件（旧 pck / 旧杂项）不残留，`web.config` + `index.html` 就位，
  旧版完整保留在 `.bak-<timestamp>`，备份数量按 2 份裁剪；
- 降级模式：`-StartHidden` 起隐藏监听器 → token 从 `token.txt` 读取 → 完整部署一次成功
  → `-Stop` 只杀掉监听器、不误杀调用它的那个 shell；
- **多站点**：用 `PK_IIS_APPCMD` 指向一个假 `appcmd`（两个站点：`Default Web Site` 只绑
  http，`Toy Empire` 绑 http+https 到 `toyempires.top`），健康检查与部署都解析出两条目标，
  两个物理目录各换一次目录、各留一份 `.bak-<stamp>`、各写入
  `web.config` / `index.html` / `check.html`，旧杂项文件都不残留；
- URL 由客户端按「站点有真实主机名就 `scheme://host/<app>/`，否则 `http://<配置里的 host>/<app>/`」
  组合——服务端不再自己拼 `127.0.0.1:80` 这种无意义地址；
- `check.html` 落到每个站点目录（2829 B），打开即给 COI 三项结论；
- 控制台：`Deploy-Cloud.cmd` 先 `chcp 65001` 且 `PYTHONIOENCODING=utf-8`，中文提示不再乱码。

这轮同时修掉了四个会被"看起来成功"掩盖的缺陷，都写成了实测项：

1. 不带任何模式参数时会走到安装流程——现在只打印用法并 `exit 1`；
2. 计划任务/隐藏模式拉起的子进程**没有带上 `-Foreground`**，会打印用法后退出，
   即"安装成功但没人监听"——子进程参数现在统一由 `Get-ChildArguments` 生成；
3. 子进程从 `token.txt` 读到 token 后只写进了局部变量，鉴权用的是空的脚本变量，
   会稳定 401——现在统一用 `$script:Token`；
4. `-Stop` 按脚本名匹配进程，会连**调用它的那个 shell** 一起杀掉——现在只匹配带
   `-Foreground` 的监听进程。

未验证：真实服务器上的网络路径（安全组、中间网关对 8099 的转发）、
Windows Server 2012 R2 上 PowerShell 4.0/.NET 4.5 的实际行为
（脚本刻意只用 PS 3 起的语法与 `System.IO.Compression.ZipFile`，未用
`Expand-Archive`，也没有三元/`??`，全文纯 ASCII）。第一次上线请先跑 `-Diagnose` 与 `--health`。

## 8. 与旧部署包（`artifacts/web-debug-deploy/`）的关系

那份 2026-11-01 的手工包是这条链路的前身：一个 zip + `一键部署.cmd` + `deploy-web-debug.ps1`，
拷到服务器解压双击。它解决的是"怎么更新"，本工具解决"怎么不用每次手工搬 100 MB"。
下面几条是直接从它那边对齐过来的，改动都保留了原口径：

| 旧包的做法 | 这里怎么落地 |
| --- | --- |
| 默认更新**所有**存在 `<站点目录>\web-debug` 的站点（README 专门警告 IP/域名双站点会分叉） | `Resolve-TargetRoots` 返回全部目标，一次全更，逐个回报 |
| 随包带 `check.html`（`crossOriginIsolated` / `SharedArrayBuffer` 自检） | 每次部署自动写入 `check.html`（英文版，纯 ASCII） |
| 500.19 时自动 `appcmd add app` 再试 | 本地探测到 500 时同样 `appcmd add app` 并重探一次 |
| `一键部署.cmd` 自动提权、双击即用 | `tools/remote/Setup-Receiver.cmd` 同款：自动提权、参数透传 |
| `.cmd` 里一个中文字节都不许有（代码页会把行边界吃掉） | `Setup-Receiver.cmd` 与 `Deploy-Cloud.cmd` 全 ASCII；中文只在 ps1 / py 里 |
| 不写死站点物理路径，走 `appcmd list site/vdir` | 同样走 `appcmd`，保留 `-AppName` 覆盖 |

刻意不同的三点：

1. **它每次都要手工搬包**；这里装一次接收器后一条命令推送，且断点续传。
2. **它覆盖式复制**（先清空再拷）；这里是**目录级改名换位**，旧版整目录留着，回滚只是一次
   `Rename-Item`，不会出现"拷到一半失败留下半个包"。
3. **它在服务器上不留任何东西**（README §7 的承诺）；这里为了免搬运会常驻一个监听器和
   计划任务——不用时 `-Uninstall` 一条命令删干净。安全边界：单端口 + token，建议安全组只
   放行你自己的出口 IP；token 只存在服务器 `%ProgramData%` 与本机 `~/.pk_cloud_deploy.json`。
