"""Complete the semantic icon inventory using generated cut-paper art and explicit reuse."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'Project/project-keynes/assets/icons/paper'
CATALOG = ROOT / 'Project/project-keynes/scripts/ui/icon_catalog.gd'


def main():
    controls = [
        ('action.add', 'bold green plus sign'), ('action.back', 'blue left-pointing arrow'),
        ('action.chevron_down', 'single black downward chevron'), ('action.chevron_right', 'single black right-pointing chevron'),
        ('action.close', 'bold red X cross'), ('action.confirm', 'bold green checkmark'),
        ('action.fit', 'four dark pencil corner brackets around a tiny folded map'),
        ('action.history', 'small clock encircled by a backward arrow'), ('action.more', 'three bold horizontal dark graphite dots'),
        ('action.pin', 'red drawing pin'), ('action.refresh', 'two blue circular arrows chasing each other'),
        ('action.reset', 'one ochre backward curved arrow'), ('action.save', 'cream document with a red bookmark and quill'),
        ('system.clock', 'round brass clock face with two dark clock hands, no numbers'),
        ('system.seed', 'ivory dice with dark pips'), ('system.target', 'red and ivory bullseye with arrow'),
        ('system.unknown', 'large dark pencil question mark'), ('status.hidden', 'eye crossed by a red diagonal stroke'),
        ('status.warning', 'ochre triangle with dark exclamation mark'), ('summary.overview', 'cream ledger report with three drawn horizontal lines and red binding'),
    ]
    states = [
        ('climate.moon', 'pale ochre crescent moon'), ('climate.snow', 'single icy blue six-point snowflake'),
        ('population.heart', 'red heart'),
        ('population.living.destitute', 'empty chipped begging bowl and rag'),
        ('population.living.struggling', 'patched brown purse with a single copper coin'),
        ('population.living.poor', 'small humble thatched hut'),
        ('population.living.secure', 'basket holding bread and green vegetables'),
        ('population.living.comfortable', 'comfortable blue upholstered chair'),
        ('population.living.affluent', 'gold coin stack with small gold crown'),
        ('population.living.luxury', 'large red ruby in a gold jewel setting'),
        ('tax.business', 'small factory with coin stack'), ('tax.consumption', 'shopping basket beside coins'),
        ('tax.default', 'ledger with three small adjustment sliders'), ('tax.export', 'wooden crate with red arrow pointing outward to the right'),
        ('tax.import', 'wooden crate with blue arrow pointing inward from the left'), ('tax.income', 'open hand receiving a gold coin'),
        ('tax.section', 'abacus beside a cream tax ledger'), ('tax.tariff', 'border gate with wooden crate and gold coin'),
        ('technology.milestone', 'gold medal on a red ribbon'), ('technology.state.available', 'glowing ochre light bulb'),
    ]
    family = [
        ('family.workspace.crest', 'red heraldic shield with simple gold oak tree, no text'),
        ('family.workspace.prestige', 'gold laurel wreath around a red star'),
        ('family.workspace.person', 'single dignified handwritten-style human bust in a brown coat'),
        ('family.workspace.traits', 'three interlocking colored puzzle pieces'),
        ('family.workspace.preferences', 'small red heart beside bread and a hammer'),
        ('family.workspace.effects', 'wax-sealed document with small blue spark and cog'),
        ('family.workspace.people', 'three distinct human busts grouped together'),
        ('family.workspace.branches', 'family tree diagram with three small portrait frames connected by brown branches'),
        ('technology.state.queued', 'three cream papers stacked in order with small blue bookmark'),
        ('trend.up', 'bold green upward arrow'), ('trend.down', 'bold red downward arrow'), ('trend.flat', 'bold blue right-pointing horizontal arrow'),
    ]
    aliases = {
        'action.pause': 'hud.clock.pause', 'action.play': 'hud.clock.play',
        'climate.sun': 'hud.system.day_night_off', 'climate.weather': 'hud.overlay.climate',
        'country.affairs': 'summary.overview', 'country.diplomacy': 'hud.country.diplomacy',
        'country.military': 'hud.country.military', 'country.politics': 'hud.country.ideology',
        'country.economy': 'hud.country.economy', 'country.technology': 'hud.country.technology',
        'country.world': 'hud.overlay.geography', 'family.house': 'family.workspace.crest',
        'family.workspace.overview': 'summary.overview', 'family.metric.population': 'family.workspace.people',
        'family.metric.wealth': 'hud.country.economy', 'family.metric.buildings': 'economy.building',
        'family.metric.time': 'system.clock', 'hud.system.gm': 'hud.system.settings',
        'hydrology.water': 'hydrology.current', 'metric.goods': 'good.packaging',
        'metric.technology': 'hud.country.technology', 'metric.territory': 'hud.overlay.geography',
        'metric.treasury': 'hud.country.economy', 'map.expedition': 'hud.overlay.geography',
        'map.population': 'family.workspace.people', 'map.construction': 'good.tools',
        'system.calendar': 'hud.clock.calendar', 'system.settings': 'hud.system.settings',
        'technology.domain.agriculture': 'good.grain', 'technology.domain.engineering': 'good.tools',
        'technology.domain.science': 'good.scientific_instruments', 'technology.domain.society': 'family.workspace.people',
        'technology.state.completed': 'action.confirm', 'technology.state.locked': 'status.hidden',
        'technology.state.pending': 'system.clock', 'technology.state.unknown': 'system.unknown',
    }
    # A lock needs its own silhouette; do not substitute a hidden eye.
    family.append(('technology.state.locked', 'closed dark iron padlock with brass keyhole'))
    aliases.pop('technology.state.locked')
    # Keep full rows, giving locked research and hidden information distinct artwork.
    family.extend([
        ('country.world', 'blue and green globe on a small brass stand'),
        ('map.expedition', 'red expedition flag planted on a small folded map'),
        ('metric.goods', 'wooden supply crate with small cloth bundle'),
    ])
    for key in ['country.world', 'map.expedition', 'metric.goods']:
        aliases.pop(key)
    style = (
        'Use case: stylized-concept. Asset type: production game UI sprite atlas. '
        'Use supplied image ONLY as a style reference. Draw NEW original icons. '
        'Match thick rough BLACK GRAPHITE contours, waxy colored-pencil grain, simple slightly irregular silhouettes, '
        'warm ochre, brick red, blue and leaf green fills, angular off-white SCISSOR-CUT paper sticker border. '
        'Paper border follows each object closely. Bold shapes readable at 16 to 32 pixels. '
        'No watercolor, engraving, smooth vectors, glossy 3D, metal frames, outer shadows, decorative background. '
        'TRUE TRANSPARENT ALPHA outside each sticker. No text or numbers or labels or grid lines. '
    )
    sheets = []
    for name, subjects, cols, rows in [('ui_controls_01', controls, 5, 4), ('ui_states_01', states, 5, 4), ('ui_family_01', family, 4, 4)]:
        prompt = style + f'EXACTLY {cols} columns by {rows} rows of equal cells on a square canvas. '
        prompt += 'One centered sticker in each cell. Each sticker occupies ONLY middle 72% of its cell, with generous transparent gutters. Read subjects left to right, top to bottom.\n'
        prompt += '\n'.join('Row %d: %s.' % (r+1, '; '.join(d for _, d in subjects[r*cols:(r+1)*cols])) for r in range(rows))
        sheets.append(dict(name=name, columns=cols, rows=rows, semantics=[k for k,_ in subjects], prompt=prompt))
    source = CATALOG.read_text(encoding='utf-8')
    specs = re.findall(r'&"([^"]+)":', source.split('const SPECS := {')[1].split('# Legacy identifiers')[0])
    paper = re.findall(r'&"([^"]+)":', source.split('const PAPER_TEXTURES := {')[1].split('# END GENERATED PAPER ICONS')[0])
    previous_aliases = re.findall(r'&"([^"]+)":', source.split('const PAPER_ALIASES := {')[1].split('\n}')[0])
    new_keys = [k for sheet in sheets for k in sheet['semantics']]
    missing = set(specs)-set(paper)-set(previous_aliases)-set(new_keys)-set(aliases)
    assert not missing, missing
    result = dict(sheets=sheets, aliases=aliases, audit=dict(registered_semantics=len(specs), generated_before=len(paper), new_art=len(new_keys), reused=len(aliases), missing=list(missing)))
    (DEST/'full-ui-manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))


if __name__ == '__main__':
    main()
