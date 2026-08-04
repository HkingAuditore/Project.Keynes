import re

with open(r'WebBuild\ProjectKeynes.js', 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()

keywords = [
    'addEventListener("resize"',
    "addEventListener('resize'",
    'updateSize()',
    'onresize',
    'desired_size=[',
    'setup_canvas',
    'ResizeObserver',
]
for kw in keywords:
    idxs = [m.start() for m in re.finditer(re.escape(kw), content)]
    print(repr(kw), '->', len(idxs), idxs[:10])
