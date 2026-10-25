"""Inventory existing semantic icons; keep atlas order and generation prompts reviewable."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'Project/project-keynes/assets/icons/paper'
SOURCE = ROOT / 'Project/project-keynes/scripts/ui/icon_catalog.gd'


def main():
    source = SOURCE.read_text(encoding='utf-8')
    def keys(name):
        return re.findall(r'&"([^"]+)":', source.split('const ' + name + ' := {')[1].split('\n}')[0])
    sheets = []
    style = (
        'Use case: stylized-concept. Asset type: production game UI sprite atlas. '
        'Use the supplied image ONLY as a style reference. Create NEW drawings of the subjects below. '
        'Match its thick rough black graphite outlines, visible colored-pencil hatching and wax-crayon grain, '
        'simple charming slightly irregular silhouettes, flat warm ochre, brick-red, muted blue and leaf-green fills. '
        'Every subject is drawn on its OWN close-cut irregular OFF-WHITE paper sticker with angular scissor-cut edges. '
        'The paper border must closely follow the object, NOT a rectangular card. '
        'Do not use watercolor, smooth vector, fine engraving, photorealism, glossy 3D, ornate framing or cast shadows. '
        'Bold simple silhouettes legible at 32 pixels. TRANSPARENT alpha outside each white paper sticker. '
        'No labels, no text, no grid lines, no numbers, no watermark. '
    )
    def add(name, semantics, cols, rows):
        subjects = [s.split('.')[-1].replace('_', ' ') for s in semantics]
        row_text = '\n'.join('Row %d: %s.' % (r+1, '; '.join(subjects[r*cols:(r+1)*cols])) for r in range(rows) if subjects[r*cols:(r+1)*cols])
        prompt = style + (
            f'Square canvas with EXACTLY {cols} columns and {rows} rows of equally sized cells. '
            'One centered sticker per cell, left to right, top to bottom. Each sticker fits within the middle 76% '
            'of its cell, leaving generous TRANSPARENT gutters on all sides. Do not move objects to other cells. '
            'Any unused final cells must stay transparent. Draw mineral deposits as rough rocks, '
            'refined metals as ingots, occupations as distinct worker busts with their characteristic tool, '
            'buildings as simple recognizable structures.\n' + row_text
        )
        sheets.append(dict(name=name, columns=cols, rows=rows, semantics=semantics, prompt=prompt))
    goods = ['good.' + k for k in keys('GOOD_IDS')]
    professions = ['profession.' + k for k in keys('PROFESSION_IDS')]
    resources = re.findall(r'&"(resource\.[^"]+)":', source.split('const SPECS := {')[1].split('# Legacy identifiers')[0])
    for i in range(0, len(goods), 36):
        add('goods_%02d' % (i//36+1), goods[i:i+36], 6, 6)
    for i in range(0, len(professions), 25):
        add('professions_%02d' % (i//25+1), professions[i:i+25], 5, 5)
    add('resources_01', resources, 6, 7)
    buildings = ['economy.building'] + re.findall(r'&"(economy\.building\.[^"]+)":', source.split('const SPECS := {')[1].split('# Legacy identifiers')[0])
    add('buildings_01', buildings, 5, 4)
    DEST.mkdir(parents=True, exist_ok=True)
    manifest = dict(style_reference='ToyEmpires Icon_TMP.png (user supplied; style reference only)', tool='built-in image_gen', sheets=sheets)
    (DEST/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == '__main__':
    main()
