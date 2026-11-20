#!/usr/bin/env python3
"""`.pkinc` 事故包检查工具（schema v1 消费者）。

用法：
    python tools/ci/inspect_incident.py <path.pkinc> [--json]

契约唯一真相：docs/runtime/incident-bundle-schema.md

做三件事：
1. 包级完整性：读 MANIFEST.json，校验 schema、成员清单、每个成员的 bytes 与
   sha256；缺成员要报出**具体缺哪个**，不许只说「包损坏」。
2. 事件级摘要：assert_id / reason / kind / stage / day / epoch / cell。
3. witness 表：字段 / 值 / 台账声明类型 / 类型是否匹配，并给出不变量判定。

witness 的期望类型来自 docs/runtime/invariants.json（R1 台账）。文件不存在时
退化为「只看类型自洽」，判定报 unknown —— 缺台账不能算作包损坏。

退出码（schema §4）：
    0  consistent（witness 与不变量自洽）
    1  violated（witness 与台账声明不符）
    2  包本身损坏或缺失成员
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

SCHEMA = "pkinc/1"
SUPPORTED_SCHEMAS = ("pkinc/1",)
MANIFEST = "MANIFEST.json"
# schema §2.2：commands.json 可选，其余必需。
REQUIRED_MEMBERS = ("incident.json", "witness.json", "cell.json",
                    "world.json", "hashes.txt")
MEMBER_HINT = {
    "incident.json": "事件身份与定位（assert_id/reason/kind/stage/day/epoch/cell）",
    "witness.json": "不变量 witness（可为 {}）",
    "cell.json": "失败格切片",
    "commands.json": "该 epoch 的命令子集（可选）",
    "world.json": "世界标量（seed/尺寸/编目哈希/国家数）",
    "hashes.txt": "state_hash 等纯文本哈希",
}

# 台账里的类型名 → 本工具接受的 Python 类型集合。
INT_TYPES = ("i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
             "int", "integer", "long", "size_t")
FLOAT_TYPES = ("f32", "f64", "float", "double")
BOOL_TYPES = ("bool", "boolean")
STR_TYPES = ("str", "string", "text", "stringname")


class CorruptBundle(Exception):
    """包级错误：缺成员、哈希不符、MANIFEST 不合法。一律退出码 2。"""


# ---------------------------------------------------------------------------
# 包读取与校验
# ---------------------------------------------------------------------------

def read_manifest(archive: zipfile.ZipFile) -> dict:
    names = archive.namelist()
    if MANIFEST not in names:
        raise CorruptBundle(
            "缺成员 %s（schema §2.2 要求第一个成员就是 MANIFEST.json；"
            "包里实际有：%s）" % (MANIFEST, ", ".join(names) or "空包"))
    try:
        raw = archive.read(MANIFEST)
    except (KeyError, zipfile.BadZipFile) as error:
        raise CorruptBundle("读不到 %s：%s" % (MANIFEST, error)) from error
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorruptBundle("%s 不是合法 UTF-8 JSON：%s" % (MANIFEST, error)) from error
    if not isinstance(manifest, dict):
        raise CorruptBundle("%s 顶层必须是对象" % MANIFEST)
    schema = manifest.get("schema")
    if schema not in SUPPORTED_SCHEMAS:
        raise CorruptBundle(
            "schema 不匹配：%s 声明 %r，本工具支持 %s（n-1 兼容只保证读 pkinc/1）"
            % (MANIFEST, schema, "/".join(SUPPORTED_SCHEMAS)))
    return manifest


def verify_members(archive: zipfile.ZipFile, manifest: dict) -> dict:
    """逐个成员核对 bytes 与 sha256。返回汇总；任何不符都抛 CorruptBundle。"""
    names = set(archive.namelist())
    declared_files = manifest.get("files")
    if not isinstance(declared_files, list):
        raise CorruptBundle("%s.files 必须是数组" % MANIFEST)

    errors: list[str] = []
    checked: list[dict] = []
    declared_names: list[str] = []
    for index, entry in enumerate(declared_files):
        if not isinstance(entry, dict):
            errors.append("files[%d] 不是对象" % index)
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            errors.append("files[%d] 缺 name" % index)
            continue
        declared_names.append(name)
        if name in declared_names[:-1]:
            errors.append("MANIFEST.files 重复登记成员：%s" % name)
            continue
        expected_bytes = entry.get("bytes")
        expected_sha = entry.get("sha256")
        if not isinstance(expected_bytes, int):
            errors.append("%s：MANIFEST 缺整数 bytes" % name)
            continue
        if not isinstance(expected_sha, str) or len(expected_sha) != 64:
            errors.append("%s：MANIFEST 的 sha256 必须是 64 位小写十六进制，实际 %r"
                          % (name, expected_sha))
            continue
        if name == MANIFEST:
            errors.append("MANIFEST.files 不得包含自身")
            continue
        if name not in names:
            errors.append("缺成员 %s（%s）" % (name, MEMBER_HINT.get(name, "MANIFEST 已登记")))
            continue
        try:
            data = archive.read(name)
        except (KeyError, zipfile.BadZipFile) as error:
            errors.append("读不出成员 %s：%s" % (name, error))
            continue
        actual_bytes = len(data)
        actual_sha = hashlib.sha256(data).hexdigest()
        if actual_bytes != expected_bytes:
            errors.append("%s 体积不符：MANIFEST 说 %d 字节，实际 %d 字节"
                          % (name, expected_bytes, actual_bytes))
        if actual_sha != expected_sha.lower():
            errors.append("%s sha256 不符：MANIFEST 说 %s，实际 %s"
                          % (name, expected_sha, actual_sha))
        checked.append({"name": name, "bytes": actual_bytes,
                        "sha256": actual_sha,
                        "sha256_ok": actual_sha == expected_sha.lower(),
                        "bytes_ok": actual_bytes == expected_bytes})

    for name in REQUIRED_MEMBERS:
        if name not in declared_names:
            errors.append("MANIFEST.files 缺必需成员登记：%s（%s）"
                          % (name, MEMBER_HINT.get(name, "")))
        if name not in names:
            errors.append("缺成员 %s（%s）" % (name, MEMBER_HINT.get(name, "")))

    for name in sorted(names - set(declared_names) - {MANIFEST}):
        errors.append("成员 %s 未登记在 MANIFEST.files 里（contract §2.2 要求覆盖"
                      "包内每个成员）" % name)

    if errors:
        # 同一处缺失可能被两条检查命中（MANIFEST 登记了但 zip 没有 / REQUIRED 名单
        # 也没有），去重后再报，免得同一条缺成员刷两遍。
        unique_errors = list(dict.fromkeys(errors))
        raise CorruptBundle("成员校验失败（%d 项）：\n  - %s"
                            % (len(unique_errors), "\n  - ".join(unique_errors)))
    return {"members": checked, "total_bytes": sum(m["bytes"] for m in checked)}


def read_json_member(archive: zipfile.ZipFile, name: str):
    try:
        raw = archive.read(name)
    except KeyError as error:
        raise CorruptBundle("缺成员 %s" % name) from error
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorruptBundle("%s 不是合法 UTF-8 JSON：%s" % (name, error)) from error


def read_hashes(archive: zipfile.ZipFile) -> dict:
    try:
        text = archive.read("hashes.txt").decode("utf-8")
    except KeyError as error:
        raise CorruptBundle("缺成员 hashes.txt") from error
    except UnicodeDecodeError as error:
        raise CorruptBundle("hashes.txt 不是 UTF-8：%s" % error) from error
    values: dict[str, str] = {}
    bad: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if "=" not in line:
            bad.append(line)
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return {"values": values, "malformed": bad}


# ---------------------------------------------------------------------------
# 台账（可选）
# ---------------------------------------------------------------------------

def ledger_path() -> Path:
    repo_root = Path(__file__).resolve().parents[2]
    return repo_root / "docs" / "runtime" / "invariants.json"


def load_ledger() -> tuple[dict, str]:
    """返回 ({reason: witness_spec}, 状态说明)。台账缺失/不可解析都不算包损坏。"""
    path = ledger_path()
    if not path.is_file():
        return {}, "absent:%s" % path
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {}, "unreadable:%s" % error
    entries = normalize_entries(data)
    if not entries:
        return {}, "no_entries:%s" % path
    return entries, "ok:%s" % path


def normalize_entries(data) -> dict:
    """容忍台账的几种可能形状：list 根、{"invariants": ...} 或 {reason: ...}。"""
    raw_items = []
    if isinstance(data, list):
        raw_items = data
    elif isinstance(data, dict):
        for key in ("invariants", "assertions", "entries", "checks"):
            container = data.get(key)
            if isinstance(container, list):
                raw_items = container
                break
            if isinstance(container, dict):
                raw_items = list(container.values())
                break
        else:
            raw_items = [value for value in data.values()
                         if isinstance(value, dict)]
    entries: dict[str, list] = {}
    for item in raw_items:
        if not isinstance(item, dict):
            continue
        reason = item.get("reason")
        if not isinstance(reason, str) or not reason:
            continue
        entries[reason] = normalize_witness_spec(item.get("witness"))
    return entries


def normalize_witness_spec(spec) -> list[dict]:
    """把 witness 声明摊平成 [{"field","type"}]。非法形状返回空列表。"""
    out: list[dict] = []
    if isinstance(spec, dict):
        # 可能是 {field: "i64"}、{field: {"type": "i64"}} 或
        # {"fields": [...]} 包一层。
        if isinstance(spec.get("fields"), (list, dict)):
            return normalize_witness_spec(spec["fields"])
        for field, value in spec.items():
            declared = value
            if isinstance(value, dict):
                declared = value.get("type", value.get("declared", ""))
            out.append({"field": str(field),
                        "type": str(declared).strip().lower()})
        return out
    if isinstance(spec, list):
        for item in spec:
            if isinstance(item, str):
                out.append({"field": item, "type": ""})
            elif isinstance(item, dict):
                field = item.get("field", item.get("name", ""))
                declared = item.get("type", item.get("declared", ""))
                if field:
                    out.append({"field": str(field),
                                "type": str(declared).strip().lower()})
            elif isinstance(item, (list, tuple)) and len(item) == 2:
                out.append({"field": str(item[0]),
                            "type": str(item[1]).strip().lower()})
    return [entry for entry in out if entry["field"]]


# ---------------------------------------------------------------------------
# witness 判定
# ---------------------------------------------------------------------------

def python_type(value) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "str"
    if value is None:
        return "null"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def type_matches(declared: str, value) -> bool | None:
    """None 表示台账类型名无法识别（跳过，不判失败）。"""
    if not declared:
        return None
    actual = python_type(value)
    if declared in INT_TYPES:
        return actual == "int"
    if declared in FLOAT_TYPES:
        # JSON 整数写成 f64 字段是常见形态（61 vs 61.0），容忍但要标出来。
        return actual in ("float", "int")
    if declared in BOOL_TYPES:
        return actual == "bool"
    if declared in STR_TYPES:
        return actual == "str"
    return None


def build_witness_rows(witness: dict, spec: list[dict] | None,
                       ledger_status: str) -> tuple[list[dict], list[str], list[str]]:
    """返回 (行, 类型违约, 缺失字段)。类型违约才是 violated；缺字段只是无法判定。"""
    rows: list[dict] = []
    type_violations: list[str] = []
    missing_fields: list[str] = []
    declared_by_field = {}
    for entry in spec or []:
        declared_by_field[entry["field"]] = entry["type"]
    fields = list(declared_by_field.keys())
    for field in witness.keys():
        if field not in declared_by_field:
            fields.append(str(field))
    for field in fields:
        present = field in witness
        value = witness.get(field)
        declared = declared_by_field.get(field, "")
        if not present:
            rows.append({"field": field, "value": None, "type": "-",
                         "declared": declared, "match": False,
                         "note": "witness 缺该字段"})
            if spec:
                missing_fields.append(
                    "witness 缺字段 %s（台账声明类型 %s）" % (field, declared or "?"))
            continue
        match = type_matches(declared, value) if spec else None
        note = ""
        if match is None and declared:
            note = "台账类型名未识别，跳过比对"
        elif match and declared in FLOAT_TYPES and python_type(value) == "int":
            note = "int 兼容 f64"
        rows.append({"field": field, "value": value,
                     "type": python_type(value), "declared": declared or "-",
                     "match": True if match is None else match, "note": note})
        if match is False:
            type_violations.append("witness.%s 类型不符：台账说 %s，实际 %s"
                                   % (field, declared, python_type(value)))
    return rows, type_violations, missing_fields


def scalar_self_check(rows: list[dict]) -> list[str]:
    """无台账时只做「类型自洽」：witness 只能是标量（schema §2.3）。"""
    return ["witness.%s 是 %s，不是标量" % (row["field"], row["type"])
            for row in rows if row["type"] in ("array", "object")]


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def format_value(value, limit: int = 48) -> str:
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    if len(text) > limit:
        text = text[:limit - 3] + "..."
    return text


def print_report(summary: dict, rows: list[dict], indent: str = "") -> None:
    package = summary["package"]
    print("%s== 包 ==" % indent)
    print("%spath        : %s" % (indent, package["path"]))
    print("%sschema      : %s" % (indent, package["schema"]))
    print("%sbuild_id    : %s" % (indent, package["build_id"] or "(空)"))
    print("%smembers     : %d（含 MANIFEST.json）" % (indent, package["member_count"]))
    print("%stotal_bytes : %d（成员内容合计 %d 字节）"
          % (indent, package["archive_bytes"], package["total_bytes"]))
    print("%ssha256      : %s" % (indent, package["checksum"]))
    print("%struncated   : %s" % (indent, ", ".join(package["truncated"]) or "-"))
    for note in package["notes"]:
        print("%snotes       : %s" % (indent, note))

    incident = summary["incident"]
    print("%s== 事件 ==" % indent)
    for field in ("assert_id", "reason", "kind", "stage", "day", "epoch_id",
                  "cell", "type_id", "build_id", "world_id", "captured_at"):
        value = incident.get(field, "(缺)")
        if isinstance(value, str) and value == "":
            value = "(空)"
        print("%s%-12s: %s" % (indent, field, value))

    print("%s== witness ==" % indent)
    print("%s%-28s %-24s %-8s %-8s %s"
          % (indent, "字段", "值", "实际类型", "声明类型", "匹配"))
    for row in rows:
        value = "-" if row["field"] not in summary["witness_raw"] \
            else format_value(summary["witness_raw"][row["field"]])
        print("%s%-28s %-24s %-8s %-8s %s%s"
              % (indent, row["field"], value, row["type"], row["declared"],
                 "是" if row["match"] else "否",
                 ("（%s）" % row["note"]) if row["note"] else ""))

    print("%s== 判定 ==" % indent)
    print("%s台账       : %s" % (indent, summary["ledger_status"]))
    for violation in summary["violations"]:
        print("%s违约        : %s" % (indent, violation))
    print("%sverdict=%s" % (indent, summary["verdict"]))
    print("%s退出码      : %d" % (indent, summary["exit_code"]))


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def inspect(path: Path) -> tuple[int, dict]:
    summary: dict = {
        "package": {"path": str(path), "schema": "", "build_id": "",
                    "member_count": 0, "total_bytes": 0, "archive_bytes": 0,
                    "checksum": "ok", "truncated": [], "notes": []},
        "incident": {},
        "witness_raw": {},
        "witness": [],
        "ledger_status": "",
        "violations": [],
        "verdict": "unknown",
        "exit_code": 2,
    }
    if not path.is_file():
        raise CorruptBundle("文件不存在：%s" % path)
    summary["package"]["archive_bytes"] = path.stat().st_size
    try:
        archive = zipfile.ZipFile(path, "r")
    except (zipfile.BadZipFile, OSError) as error:
        raise CorruptBundle("不是合法 zip：%s" % error) from error

    with archive:
        try:
            broken = archive.testzip()
        except (zipfile.BadZipFile, OSError) as error:
            raise CorruptBundle("zip 结构损坏：%s" % error) from error
        if broken is not None:
            raise CorruptBundle("zip 内成员 CRC 校验失败：%s" % broken)

        manifest = read_manifest(archive)
        verified = verify_members(archive, manifest)
        incident = read_json_member(archive, "incident.json")
        witness = read_json_member(archive, "witness.json")
        world = read_json_member(archive, "world.json")
        cell = read_json_member(archive, "cell.json")
        hashes = read_hashes(archive)

    if not isinstance(incident, dict):
        raise CorruptBundle("incident.json 顶层必须是对象")
    if not isinstance(witness, dict):
        raise CorruptBundle("witness.json 顶层必须是对象")
    reason = incident.get("reason")
    if not isinstance(reason, str) or not reason:
        raise CorruptBundle("incident.json 的 reason 必须是非空字符串（schema §2.2）")
    if not isinstance(world, dict):
        raise CorruptBundle("world.json 顶层必须是对象")
    if not isinstance(cell, dict):
        raise CorruptBundle("cell.json 顶层必须是对象")

    package = summary["package"]
    package["schema"] = manifest.get("schema", "")
    package["build_id"] = str(manifest.get("build_id", ""))
    package["member_count"] = len(verified["members"]) + 1
    package["total_bytes"] = verified["total_bytes"]
    package["checksum"] = "ok（%d/%d 成员 sha256 与 bytes 全部匹配）" % (
        len(verified["members"]), len(verified["members"]))
    truncated = manifest.get("truncated")
    package["truncated"] = [str(item) for item in truncated] if isinstance(truncated, list) else []
    notes = manifest.get("notes")
    package["notes"] = [str(item) for item in notes] if isinstance(notes, list) else []
    if hashes["malformed"]:
        package["notes"].append("hashes.txt 有 %d 行不是 key=value：%s"
                                % (len(hashes["malformed"]),
                                   "; ".join(hashes["malformed"][:3])))
    package["hashes"] = hashes["values"]
    summary["incident"] = incident
    summary["witness_raw"] = witness

    entries, ledger_status = load_ledger()
    summary["ledger_status"] = ledger_status
    spec = entries.get(reason)
    # spec 为 None = 台账没登记这个 reason；spec 为空列表 = 登记了但没声明 witness。
    # 两者都不能判定，但都不算包损坏。
    if spec is not None and not spec:
        spec = None
    rows, type_violations, missing_fields = build_witness_rows(
        witness, spec, ledger_status)
    summary["witness"] = rows
    summary["violations"] = type_violations + missing_fields

    if not entries:
        # 台账缺失：退化到「只看类型自洽」，判定保持 unknown（schema §4）。
        summary["violations"] = scalar_self_check(rows)
        summary["verdict"] = "unknown"
        summary["exit_code"] = 0
    elif reason not in entries:
        summary["violations"] = ["reason %r 未在台账登记，无法判定" % reason]
        summary["verdict"] = "unknown"
        summary["exit_code"] = 0
    elif spec is None:
        summary["violations"] = [
            "reason %r 在台账登记了但没有 witness schema，无法判定" % reason]
        summary["verdict"] = "unknown"
        summary["exit_code"] = 0
    elif type_violations:
        summary["verdict"] = "violated"
        summary["exit_code"] = 1
    elif missing_fields:
        # witness 不完整（生产者拿不到字段）不等于不变量被违反，只代表判不了。
        summary["verdict"] = "unknown"
        summary["exit_code"] = 0
    else:
        summary["verdict"] = "consistent"
        summary["exit_code"] = 0
    return summary["exit_code"], summary


def _configure_stdout() -> None:
    # Windows 默认用 locale 代码页写 stdout，中文诊断会变成乱码；统一按 UTF-8 输出。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass


def main(argv: list[str]) -> int:
    _configure_stdout()
    parser = argparse.ArgumentParser(
        description="检查 .pkinc 事故包（schema pkinc/1）")
    parser.add_argument("path", help="事故包路径（*.pkinc）")
    parser.add_argument("--json", action="store_true",
                        help="输出机器可读 JSON（判定与退出码不变）")
    args = parser.parse_args(argv)

    path = Path(args.path)
    try:
        exit_code, summary = inspect(path)
    except CorruptBundle as error:
        if args.json:
            print(json.dumps({
                "path": str(path), "verdict": "corrupt", "exit_code": 2,
                "errors": [str(error)],
            }, ensure_ascii=False, indent=2))
        else:
            print("包损坏 / 缺成员：")
            for line in str(error).splitlines():
                print("  %s" % line)
            print("verdict=corrupt 退出码=2")
        return 2
    except Exception as error:  # noqa: BLE001 - 消费端绝不允许崩栈
        if args.json:
            print(json.dumps({
                "path": str(path), "verdict": "corrupt", "exit_code": 2,
                "errors": ["unexpected:%s" % error],
            }, ensure_ascii=False, indent=2))
        else:
            print("检查失败（未预期的错误）：%s" % error)
            print("verdict=corrupt 退出码=2")
        return 2

    if args.json:
        payload = {
            "path": summary["package"]["path"],
            "schema": summary["package"]["schema"],
            "build_id": summary["package"]["build_id"],
            "member_count": summary["package"]["member_count"],
            "total_bytes": summary["package"]["total_bytes"],
            "archive_bytes": summary["package"]["archive_bytes"],
            "checksum": "ok",
            "truncated": summary["package"]["truncated"],
            "notes": summary["package"]["notes"],
            "hashes": summary["package"].get("hashes", {}),
            "incident": summary["incident"],
            "witness": summary["witness"],
            "ledger": summary["ledger_status"],
            "violations": summary["violations"],
            "verdict": summary["verdict"],
            "exit_code": summary["exit_code"],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_report(summary, summary["witness"])
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
