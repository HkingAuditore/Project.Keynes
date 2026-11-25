#!/usr/bin/env bash
# 一条命令把仓库构建到能跑的状态（macOS / Linux）。
#
# 与 Windows 的 scripts/setup.ps1 覆盖同样的阶段，但这台机器上做不到的部分
# **明确报不支持**，不静默跳过：
#
#   FMOD banks     不支持 —— 生成链是 Windows 的 PowerShell + FMOD Studio GUI
#   FmodGodot 原生库（非 web）  不支持 —— 上游只有 Windows/Android 预编译件
#
# 用法:
#   ./scripts/setup.sh [--platform windows|linux|macos|android|web|all] [--skip-banks] [--skip-skills]
#                      [--jobs N] [--godot-bin PATH] [--fmod-sdk PATH]
#
# 默认 --platform 取当前系统（linux 或 macos）。--skip-banks 在 mac/Linux 上本来就是
# 无意义的（banks 不支持），保留只为命令对称。

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM=""
SKIP_BANKS=0
SKIP_SKILLS=0
JOBS=""
GODOT_BIN="${GODOT_BIN:-}"
FMOD_SDK="${FMOD_SDK:-}"

case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      PLATFORM="linux" ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --platform)   PLATFORM="$2"; shift 2 ;;
        --skip-banks) SKIP_BANKS=1; shift ;;
        --skip-skills) SKIP_SKILLS=1; shift ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        --godot-bin)  GODOT_BIN="$2"; shift 2 ;;
        --fmod-sdk)   FMOD_SDK="$2"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
    esac
done

if [ -z "$JOBS" ]; then
    if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    else JOBS=4; fi
fi

FAILURES=0
step() { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok   %s\n' "$1"; }
skip() { printf '   skip %s\n' "$1"; }
warn() { printf '   warn %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
fix()  { for l in "$@"; do printf '        -> %s\n' "$l"; done; }
have() { command -v "$1" >/dev/null 2>&1; }

printf '\nProject.Keynes 一键构建\n'
printf '仓库根目录 : %s\n' "$REPO_ROOT"
printf '平台       : %s\n' "$PLATFORM"
printf '并行度     : %s\n' "$JOBS"

# --------------------------------------------------------------------------- #
step '1/6 前置检查'

PYTHON=""
for c in python3 python; do have "$c" && PYTHON="$c" && break; done
if [ -n "$PYTHON" ]; then ok "python     $($PYTHON --version 2>&1)"
else bad '缺 python3'; fix 'macOS: brew install python   /   Debian: sudo apt install python3'; fi

if have git; then ok "git        $(git --version)"
else bad '缺 git'; fix 'macOS: brew install git   /   Debian: sudo apt install git'; fi

if have scons; then ok "scons      $(scons --version 2>&1 | head -1)"
else bad '缺 scons'; fix "$PYTHON -m pip install --user scons" "确认 ~/.local/bin 在 PATH 上"; fi

if [ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ]; then ok "godot      $GODOT_BIN"
elif [ -n "$GODOT_BIN" ]; then warn "GODOT_BIN 指向的路径不可执行：$GODOT_BIN"; GODOT_BIN=""
else warn '没找到 Godot（GODOT_BIN 未设置）'
     fix '编 dots_ext 不需要 Godot；导出 Web 与跑 headless 才需要'
     fix 'export GODOT_BIN="$HOME/Applications/Godot.app/Contents/MacOS/Godot"'
fi

case "$PLATFORM" in
    web|all)
        if have emcc; then
            v="$(emcc -dumpversion 2>/dev/null || echo unknown)"
            ok "emcc       $v"
            case "$v" in
                4.0.20*) : ;;
                *) warn "Emscripten 期望 4.0.20，当前 $v —— side module 很可能加载不了"
                   fix 'emsdk install 4.0.20 && emsdk activate 4.0.20 && source ./emsdk_env.sh' ;;
            esac
        else
            bad '缺 emcc（Web 构建必需）'
            fix 'git clone https://github.com/emscripten-core/emsdk'
            fix 'cd emsdk && ./emsdk install 4.0.20 && ./emsdk activate 4.0.20'
            fix 'source ./emsdk_env.sh 后再跑本脚本'
        fi ;;
esac

# --------------------------------------------------------------------------- #
step '2/6 子模块（godot-cpp）'

if [ -f "$REPO_ROOT/gdext/godot-cpp/SConstruct" ]; then
    skip 'gdext/godot-cpp 已就位'
elif [ ! -d "$REPO_ROOT/.git" ]; then
    bad 'gdext/godot-cpp 是空的，而且当前目录不是 git 克隆'
    fix '从 GitHub clone 仓库再跑本脚本'
else
    printf '   ...  git submodule update --init --recursive\n'
    if ( cd "$REPO_ROOT" && git submodule update --init --recursive ); then
        [ -f "$REPO_ROOT/gdext/godot-cpp/SConstruct" ] \
            && ok 'godot-cpp 拉取完成' \
            || { bad 'submodule 成功但 gdext/godot-cpp/SConstruct 仍不存在'; fix 'git submodule status 看它是否 initialized'; }
    else
        bad '子模块拉取失败'
        fix '确认能访问 github.com' 'cd 仓库根; git submodule update --init --recursive 单独跑看完整输出'
    fi
fi

# --------------------------------------------------------------------------- #
step "3/6 dots_ext GDExtension（$PLATFORM）"

run_scons() {
    local dir="$1"; shift
    local label="$1"; shift
    printf '   ...  %s\n        scons %s\n' "$label" "$*"
    if ( cd "$dir" && scons "$@" ); then
        return 0
    fi
    bad "$label 失败"
    fix "cd $dir && scons $*   单独跑看完整报错"
    return 1
}

if [ ! -f "$REPO_ROOT/gdext/SConstruct" ]; then
    bad 'gdext/SConstruct 不存在，仓库不完整'
elif ! have scons; then
    bad '没有 scons，跳过 dots_ext'
else
    case "$PLATFORM" in
        linux)   run_scons "$REPO_ROOT/gdext" 'dots_ext linux' platform=linux target=template_debug dev_build=no -j"$JOBS" || true ;;
        macos)   run_scons "$REPO_ROOT/gdext" 'dots_ext macos' platform=macos target=template_debug dev_build=no -j"$JOBS" || true ;;
        windows)
            warn '在 mac/Linux 上不构建 Windows 目标'
            fix '要 Windows 的 .dll 请在 Windows 机器上跑 scripts\setup.ps1' ;;
        android)
            if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
                bad 'ANDROID_HOME / ANDROID_SDK_ROOT 都没设'
                fix '装 Android SDK + NDK，然后 export ANDROID_HOME=...'
            else
                run_scons "$REPO_ROOT/gdext" 'dots_ext android/arm64' platform=android target=template_release arch=arm64 -j"$JOBS" || true
            fi ;;
        web)
            if have emcc; then
                run_scons "$REPO_ROOT/gdext" 'dots_ext web' platform=web target=template_release arch=wasm32 threads=yes -j"$JOBS" || true
            else
                bad '缺 emcc，跳过 web'
            fi ;;
        all)
            if [ "$PLATFORM" = "all" ]; then
                run_scons "$REPO_ROOT/gdext" 'dots_ext linux' platform=linux target=template_debug dev_build=no -j"$JOBS" || true
                if have emcc; then
                    run_scons "$REPO_ROOT/gdext" 'dots_ext web' platform=web target=template_release arch=wasm32 threads=yes -j"$JOBS" || true
                fi
            fi ;;
    esac
fi

# --------------------------------------------------------------------------- #
step '4/6 FMOD 插件链'

if [ "$PLATFORM" = "web" ] || [ "$PLATFORM" = "all" ]; then
    if [ -z "$FMOD_SDK" ]; then
        FMOD_SDK="$(cd "$REPO_ROOT/.." 2>/dev/null && pwd)/sdk/fmod/html5-20400"
    fi
    if [ -d "$FMOD_SDK/api/studio/lib" ]; then
        if have scons; then
            run_scons "$REPO_ROOT/gdext/fmod_godot" 'FmodGodot web' \
                platform=web target=template_release arch=wasm32 threads=yes \
                fmod_sdk="$FMOD_SDK" -j"$JOBS" || true
        fi
    else
        warn "FMOD HTML5 SDK 没找到：$FMOD_SDK"
        fix '到 https://www.fmod.com/download 下载 FMOD Engine（HTML5 平台）'
        fix '解压成 <仓库上级>/sdk/fmod/html5-20400，或 export FMOD_SDK=它的根目录'
        fix '这个 SDK 带授权，仓库不会自带，脚本也不会替你下载'
    fi
fi

case "$PLATFORM" in
    windows|android|all)
        warn 'FmodGodot 的 Windows/Android 原生库不支持在这里构建'
        fix '上游 FMOD-GODOT v1.1.3 只提供 Windows/Android 预编译件（FMOD 授权限制）'
        fix '在 Windows 机器上把它们放到 Project/project-keynes/addons/FmodGodot/bin/<平台>/'
        fix '缺这一步不影响画面与逻辑，只是没有声音' ;;
esac

# --------------------------------------------------------------------------- #
step '5/6 FMOD banks'

if [ "$SKIP_BANKS" -eq 1 ]; then
    skip '--skip-banks 已指定'
elif [ -d "$REPO_ROOT/Project/project-keynes/assets/audio/banks" ] \
     && [ "$(find "$REPO_ROOT/Project/project-keynes/assets/audio/banks" -name '*.bank' 2>/dev/null | wc -l)" -gt 0 ]; then
    skip '已有 .bank，跳过'
else
    warn '不支持：bank 生成链是 Windows 的 PowerShell + FMOD Studio GUI'
    fix '需要 FMOD Studio（不是 FMOD Engine）与 Audio/ProjectKeynes/ProjectKeynes.fspro'
    fix '在 Windows 上跑 scripts\Build-FMOD-Banks.cmd'
    fix '没有 bank 时游戏能跑但没有声音'
fi

# --------------------------------------------------------------------------- #
step '6/6 AI skill 与自检'

if [ "$SKIP_SKILLS" -eq 1 ]; then
    skip '--skip-skills 已指定'
elif [ -z "$PYTHON" ]; then
    warn '没有 python，跳过 skill 铺开'
elif [ ! -f "$REPO_ROOT/tools/sync_skills.py" ]; then
    warn 'tools/sync_skills.py 不存在'
else
    if ( cd "$REPO_ROOT" && "$PYTHON" tools/sync_skills.py link ); then
        ok 'skill 链接已铺开'
    else
        warn 'sync_skills.py link 有问题'
        fix "$PYTHON tools/sync_skills.py check  看哪个工具缺 skill"
    fi
fi

step '产物自检'

report() {
    local label="$1" dir="$2" pattern="$3" required="$4"
    local n=0
    [ -d "$dir" ] && n="$(find "$dir" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" -gt 0 ]; then
        ok "$(printf '%-22s %3s 个文件' "$label" "$n")"
        return 0
    fi
    if [ "$required" = "1" ]; then bad "$label 缺失（$dir）"; else warn "$label 缺失（$dir）"; fi
    return 1
}

DOTS_DIR="$REPO_ROOT/Project/project-keynes/addons/dots_ext/bin"
report 'dots_ext' "$DOTS_DIR" '*.so' 1 >/dev/null || true
report 'dots_ext(dylib)' "$DOTS_DIR" '*.dylib' 0 >/dev/null || true
report 'FmodGodot 原生库' "$REPO_ROOT/Project/project-keynes/addons/FmodGodot/bin" '*.so' 0 >/dev/null || true
report 'FMOD banks' "$REPO_ROOT/Project/project-keynes/assets/audio/banks" '*.bank' 0 >/dev/null || true

if [ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ]; then ok "Godot 可执行      $GODOT_BIN"
else warn 'Godot 可执行：未配置（GODOT_BIN）'; fi

step '结论'
if [ "$FAILURES" -eq 0 ]; then
    printf '   构建通过。Godot 打开：Project/project-keynes/project.godot\n'
    printf '   注意：mac/Linux 上 banks 与 FmodGodot 非 web 原生库不支持构建，游戏会没有声音。\n'
    exit 0
fi
printf '   %s 个阻塞项，按上面的 -> 提示逐条处理后重跑本脚本。\n' "$FAILURES"
exit 1
