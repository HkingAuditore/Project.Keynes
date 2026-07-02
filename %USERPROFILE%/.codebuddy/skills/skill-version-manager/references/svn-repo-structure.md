# SVN Repository Structure & Data Format Reference

## Repository Directory Layout

```
trunk/                                  # Root directory (svn_url points here)
├── config/                             # Team configuration
│   ├── team.json                      # Team name and admin list
│   ├── settings.json                  # Global settings
│   └── .admin-verify                  # Nonce file for admin identity verification
├── history/                            # Audit trail
│   └── reviews.jsonl                  # Append-only review log
├── skills/                             # Skill assets
│   ├── _catalog.json                  # Asset catalog (roles, tags, search index)
│   ├── shared/                        # Shared across all roles
│   ├── art/                           # Art-specific
│   ├── ta/                            # TA-specific
│   ├── dev/                           # Dev-specific
│   ├── user/                          # User/personal assets (e.g. skill-version-manager)
│   └── <legacy-skills>/               # Existing skills at top-level (backward compat)
├── agents/                             # Agent assets
│   ├── _catalog.json
│   ├── shared/
│   ├── art/
│   ├── ta/
│   ├── dev/
│   └── user/
├── commands/                           # Command assets
│   ├── _catalog.json
│   ├── shared/
│   ├── art/
│   ├── ta/
│   ├── dev/
│   └── user/
└── rules/                              # Rule assets
    ├── _catalog.json
    ├── shared/
    ├── art/
    ├── ta/
    ├── dev/
    └── user/
```

## Asset Types

| Type | Local Directory | SVN Path | Identifier |
|------|----------------|----------|------------|
| skills | `~/.codebuddy/skills/` | `{svn_url}/skills/{group}/{name}/` | SKILL.md + manifest.json |
| agents | `~/.codebuddy/agents/` | `{svn_url}/agents/{group}/{name}/` | Directory with agent definition |
| commands | `~/.codebuddy/commands/` | `{svn_url}/commands/{group}/{name}/` | Directory with command definition |
| rules | `~/.codebuddy/rules/` | `{svn_url}/rules/{group}/{name}/` | .mdc file(s) |

## Role Groups

Each asset type directory contains role-based subdirectories:

| Group | Purpose | Who syncs it |
|-------|---------|-------------|
| `shared` | Common assets used by all roles | Everyone |
| `art` | Art/artist-specific assets | Art, TA |
| `ta` | TA-specific assets | TA |
| `dev` | Developer-specific assets | Dev |
| `user` | Personal/utility assets | Everyone (e.g. skill-version-manager) |

Role-based sync mapping (via `sync_all.py --role`):
- `--role art` → syncs `shared/` + `art/` + `user/`
- `--role ta` → syncs `shared/` + `art/` + `ta/` + `user/`
- `--role dev` → syncs `shared/` + `dev/` + `user/`
- `--role all` (default) → syncs everything

## manifest.json Schema

Each asset (in skills/agents/commands) should have a `manifest.json` in its root directory.

```json
{
  "skill_name": "example-skill",
  "version": "1.0.0",
  "author": "svn_username",
  "description": "Brief description of what the asset does",
  "created_at": "2025-01-15T10:30:00Z",
  "updated_at": "2025-01-15T10:30:00Z",
  "changelog": "Initial release with core features",
  "status": "pending",
  "reviewed_by": null,
  "reviewed_at": null,
  "reject_reason": null,
  "dependencies": [],
  "install_scope": "user",
  "roles": ["art", "ta"]
}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `skill_name` | string | Yes | Must match the directory name exactly |
| `version` | string | Yes | Semantic versioning (e.g., "1.0.0", "1.2.3") |
| `author` | string | Yes | SVN username of the publisher |
| `description` | string | Yes | Brief description |
| `created_at` | string | Yes | ISO 8601 timestamp of first publish |
| `updated_at` | string | Yes | ISO 8601 timestamp of latest update |
| `changelog` | string | Yes | Description of changes in this version |
| `status` | string | Yes | One of: `"pending"`, `"approved"`, `"rejected"` |
| `reviewed_by` | string\|null | No | SVN username of reviewer |
| `reviewed_at` | string\|null | No | ISO 8601 timestamp of review |
| `reject_reason` | string\|null | No | Reason for rejection |
| `dependencies` | string[] | No | List of other asset names this depends on |
| `install_scope` | string | No | `"user"` (default) or `"project"` |
| `roles` | string[] | No | Target roles: `["art", "ta", "dev"]` for filtering |

### Status Field Semantics

- **`pending`**: Asset published/updated, awaiting admin review.
- **`approved`**: Reviewed and approved. Only approved assets are synced on pull.
- **`rejected`**: Reviewed and rejected. Author should fix and re-publish.

## _catalog.json Schema

Each asset type directory has a `_catalog.json` for search indexing:

```json
{
  "assets": [
    {
      "id": "texture-import",
      "name": "Texture Import Helper",
      "description": "Auto-import textures with project naming conventions",
      "roles": ["art", "ta"],
      "tags": ["texture", "import", "naming"],
      "group": "art"
    }
  ]
}
```

## team.json Schema

Stored at `config/team.json`.

```json
{
  "team_name": "skills",
  "created_at": "2025-01-15T10:00:00Z",
  "admins": ["admin_user1", "admin_user2"]
}
```

## Local Configuration

Stored at `~/.codebuddy/skills/.svn-skill-manager/config.json`.

```json
{
  "svn_url": "https://svn.woa.com/UGameArt/CodeBuddySkill/trunk",
  "username": "my_svn_username",
  "last_sync_time": "2025-01-15T16:00:00Z",
  "initialized": true
}
```

> **Note**: `svn_url` points to `trunk/` (not `trunk/skills/`). All asset types are accessed as `{svn_url}/skills/`, `{svn_url}/agents/`, etc.
