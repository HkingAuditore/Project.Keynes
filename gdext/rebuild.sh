#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Project.Keynes gdext 一键重 build（macOS 版，同时编 debug + release）
#
# 背景：editor 跑游戏默认加载 .template_debug.dylib；导出 / release 跑用
# .template_release.dylib。只 build 一个 target 时另一个保持旧版本，会出现
# 「我 rebuild 了为什么 F.X 没生效」类隐藏 bug（dots-f5 验收时踩过）。
#
# 用法：
#   1. 完全关闭 Godot 编辑器（确认进程里没有 Godot.app / godot 残留）
#   2. 在终端 cd 到 gdext 目录后执行：
#        chmod +x rebuild.sh   # 仅第一次需要
#        ./rebuild.sh
#   3. 等待两个 target 都 done building
#   4. 重新打开 Godot，跑游戏验证
#
# 退出码：
#   0    = 两个 target 都成功
#   非 0 = 有 target 编译失败，看末尾 error
# ─────────────────────────────────────────────────────────────────────────────

set -u  # 不要 set -e —— 我们要手动判断 errorlevel 给出更友好的输出

# 切到脚本所在目录（等价于 .bat 里的 cd /d %~dp0）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 自动检测 CPU 架构：Apple Silicon → arm64，Intel Mac → x86_64
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64)  SCONS_ARCH="arm64"  ;;
    x86_64) SCONS_ARCH="x86_64" ;;
    *)
        echo "=== ERROR: 未知的 macOS 架构: $HOST_ARCH ==="
        echo "    期望 arm64 (Apple Silicon) 或 x86_64 (Intel)"
        exit 2
        ;;
esac

# 并行任务数：默认按物理核数，sysctl 拿不到就退回 8
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

echo "=== macOS rebuild: arch=$SCONS_ARCH, jobs=$JOBS ==="
echo

echo "=== [1/3] Building target=template_debug ==="
scons platform=macos target=template_debug arch="$SCONS_ARCH" dev_build=no -j"$JOBS"
if [[ $? -ne 0 ]]; then
    echo
    echo "=== ERROR: template_debug build FAILED ==="
    exit 1
fi

echo
echo "=== [2/3] Building target=template_release ==="
scons platform=macos target=template_release arch="$SCONS_ARCH" dev_build=no -j"$JOBS"
if [[ $? -ne 0 ]]; then
    echo
    echo "=== ERROR: template_release build FAILED ==="
    exit 1
fi

echo
echo "=== [3/3] Build done. Updated dylibs: ==="
ls -lh ../Project/project-keynes/addons/dots_ext/bin/macos/*.dylib 2>/dev/null \
    || echo "(没找到 dylib，检查 SConstruct 的输出路径)"

echo
echo "=== Both debug + release dylibs updated. Now restart Godot completely. ==="
echo "=== (Editor must be closed before rebuild — it locks loaded dylib.) ==="
