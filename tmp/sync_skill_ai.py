from pathlib import Path

ANCHOR = "  cells starve even under PROBE; that is not an AI decision problem.\n"
TEXT = (
    "- Country records are staggered: each slot writes on its own day. Aggregate per slot with the last\n"
    "  row at or before the target day, never by summing rows of one calendar day.\n"
    "- After the 2026-10 rule changes (base death 7.5% lowered by technology, savings gate, no\n"
    "  knowledge cap) PROBE stays at 7.5% death because it never researches; compare ACTIVE/PROBE\n"
    "  ratios, not absolute totals, against older runs. Remaining ACTIVE famine cells show empty hunting\n"
    "  camps and knapping workshops with stone tools at 0 stock; read `[headless-perf/groups]` first.\n"
)
for copy in [".cursor", ".codex"]:
    path = Path(copy) / "skills/project-keynes-country-ai-runtime/SKILL.md"
    raw = path.read_bytes()
    eol = "\r\n" if b"\r\n" in raw else "\n"
    text = raw.decode("utf-8").replace("\r\n", "\n")
    if "Country records are staggered" in text:
        print("already", path)
        continue
    assert text.count(ANCHOR) == 1, path
    text = text.replace(ANCHOR, ANCHOR + TEXT)
    path.write_bytes(text.replace("\n", eol).encode("utf-8"))
    print("updated", path)
