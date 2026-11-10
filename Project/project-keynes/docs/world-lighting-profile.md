# 双时态环境光 Profile

## 输入图

使用正方形上下堆叠全景图：总尺寸为 `W × W`，上半部和下半部各是 `2:1` 等距全景；上半部为白天，下半部为夜晚。PNG/JPEG 按 sRGB 解码，EXR 按线性 HDR 解码。EXR 中的 RGB 必须是有限且非负的辐射值。

## 生成 Profile

先确保输出目录存在，然后从 PowerShell 运行：

```powershell
& "F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe" `
  --headless --path "F:\Developent\Godot\Project.Keynes\Project\project-keynes" `
  --script "res://tools/preprocess_world_lighting.gd" -- `
  "D:\art\dual_day_night_panorama.png" `
  "res://assets/rendering/world_lighting_profile.tres" 1.0 0.8
```

最后两个数字分别是白天和夜晚曝光倍率，可省略并默认为 `1.0`。预处理会生成背景纹理、L1 系数、64×64 昼夜辐照度层和 128×128 的 8 级昼夜反射层，并将数据保存在同一个 `.tres` 中。

## 启用

在 Godot Inspector 中打开 `scenes/main.tscn` 和 `scenes/player_game.tscn`，选择 `WorldRoot/HexRenderer`，将 `world_lighting_profile` 指向生成的 `.tres`。地图背景会按全局昼夜相位混合，物件的漫反射继续使用各自位置的本地昼夜值。

桌面低档和 Web 不创建环境纹理数组；桌面中档及移动中/高档只为水面创建反射数组；桌面高档地形额外创建辐照度数组。植被、建筑、资源和单位使用共享 L1 系数。离线阶段完成卷积和粗糙度预滤波，运行时只在需要的档位从已保存 Image 层创建并缓存共享 `Texture2DArray`。
