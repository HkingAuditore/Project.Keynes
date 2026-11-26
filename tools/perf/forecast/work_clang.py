"""Adapt Clang's debug.DumpCFG output; the compiler decides the control flow."""
import re
import subprocess


def scan(path, extra):
    driver = "clang" if path.suffix == ".c" else "clang++"
    cmd = [driver, *extra, "-fsyntax-only", "-Xclang", "-analyze", "-Xclang",
           "-analyzer-checker=debug.DumpCFG", "-fno-color-diagnostics", "-o", "/dev/null", str(path)]
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode:
        raise ValueError(proc.stderr.strip())
    functions, diagnostics = [], []
    last_title = ""
    current = block = None
    for line in proc.stderr.splitlines():
        if not line:
            continue
        header = re.fullmatch(r" \[B(\d+)(?: \(([^)]+)\))?\]", line)
        if header:
            n, tag = int(header[1]), header[2]
            if tag == "ENTRY":
                current = {"name": last_title, "entry": n, "nodes": [], "edges": []}
                functions.append(current)
            if current is None:
                raise ValueError("unrecognized Clang CFG header")
            block = {"id": n, "lines": [], "statement": tag or "", "operations": []}
            current["nodes"].append(block)
        elif not line[0].isspace():
            last_title = line
        elif block is not None:
            text = line.strip()
            if text.startswith("Succs ("):
                for target in text.partition(":")[2].split():
                    match = re.fullmatch(r"B(\d+)(?:\(([^)]+)\))?", target)
                    if match:
                        current["edges"].append((block["id"], int(match[1]), match[2] or "successor"))
                    else:
                        diagnostics.append(f"{last_title} B{block['id']}: {target}")
            elif not text.startswith("Preds ("):
                block["operations"].append(text)
                if text.startswith("T:") or (not block["statement"] and text):
                    block["statement"] = text
    limits = ["Compiler blocks for this translation unit and its active preprocessor flags.",
              "Block IDs refer to Clang's graph. This dump has no per-block source line numbers.",
              "Calls are visible in block operations; callees and other threads are not expanded."]
    if diagnostics:
        limits.append("Unresolved compiler successors: " + ", ".join(diagnostics))
    if not functions:
        limits.append("Clang emitted no function bodies.")
    return functions, [], limits
