from pathlib import Path
p=Path('docs/cpp-dots-runtime/trade-visual-runtime.md'); s=p.read_text(encoding='utf-8')
s=s.replace('''与树木的粗略阴影表现一致；椭圆长宽贴近载具占地，不随太阳高度继续放大；仅按太阳方向小幅偏移，
投影向量上限取 1.5 世界单位与载具长度 6% 中的较小值。''','''与树木的粗略阴影表现一致。基础椭圆按 12 种外观各自的图像占地与 UV 中心定位，
排除精灵格透明留白；搬运队、马车、篷车与货车不再共用整格尺寸和高度。
`TRADE_SHADOW_SHAPES` / `TRADE_SHADOW_HEIGHTS` 为静态美术元数据，只在装配时上传；
不在运行期扫描图片。太阳低垂时仍按高度伸长、偏移椭圆，投影长度上限按对象高度缩放。
高度和上限都相对当前载具尺寸计算，近景屏幕尺寸封顶时同步缩放。''')
p.write_text(s,encoding='utf-8')
p=Path('Project/project-keynes/assets/vfx/trade/README.md'); s=p.read_text(encoding='utf-8'); s+='''
阴影基础形状使用 `UITokens.TRADE_SHADOW_SHAPES` 中每类图像的 UV 中心和实际范围，
排除透明留白；高度使用 `TRADE_SHADOW_HEIGHTS`，不以货车的整格阴影套用人物或马车。
替换图集或改变布局时同步校准这两个表。低角度阳光的伸长保留。
'''; p.write_text(s,encoding='utf-8')
p=Path('docs/cpp-dots-runtime/trade-visual-validation.md'); s=p.read_text(encoding='utf-8'); s+='''
### 按对象校准基础阴影（2026-10-20，最终修正）

实际问题是不同对象共用整格比例，未排除透明留白和位置偏移。
撤销上文 compact 方案对低角度伸长的限制，恢复正常太阳投影；新增 12 类图像的
静态占地、中心与相对高度，分别匹配搬运队、马车、篷车和货车等外观。
不新增图集采样或运行期图片分析，仍是单个解析椭圆。

图形专项扩为 24 项，分别检查搬运队、马车、篷车及货车的本体／纯阴影，
正上方太阳隔离基础尺寸，低角度太阳另行验证伸长。OpenGL 放大样本：

| 对象 | 本体像素范围 | 基础阴影像素范围 | 低角度阴影像素范围 |
| --- | --- | --- | --- |
| 搬运队 | 97×30 | 83×23 | 106×23 |
| 马车 | 113×38 | 97×30 | 127×30 |
| 篷车 | 125×45 | 107×36 | 144×36 |

截图为 `per_style_opengl/porters_preview.png`、`horse_cart_preview.png`、
`covered_wagon_preview.png` 和 `all_objects_preview.png`；Vulkan 对应 `per_style_vulkan/`。
'''; p.write_text(s,encoding='utf-8')
