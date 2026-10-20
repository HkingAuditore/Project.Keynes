# ProjectKeynes audio source

Open `../Open-FMOD-Studio.cmd` to edit `ProjectKeynes/ProjectKeynes.fspro` in Studio 2.03.15.
Run `../Build-FMOD-Banks.cmd` after saving to build and synchronize the four Desktop banks.
Run `../Run-FMOD-Demo.cmd` to audition the layered music and eight UI cues in Godot 4.6.2.

The current menu and in-game UI use the CC0 paper palette under `ProjectKeynes/Assets/UI/`.
See [source licenses](Sources/UI/README.md) and [UI feedback](../docs/audio/ui-feedback.md).

`ProjectKeynes/Assets/Prototype/` contains original synthesized test audio produced by
`tools/audio/generate_prototype_audio.py`. These are integration fixtures, not the final
soundtrack. The generator refuses to replace existing files. No audio from FMOD's example
package is included. The music event loops all three stems on one eight-second timeline;
the `Tension` parameter controls Melody and Pulse track volume automation.

Commit the `.fspro`, `Metadata/`, and owned `Assets/` together. Metadata is essential: the
small `.fspro` alone does not contain the project. Local Studio state and intermediate
`Build/` outputs are ignored; the synchronized game banks are versioned for immediate play.
Studio executables remain ignored under `tools/fmod-studio/`, with a per-machine installer
cache for new clones. These paths currently have no Git LFS filter.

The runtime is Windows-only in this first integration. Era-specific compositions, state
selection, transition timing and real gameplay tension inputs have not been authored yet.
