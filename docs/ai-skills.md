# AI skill 目录

本仓库只在 **`skills/`** 放一份 skill，每个是 `skills/<name>/SKILL.md`（可带 `references/`）。其它 AI 工具目录里的 `skills/` 都是指向它的链接，不进版本控制。

## 为什么这么放

旧仓库里 7 个工具目录各存一份副本，内容完全一样（36 个 skill、111 个 blob 逐一比对无差异），但**覆盖不全**：24 个 skill 六份齐全，3 个只有三份，9 个只有两份，其中 8 个只活在 `.agents` + `.codex`，`project-keynes-narrative-event-writing` 只活在 `.agents` + `.dsh` —— 等于 12 个 skill 在别的工具里根本读不到。现在统一从 `skills/` 分发，各工具都能看到同一组 skill。

## 各工具读哪个路径

`--scope project`（默认）落在仓库内，`--scope user` 落在用户主目录。下表两列都对。

| 工具 | project scope（默认） | user scope | 本机实测 |
|---|---|---|---|
| Claude Code | `<repo>/.claude/skills` | `~/.claude/skills` | `~/.claude` 存在但**没有** `skills/` 目录 |
| Codex | `<repo>/.codex/skills` | `~/.codex/skills` | 已存在 |
| Cursor | `<repo>/.cursor/skills` | `~/.cursor/skills` | 已存在 |
| CodeBuddy | `<repo>/.codebuddy/skills` | `~/.codebuddy/skills` | 已存在 |
| WorkBuddy | `<repo>/.workbuddy/skills` | `~/.workbuddy/skills` | 已存在 |
| DeepSeek Harness | `<repo>/.dsh/skills` | `~/.dsh/skills` | 已存在 |
| generic agents | `<repo>/.agents/skills` | `~/.agents/skills` | 已存在 |

`<repo>` 是仓库根目录；脚本按自身位置推算（`tools/sync_skills.py` → 上一级）。

## 换一台设备：三步

```bash
git clone <repo-url> Project.Keynes && cd Project.Keynes
python tools/sync_skills.py link      # 建链接
python tools/sync_skills.py check     # 各工具的可见数应等于仓库总数，缺 skill 时退出码 1
```

`check` 的退出码可以直接进 CI 或 pre-commit。要铺到用户主目录（不限于在仓库里工作）：

```bash
python tools/sync_skills.py link --scope user
python tools/sync_skills.py check --scope user
```

## 手工建链接（不想跑脚本时）

Windows，**junction 不需要管理员权限**，symlink 需要开发者模式或管理员：

```bat
mklink /J "%USERPROFILE%\.codex\skills" "%CD%\skills"
```

macOS / Linux：

```bash
ln -s "$PWD/skills" "$HOME/.codex/skills"
```

七个工具把 `.codex` 换成 `.claude` / `.cursor` / `.codebuddy` / `.workbuddy` / `.dsh` / `.agents` 即可。

## 命令

| 命令 | 作用 |
|---|---|
| `link` | 给 7 个工具建目录链接指向 `<repo>/skills`。已存在且指向正确的跳过；存在但指向别处的**报错不覆盖** |
| `unlink` | 只删这些链接，`skills/` 一个字节都不动 |
| `check` | 逐个工具列出实际可见 skill 数，缺的列名，不同步则退出码 1 |
| `copy` | 不支持链接的环境兜底复制，会打印「会漂移」警告 |

`--scope project|user` 对所有子命令生效，默认 `project`。

脚本只用 Python 标准库，**不含任何 git 命令**：生成物已进 `.gitignore`，没有 git 也该能跑。

## 不依赖锁文件

skill 由仓库自身承载：真源就是 `skills/`，工具靠目录链接读它。仓库里**没有** `skills-lock.json` 这类同步元数据 —— 原来的锁文件记录的是「七个 home 各有一份、内容哈希是多少」，单一真源之后没有可锁的东西，所以删掉了。增删 skill 只动 `skills/` 目录本身。

## 谁改 skill

只改 `skills/<name>/` 下的文件。链接会让 7 个工具立刻看到同一份内容，不需要再同步。

如果用 `copy` 兜底，副本会漂移 —— 每次 `git pull` 后重跑 `link` 或 `copy --force`。
