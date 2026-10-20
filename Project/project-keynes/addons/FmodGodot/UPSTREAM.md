# FMOD-GODOT vendor runtime

Source: https://github.com/marcozee03/FMOD-GODOT/releases/tag/v1.1.3

Release archive SHA-256:
`C0632F72C97EED825C2941F7B39E98A038D2ECAFD8909A5F952516A5B4E4F9B6`

Only the upstream extension descriptor, MIT license, and Windows x86_64 DLLs are retained.
The FMOD Core and Studio runtime DLLs report version 2.03.15 and are licensed separately
from the MIT integration code: https://www.fmod.com/licensing and https://www.fmod.com/legal

`.gdignore` is deliberate: GameAudio explicitly loads this extension on supported Windows
sessions. The Keynes audio export plugin packages Windows libraries and banks only, so
Web/Android do not auto-load a Windows extension. This arrangement does not expose the
upstream event browser inside the Godot editor; author audio in FMOD Studio instead.

The debug runtime emits two debugger-related errors in a headless run without an active
debugger. The isolated Release playback test does not emit these messages. Do not replace
the DLLs with another FMOD version independently of this pinned integration.
