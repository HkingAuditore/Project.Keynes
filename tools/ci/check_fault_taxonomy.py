#!/usr/bin/env python3
"""Check the runtime fault taxonomy in ``docs/runtime/invariants.json``.

Every failure-reason string a native runtime (``gdext/src/**/*.cpp``) can raise
has to be registered in the invariant ledger before it ships.  An unregistered
reason is a stop with no stable id, no witness schema and no playbook, so a
player report cannot be turned into a reproducible root cause.

Extraction - only pure string literals are recognised (``error = String(...)``
and concatenations are deliberately not parsed, because their value is not
visible in the source line):

  * ``error = "..."`` / ``error="..."``
  * ``fail("...")`` (first literal only)
  * ``set_restore_rejected_reason("...")``

A literal is in scope only when it is at least 8 characters long and matches
``[a-z0-9_]+``.  Whitelisted, never reported as missing: ``test_only_*`` /
``probe_*`` prefixes, and any ``status="retired"`` ledger entry (a tombstone
keeps the id after a merge, so the old reason keeps passing).

Modes (combinable; ``--json`` replaces the human table):

  --strict             exit 1 when a reason is neither registered nor
                       whitelisted, or when a ``kind=="fatal"`` entry does not
                       carry the mandatory fields (see "Fatal entry gate"
                       below); otherwise print scan statistics.
  --json               machine-readable report; also carries the fatal-field
                       violations under ``fatal_field_violations``.
  --suggest            print one paste-ready JSON object per unregistered
                       reason (the same object --bootstrap-missing would add).
  --bootstrap-missing  register every unregistered reason as
                       kind=unknown/stage=unclassified.  Append only: existing
                       entries are never modified.  Ids are allocated from the
                       lowest unused number of the inferred module.  Note it can
                       only ever write ``kind=unknown``: see "Known limits".
  --write-doc          regenerate docs/runtime/invariants.md.  Output is
                       deterministic (no timestamps, everything sorted), so
                       repeated runs are byte-identical.
  --check-cpp-ids      require every ``kind=="fatal"`` ledger reason to have an
                       ``assert_id`` binding in gdext/src/fault_taxonomy.h, and
                       require the bound pair to agree with the ledger (a swapped
                       id is a failure, not just a missing one).  A missing
                       header is not a failure: print ``skipped:`` and exit 0.
  --review             ADVISORY WORK LIST, never a gate.  List the ``kind=="unknown"``
                       entries whose reason name looks like a stop point
                       (``_fatal`` / ``_drift`` / ``_mismatch`` / ``_violat`` /
                       ``_rejected`` / ``_must`` / ``_invalid``), each with the
                       first ``file:line`` where it is raised, grouped and
                       counted per file.  It does not take part in ``--strict``
                       and never changes the exit code; its only purpose is
                       "which batch should be classified next".  The list is
                       deliberately long - do not narrow the token set to make
                       it look shorter.  Under ``--json`` it is written to
                       stderr, so stdout stays one parseable JSON document.

Fatal entry gate (part of ``--strict``):

  A fatal is the one class a player report is supposed to turn into a root
  cause, so a fatal registration has to be filled in, not just named:

    * ``witness`` is a non-empty object and every value is one of
      ``i32``/``i64``/``f64``/``bool``/``str``;
    * ``playbook`` is a non-empty list of at least ``MIN_PLAYBOOK_STEPS`` (=3)
      steps, each a non-empty string;
    * ``stage`` and ``owner`` are non-empty.

  A violation prints ``<id> (<reason>): <what is missing>`` and exits 1.  There
  is no historical exemption and no whitelist: the four fatal entries that
  existed when the rule landed already satisfied it, so from then on the rule
  binds every new registration.  A fatal ``witness`` value outside the allowed
  set is caught while loading the ledger (``FatalFieldError``) but reported with
  the same message shape and exit 1, so every fatal-field violation looks the
  same; the gate repeats the type check defensively.  The identical bad value on
  a *non*-fatal entry stays a malformed-ledger error (exit 2): the fatal
  contract got stricter, the parser got no looser.

Known limits (honest accounting):

  ``--bootstrap-missing`` only ever writes ``kind=unknown``.  Nothing in this
  script can tell whether a given registered reason *should* have been
  classified fatal, so "this stop was registered, but as unknown instead of
  fatal" is NOT caught by any gate here.  It is deliberately not guessed at
  with a name heuristic: a wrong guess forces someone to tick a box that is
  wrong, which is more expensive than an honestly unknown entry.  ``--review``
  narrows the search space by name for a human, and that is all it does.

Exit codes: 0 clean, 1 check failed, 2 ledger/usage error.

Portability notes (Windows):

  * Every read is explicit ``encoding="utf-8"``.  The default locale code page
    here is GBK and ``Path.read_text()`` on UTF-8 sources raises
    ``UnicodeDecodeError``.  Source reads use ``errors="strict"`` on purpose: a
    non-UTF-8 native source is a bug we want to see, not silently mangle.
  * Generated files are written with ``newline="\\n"`` so a second run cannot
    turn into a CRLF-only diff.
  * stdout/stderr are reconfigured to UTF-8 so non-ASCII diagnostics do not
    raise ``UnicodeEncodeError`` on the legacy console code page.
"""
from __future__ import annotations

import argparse
import bisect
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEDGER = "docs/runtime/invariants.json"
DOC = "docs/runtime/invariants.md"
SCAN_ROOT = "gdext/src"
SCAN_SUFFIX = ".cpp"
CPP_TABLE = "gdext/src/fault_taxonomy.h"
SCHEMA = "pk-invariants/1"
GENERATED_FROM = "gdext/src"

# Fixed module set.  The order is both the id namespace order and the order the
# generated document groups sections in, so it is part of the contract.
MODULES = (
    "ECON",
    "CLIMATE",
    "COUNTRY",
    "MILITARY",
    "SAVE",
    "EFFECT",
    "TRIGGER",
    "MODIFIER",
    "FAMILY",
    "CORE",
)
# Module inference from the failing file path.  First match wins, so the order
# mirrors MODULES; "country_runtime_persistence.cpp" is COUNTRY, not SAVE.
MODULE_KEYWORDS = (
    ("ECON", ("economy",)),
    ("CLIMATE", ("climate",)),
    ("COUNTRY", ("country",)),
    ("MILITARY", ("military",)),
    ("SAVE", ("save", "persistence")),
    ("EFFECT", ("effect",)),
    ("TRIGGER", ("trigger",)),
    ("MODIFIER", ("modifier",)),
    ("FAMILY", ("family",)),
)
# Ledger field order (docs/plans/runtime-fault-infrastructure-plan.md §4.2).
FIELDS = (
    "id",
    "reason",
    "kind",
    "stage",
    "invariant",
    "witness",
    "owner",
    "first_seen",
    "playbook",
    "status",
)
KINDS = ("fatal", "rejection", "backpressure", "unknown")
STATUSES = ("active", "retired")
WITNESS_TYPES = ("i32", "i64", "f64", "bool", "str")
# Fatal entry gate: a playbook shorter than this cannot get anyone from
# "a player saw a stop" to "the state is restored".
MIN_PLAYBOOK_STEPS = 3
MIN_REASON_LEN = 8
REASON_RE = re.compile(r"[a-z0-9_]+")
ID_RE = re.compile(r"INV-([A-Z]+)-(\d{4,})")
WHITELIST_PREFIXES = ("test_only_", "probe_")
EXTRACTORS = (
    ("error", re.compile(r'\berror\s*=\s*"([^"\\\n]*)"')),
    ("fail", re.compile(r'\bfail\(\s*"([^"\\\n]*)"')),
    ("restore_reason", re.compile(r'set_restore_rejected_reason\(\s*"([^"\\\n]*)"')),
)
CPP_LITERAL = re.compile(r'"([^"\\\n]*)"')
CPP_ID_LITERAL = re.compile(r"INV-([A-Z]+)-(\d{4,})")
CPP_ID_IDENT = re.compile(r"INV_([A-Z]+)_(\d{4,})")
# --review stop-point names.  Matched as plain substrings on purpose: a reason
# ending in "_invalid" (the shape INV-SAVE-0001 had before it became fatal) is
# exactly as suspicious as one with "_invalid_" in the middle.  Measured on the
# ledger as it stands (2026-11-19): 1181 of 2727 kind=unknown rows match.  That
# is the point - this is a work queue, not a green-light list.  Extending it is
# a one-line edit; narrowing it to produce a shorter printout is not allowed.
REVIEW_STOP_TOKENS = ("_fatal", "_drift", "_mismatch", "_violat", "_rejected", "_must", "_invalid")
REVIEW_STOP_RE = re.compile("|".join(REVIEW_STOP_TOKENS))
REVIEW_UNLOCATED = "(reason not present in gdext/src)"


class LedgerError(RuntimeError):
    """Malformed ledger - a configuration/usage problem, not a scan verdict."""


class FatalFieldError(LedgerError):
    """A kind=fatal entry's witness type is outside the POD set.

    Kept separate from the generic LedgerError so the fatal entry gate can print
    the same ``<id> (<reason>): <what is missing>`` message and exit 1 for every
    fatal-field violation, no matter which layer noticed it first.  The same
    violation on a non-fatal entry stays a malformed-ledger error (exit 2): the
    fatal contract is stricter, not the parser.
    """

    def __init__(self, ident: str, reason: str, detail: str) -> None:
        super().__init__(f"{ident} ({reason}): {detail}")
        self.ident = ident
        self.reason = reason
        self.detail = detail


class ScanError(RuntimeError):
    """Missing scan root - refuse to pass a wrong --root vacuously."""


@dataclass(frozen=True)
class Occurrence:
    reason: str
    pattern: str
    file: str
    line: int


def configure_console() -> None:
    """Force UTF-8 stdio so non-ASCII diagnostics never raise on Windows."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            # Older/redirected streams may not support it; printing ASCII-only
            # output must keep working, so this is best effort by design.
            pass


def is_reason_literal(text: str) -> bool:
    return len(text) >= MIN_REASON_LEN and REASON_RE.fullmatch(text) is not None


def infer_module(file: str) -> str:
    """Map a failing source path to its id module (plan §4.2 / R1 spec)."""
    lowered = file.lower()
    for module, keywords in MODULE_KEYWORDS:
        if any(keyword in lowered for keyword in keywords):
            return module
    return "CORE"


def default_owner(module: str) -> str:
    for owner_module, keywords in MODULE_KEYWORDS:
        if owner_module == module:
            return f"{keywords[0]}.unassigned"
    return "core.unassigned"


def read_text(path: Path) -> str:
    # Native sources and the ledger are UTF-8; strict decoding surfaces a
    # mojibake/legacy-encoded file instead of silently dropping reasons.
    with open(path, "r", encoding="utf-8", errors="strict", newline="") as handle:
        return handle.read()


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


# --------------------------------------------------------------------------
# Ledger
# --------------------------------------------------------------------------


def empty_ledger() -> dict:
    return {"schema": SCHEMA, "generated_from": GENERATED_FROM, "invariants": []}


def normalize_entry(raw: dict, where: str) -> dict:
    if not isinstance(raw, dict):
        raise LedgerError(f"{where}: entry is not a JSON object")
    ident = raw.get("id")
    if not isinstance(ident, str) or not ID_RE.fullmatch(ident):
        raise LedgerError(f"{where}: invalid id {ident!r} (expected INV-<MODULE>-<NNNN>)")
    if ID_RE.fullmatch(ident).group(1) not in MODULES:
        raise LedgerError(f"{where}: id {ident!r} uses an unknown module")
    reason = raw.get("reason")
    if not isinstance(reason, str) or not reason:
        raise LedgerError(f"{where}: {ident}: reason must be a non-empty string")
    kind = raw.get("kind", "unknown")
    if kind not in KINDS:
        raise LedgerError(f"{where}: {ident}: kind {kind!r} not in {KINDS}")
    status = raw.get("status", "active")
    if status not in STATUSES:
        raise LedgerError(f"{where}: {ident}: status {status!r} not in {STATUSES}")
    witness = raw.get("witness", {})
    if not isinstance(witness, dict):
        raise LedgerError(f"{where}: {ident}: witness must be an object")
    for key, value in witness.items():
        if not isinstance(key, str) or value not in WITNESS_TYPES:
            detail = f"witness {key!r}={value!r} must map to one of {WITNESS_TYPES}"
            if kind == "fatal":
                # Fatal entries are the one class with a hard, named field rule;
                # route through the gate's exit code and message shape.
                raise FatalFieldError(ident, reason, detail)
            raise LedgerError(f"{where}: {ident}: {detail}")
    playbook = raw.get("playbook", [])
    if not isinstance(playbook, list) or any(not isinstance(step, str) for step in playbook):
        raise LedgerError(f"{where}: {ident}: playbook must be a list of strings")
    first_seen = raw.get("first_seen")
    if first_seen is not None and not isinstance(first_seen, str):
        raise LedgerError(f"{where}: {ident}: first_seen must be a string or null")
    for key in ("stage", "invariant", "owner"):
        if not isinstance(raw.get(key, ""), str):
            raise LedgerError(f"{where}: {ident}: {key} must be a string")
    normalized = {
        "id": ident,
        "reason": reason,
        "kind": kind,
        "stage": raw.get("stage", ""),
        "invariant": raw.get("invariant", ""),
        "witness": dict(witness),
        "owner": raw.get("owner", ""),
        "first_seen": first_seen,
        "playbook": list(playbook),
        "status": status,
    }
    return {key: normalized[key] for key in FIELDS}


def load_ledger(root: Path) -> dict:
    path = root / LEDGER
    if not path.exists():
        return empty_ledger()
    try:
        data = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise LedgerError(f"{LEDGER}: invalid JSON ({exc})") from exc
    if not isinstance(data, dict):
        raise LedgerError(f"{LEDGER}: top-level value must be an object, not a bare array")
    if data.get("schema") != SCHEMA:
        raise LedgerError(f"{LEDGER}: schema must be {SCHEMA!r}, got {data.get('schema')!r}")
    entries = data.get("invariants")
    if not isinstance(entries, list):
        raise LedgerError(f"{LEDGER}: 'invariants' must be a list")
    ids = set()
    reasons = set()
    normalized = []
    for index, raw in enumerate(entries):
        entry = normalize_entry(raw, f"{LEDGER}: invariants[{index}]")
        if entry["id"] in ids:
            raise LedgerError(f"{LEDGER}: duplicate id {entry['id']}")
        if entry["reason"] in reasons:
            raise LedgerError(f"{LEDGER}: duplicate reason {entry['reason']!r}")
        ids.add(entry["id"])
        reasons.add(entry["reason"])
        normalized.append(entry)
    data["invariants"] = normalized
    return data


def dump_ledger(ledger: dict) -> str:
    entries = sorted(ledger["invariants"], key=lambda entry: entry["id"])
    payload = {
        "schema": SCHEMA,
        "generated_from": GENERATED_FROM,
        "invariants": [{key: entry[key] for key in FIELDS} for entry in entries],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def save_ledger(root: Path, ledger: dict) -> None:
    write_text(root / LEDGER, dump_ledger(ledger))


def used_numbers(entries: list, module: str) -> set:
    used = set()
    for entry in entries:
        match = ID_RE.fullmatch(entry["id"])
        if match and match.group(1) == module:
            used.add(int(match.group(2)))
    return used


def next_id(entries: list, module: str, reserved: set) -> str:
    used = used_numbers(entries, module) | reserved
    number = 1
    while number in used:
        number += 1
    return f"INV-{module}-{number:04d}"


def make_entry(ident: str, reason: str, module: str) -> dict:
    return {
        "id": ident,
        "reason": reason,
        "kind": "unknown",
        "stage": "unclassified",
        "invariant": "",
        "witness": {},
        "owner": default_owner(module),
        "first_seen": None,
        "playbook": [],
        "status": "active",
    }


# --------------------------------------------------------------------------
# Fatal entry field gate (--strict)
# --------------------------------------------------------------------------


def fatal_field_problems(entry: dict) -> list:
    """Return what a ``kind=="fatal"`` entry is still missing.

    An empty list means the entry is a complete registration.  A witness value
    outside ``WITNESS_TYPES`` is normally caught by the loader first (as a
    ``FatalFieldError``, exit 1); the type check is repeated here so this
    function is the single readable statement of the fatal contract and stays
    correct if the loader ever loosens.
    """
    problems = []
    witness = entry.get("witness")
    if not isinstance(witness, dict):
        problems.append("witness is not an object")
        witness = {}
    elif not witness:
        problems.append("witness is empty (need a non-empty {field: pod_type} object)")
    for name, witness_type in sorted(witness.items()):
        if witness_type not in WITNESS_TYPES:
            problems.append(
                f"witness {name!r} has type {witness_type!r}, need one of {'/'.join(WITNESS_TYPES)}")
    playbook = entry.get("playbook")
    if not isinstance(playbook, list):
        problems.append("playbook is not a list")
        playbook = []
    elif not playbook:
        problems.append(f"playbook is empty (need at least {MIN_PLAYBOOK_STEPS} steps)")
    elif len(playbook) < MIN_PLAYBOOK_STEPS:
        problems.append(f"playbook has {len(playbook)} step(s), need at least {MIN_PLAYBOOK_STEPS}")
    for index, step in enumerate(playbook):
        if not isinstance(step, str):
            problems.append(f"playbook[{index}] is not a string")
        elif not step.strip():
            problems.append(f"playbook[{index}] is blank (every step must be a non-empty string)")
    for field in ("stage", "owner"):
        value = entry.get(field, "")
        if not isinstance(value, str) or not value.strip():
            problems.append(f"{field} is empty")
    return problems


def fatal_field_violations(entries: list) -> list:
    """Every ``kind=="fatal"`` entry that fails the gate, as (entry, problems)."""
    violations = []
    for entry in sorted(entries, key=lambda item: item["id"]):
        if entry.get("kind") != "fatal":
            continue
        problems = fatal_field_problems(entry)
        if problems:
            violations.append((entry, problems))
    return violations


def report_fatal_field_violations(violations: list, stream=None) -> None:
    out = stream if stream is not None else sys.stdout
    label = "entry" if len(violations) == 1 else "entries"
    print(f"fatal entry gate: {len(violations)} kind=fatal {label} missing required fields",
          file=out)
    for entry, problems in violations:
        print(f"  {entry['id']} ({entry['reason']}): {'; '.join(problems)}", file=out)
    print("  a fatal must be replayable: fill witness/playbook/stage/owner, then run --write-doc",
          file=out)


# --------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------


def scan_sources(root: Path) -> tuple:
    base = root / SCAN_ROOT
    if not base.is_dir():
        # Never pass vacuously: a typo in --root would otherwise scan 0 files and
        # report a clean taxonomy.
        raise ScanError(f"scan root {SCAN_ROOT} not found under {root}")
    files = sorted(
        path.relative_to(root).as_posix()
        for path in base.rglob(f"*{SCAN_SUFFIX}")
        if path.is_file()
    )
    found: dict = {}
    for relative in files:
        text = read_text(root / relative)
        line_starts = [0]
        line_starts.extend(index + 1 for index, char in enumerate(text) if char == "\n")
        for pattern_name, regex in EXTRACTORS:
            for match in regex.finditer(text):
                reason = match.group(1)
                if not is_reason_literal(reason):
                    continue
                line = bisect.bisect_right(line_starts, match.start())
                occurrence = Occurrence(reason, pattern_name, relative, line)
                found.setdefault(reason, {})[(relative, line, pattern_name)] = occurrence
    ordered = {
        reason: [occurrences[key] for key in sorted(occurrences)]
        for reason, occurrences in found.items()
    }
    return len(files), ordered


def is_whitelisted(reason: str) -> bool:
    return reason.startswith(WHITELIST_PREFIXES)


@dataclass
class Report:
    scanned_files: int
    found: dict
    registered: set
    missing: list
    whitelisted: set
    orphaned: list

    @property
    def missing_reasons(self) -> list:
        return sorted({occurrence.reason for occurrence in self.missing})


def build_report(scanned_files: int, found: dict, entries: list) -> Report:
    registered = {entry["reason"] for entry in entries}
    missing = []
    whitelisted = set()
    for reason in sorted(found):
        if reason in registered:
            continue
        if is_whitelisted(reason):
            whitelisted.add(reason)
            continue
        for occurrence in found[reason]:
            missing.append(occurrence)
    missing.sort(key=lambda occurrence: (occurrence.file, occurrence.line, occurrence.reason))
    orphaned = [
        {"id": entry["id"], "reason": entry["reason"], "status": entry["status"]}
        for entry in sorted(entries, key=lambda entry: entry["id"])
        if entry["reason"] not in found and entry["status"] == "active"
    ]
    return Report(scanned_files, found, registered, missing, whitelisted, orphaned)


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def report_human(report: Report, entries: list) -> None:
    distinct = len(report.found)
    print(f"fault taxonomy: {report.scanned_files} files, {distinct} distinct reasons")
    print(f"  registered: {len(report.found) - len(report.missing_reasons) - len(report.whitelisted)}")
    print(f"  whitelisted (test_only_/probe_): {len(report.whitelisted)}")
    print(f"  missing: {len(report.missing_reasons)}")
    print(f"  ledger entries: {len(entries)}")
    if report.orphaned:
        print(f"  ledger entries with no scanned reason: {len(report.orphaned)}")
    if report.missing:
        print()
        print(f"unregistered fault reasons ({len(report.missing)} occurrence(s)):")
        for occurrence in report.missing:
            print(f"  {occurrence.file}:{occurrence.line}: {occurrence.reason}")
        print()
        print("register them with: python tools/ci/check_fault_taxonomy.py --bootstrap-missing")


def report_json(report: Report, violations: list = ()) -> None:
    payload = {
        "scanned_files": report.scanned_files,
        "found": len(report.found),
        "registered": len(report.found) - len(report.missing_reasons) - len(report.whitelisted),
        "missing": [
            {"reason": occurrence.reason, "file": occurrence.file, "line": occurrence.line}
            for occurrence in report.missing
        ],
        "orphaned": report.orphaned,
        "fatal_field_violations": [
            {"id": entry["id"], "reason": entry["reason"], "missing": problems}
            for entry, problems in violations
        ],
    }
    print(json.dumps(payload, indent=2, ensure_ascii=False))


def suggest_missing(root: Path, ledger: dict, report: Report) -> None:
    if not report.missing_reasons:
        print("no unregistered reasons; nothing to suggest", file=sys.stderr)
        return
    entries = list(ledger["invariants"])
    reserved: dict = {}
    snippets = []
    for reason in sorted(report.missing_reasons, key=lambda item: (MODULES.index(
            infer_module(report.found[item][0].file)), item)):
        file = report.found[reason][0].file
        module = infer_module(file)
        reserved.setdefault(module, set())
        ident = next_id(entries, module, reserved[module])
        reserved[module].add(int(ID_RE.fullmatch(ident).group(2)))
        snippets.append(make_entry(ident, reason, module))
    print(f"# {len(snippets)} unregistered reason(s); each object below can be pasted into the "
          f"'invariants' array of {LEDGER}", file=sys.stderr)
    for snippet in snippets:
        print(json.dumps(snippet, indent=2, ensure_ascii=False))


def bootstrap_missing(root: Path, ledger: dict, report: Report) -> int:
    if not report.missing_reasons:
        print(f"bootstrap: no unregistered reasons; {LEDGER} unchanged "
              f"({len(ledger['invariants'])} entries)")
        return 0
    entries = list(ledger["invariants"])
    reserved: dict = {}
    ordered = sorted(
        report.missing_reasons,
        key=lambda reason: (MODULES.index(infer_module(report.found[reason][0].file)), reason),
    )
    added = []
    for reason in ordered:
        file = report.found[reason][0].file
        module = infer_module(file)
        reserved.setdefault(module, set())
        ident = next_id(entries, module, reserved[module])
        reserved[module].add(int(ID_RE.fullmatch(ident).group(2)))
        entry = make_entry(ident, reason, module)
        entries.append(entry)
        added.append(entry)
    ledger["invariants"] = entries
    save_ledger(root, ledger)
    by_module: dict = {}
    for entry in added:
        module = ID_RE.fullmatch(entry["id"]).group(1)
        by_module[module] = by_module.get(module, 0) + 1
    summary = ", ".join(f"{module}+{by_module[module]}" for module in MODULES if module in by_module)
    print(f"bootstrap: added {len(added)} unregistered reason(s) as kind=unknown "
          f"({summary}); ledger now {len(entries)} entries")
    print(f"bootstrap: next step - replace kind/stage/invariant/witness/playbook per module, "
          f"then run --write-doc")
    return 0


# --------------------------------------------------------------------------
# Advisory review list (--review)
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class ReviewRow:
    entry: dict
    occurrence: "Occurrence | None"


def review_rows(entries: list, found: dict) -> list:
    """kind=unknown + active + stop-point-looking name, with its first raise site.

    Pure selection: no heuristics beyond the name, no verdict.  A row whose
    reason no longer appears in ``gdext/src`` keeps its place with no location
    (it is a tombstone that was never classified), rather than being dropped
    silently.
    """
    rows = []
    for entry in entries:
        if entry.get("kind") != "unknown" or entry.get("status") != "active":
            continue
        if not REVIEW_STOP_RE.search(entry["reason"]):
            continue
        occurrences = found.get(entry["reason"]) or ()
        rows.append(ReviewRow(entry, occurrences[0] if occurrences else None))
    return rows


def print_review(rows: list, unknown_total: int, stream=None) -> None:
    """Print the advisory list.  Grouped per file, biggest group first.

    Formatting is one line per candidate so ``| head -30`` is directly usable in
    a terminal or a status report.  ``stream`` exists so a combined
    ``--json --review`` run can keep stdout pure JSON.
    """
    out = stream if stream is not None else sys.stdout
    groups: dict = {}
    for row in rows:
        key = row.occurrence.file if row.occurrence is not None else REVIEW_UNLOCATED
        groups.setdefault(key, []).append(row)
    ordered = sorted(groups.items(), key=lambda item: (-len(item[1]), item[0]))
    print("review: kind=unknown reasons whose name looks like a stop point", file=out)
    print("  advisory work queue, NOT a gate: no effect on the exit code, not part of --strict",
          file=out)
    print(f"  kind=unknown entries scanned: {unknown_total}", file=out)
    print(f"  matching stop-point names: {len(rows)}", file=out)
    print(f"  stop-point tokens: {'|'.join(REVIEW_STOP_TOKENS)}", file=out)
    print("  pick one batch, fill kind/stage/witness/playbook, then --strict and --write-doc",
          file=out)
    for file, group in ordered:
        print("", file=out)
        print(f"{file} ({len(group)})", file=out)
        for row in sorted(group, key=lambda item: (
                item.occurrence.line if item.occurrence is not None else 0, item.entry["reason"])):
            where = (f"{row.occurrence.file}:{row.occurrence.line}"
                     if row.occurrence is not None else REVIEW_UNLOCATED)
            print(f"  {row.entry['id']}  {row.entry['reason']}  {where}", file=out)
    print("", file=out)
    print(f"total: {len(rows)} candidate(s) in {len(ordered)} file(s)", file=out)


# --------------------------------------------------------------------------
# Document generation
# --------------------------------------------------------------------------


def md_cell(value) -> str:
    return str(value).replace("|", "\\|")


def render_doc(ledger: dict) -> str:
    entries = sorted(ledger["invariants"], key=lambda entry: entry["id"])
    lines = [
        "# Runtime invariant ledger",
        "",
        "> Generated file. Do not edit by hand: edit `docs/runtime/invariants.json` and run",
        "> `python tools/ci/check_fault_taxonomy.py --write-doc`.",
        f"> Schema `{SCHEMA}`, extracted from `{GENERATED_FROM}`.",
        "",
        "## Summary",
        "",
        "| Metric | Count |",
        "| --- | --- |",
        f"| Invariants | {len(entries)} |",
    ]
    for kind in KINDS:
        lines.append(f"| kind={kind} | {sum(1 for entry in entries if entry['kind'] == kind)} |")
    for status in STATUSES:
        lines.append(f"| status={status} | {sum(1 for entry in entries if entry['status'] == status)} |")
    with_witness = sum(1 for entry in entries if entry["witness"])
    with_playbook = sum(1 for entry in entries if entry["playbook"])
    lines.append(f"| entries with witness | {with_witness} |")
    lines.append(f"| entries with playbook | {with_playbook} |")
    # Same helper the --strict gate uses, so the document can never claim 0
    # while CI is red for the same ledger.
    missing_fields = len(fatal_field_violations(entries))
    lines.append(f"| fatal entries missing required fields | {missing_fields} |")
    lines.append("")
    lines.append("## Invariants by module")
    for module in MODULES:
        group = [entry for entry in entries if ID_RE.fullmatch(entry["id"]).group(1) == module]
        if not group:
            continue
        lines.append("")
        lines.append(f"### {module} ({len(group)})")
        lines.append("")
        lines.append("| ID | reason | kind | stage | owner | status |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for entry in group:
            lines.append(
                f"| {md_cell(entry['id'])} | `{md_cell(entry['reason'])}` | "
                f"{md_cell(entry['kind'])} | {md_cell(entry['stage'])} | "
                f"{md_cell(entry['owner'])} | {md_cell(entry['status'])} |")
    lines.append("")
    lines.append("## Witness fields")
    lines.append("")
    if with_witness:
        lines.append("Field name to POD type; the C++ witness struct carries exactly these members.")
        lines.append("")
        lines.append("| ID | reason | witness |")
        lines.append("| --- | --- | --- |")
        for entry in entries:
            if not entry["witness"]:
                continue
            fields = ", ".join(f"`{md_cell(name)}:{md_cell(kind)}`"
                               for name, kind in entry["witness"].items())
            lines.append(f"| {md_cell(entry['id'])} | `{md_cell(entry['reason'])}` | {fields} |")
    else:
        lines.append("_No witness fields registered yet._")
    lines.append("")
    lines.append("## Playbooks")
    lines.append("")
    if with_playbook:
        for entry in entries:
            if not entry["playbook"]:
                continue
            lines.append(f"### {md_cell(entry['id'])} `{md_cell(entry['reason'])}`")
            lines.append("")
            for index, step in enumerate(entry["playbook"], 1):
                lines.append(f"{index}. {step}")
            lines.append("")
    else:
        lines.append("_No playbooks registered yet._")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def write_doc(root: Path, ledger: dict) -> None:
    text = render_doc(ledger)
    path = root / DOC
    previous = read_text(path) if path.exists() else None
    changed = previous != text
    write_text(path, text)
    state = "regenerated" if changed else "unchanged"
    print(f"write-doc: {DOC} {state} ({len(ledger['invariants'])} invariants)")


# --------------------------------------------------------------------------
# C++ assert_id binding check
# --------------------------------------------------------------------------


def cpp_row_ids(line: str) -> set:
    ids = {f"INV-{match.group(1)}-{match.group(2)}" for match in CPP_ID_LITERAL.finditer(line)}
    ids |= {f"INV-{match.group(1)}-{match.group(2)}" for match in CPP_ID_IDENT.finditer(line)}
    return ids


def cpp_row_reasons(line: str) -> set:
    return {
        match.group(1) for match in CPP_LITERAL.finditer(line)
        if is_reason_literal(match.group(1))
    }


def check_cpp_ids(root: Path, entries: list) -> int:
    """Require every kind=fatal ledger entry to be bound in the C++ table.

    A binding is a table row carrying exactly one reason and one assert id; the
    pair must match the ledger.  A file-wide presence fallback covers macro /
    ``#define`` spellings where the id sits on a different line than the reason.
    """
    path = root / CPP_TABLE
    if not path.exists():
        print(f"skipped: {CPP_TABLE} not present")
        return 0
    text = read_text(path)
    file_ids = set()
    for line in text.splitlines():
        file_ids |= cpp_row_ids(line)
    file_reasons = {
        match.group(1) for match in CPP_LITERAL.finditer(text)
        if is_reason_literal(match.group(1))
    }
    pairs = {}
    conflicts = []
    for line in text.splitlines():
        ids = cpp_row_ids(line)
        reasons = cpp_row_reasons(line)
        if len(ids) != 1 or len(reasons) != 1:
            continue
        ident = next(iter(ids))
        reason = next(iter(reasons))
        if reason in pairs and pairs[reason] != ident:
            conflicts.append((reason, pairs[reason], ident))
        pairs[reason] = ident
    fatal = [entry for entry in entries if entry["kind"] == "fatal"]
    unbound = []
    mismatched = []
    verified = 0
    for entry in fatal:
        bound_id = pairs.get(entry["reason"])
        if bound_id is not None:
            if bound_id == entry["id"]:
                verified += 1
            else:
                mismatched.append((entry, bound_id))
            continue
        missing = []
        if entry["id"] not in file_ids:
            missing.append("assert_id")
        if entry["reason"] not in file_reasons:
            missing.append("reason")
        if missing:
            unbound.append((entry, missing))
        else:
            # Macro/#define spelling: id and reason exist, just not on one line.
            verified += 1
    print(f"cpp ids: {CPP_TABLE} binds {verified}/{len(fatal)} kind=fatal invariants")
    for entry, bound_id in mismatched:
        print(f"  mismatch: {entry['id']} {entry['reason']} is bound to {bound_id} in the table")
    for reason, first, second in conflicts:
        print(f"  conflict: {reason} is bound to both {first} and {second}")
    for entry, missing in unbound:
        print(f"  unbound: {entry['id']} {entry['reason']} (missing {'/'.join(missing)})")
    return 1 if (unbound or mismatched or conflicts) else 0


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def parse_args(argv) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Cross-check gdext/src failure reasons against docs/runtime/invariants.json.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="repository root (default: this checkout)")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when an unregistered reason is found, or when a "
                             "kind=fatal entry misses witness/playbook/stage/owner")
    parser.add_argument("--json", action="store_true",
                        help="machine-readable report instead of the human table")
    parser.add_argument("--suggest", action="store_true",
                        help="print paste-ready ledger entries for unregistered reasons")
    parser.add_argument("--bootstrap-missing", action="store_true",
                        help="register unregistered reasons as kind=unknown (append only)")
    parser.add_argument("--write-doc", action="store_true",
                        help="regenerate docs/runtime/invariants.md")
    parser.add_argument("--check-cpp-ids", action="store_true",
                        help="verify kind=fatal entries have an assert_id in fault_taxonomy.h")
    parser.add_argument("--review", action="store_true",
                        help="advisory list of kind=unknown stop-point candidates "
                             "(never blocks; does not affect the exit code)")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    configure_console()
    args = parse_args(argv)
    root = args.root if args.root.is_absolute() else (Path.cwd() / args.root).resolve()
    status = 0
    try:
        ledger = load_ledger(root)
        scanned_files, found = scan_sources(root)
    except FatalFieldError as exc:
        # Same message shape and exit code as the fatal entry gate below, so a
        # fatal-field violation always reads the same way.
        print(f"{exc.ident} ({exc.reason}): {exc.detail}",
              file=sys.stderr if args.json else sys.stdout)
        return 1
    except LedgerError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except ScanError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except UnicodeDecodeError as exc:
        print(f"error: source file is not UTF-8: {exc}", file=sys.stderr)
        return 2
    report = build_report(scanned_files, found, ledger["invariants"])

    if args.bootstrap_missing:
        bootstrap_missing(root, ledger, report)
        # Rebuild so a following --strict/--json/--write-doc sees the new state.
        ledger = load_ledger(root)
        report = build_report(scanned_files, found, ledger["invariants"])
    if args.write_doc:
        write_doc(root, ledger)
    if args.check_cpp_ids:
        status = max(status, check_cpp_ids(root, ledger["invariants"]))

    # Computed after --bootstrap-missing so the gate sees the ledger it just wrote.
    fatal_violations = fatal_field_violations(ledger["invariants"])

    if args.json:
        report_json(report, fatal_violations)
    elif args.strict or not (args.bootstrap_missing or args.write_doc
                             or args.check_cpp_ids or args.suggest or args.review):
        report_human(report, ledger["invariants"])

    if args.suggest:
        suggest_missing(root, ledger, report)

    if args.strict and fatal_violations:
        # --json promises a machine-readable stdout, so keep the narration on
        # stderr there; the same violations are already in the JSON payload.
        report_fatal_field_violations(fatal_violations,
                                      sys.stderr if args.json else sys.stdout)
        status = max(status, 1)
    if args.strict and report.missing:
        status = max(status, 1)

    if args.review:
        # Advisory by contract: prints, never touches `status`.  With --json it
        # goes to stderr so stdout stays a single parseable JSON document.
        unknown_total = sum(1 for entry in ledger["invariants"]
                            if entry["kind"] == "unknown" and entry["status"] == "active")
        print_review(review_rows(ledger["invariants"], found), unknown_total,
                     sys.stderr if args.json else sys.stdout)
    return status


if __name__ == "__main__":
    sys.exit(main())
