"""Create Godot AtlasTexture resources without modifying generated image pixels."""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'Project/project-keynes/assets/icons/paper'
CATALOG = ROOT / 'Project/project-keynes/scripts/ui/icon_catalog.gd'


def split_edges(profile, count):
    """Locate transparent gutters near nominal grid lines; generation is not pixel aligned."""
    length = len(profile)
    edges = [0]
    for i in range(1, count):
        expected = i * length / count
        span = length / count * 0.24
        candidates = range(max(1, round(expected-span)), min(length-1, round(expected+span)))
        edge = min(candidates, key=lambda j: sum(profile[max(0, j-2):j+3]) + abs(j-expected)*0.015)
        edges.append(edge)
    return edges + [length]


def art_bounds(alpha, box):
    """Read the largest connected sticker bounds; this never edits source pixels."""
    x0, y0, x1, y1 = box
    width, height = x1-x0, y1-y0
    mask = bytes(alpha.crop(box).point(lambda x: 255 if x > 160 else 0).getdata())
    seen = bytearray(width*height)
    best = (0, (0, 0, width, height))
    for start, value in enumerate(mask):
        if not value or seen[start]:
            continue
        seen[start] = 1
        pending = [start]
        count = 0
        left, top, right, bottom = width, height, 0, 0
        while pending:
            pos = pending.pop()
            x, y = pos % width, pos // width
            count += 1
            left, top, right, bottom = min(left,x), min(top,y), max(right,x), max(bottom,y)
            neighbors = []
            if x: neighbors.append(pos-1)
            if x+1 < width: neighbors.append(pos+1)
            if y: neighbors.append(pos-width)
            if y+1 < height: neighbors.append(pos+width)
            for neighbor in neighbors:
                if mask[neighbor] and not seen[neighbor]:
                    seen[neighbor] = 1
                    pending.append(neighbor)
        if count > best[0]:
            best = count, (left,top,right+1,bottom+1)
    left,top,right,bottom = best[1]
    return [x0+left, y0+top, right-left, bottom-top]


def main():
    manifest = json.loads((ASSETS / 'manifest.json').read_text(encoding='utf-8'))
    # Generation sometimes compacts unused final rows. Record the actual layout.
    layout_rows = {'goods_04': 5, 'professions_02': 4}
    bindings = []
    for sheet in manifest['sheets']:
        name = sheet['name']
        image = Image.open(ASSETS / (name + '.png'))
        alpha = image.getchannel('A')
        width, height = image.size
        cols = sheet['columns']
        rows = layout_rows.get(name, sheet['rows'])
        alpha_pixels = list(alpha.getdata())
        profile = [sum(value > 160 for value in alpha_pixels[y*width:(y+1)*width]) for y in range(height)]
        edges = split_edges(profile, rows)
        sheet['actual_rows'] = rows
        sheet['row_edges_px'] = edges
        sheet['regions'] = {}
        for index, key in enumerate(sheet['semantics']):
            col, row = index % cols, index // cols
            y0, y1 = edges[row], edges[row + 1]
            row_profile = [sum(alpha_pixels[y*width+x] > 160 for y in range(y0,y1)) for x in range(width)]
            columns = split_edges(row_profile, cols)
            x0, x1 = columns[col], columns[col+1]
            # Regions are metadata only; original generated alpha and pixels stay intact.
            region = art_bounds(alpha, (x0, y0, x1, y1))
            sheet['regions'][key] = region
            filename = key.replace('.', '_') + '.tres'
            text = ('[gd_resource type="AtlasTexture" load_steps=2 format=3]\n\n'
                    f'[ext_resource type="Texture2D" path="res://assets/icons/paper/{name}.png" id="1"]\n\n'
                    '[resource]\natlas = ExtResource("1")\n'
                    'region = Rect2(%s)\nfilter_clip = true\n' % ', '.join(map(str, region)))
            (ASSETS / filename).write_text(text, encoding='utf-8')
            bindings.append(f'\t&"{key}": preload("res://assets/icons/paper/{filename}"),')
    block = '# BEGIN GENERATED PAPER ICONS\nconst PAPER_TEXTURES := {\n' + '\n'.join(bindings) + '\n}\n# END GENERATED PAPER ICONS'
    source = CATALOG.read_text(encoding='utf-8')
    if '# BEGIN GENERATED PAPER ICONS' in source:
        start = source.index('# BEGIN GENERATED PAPER ICONS')
        end = source.index('# END GENERATED PAPER ICONS') + len('# END GENERATED PAPER ICONS')
        source = source[:start] + block + source[end:]
    else:
        source = source.replace('const GOOD_GLYPHS := {', block + '\n\n\nconst GOOD_GLYPHS := {', 1)
    CATALOG.write_text(source, encoding='utf-8')
    (ASSETS / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Created %d semantic AtlasTextures from %d original generated PNGs.' % (len(bindings), len(manifest['sheets'])))


if __name__ == '__main__':
    main()
