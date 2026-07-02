---
name: skill-version-manager
description: >
  Manage team-shared CodeBuddy assets (skills, agents, commands, rules) via SVN.
  All operations are thin wrappers around Python scripts — the AI only needs
  to run commands, not understand the implementation.
  Trigger phrases: "sync skills", "sync agents", "sync rules", "sync commands",
  "upload skill", "upload agent", "upload rule", "download skill",
  "publish skill", "review skills", "skill status", "check for updates",
  "同步skill", "同步agent", "同步rule", "上传skill", "下载skill", "检查更新".
---

# Skill Version Manager (v4.3 — Smart Upload)

Run scripts in `{SKILL_DIR}/scripts/`. Pass arguments directly. **Do NOT reimplement any logic in the prompt.**

Supports 4 asset types: `skills`, `agents`, `commands`, `rules`.
Each type can have role groups: `shared`, `art`, `ta`, `dev`, `user`.

## AI Behavior: Intent Mapping

When the user says **"同步 skill"** or **"sync skills"**:
- → Only sync `--type skills` (NOT other asset types)
- When user says "同步所有" or "sync all" → use `--type all`
- When user says "同步 agent/rule/command" → use the corresponding `--type`

**Role auto-detection**: The `--role` flag controls which group directories to sync.
If the user hasn't set their role yet, **ask them once** then save it:

```
python {SKILL_DIR}/scripts/sync_all.py --set-role <art|ta|dev>
```

After role is saved, all future syncs automatically filter by that role.
The user can always override with `--role all` to get everything.

## AI Behavior: Smart Upload Flow

**CRITICAL RULES (MUST follow ALL):**
1. **NEVER use raw `svn import`/`svn add` commands to upload assets.** Always use the `svn_transfer.py` script.
2. **NEVER guess or assume the `--group` parameter.** For new assets, you MUST ask the user to confirm the target group before uploading.
3. **Even if the context seems obvious** (e.g., a TA-related skill), still ask the user — they may have a different preference.

### Step 1: Call upload WITHOUT `--group`

```
python {SKILL_DIR}/scripts/svn_transfer.py --upload <name> --type skills
```

The script will automatically:
- Search SVN across **all groups** (top-level + shared/art/ta/dev/user) for the asset
- If found → **update in-place** at the existing location (no `--group` needed)
- If not found → output a `GROUP_REQUIRED` JSON with a recommended group, then exit with code 2

### Step 2: Handle exit code 2 (GROUP_REQUIRED)

If the command exits with code 2, the output contains JSON like:

```json
{
  "action": "GROUP_REQUIRED",
  "asset_name": "my-skill",
  "recommended_group": "art",
  "recommendation_reason": "content matches art-related keywords",
  "available_groups": ["shared", "art", "ta", "dev", "user"],
  "message": "Asset 'my-skill' is new. Recommended group: 'art'. Please confirm..."
}
```

**You MUST then:**
1. Show the user the recommendation and available groups
2. Ask the user which group to use
3. Re-run with `--group <confirmed_group>`:

```
python {SKILL_DIR}/scripts/svn_transfer.py --upload <name> --type skills --group <group>
```

### Summary

| Scenario | What happens |
|----------|-------------|
| Asset exists in SVN | Auto-detected, updated in-place. `--group` ignored if conflicts. |
| Asset is new + `--group` specified | Created in the specified group directly. |
| Asset is new + no `--group` | Exit code 2 + JSON recommendation → AI asks user → re-run with `--group`. |

> ⛔ **NEVER bypass the script by running `svn import`, `svn add`, or `svn copy` directly.**
> The script handles group detection, catalog updates, and conflict resolution.
> Bypassing it causes assets to land in wrong locations and miss catalog registration.

## Quick Reference

### Role Setup (first time only)

| User Intent | Command |
|-------------|---------|
| **Set role (ask user first!)** | `python {SKILL_DIR}/scripts/sync_all.py --set-role art\|ta\|dev` |
| Sync with saved role | `python {SKILL_DIR}/scripts/sync_all.py` ← auto uses saved role |
| Override: sync all roles | `python {SKILL_DIR}/scripts/sync_all.py --role all` |

### Sync (batch, pure CLI, zero token)

| User Intent | Command |
|-------------|---------|
| **Sync skills** | `python {SKILL_DIR}/scripts/sync_all.py` |
| Sync all asset types | `python {SKILL_DIR}/scripts/sync_all.py --type all` |
| Sync agents only | `python {SKILL_DIR}/scripts/sync_all.py --type agents` |
| Sync rules only | `python {SKILL_DIR}/scripts/sync_all.py --type rules` |
| Sync by role (explicit) | `python {SKILL_DIR}/scripts/sync_all.py --role art\|ta\|dev` |
| Sync specific names | `python {SKILL_DIR}/scripts/sync_all.py --names name1 name2` |
| Dry-run preview | `python {SKILL_DIR}/scripts/sync_all.py --dry-run` |

### Upload / Download (per asset)

| User Intent | Command |
|-------------|---------|
| **Upload a skill (smart)** | `python {SKILL_DIR}/scripts/svn_transfer.py --upload <name> --type skills` |
| Upload to a specific group | `python {SKILL_DIR}/scripts/svn_transfer.py --upload <name> --type skills --group user` |
| Upload an agent | `python {SKILL_DIR}/scripts/svn_transfer.py --upload <name> --type agents` |
| Upload a rule | `python {SKILL_DIR}/scripts/svn_transfer.py --upload <name> --type rules` |
| Upload all skills | `python {SKILL_DIR}/scripts/svn_transfer.py --upload-all --scope user --type skills` |
| **Download one asset** | `python {SKILL_DIR}/scripts/svn_transfer.py --download <name> --type skills` |
| **List SVN assets** | `python {SKILL_DIR}/scripts/svn_transfer.py --list --type skills` |
| List agents | `python {SKILL_DIR}/scripts/svn_transfer.py --list --type agents` |

> **Note**: Prefer uploading WITHOUT `--group` — the script auto-detects existing assets in SVN. Only specify `--group` when the script asks (exit code 2) or when you're certain of the target group.

### Other Operations

| User Intent | Command |
|-------------|---------|
| **Check for updates** | `python {SKILL_DIR}/scripts/auto_update.py --check` |
| Self-update (auto) | `python {SKILL_DIR}/scripts/auto_update.py --self-update` |
| **Publish (with review)** | `python {SKILL_DIR}/scripts/publish.py --skill-name <name> --changelog "msg"` |
| Review pending | `python {SKILL_DIR}/scripts/review.py --list` |
| Approve | `python {SKILL_DIR}/scripts/review.py --approve <name>` |
| Reject | `python {SKILL_DIR}/scripts/review.py --reject <name> --reason "why"` |
| **View status** | `python {SKILL_DIR}/scripts/status.py --list` |
| **Init / reconfig** | `python {SKILL_DIR}/scripts/init_repo.py --check` |
| | `python {SKILL_DIR}/scripts/init_repo.py --init --svn-url <url> --username <user>` |
| **Admin management** | `python {SKILL_DIR}/scripts/config_manager.py --list-admins` |

## Asset Types

| Type | SVN Path | Identifier |
|------|----------|------------|
| skills | `{svn_url}/skills/{group}/{name}` | SKILL.md |
| agents | `{svn_url}/agents/{group}/{name}` | directory |
| commands | `{svn_url}/commands/{group}/{name}` | directory |
| rules | `{svn_url}/rules/{group}/{name}` | .mdc file |

## Install Scope Rules

**The `group` directory determines where assets are installed locally:**

| Group | Install Scope | Local Path |
|-------|---------------|------------|
| `user` | **user** (global) | `~/.<ide>/{type}/{name}` |
| `shared` | **project** | `{workspace}/.<ide>/{type}/{name}` |
| `art` | **project** | `{workspace}/.<ide>/{type}/{name}` |
| `ta` | **project** | `{workspace}/.<ide>/{type}/{name}` |
| `dev` | **project** | `{workspace}/.<ide>/{type}/{name}` |

- Only assets in the `user/` group are installed globally to `~/.<ide>/`
- All other groups (shared/art/ta/dev) are installed to the current project's `.<ide>/`
- This can be overridden with `--scope user|project` on the CLI or `install_scope` in manifest.json

## Role Filter Logic

| Role | Syncs these groups |
|------|--------------------|
| `art` | shared + art + user |
| `ta` | shared + art + ta + user |
| `dev` | shared + dev + user |
| `all` | everything |

Role is saved in `~/.codebuddy/skills/.svn-skill-manager/config.json` → `"role"` field.
Once set, the user never needs to specify `--role` again unless they want to override.

## First-Time Setup

If `init_repo.py --check` outputs `not_configured`, run `--init` with the user's SVN URL and username. Team name is auto-derived from the URL.

## Auto-Update Policy

When `auto_update.py --check` reports:
- `SELF_UPDATE_AVAILABLE` → auto-run `--self-update` silently
- `OTHER_UPDATES_AVAILABLE` → show list to user, update only after confirmation
- `ALL_UP_TO_DATE` → do nothing

## Important: Chat Mode Sync May Be Skipped

**Always attempt to execute the sync command first.** Do NOT preemptively warn the user before trying.

Only if the command execution returns `"Execution skipped: may take a long time"`, then tell the user:

> ⚠️ 同步操作在 Chat 模式下因耗时较长被系统跳过。请切换到 **Agent 模式** 后重新执行同步。

Do NOT attempt to work around this by splitting into smaller batches — directly recommend switching to Agent mode.

## Notes
- All SVN auth uses native credential caching — **never ask for passwords**
- Scripts handle all error cases and print human-readable messages
- `--type` defaults to `skills` when omitted — backward compatible
- `--role` reads from saved config when omitted — no need to repeat every time
- For detailed schema/format docs, see `{SKILL_DIR}/references/svn-repo-structure.md`
