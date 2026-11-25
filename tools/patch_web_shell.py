#!/usr/bin/env python3
"""Inject the Project.Keynes Web shell watchdog into an exported Web build.

Background
----------
The Godot Web export produces a fixed ``ProjectKeynes.html`` shell. We need a
small page-side script that samples the wasm heap and turns the 2 GB
out-of-memory death spiral (thousands of identical "Cannot enlarge memory" /
"table index is out of bounds" lines, one per mouse event) into one readable
overlay plus a heap-vs-time telemetry stream.

The script is kept outside the export preset on purpose:
  * it is a normal JS file, so it can be syntax-checked and unit-tested with
    node without a browser or a rebuild;
  * it is injected after export, so it does not depend on Godot template
    internals and cannot break the export itself.

``Build-Web.cmd`` calls this after a successful ``--export-release`` /
``--export-debug``; it is also safe to run manually on an existing WebBuild/:

    python tools/patch_web_shell.py --web-root WebBuild
    python tools/patch_web_shell.py --web-root WebBuildDebug --check

The operation is idempotent: the marker comment keeps a re-run from inserting
the script twice.
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import sys

MARKER = "<!-- pk-web-watchdog -->"
SCRIPT_TAG = '<script src="pk_web_watchdog.js"></script>'
SCRIPT_NAME = "pk_web_watchdog.js"
PWA_RELOAD_MARKER = "pk-web-pwa-ready"
PWA_REGISTRATION = "\t\t\tlet serviceWorkerRegistrationPromise;"
PWA_REGISTRATION_ERROR = "\t\t\t\tconsole.error('Error while registering service worker:', err);\n\t\t\t});"
PWA_RELOAD = """			// pk-web-pwa-ready
			const worker = navigator.serviceWorker;
			const reloadKey = 'pk-web-pwa:' + window.location.pathname;
			Promise.resolve().then(async () => {
				if (sessionStorage.getItem(reloadKey) || window.crossOriginIsolated) {
					throw new Error('Cross-origin isolation is unavailable.');
				}
				const registration = await worker.getRegistration();
				if (registration == null) {
					await engine.installServiceWorker();
				}
				await worker.ready;
				sessionStorage.setItem(reloadKey, '1');
				window.location.reload();
			}).catch((err) => {
				displayFailureNotice(err);
			});"""
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def find_shell(web_root: pathlib.Path, explicit: str) -> pathlib.Path:
    if explicit:
        path = pathlib.Path(explicit)
        if not path.is_absolute():
            path = (web_root / path).resolve()
        return path
    candidates = sorted(web_root.glob("*.html"))
    if not candidates:
        raise SystemExit(f"patch_web_shell: no .html found under {web_root}")
    # Prefer the export preset's ProjectKeynes.html when several exist.
    for path in candidates:
        if path.name.startswith("ProjectKeynes"):
            return path
    return candidates[0]


def patch_pwa_reload(html: pathlib.Path) -> int:
    text = html.read_text(encoding="utf-8")
    if PWA_RELOAD_MARKER in text:
        return 0
    start = text.find(PWA_REGISTRATION)
    end = text.find(PWA_REGISTRATION_ERROR, start)
    if start < 0 or end < 0:
        print(f"patch_web_shell: unrecognized Godot service worker block in {html.name}",
              file=sys.stderr)
        return 1
    html.write_text(text[:start] + PWA_RELOAD + text[end + len(PWA_REGISTRATION_ERROR):],
                    encoding="utf-8")
    print(f"patch_web_shell: wait for the active service worker in {html.name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", default=str(REPO_ROOT / "WebBuild"),
                        help="directory that holds the exported .html/.pck/.wasm")
    parser.add_argument("--js", default=str(REPO_ROOT / "tools" / "web" / "pk_web_watchdog.js"),
                        help="watchdog source to copy next to the page")
    parser.add_argument("--html", default="", help="override the shell filename")
    parser.add_argument("--check", action="store_true",
                        help="only verify that the shell already carries the watchdog")
    parser.add_argument("--wait-for-pwa", action="store_true",
                        help="patch first-visit reload timing in the Godot PWA shell")
    args = parser.parse_args()

    web_root = pathlib.Path(args.web_root).resolve()
    if not web_root.is_dir():
        print(f"patch_web_shell: web root does not exist: {web_root}", file=sys.stderr)
        return 2
    html = find_shell(web_root, args.html)
    if not html.is_file():
        print(f"patch_web_shell: shell not found: {html}", file=sys.stderr)
        return 2

    if args.wait_for_pwa:
        return patch_pwa_reload(html)

    js_src = pathlib.Path(args.js).resolve()
    if not js_src.is_file():
        print(f"patch_web_shell: watchdog source not found: {js_src}", file=sys.stderr)
        return 2

    text = html.read_text(encoding="utf-8", errors="replace")
    has_marker = MARKER in text and SCRIPT_NAME in text

    if args.check:
        if not has_marker:
            print(f"patch_web_shell: MISSING watchdog in {html.name}", file=sys.stderr)
            return 1
        print(f"patch_web_shell: ok {html.name} carries {SCRIPT_NAME}")
        return 0

    js_dst = web_root / SCRIPT_NAME
    shutil.copyfile(js_src, js_dst)

    if has_marker:
        print(f"patch_web_shell: already injected in {html.name}; refreshed {SCRIPT_NAME} "
              f"({js_dst.stat().st_size} bytes)")
        return 0

    block = f"\t\t{MARKER}\n\t\t{SCRIPT_TAG}\n"
    lowered = text.lower()
    body_close = lowered.rfind("</body>")
    if body_close >= 0:
        text = text[:body_close] + block + text[body_close:]
    else:
        html_close = lowered.rfind("</html>")
        if html_close < 0:
            print(f"patch_web_shell: cannot find </body> or </html> in {html.name}", file=sys.stderr)
            return 2
        text = text[:html_close] + block + text[html_close:]
    html.write_text(text, encoding="utf-8")
    print(f"patch_web_shell: injected {SCRIPT_NAME} into {html.name} "
          f"({js_dst.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
