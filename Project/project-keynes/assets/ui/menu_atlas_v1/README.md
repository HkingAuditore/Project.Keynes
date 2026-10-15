# Menu atlas v1

Generated with the built-in ImageGen tool, 2026-10-15. Original RGBA files preserved. No bitmap postprocessing; Godot derives/caches the terrain color masks and projects the land pieces.

- `hero_atlas_v1.png`: two-continent frontispiece, authored stacked paper coast/plains/hills/mountains and thin blue river ribbons; coherent upper-left light, warm ivory/sage/ochre/umber palette, transparent outside land; no text, symbols, frame or icons. Original `exec-156955c7-18ab-44ac-be67-e208d41e1fc2.png`.
- `land_paper_v1.png`: one broad irregular overhead paper-cut continent with cream coast, sage plains/forest, ochre hills, folded ivory ridge and blue rivers, no text/icons/frame. Original `exec-e8afade7-8159-468a-ab43-61021c62308b.png`. An ImageGen background-extraction edit removed the outer studio matte while retaining the land and coast; RGB exists under transparent pixels, but sampled outside-land alpha is zero.

Projection is artistic layout illustration, not authoritative world geography. Seed changes arrangement/handedness; continent count/size/spacing/sea level change composition. Paper layers are cached at 768x512 (192x128 thumbnails), updated only after 180ms input debounce; animation moves cached layers. Existing UI icons/fonts remain separate.
