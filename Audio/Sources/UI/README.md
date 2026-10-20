# CC0 UI sound sources

The unmodified selected Ogg files are retained here so the processed WAVs can be
rebuilt with `python tools/audio/prepare_ui_sounds.py` (FFmpeg required).
`sha256.json` records the SHA-256 of each original. Runtime uses the FMOD banks,
not these source files. No network or Studio installation is needed to run the game.

## Kenney — Interface Sounds (1.0)

- Author / publisher: Kenney, https://kenney.nl/
- Author's pack page: https://kenney.nl/assets/interface-sounds
- License: Creative Commons Zero (CC0 1.0); original `kenney/License.txt` retained.
- Download: https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip
- Selected: `click_001`, `drop_003`, `toggle_001`, `toggle_002`, `scratch_001`.

## StarNinjas — 10 Book Page Flips

- Author: StarNinjas, https://opengameart.org/user/85392
- Author's pack / license page: https://opengameart.org/content/10-book-page-flips
- License: Creative Commons Zero (CC0 1.0), as stated on the author's upload page.
- License text: https://creativecommons.org/publicdomain/zero/1.0/legalcode
- Download: https://opengameart.org/sites/default/files/book_flips_-_starninjas.zip
- Selected: `book_flip.4`, `book_flip.6`, `book_flip.8`.
- The author appreciates credit; this project credits the author here.

License pages checked 2026-10-20. The processed files under
`Audio/ProjectKeynes/Assets/UI/` are derived from these CC0 recordings: mono 48 kHz,
shortened, filtered, peak attenuated and edge faded; the close cue is reversed.
No non-CC0 audio is included in this palette.
