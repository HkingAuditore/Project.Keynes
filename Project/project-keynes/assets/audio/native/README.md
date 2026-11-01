# Web 音频

由仓库中的无损 FMOD 源音频离线转换，运行时由 `native_audio_backend.gd` 播放。
菜单使用石器时代配乐；进入游戏延续同一条时间轴。时代升级切换组曲并叠加过渡曲。
每套组曲首次播放包含引子，后续循环跳过引子。音效保留 GameAudio 的冷却和信号，
最多同时播放 12 个效果声；播放器随全局服务常驻，暂停菜单仍可播放反馈。

Web 使用完整混音，不实现 FMOD 的人口、镜头、情绪分轨自动化或试听台单段锁定。
不支持的动态参数接口返回 false，正式时代切换接口仍然有效。
总音量和静音沿用 GameSettings 的 Master 总线。浏览器通常需要一次点击或按键才会
恢复 AudioContext；加载页面后暂时无声属于浏览器的自动播放限制。

重新生成：在仓库根目录执行 `python tools/audio/build_web_audio.py`。
依赖 ffmpeg（PATH）或 `python -m pip install imageio-ffmpeg`。
输入是 `Audio/ProjectKeynes/Assets/` 中的 WAV，音乐分轨按原始增益精确相加，
保持 48 kHz，输出 Vorbis quality 7。不会调用外部生成 API，也不会改动母带。
生成的 OGG 和 `.import` 一同纳入版本库，普通 Web 构建无需安装音频编码工具。
导出插件仅在 Web 包含这些资源，Windows 仍然使用原有 FMOD bank。

验证：`godot --headless --path Project/project-keynes --script res://tests/audio/native_audio_backend_test.gd`；
构建后运行 `python tools/verify_web_audio.py --url http://127.0.0.1:8060/ProjectKeynes.html`，
检查真实浏览器在用户点击后有非零音频输出。
