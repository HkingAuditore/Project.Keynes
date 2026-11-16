# FMOD-GODOT vendor runtime

Source: https://github.com/marcozee03/FMOD-GODOT/releases/tag/v1.1.3

Release archive SHA-256:
`C0632F72C97EED825C2941F7B39E98A038D2ECAFD8909A5F952516A5B4E4F9B6`

Only the upstream extension descriptor, MIT license, Windows x86_64 DLLs, and the editor
plugin's icon set (`icons/` + `fmod-logo.svg`, with their `.import` settings) are retained.
The icons come verbatim from the same pinned archive and exist only to silence the editor
plugin's icon lookups -- see below.
The FMOD Core and Studio runtime DLLs report version 2.03.15 and are licensed separately
from the MIT integration code: https://www.fmod.com/licensing and https://www.fmod.com/legal

The editor plugin inside `libFmodGodot.editor.dll` resolves its dock icons through
`res://addons/FmodGodot/icons/`. Before the icons were vendored, every editor start printed
18 `Failed loading resource` errors plus 9 `non-existing editor theme icon 'Fmod'` warnings.
Vendoring them removes that noise and changes nothing at runtime.

GDExtension auto-loading cannot be suppressed from the project side: extension discovery
runs during engine startup, *before* `EditorFileSystem` scans the project, so a `.gdignore`
marker has no effect on it (verified on 4.6.2 -- the marker was present until commit
`e395588e4` and made no measurable difference either way). Runtime is explicit anyway:
GameAudio calls `GDExtensionManager.load_extension()` on supported Windows sessions, and
the Keynes audio export plugin packages the Windows libraries and banks, so Web/Android
never auto-load a Windows extension.

Two things are deliberately absent: `fmod_installer.gd` (upstream's setup helper) and the
event browser wiring, which is why the editor still logs three `fmod_installer.gd` load
errors per start. Without it the upstream event browser stays unusable -- author audio in
FMOD Studio instead.

The debug runtime emits two debugger-related errors in a headless run without an active
debugger. The isolated Release playback test does not emit these messages. Do not replace
the DLLs with another FMOD version independently of this pinned integration.
