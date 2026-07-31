import re

src = open(r'd:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\rendering\shrub_layer.gd', encoding='utf-8').read()
for name in ['_SHADER_CODE', '_SHADOW_SHADER_CODE']:
    m = re.search(r'const %s := """\n(.*?)\n"""' % name, src, re.S)
    assert m, name
    code = m.group(1)
    for variant, prefix in [('tiled', '#define MAP_VISUAL_TILED\n'), ('legacy', '')]:
        out = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\%s_%s.gdshader' % (name, variant)
        open(out, 'w', encoding='utf-8').write(prefix + code + '\n')
    print(name, 'extracted', len(code), 'chars')
