@echo off
:: ─────────────────────────────────────────────────────────────────────────────
:: Project.Keynes gdext 一键重 build（同时编 debug + release，避免遗漏 target）
::
:: 背景：editor 跑游戏默认加载 .template_debug.dll；导出 / release 跑用
:: .template_release.dll。只 build 一个 target 时另一个保持旧版本，会出现
:: 「我 rebuild 了为什么 F.X 没生效」类隐藏 bug（dots-f5 验收时踩过）。
::
:: 用法：
::   1. 完全关闭 Godot 编辑器（任务管理器确认 godot.exe 没了）
::   2. 双击本文件，或 cmd 里 cd 到 gdext 跑 rebuild.bat
::   3. 等待两个 target 都 done building
::   4. 重新打开 Godot，跑游戏验证
::
:: 退出码：
::   0 = 两个 target 都成功
::   非 0 = 有 target 编译失败，看末尾 error
:: ─────────────────────────────────────────────────────────────────────────────

setlocal enabledelayedexpansion
cd /d %~dp0

echo === [1/3] Building target=template_debug ===
scons platform=windows target=template_debug dev_build=no -j8
if errorlevel 1 (
    echo.
    echo === ERROR: template_debug build FAILED ===
    pause
    exit /b 1
)

echo.
echo === [2/3] Building target=template_release ===
scons platform=windows target=template_release dev_build=no -j8
if errorlevel 1 (
    echo.
    echo === ERROR: template_release build FAILED ===
    pause
    exit /b 1
)

echo.
echo === [3/3] Build done. Updated DLLs: ===
dir ..\Project\project-keynes\addons\dots_ext\bin\windows\*.dll

echo.
echo === Both debug + release dlls updated. Now restart Godot completely. ===
echo === (Editor must be closed before rebuild — it locks loaded DLL.) ===
pause
endlocal
