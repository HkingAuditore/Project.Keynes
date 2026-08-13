# 玩家地图信息菜单规范

## 视觉语言

左侧信息菜单属于宏观战略地图仪表层：深色半透明胡桃色面板、细黄铜描边、克制的内阴影，
全部复用 `UITokens.make_player_theme()`。禁止 Emoji、文字缩写、霓虹光和移动应用式大圆角。

按钮点击区最小 `44×44` 逻辑像素，主列宽 `56`、资源滚动列宽 `62`，图标约 `21px`。图标来自项目内已授权的
Font Awesome Solid 字体并经 `IconBadge` 语义键注册；资源 profile 可用 `Texture2D icon`
覆盖。无专属图标时使用统一问号占位并输出开发告警，正式按钮不得退回文字。

按钮本体无可见名称。名称、简短说明、适用域和快捷信息只能出现在本地化 Tooltip 或非交互图例。
默认、hover、pressed、disabled、focus、active 由现有 Theme 同时改变背景、描边和图标色；
激活/焦点不能只靠颜色表达。

## 信息架构与交互

第一列固定四个分类：地理、气候、资源、生物。点击后在右侧展开第二列；再次点击当前分类只收起菜单，
不会关闭已激活遮罩。分类切换直接替换第二列内容。

- 地理：海拔、地貌、生物群系组、当前植被。
- 气候：温度、湿度、风向、洋流。
- 资源：按 `ResourceProfileRegistry.ordered()` 动态生成。
- 生物：按研究信号目录 `Kind.BIO` 动态生成，点一种物种只显示该物种当前占领。
- 第二列底部固定“关闭图层”图标；任一时刻只激活一个具体图层。

地理与气候列按内容收缩；资源与生物列最高 `430px`，按钮在内部滚动，底部关闭按钮固定在滚动区外。
容器 `MOUSE_FILTER_STOP`，滚轮不得传到地图缩放。两列面板和按钮都消费鼠标输入，点击/拖动不得
选择 cell 或移动镜头。按钮均可获得键盘/手柄焦点；容器顺序支持上下导航，取消键先收起第二列，
再回到地图行为。工具栏面板只保留一层 `6px` 内容边距，禁止将通用 Panel content margin 与组件
margin 叠加，以免实际最小宽度撑破声明列宽。

展开/收起使用 `UIAnimation` 的短距离横移淡入淡出（现值为 `ANIM_FAST`），动画可被新 tween
中断。Overlay mode 切换以 `DataOverlayLayer.show_mode_animated()` 做短 alpha 过渡，不闪白/黑。

## Tooltip 与图例

Tooltip 第一行为本地化名称，第二行为一句数据语义说明。不得显示内部字段、resource ID 或 enum。
图例停靠地图右下角，避开顶部视觉焦点与左侧菜单；右侧 Inspector 打开时，图例自动左移到
Inspector 外侧，并始终从底边向上生长：

- 连续数据：标题、色带、两端语义。
- 离散数据：色块与本地化分类；列表最高 `220px`，超出滚动。
- 风向/洋流：方向色环与强弱色带。
- 资源：profile 显示名、稀少到丰富固定参考色带；透明区域表示无可用储量。
- 生物：物种显示名、单色块「有分布」；透明区域当前没有该物种。不在一张图上叠多种物种。

资源色带使用深紫—电蓝—洋红—橙—黄的固定感知序列，并以 gamma 曲线扩展低值；不得在 gamma
之后再用 `smoothstep` 把中低值压回暗部。海拔使用深蓝—青—绿—黄—红棕—白的高色差科学色带，
相邻区间同时改变色相与亮度。这两类图层允许在统一 `base_alpha` 上使用受限的 mode alpha 增益，
但仍须保留基础地形纹理。资源参考储量不依赖当前世界最大值，并必须与地图生成使用同一数量单位：
`init_floor_reserve` / `init_min_reserve` 在乘以
`CELL_AREA_RESOURCE_SCALE` 后参与参考值，避免保底资源被错误截断为全图 1.0。

## 资源注册与未来发现过滤

资源按钮优先使用 `ResourceProfile.icon`，否则读取 `ResourceProfileRegistry.icon_key(profile)`。
新增资源必须同时注册清晰轮廓图标；菜单代码不得按资源数量或固定下标分支。

`GameUIManager.set_resource_discovery_context(technology_ids, enforce_discovery=false)` 是未来玩家国家科技
接入点。当前默认展示全部自然资源；启用过滤只影响按钮与可见遮罩，不删除或修改实际储量。
生物 Overlay 同样不按国家证据过滤物种按钮；未探索格由迷雾盖住，baker 不再滤一遍 `explored`。

## 性能与生命周期

玩家遮罩使用 `静态 map-index atlas → cell ID → per-cell RGBA8 LUT`。未激活时不编码、不上传；
dirty 事件在权威 flush 后合并到最高 10 Hz，首次开启和切换立即刷新。UI/overlay 状态不进存档，
进入或重建世界后默认关闭。
