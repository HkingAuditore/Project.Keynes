#!/usr/bin/env python3
"""从设备 logcat 里自动补齐 FMOD 的 Java stub（`org.fmod.*`）。

背景：FMOD 的 Android 运行库完全靠 JNI 反射找 `org.fmod.*` 的成员，缺一个就
`NoSuchMethodError` / `NoSuchFieldError`，被 CheckJNI 撞上就直接 abort 整个进程。
每补一个要跑一次设备，很慢；这个脚本把"读 logcat -> 生成 Java 成员 -> 写回 stub"
自动化，配合 `inject_fmod_java_stub.py` 就能一条命令迭代。

它会识别这几类 FMOD/ART 报错：

    NoSuchMethodError: no static method "Lorg/fmod/FMOD;.checkInit()Z"
    NoSuchMethodError: no non-static method "Lorg/fmod/AudioDevice;.init(IIII)Z"
    Failed to register native method org.fmod.MediaCodec.fmodReadAt(JJ[BII)I
    NoSuchFieldError: no field "Lorg/fmod/AudioDevice;.guid"

用法：
    python tools/fmod_java_stub_sync.py tmp/fmod_multi/probe-all.txt            # 看要补什么
    python tools/fmod_java_stub_sync.py tmp/fmod_multi/probe-all.txt --write    # 直接写进 stub
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
STUB_ROOT = REPO / "tools" / "fmod_java_stub"

METHOD_NO_STATIC = re.compile(
    r'no static method "L(?P<cls>[A-Za-z0-9_/$]+);\.(?P<name>[A-Za-z0-9_$<>]+)(?P<sig>\([^)]*\)[^"]+)"')
METHOD_NO_INSTANCE = re.compile(
    r'no non-static method "L(?P<cls>[A-Za-z0-9_/$]+);\.(?P<name>[A-Za-z0-9_$<>]+)(?P<sig>\([^)]*\)[^"]+)"')
REGISTER_NATIVE = re.compile(
    r'Failed to register native method (?P<cls>[A-Za-z0-9_.$]+)\.(?P<name>[A-Za-z0-9_$]+)(?P<sig>\([^)]*\)[^"\s]+)')
FIELD_MISSING = re.compile(
    r'JNI DETECTED ERROR.*ClassNotFoundException: Didn\'t find class "(?P<cls>[A-Za-z0-9_.$]+)"')
FIELD_NO_SUCH = re.compile(
    r'no (?:static |instance )?field "?L?(?P<cls>[A-Za-z0-9_/$]+);?\.(?P<name>[A-Za-z0-9_$]+)"?')

PRIMITIVES = {
    "Z": "boolean", "B": "byte", "C": "char", "S": "short",
    "I": "int", "J": "long", "F": "float", "D": "double", "V": "void",
}

# Android 类型：只保留 stub 用得到的那几个
PLATFORM = {
    "Landroid/content/Context;": "android.content.Context",
    "Landroid/app/Activity;": "android.app.Activity",
    "Landroid/net/Uri;": "android.net.Uri",
}


def java_type(descriptor: str) -> str:
    descriptor = descriptor.strip()
    if descriptor.startswith("["):
        return java_type(descriptor[1:]) + "[]"
    if descriptor.startswith("L") and descriptor.endswith(";"):
        body = descriptor[1:-1]
        if descriptor in PLATFORM:
            return PLATFORM[descriptor]
        if body.startswith("java/lang/"):
            return body[len("java/lang/"):].replace("/", ".")
        if body.startswith("org/fmod/"):
            return body.replace("/", ".")
        # 其他平台类用全限定名（编译时可能缺类，调用处再处理）
        return body.replace("/", ".")
    return PRIMITIVES.get(descriptor, "Object")


def _take_one(desc: str, index: int) -> tuple[str, int]:
    """取一个 JNI 类型描述符（支持数组、对象），返回 (descriptor, next_index)。"""
    if desc[index] == "[":
        depth = index
        while desc[depth] == "[":
            depth += 1
        if desc[depth] == "L":
            stop = desc.index(";", depth)
            return desc[index:stop + 1], stop + 1
        return desc[index:depth + 1], depth + 1
    if desc[index] == "L":
        stop = desc.index(";", index)
        return desc[index:stop + 1], stop + 1
    return desc[index], index + 1


def parse_signature(sig: str) -> tuple[list[str], str]:
    """(params, ret) as java type strings."""
    inner = sig[1:sig.index(")")]
    ret_desc = sig[sig.index(")") + 1:]
    params: list[str] = []
    index = 0
    while index < len(inner):
        descriptor, index = _take_one(inner, index)
        params.append(java_type(descriptor))
    return params, java_type(ret_desc)


def class_file_name(cls: str) -> str:
    return cls.replace("/", ".")


def default_return(ret: str) -> str:
    if ret == "void":
        return ""
    if ret == "boolean":
        return "return false;"
    if ret in ("byte", "short", "int", "char", "long"):
        return "return 0;"
    if ret in ("float", "double"):
        return "return 0.0;"
    return "return null;"


def collect(log_text: str) -> tuple[dict, dict]:
    methods: dict[tuple[str, str, str], dict] = {}
    fields: dict[tuple[str, str], bool] = {}

    for match in METHOD_NO_STATIC.finditer(log_text):
        key = (class_file_name(match["cls"]), match["name"], match["sig"])
        methods[key] = {"static": True, "native": False}
    for match in METHOD_NO_INSTANCE.finditer(log_text):
        key = (class_file_name(match["cls"]), match["name"], match["sig"])
        methods[key] = {"static": False, "native": False}
    for match in REGISTER_NATIVE.finditer(log_text):
        key = (match["cls"], match["name"], match["sig"])
        methods[key] = {"static": True, "native": True}
    for match in FIELD_NO_SUCH.finditer(log_text):
        fields[(class_file_name(match["cls"]), match["name"])] = True
    return methods, fields


def render_member(cls: str, name: str, sig: str, meta: dict) -> str:
    params, ret = parse_signature(sig)
    args = ", ".join("arg%d" % i for i in range(len(params)))
    signature = "%s %s(%s)" % (ret, name, ", ".join(
        "%s arg%d" % (ptype, i) for i, ptype in enumerate(params)))
    modifier = "public static " if meta["static"] else "public "
    if meta["native"]:
        return "    %snative %s;" % (modifier, signature)
    body = default_return(ret)
    return "    %s%s {\n        %s\n    }" % (modifier, signature, body) if body else \
           "    %s%s {\n    }" % (modifier, signature)


def write_stub(cls: str, additions: list[str]) -> pathlib.Path:
    path = STUB_ROOT / (cls.replace(".", "/") + ".java")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        package = cls.rsplit(".", 1)[0] if "." in cls else ""
        class_name = cls.rsplit(".", 1)[-1]
        text = "package %s;\n\n/** Auto-generated by tools/fmod_java_stub_sync.py */\npublic class %s {\n}\n" % (
            package, class_name)
    else:
        text = path.read_text(encoding="utf-8")
    if "// --- auto-generated members ---" in text:
        head, _, _ = text.partition("// --- auto-generated members ---")
    else:
        head = text.rstrip()
        if head.endswith("}"):
            head = head[:-1].rstrip()
    body = "\n\n    // --- auto-generated members ---\n" + "\n\n".join(additions) + "\n}\n"
    path.write_text(head + body, encoding="utf-8")
    return path


def read_logcat(path: pathlib.Path) -> str:
    """PowerShell 的 `>` 重定向会写成 UTF-16LE，这里统一嗅探。"""
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    if raw[:3] == b"\xef\xbb\xbf":
        return raw[3:].decode("utf-8", errors="replace")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-16", errors="replace")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logcat")
    ap.add_argument("--write", action="store_true", help="把结果写回 tools/fmod_java_stub")
    args = ap.parse_args(argv[1:])

    text = read_logcat(pathlib.Path(args.logcat))
    methods, fields = collect(text)
    if not methods and not fields:
        print("[sync] no missing members found in %s" % args.logcat)
        return 0

    per_class: dict[str, list[str]] = {}
    for (cls, name, sig), meta in sorted(methods.items()):
        per_class.setdefault(cls, []).append(render_member(cls, name, sig, meta))
        print("[sync] %s.%s%s  (%s%s)" % (
            cls, name, sig,
            "static " if meta["static"] else "instance ",
            "native" if meta["native"] else "java"))
    for (cls, name) in sorted(fields):
        per_class.setdefault(cls, []).append("    public Object %s;" % name)
        print("[sync] %s.%s  (field)" % (cls, name))

    if args.write:
        for cls, members in sorted(per_class.items()):
            path = write_stub(cls, members)
            print("[sync] wrote %s" % path)
    else:
        print("[sync] dry run; re-run with --write to update the stubs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
