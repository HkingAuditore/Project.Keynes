#!/usr/bin/env python3
"""Post-process the exported Godot web shell so the first visit can finish.

Godot's stock shell registers the cross-origin-isolation service worker and then
reloads *immediately*:

    Promise.race([...]).then(() => {
        // Reload if there was no error.
        window.location.reload();
    })

`engine.installServiceWorker()` resolves when the registration is created, not
when the worker is active, so the reload usually lands on a page that the worker
does not control yet. That page is still missing COI/SAB, `getRegistration()` is
now non-null, and the stock code then does

    return Promise.reject(new Error('Service worker already exists.'));

so it never reloads again and the visitor stays on the "missing features" notice
until a manual refresh. Symptom reported on keynes.pages.example.invalid: black/broken
first load + "Error while registering service worker: Error: Service worker
already exists." in the console (html line 217 of the stock shell).

This patch, applied to the *exported* html (so it survives every rebuild):

 1. reuses an existing registration instead of rejecting it;
 2. waits for `navigator.serviceWorker.ready` (the worker is active) before the
    reload;
 3. keeps a one-shot sessionStorage guard so a broken worker cannot cause a
    reload loop.

Idempotent: a second run reports "already patched" and changes nothing.
Fails loudly (exit 1) when the stock markers are not found, so a Godot template
change cannot silently ship an unpatched shell.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys

MARKER = "pk-coi-reloaded"

REJECT_RE = re.compile(
    r"if \(registration != null\) \{\s*\n\s*return Promise\.reject\(new Error\('Service worker already exists\.'\)\);\s*\n\s*\}",
)
RELOAD_RE = re.compile(
    r"\]\)\.then\(\(\) => \{\s*\n\s*// Reload if there was no error\.\s*\n\s*window\.location\.reload\(\);\s*\n\s*\}\)",
)

REJECT_NEW = (
    "if (registration != null) {\n"
    "\t\t\t\t\treturn registration;\n"
    "\t\t\t\t}"
)

RELOAD_NEW = (
    "]).then(() => navigator.serviceWorker.ready).then(() => {\n"
    "\t\t\t\t// [" + MARKER + "] only reload once the worker is active: an earlier reload\n"
    "\t\t\t\t// lands on an uncontrolled page and this branch never runs again.\n"
    "\t\t\t\tif (window.crossOriginIsolated) { return; }\n"
    "\t\t\t\ttry {\n"
    "\t\t\t\t\tif (sessionStorage.getItem('" + MARKER + "') === '1') { return; }\n"
    "\t\t\t\t\tsessionStorage.setItem('" + MARKER + "', '1');\n"
    "\t\t\t\t} catch (err) {}\n"
    "\t\t\t\twindow.location.reload();\n"
    "\t\t\t})"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="patch the exported Godot web shell")
    ap.add_argument("--root", default="WebBuild", help="export directory holding ProjectKeynes.html")
    ap.add_argument("--check", action="store_true", help="report only, change nothing")
    args = ap.parse_args(argv)

    root = pathlib.Path(args.root)
    html = root / "ProjectKeynes.html"
    if not html.is_file():
        print(f"[html-patch] ERROR: {html} not found", file=sys.stderr)
        return 1

    raw = html.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    before_len, before_sha = len(raw), sha256(raw)

    if MARKER in text:
        print(f"[html-patch] already patched: {html} ({before_len} B, sha256 {before_sha[:16]})")
        return 0

    n_reject = len(REJECT_RE.findall(text))
    n_reload = len(RELOAD_RE.findall(text))
    if n_reject != 1 or n_reload != 1:
        print(
            f"[html-patch] ERROR: stock markers not found as expected "
            f"(reject={n_reject}, reload={n_reload}); the Godot shell changed - "
            f"refusing to ship an unpatched html",
            file=sys.stderr,
        )
        return 1

    text = REJECT_RE.sub(REJECT_NEW, text, count=1)
    text = RELOAD_RE.sub(RELOAD_NEW, text, count=1)

    out = text.encode("utf-8")
    if bom:
        out = b"\xef\xbb\xbf" + out

    if args.check:
        print(f"[html-patch] CHECK: would patch {html}: {before_len} -> {len(out)} B (+{len(out) - before_len})")
        return 0

    html.write_bytes(out)
    after_sha = sha256(out)
    print(f"[html-patch] patched {html}")
    print(f"[html-patch] size   {before_len} -> {len(out)} B (+{len(out) - before_len})")
    print(f"[html-patch] sha256 {before_sha} -> {after_sha}")
    print(f"[html-patch] marker {MARKER}: reload waits for navigator.serviceWorker.ready")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
