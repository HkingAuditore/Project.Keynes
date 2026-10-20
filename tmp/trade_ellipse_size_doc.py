from pathlib import Path
p=Path('docs/cpp-dots-runtime/trade-visual-validation.md'); s=p.read_text(encoding='utf-8'); s+='''
同日按实机反馈继续收紧阴影：占地系数由 (0.90, 0.65) 改为 (0.86, 0.48)，
取消低太阳高度下对椭圆本身的伸长；投影向量同时受 1.5 世界单位和载具长度 6% 限制。
OpenGL 16 项图形检查通过，放大货车样本的本体包围盒为 129×36 像素，
加入阴影后为 129×39 像素。截图在 `ellipse_compact/ellipse_preview.png`。
'''; p.write_text(s,encoding='utf-8')
