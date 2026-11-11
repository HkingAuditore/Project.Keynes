@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ===========================================================================
rem Project.Keynes - one-shot Web export
rem
rem   1. Rebuild the dots_ext wasm32 side module from the current C++ source.
rem
rem      threads= must match the Web preset's variant/thread_support, otherwise
rem      the pthread ABI differs and the side module fails to load. The preset
rem      ships variant/thread_support=true, so this script builds threads=yes by
rem      default: the native runtime drives its daily simulation from a
rem      std::thread worker, and without pthreads that worker never runs, which
rem      freezes the browser at "进入世界" 98%. Set PK_WEB_THREADS=no to build the
rem      nothreads variant anyway (menu/world-gen only, then it hangs).
rem
rem      disable_exceptions=no is required: godot-cpp forces -fno-exceptions by
rem      default, but the native runtime uses C++ exceptions for economy
rem      invariant failures. The Godot 4.6 dlink Web main module ships a wasm
rem      exception tag, so an exceptions-enabled side module links and loads.
rem   2. Prebake the loading catalogs (effect/economy/technology/research/display)
rem      into Project\project-keynes\data\loading_catalog_v1\ before exporting.
rem
rem      This MUST run in its own headless process, before the export:
rem        * The export hook (_export_begin) runs inside the editor process, where
rem          GDScript "scripting" is disabled. Scripted .tres resources then get
rem          placeholder instances, so every script default (e.g. a PackedStringArray
rem          that is not stored in the .tres) reads back as null. The catalog
rem          compiler aborts on that ("Invalid cast"), which is exactly the old
rem          "Loading catalog export bake failed: Invalid data" error, and even if
rem          it survived it would bake null/0 defaults into the snapshot.
rem        * Without a fresh snapshot every new game recompiles the catalogs and
rem          pays the 4-5 s cold start again (the cache would miss).
rem      A failed prebake aborts the script: never export a package that silently
rem      ships stale catalogs.
rem   3. Subset the CJK fonts for the web package only (tools\subset_fonts.py).
rem
rem      .fontdata is ~57 MB of the pck (5 CJK fonts + 2 handwriting fonts). The
rem      script scans every .gd/.tscn/.tres/data/*.json for the characters the game
rem      can actually render, subsets each font (fontTools), proves no glyph the
rem      original font had was dropped, and only then swaps the imported
rem      .godot\imported\*.fontdata for the export. Original .ttf files, .import
rem      files and every res:// reference stay untouched, so desktop/Android/editor
rem      builds keep the full fonts. The swap is reverted right after the export
rem      (and by the next run if this script is killed mid-export).
rem
rem      Skip it with PK_WEB_SKIP_FONT_SUBSET=1 (old behaviour, +57 MB pck).
rem   3.6 Register FmodGodot for the web package.
rem
rem      Web 上 FMOD 必须在引擎启动时自动加载（运行期 load_extension 在浏览器里
rem      同步等异步 fetch，主线程死锁），而 .godot\extension_list.cfg 只收录没有
rem      .gdignore 的 .gdextension。所以导出前临时摘掉 addon 的 .gdignore 并重新
rem      import，导出后立刻还原（成功和失败两条路径都还原）。
rem
rem      注意：一旦 FmodGodot 被注册，它的 EditorExportPlugin 会用 add_file()
rem      把 bank 硬塞进包，preset 里的 assets/audio/banks/* 排除规则对它无效。
rem      这也正是下面 3.7 存在的理由。
rem   3.7 Stage the FMOD banks for web (web only).
rem
rem      两件事：
rem      a) 四个核心 bank（Master / Master.strings / Music / UI）换成 HTML5 平台那套。
rem      b) 四个时代 bank（Music_stone/agrarian/kingdom/empire）**整个移出工程**，
rem         导出后再作为独立文件发布到 WebBuild\ 根目录。
rem
rem      为什么 era bank 不能留在包里：它们每个 20~25 MB（q70），而一局只会用到其中
rem      一个；拆包后 web 首包只带一个时代那 8~10 MB（q24），其余在时代推进时按需
rem      fetch。preset 的 exclude 拦不住它们 —— 只要文件在 res:// 下，FmodGodot 的
rem      add_file() 就会把它塞进 pck，所以只能物理移走。
rem
rem      前提：FMOD 工程已按时代拆 bank（tools\audio\split_music_banks.py）。
rem      Skip it with PK_WEB_SKIP_BANK_DOWNGRADE=1 (pck carries all four, +91 MB).
rem   4. Export the Godot "Web" preset into WebBuild\.
rem
rem Requirements:
rem   * emsdk checked out at <repo>\emsdk, with 4.0.20 installed + activated
rem     (4.0.20 is the Emscripten release the official Godot 4.6 templates use;
rem      any other version makes the side module fail to load in the browser).
rem   * Godot 4.6.x editor binary (set GODOT_BIN, or installed next to the repo).
rem   * 4.6.2.stable web export templates (%APPDATA%\Godot\export_templates).
rem
rem Usage:
rem   Build-Web.cmd                 rebuild native release + export release
rem   Build-Web.cmd debug           rebuild native debug + export debug
rem   Build-Web.cmd both            rebuild/export both variants
rem   Build-Web.cmd skip-native     reuse the existing wasm side module
rem   Build-Web.cmd skip-native-debug  export debug only, reuse the debug wasm
rem ===========================================================================

set "ROOT=%~dp0"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=release"

rem 跳过 native 重建时仍要能区分 release/debug 导出。
set "SKIP_NATIVE="
if defined PK_WEB_SKIP_NATIVE set "SKIP_NATIVE=1"
if /i "%MODE%"=="skip-native" (
    set "SKIP_NATIVE=1"
    set "MODE=release"
)
if /i "%MODE%"=="skip-native-debug" (
    set "SKIP_NATIVE=1"
    set "MODE=debug"
)

set "JOBS=16"
if defined PK_WEB_JOBS set "JOBS=%PK_WEB_JOBS%"

rem Must match the Web export preset's variant/thread_support. The native daily
rem simulation host runs on a std::thread worker, so threads=no produces a
rem module that freezes the page when a world finishes generating.
set "THREADS=yes"
if defined PK_WEB_THREADS set "THREADS=%PK_WEB_THREADS%"

set "WEB_ROOT=%ROOT%WebBuild"
set "LOG_DIR=%ROOT%tmp"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

rem --- locate the Godot editor binary -----------------------------------------
rem Candidates, in order: GODOT_BIN, the usual Windows zip layout where the
rem downloaded archive was extracted into a folder named like the executable,
rem a plain sibling binary, then anything named godot on PATH.
set "GODOT="
if defined GODOT_BIN set "GODOT=%GODOT_BIN%"
call :find_godot "%ROOT%..\..\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe"
call :find_godot "%ROOT%..\..\Godot_v4.6.2-stable_win64.exe"
call :find_godot "%ROOT%..\Godot_v4.6.2-stable_win64.exe"
call :find_godot "%ROOT%..\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe"
call :find_godot "%ROOT%Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe"
if not defined GODOT for %%G in (godot.exe godot4.exe) do (
    if not defined GODOT where %%G >nul 2>nul && set "GODOT=%%G"
)
if not defined GODOT (
    echo === ERROR: Godot editor binary not found ===
    echo Set GODOT_BIN to the Godot 4.6.x executable and retry.
    exit /b 1
)
rem Canonicalise: cmd cannot launch a quoted path that still contains "..\"
rem components (fails with 9009 even though `if exist` reports the file).
for %%F in ("%GODOT%") do set "GODOT=%%~fF"

echo ============================================================
echo  Project.Keynes Web export
echo  Mode:      %MODE%
echo  Godot:     %GODOT%
echo  Output:    %WEB_ROOT%\ProjectKeynes.html
echo  Logs:      %LOG_DIR%\web_export_*.log
echo ============================================================
echo.

rem --- 1. native wasm side module ---------------------------------------------
if not defined SKIP_NATIVE (
    if not exist "%ROOT%emsdk\emsdk_env.bat" (
        echo === ERROR: emsdk not found at "%ROOT%emsdk" ===
        echo Install emsdk 4.0.20 and activate it first.
        exit /b 1
    )
    call "%ROOT%emsdk\emsdk_env.bat" >nul
    if errorlevel 1 (
        echo === ERROR: failed to activate emsdk ===
        exit /b 1
    )

    for /f "tokens=*" %%V in ('emcc -dumpversion 2^>nul') do set "EM_ACTUAL=%%V"
    if not "!EM_ACTUAL!"=="4.0.20" (
        echo === WARNING: Emscripten "%EM_ACTUAL%" ^(expected 4.0.20^) ===
        echo The side module will most likely fail to load in the browser.
        echo.
    )

    pushd "%ROOT%gdext"
    set "PUSHED=1"
    if /i "%MODE%"=="debug" (
        call :build_native template_debug
        if errorlevel 1 goto :fail
    ) else if /i "%MODE%"=="both" (
        call :build_native template_release
        if errorlevel 1 goto :fail
        call :build_native template_debug
        if errorlevel 1 goto :fail
    ) else (
        call :build_native template_release
        if errorlevel 1 goto :fail
    )
    popd
    set "PUSHED="
    echo.
)

rem --- 2. loading catalog prebake (must be before the export) ----------------
rem Why here and why a separate process:
rem   * data\loading_catalog_v1\*.res is what the game loads at "新开游戏". If the
rem     snapshots are missing/stale the runtime falls back to the GDScript source
rem     compiler and every new game costs roughly 4-5 extra seconds.
rem   * The export hook (addons\loading_prebake\plugin.gd _export_begin) cannot be
rem     the producer: it runs in the editor process with scripting disabled, so
rem     scripted .tres defaults read as null and the catalog compile fails (this
rem     used to surface as "Loading catalog export bake failed: Invalid data").
rem   * So the snapshot is generated here, in a plain headless game process, and
rem     the export hook only verifies + packs it. Fail hard: shipping a package
rem     with stale catalogs is silent, and it costs the player 4-5 s per new game.
echo [prebake] loading catalogs (effect/economy/technology/research/display) ...
"%GODOT%" --headless --path "%ROOT%Project\project-keynes" ^
    --script res://tools/prebake_loading_catalogs.gd >"%LOG_DIR%\web_prebake.log" 2>&1
if errorlevel 1 (
    echo === ERROR: loading catalog prebake FAILED ^(see "%LOG_DIR%\web_prebake.log"^) ===
    echo === Export aborted: stale snapshots would make every new game recompile. ===
    exit /b 1
)
echo [prebake] ok

rem --- 3.5 web texture downgrade (web only, temporary import-cache swap) -------
rem The pck ships .godot\imported\*.ctex, so the only lever is what they contain:
rem every 2D texture is currently lossless WebP (compress/mode=0). This re-imports
rem them as lossy WebP at per-class qualities and temporarily re-bakes
rem loading_prebaked_v1 material_1024_*.res at 256 (web reads the 512 set).
rem Resolution is untouched; desktop state is restored byte-for-byte afterwards
rem (also on the failure path). Measured with textures only: 282.75 -> 132.17 MiB.
rem Skipping is a supported fallback: PK_WEB_SKIP_TEXTURE_DOWNGRADE=1.
set "TEX_DOWNGRADE_ACTIVE="
if defined PK_WEB_SKIP_TEXTURE_DOWNGRADE (
    echo [tex] skipped ^(PK_WEB_SKIP_TEXTURE_DOWNGRADE=1^): pck keeps lossless WebP textures
) else (
    call :find_python
    if errorlevel 1 goto :fail
    echo [tex] downgrading web textures ^(backup .import/.res, lossy WebP, re-import^) ...
    !PY! "%ROOT%tools\web_tex_downgrade.py" begin --godot "%GODOT%"
    if errorlevel 1 (
        echo === ERROR: web texture downgrade FAILED ^(state restored automatically, see above^) ===
        echo === Skip it with: set PK_WEB_SKIP_TEXTURE_DOWNGRADE=1 ===
        goto :fail
    )
    set "TEX_DOWNGRADE_ACTIVE=1"
)

rem --- 3.6 cloud-shadow prebake shrink (web only) ------------------------------
rem assets\textures\cloud_shadow\*.res 存的是**裸 Image**（1024^2 RGBA8 + mipmap，
rem 各 5.33 MB），不是导入纹理，所以上面那套 .import 参数对它完全无效 —— 只能改
rem 内容本身。云影是低频的（云团直径约 62 texel），1080p 下 512 与 1024 看不出
rem 差别，字节数只有 1/4。脚本自己备份成 <name>.1024.bak，restore 用 md5 可验。
rem Skipping is a supported fallback: PK_WEB_SKIP_CLOUD_SHRINK=1.
set "CLOUD_SHRINK_ACTIVE="
if defined PK_WEB_SKIP_CLOUD_SHRINK (
    echo [cloud] skipped ^(PK_WEB_SKIP_CLOUD_SHRINK=1^): cloud shadows stay at 1024
) else (
    echo [cloud] shrinking cloud-shadow prebake to 512 ^(1024 -^> 512 per axis^) ...
    "%GODOT%" --headless --path "%ROOT%Project\project-keynes" ^
        --script res://tools/web_cloud_shadow_shrink.gd -- shrink 512 >"%LOG_DIR%\web_cloud_shadow.log" 2>&1
    if errorlevel 1 (
        echo === ERROR: cloud-shadow shrink FAILED ^(see "%LOG_DIR%\web_cloud_shadow.log"^) ===
        echo === Skip it with: set PK_WEB_SKIP_CLOUD_SHRINK=1 ===
        goto :fail
    )
    set "CLOUD_SHRINK_ACTIVE=1"
)


rem --- 3. web font subsetting (web only) --------------------------------------
rem The pck ships .godot\imported\*.fontdata, so "not using the fonts" is not an
rem option: the only way to make them smaller is to shrink what they contain.
rem tools\subset_fonts.py builds the used-character set from the project, subsets
rem every imported font into tmp\web_font_subset\ (gitignored), has the real Godot
rem importer produce .fontdata for the subsets, and swaps them into the import
rem cache for the duration of the export. `restore` puts the originals back.
rem Skipping is a supported fallback: PK_WEB_SKIP_FONT_SUBSET=1.
set "FONT_SUBSET_ACTIVE="
if defined PK_WEB_SKIP_FONT_SUBSET (
    echo [font-subset] skipped ^(PK_WEB_SKIP_FONT_SUBSET=1^): pck keeps the full ~57 MB of .fontdata
) else (
    call :find_python
    if errorlevel 1 goto :fail
    echo [font-subset] scanning text + subsetting fonts for the web package ...
    rem !PY! not %PY%: this whole block is parsed before :find_python runs, so %PY%
    rem would expand to nothing (delayed expansion is on at the top of the script).
    !PY! "%ROOT%tools\subset_fonts.py" prepare ^
        --project "%ROOT%Project\project-keynes" --godot "%GODOT%" --cache "%ROOT%tmp\web_font_subset"
    if errorlevel 1 (
        echo === ERROR: web font subsetting FAILED ^(exit=!ERRORLEVEL!, missing glyphs or import problem, see above^) ===
        echo === Fix the report, or export the old way with PK_WEB_SKIP_FONT_SUBSET=1. ===
        goto :fail
    )
    set "FONT_SUBSET_ACTIVE=1"
)

rem --- 3.9 music split gate (web only) -----------------------------------------
rem `assets/audio/native/music/` is ~17.7 MB of ogg and a session only needs the
rem current era. With the gate ON (default) the Web preset excludes those files and
rem step 6 emits `music_<era>.pck` / `music_trans.pck`, which the game fetches after
rem entering the world (scripts/audio/web_music_stream.gd).
rem PK_WEB_DEFER_MUSIC=0 -> music goes back into the boot pck (old behaviour).
if defined PY (
    if "%PK_WEB_DEFER_MUSIC%"=="0" (
        echo [music] PK_WEB_DEFER_MUSIC=0 -^> music stays in the boot pck
        !PY! "%ROOT%tools\web_music_pack.py" gate --disable
    ) else (
        echo [music] deferring music into per-era packs
        !PY! "%ROOT%tools\web_music_pack.py" gate --enable
    )
    if errorlevel 1 (
        echo === ERROR: music export gate FAILED ===
        goto :fail
    )
) else (
    echo === WARNING: Python not found; music gate left as-is in export_presets.cfg ===
)

rem [audio-guard 2026-11-01] preset-level assertion: the three platforms must not
rem pollute each other's audio filter (Android excludes the FMOD banks, Windows must
rem not, Web depends on whether music is split). Last time the gate edited the wrong
rem preset and only a human `git diff` caught it - now the machine catches it.
if defined PY (
    set "AUDIO_GUARD_FLAG="
    if "%PK_WEB_DEFER_MUSIC%"=="0" set "AUDIO_GUARD_FLAG=--web-inline"
    !PY! "%ROOT%tools\verify_audio_packaging.py" --presets-only !AUDIO_GUARD_FLAG!
    if errorlevel 1 (
        echo === ERROR: audio packaging preset guard FAILED ^(see message above^) ===
        goto :fail
    )
) else (
    echo === WARNING: Python not found; audio packaging preset guard not run ===
)

rem --- 4. Godot Web export ----------------------------------------------------
rem FmodGodot 必须在**导出之前**进 .godot\extension_list.cfg：浏览器里运行期
rem GDExtensionManager.load_extension() 会同步等异步 fetch，主线程死锁。挂/摘都
rem 交给 tools\export_web_with_fmod.ps1（它自己记账，重复调用幂等），:fail 路径
rem 也会摘一次 —— 漏摘会让编辑器/Android 下次打开时多认一个扩展。
call :fmod_enable
if errorlevel 1 goto :fail

rem bank 降质：Desktop 那套是 Vorbis q70（Music.bank 91.0 MB），HTML5 那套是
rem q37（49.5 MB）。必须在 :fmod_enable 之后 —— 只有 FmodGodot 注册了，Godot 才
rem 认得 .bank 的导入器。详见 tools\web_bank_downgrade.py 的说明。
call :bank_begin
if errorlevel 1 goto :fail

if /i "%MODE%"=="debug" (
    call :export_web debug
) else if /i "%MODE%"=="both" (
    call :export_web release
    if errorlevel 1 goto :fail
    call :export_web debug
) else (
    call :export_web release
)
if errorlevel 1 goto :fail

call :bank_end
if errorlevel 1 goto :fail
call :fmod_disable
if errorlevel 1 goto :fail

call :cloud_end
call :font_subset_restore
call :tex_end
if errorlevel 1 goto :fail

echo.
echo === Web export finished ===
dir /b "%WEB_ROOT%"
echo.
echo Serve it with:  serve_web.bat
exit /b 0

:fail
if defined PUSHED popd
call :bank_end
call :fmod_disable
call :cloud_end
call :tex_end
call :font_subset_restore
echo.
echo === Web export FAILED ===
exit /b 1

rem ---------------------------------------------------------------------------
:cloud_end
rem 还原 1024 的云影预烘。成功和失败两条路径都要调：留着 512 的版本会让编辑器和
rem 桌面构建的云影分辨率悄悄降一档，而且看不出来是这里改的。
if not defined CLOUD_SHRINK_ACTIVE exit /b 0
echo [cloud] restoring the 1024 cloud-shadow prebake ...
"%GODOT%" --headless --path "%ROOT%Project\project-keynes" ^
    --script res://tools/web_cloud_shadow_shrink.gd -- restore >>"%LOG_DIR%\web_cloud_shadow.log" 2>&1
if errorlevel 1 (
    echo === WARNING: cloud-shadow restore FAILED ===
    echo Run: "%GODOT%" --headless --path Project\project-keynes --script res://tools/web_cloud_shadow_shrink.gd -- restore
    echo Until then the editor/desktop builds use the 512 cloud-shadow textures.
    exit /b 1
)
set "CLOUD_SHRINK_ACTIVE="
exit /b 0

rem ---------------------------------------------------------------------------
:font_subset_restore
rem Put the original .fontdata back into .godot even when the export failed: the
rem import cache is shared with the editor and desktop exports.
if not defined FONT_SUBSET_ACTIVE exit /b 0
echo [font-subset] restoring the original .fontdata in .godot ...
%PY% "%ROOT%tools\subset_fonts.py" restore --cache "%ROOT%tmp\web_font_subset"
if errorlevel 1 (
    echo === WARNING: restore reported a problem ===
    echo Run: python tools\subset_fonts.py restore --cache tmp\web_font_subset
)
set "FONT_SUBSET_ACTIVE="
exit /b 0

rem ---------------------------------------------------------------------------
:find_python
if defined PY exit /b 0
where python >nul 2>nul && set "PY=python" && exit /b 0
where py >nul 2>nul && set "PY=py -3" && exit /b 0
echo === ERROR: Python 3 not found on PATH ^(needed for web font subsetting^) ===
echo Install Python 3 + `python -m pip install fonttools brotli`, or skip subsetting:
echo     set PK_WEB_SKIP_FONT_SUBSET=1
exit /b 1

rem ---------------------------------------------------------------------------
:tex_end
rem Restore the desktop texture import state. Runs on BOTH the success and the
rem failure path: leaving .godot in web quality silently degrades the editor.
if not defined TEX_DOWNGRADE_ACTIVE exit /b 0
call :find_python
if errorlevel 1 exit /b 1
echo [tex] restoring desktop texture import state ...
rem Retry: another Godot process (editor, headless test) may hold an .import/.res
rem memory-mapped, which makes the restore fail with WinError 1224 and would leave
rem the local import cache in web quality.
set "TEX_RESTORE_TRIES=0"
:tex_end_retry
set /a TEX_RESTORE_TRIES+=1
!PY! "%ROOT%tools\web_tex_downgrade.py" end --godot "%GODOT%"
if not errorlevel 1 goto :tex_end_ok
if %TEX_RESTORE_TRIES% GEQ 3 goto :tex_end_failed
echo [tex] restore attempt %TEX_RESTORE_TRIES% failed (file likely memory-mapped); retrying in 3s ...
ping -n 4 127.0.0.1 >nul
goto :tex_end_retry
:tex_end_ok
set "TEX_DOWNGRADE_ACTIVE="
exit /b 0
:tex_end_failed
echo === WARNING: texture state not fully restored after 3 attempts ===
echo The local import cache may still be in web quality. Close the Godot editor and run:
echo     python tools\web_tex_downgrade.py restore --godot "%%GODOT%%"
echo Until then the editor/desktop builds use lossy web textures.
exit /b 1

rem ---------------------------------------------------------------------------
:fmod_enable
rem Register FmodGodot for the web export: drop the addon .gdignore, reimport so
rem .godot\extension_list.cfg lists it, and verify. Must happen BEFORE the export
rem (runtime load_extension deadlocks the browser main thread) and BEFORE
rem :bank_begin (the .bank importer only exists while FmodGodot is registered).
rem FMOD_ENABLED is set before the call so the failure path still tries to restore.
set "FMOD_ENABLED=1"
echo [fmod] registering FmodGodot for the web export ...
rem 必须带 import：extension_list.cfg 是 Godot 扫描 addon 目录后生成的，只删
rem .gdignore 不重扫，列表里不会出现 FmodGodot，导出出来照样是"引擎启动时不加载"。
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\export_web_with_fmod.ps1" ^
    -EnableOnly -GodotExe "%GODOT%"
if errorlevel 1 (
    echo === ERROR: registering FmodGodot for web FAILED ===
    exit /b 1
)
exit /b 0

rem ---------------------------------------------------------------------------
:fmod_disable
rem Idempotent: safe to call from both the success path and :fail, and safe when
rem :fmod_enable never ran (FMOD_ENABLED undefined) or never got that far.
if not defined FMOD_ENABLED exit /b 0
echo [fmod] restoring the addon .gdignore flags ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\export_web_with_fmod.ps1" ^
    -RestoreOnly -GodotExe "%GODOT%"
if errorlevel 1 (
    echo === WARNING: restoring .gdignore FAILED ===
    echo Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\export_web_with_fmod.ps1 -RestoreOnly
    echo Until then the editor/Android builds also see FmodGodot as an autoload extension.
    exit /b 1
)
set "FMOD_ENABLED="
exit /b 0

rem ---------------------------------------------------------------------------
:bank_begin
rem Swap the Desktop (Vorbis q70) banks for the HTML5 (q37) ones. The pck stores
rem the .bank at its source path, so the source itself has to change; the import
rem cache and its .md5 sidecar are swapped too so Godot never reimports mid-build.
rem Skipping is a supported fallback: PK_WEB_SKIP_BANK_DOWNGRADE=1.
if defined PK_WEB_SKIP_BANK_DOWNGRADE (
    echo [bank] skipped ^(PK_WEB_SKIP_BANK_DOWNGRADE=1^): pck keeps the q70 Music.bank
    exit /b 0
)
call :find_python
if errorlevel 1 exit /b 1
echo [bank] switching to the HTML5-platform banks ^(q70 -^> q37^) ...
!PY! "%ROOT%tools\web_bank_downgrade.py" begin
if errorlevel 1 (
    echo === ERROR: web bank downgrade FAILED ^(state restored automatically, see above^) ===
    echo === Skip it with: set PK_WEB_SKIP_BANK_DOWNGRADE=1 ===
    exit /b 1
)
set "BANK_SWAPPED=1"
exit /b 0

rem ---------------------------------------------------------------------------
:bank_end
rem Idempotent: the tool exits 0 when there is no state to restore.
if not defined BANK_SWAPPED exit /b 0
call :find_python
if errorlevel 1 exit /b 1
echo [bank] restoring the desktop banks ...
!PY! "%ROOT%tools\web_bank_downgrade.py" end
if errorlevel 1 (
    echo === WARNING: bank restore reported a problem ===
    echo Run: python tools\web_bank_downgrade.py restore
    echo Until then this machine ships the q37 bank to desktop builds too.
    exit /b 1
)
set "BANK_SWAPPED="
exit /b 0

rem ---------------------------------------------------------------------------
:build_native
echo [native] scons platform=web target=%1 threads=%THREADS% ...
scons platform=web arch=wasm32 threads=%THREADS% lto=none disable_exceptions=no -j%JOBS% target=%1 dev_build=no ^
    >"%LOG_DIR%\web_native_%1.log" 2>&1
if errorlevel 1 (
    echo === ERROR: native %1 build FAILED ^(see "%LOG_DIR%\web_native_%1.log"^) ===
    exit /b 1
)
echo [native] %1 ok
exit /b 0

rem ---------------------------------------------------------------------------
:export_web
set "EXPORT_MODE=%1"
rem release 与 debug 分开：debug 走 --export-debug 并输出到独立目录，
rem 否则带调试符号的 side module 会混进发布包。
set "EXPORT_DIR=%ROOT%WebBuild"
set "EXPORT_FUNC=--export-release"
set "EXPORT_LOG=web_export_release.log"
if /i "%EXPORT_MODE%"=="debug" (
    set "EXPORT_DIR=%ROOT%WebBuildDebug"
    set "EXPORT_FUNC=--export-debug"
    set "EXPORT_LOG=web_export_debug.log"
)
if not exist "%EXPORT_DIR%" mkdir "%EXPORT_DIR%"
rem Drop the previous artifacts first: Godot only writes the files the current
rem preset references, so a stale side module from an earlier run (e.g. the
rem template_debug wasm after a release export) would otherwise linger in the
rem served folder.
for %%X in (html js pck wasm png br gz bank) do del /q "%EXPORT_DIR%\*.%%X" 2>nul
del /q "%EXPORT_DIR%\*.worklet.js" 2>nul
echo [export] Godot %EXPORT_FUNC% Web preset ^(%EXPORT_MODE%^) ...
"%GODOT%" --headless --path "%ROOT%Project\project-keynes" %EXPORT_FUNC% "Web" ^
    "%EXPORT_DIR%\ProjectKeynes.html" >"%LOG_DIR%\%EXPORT_LOG%" 2>&1
if errorlevel 1 (
    echo === ERROR: Godot Web export FAILED ^(see "%LOG_DIR%\%EXPORT_LOG%"^) ===
    exit /b 1
)
echo [export] ok

rem FmodGodot 的 web side module 被 preset 的 `addons/FmodGodot/*` 排除在 pck 之外，
rem 但 GDExtension 是拿 res:// 路径去站点根目录 fetch 它的。少了这一个文件，web 上
rem FMOD 根本起不来 —— 表现是全程静音，而且从 bank 侧完全看不出问题（2026-11-11
rem 实测：导出目录里只有 pck 和 dots_ext 的 wasm）。老包里这个是手工拷的，这里补成
rem 构建期自动步骤。
set "FMOD_WASM=%ROOT%Project\project-keynes\addons\FmodGodot\bin\web\libFmodGodot.web.template_release.threads.wasm32.wasm"
if not exist "!FMOD_WASM!" set "FMOD_WASM=%ROOT%Project\project-keynes\addons\FmodGodot\bin\web\libFmodGodot.web.template_debug.threads.wasm32.wasm"
if exist "!FMOD_WASM!" (
    copy /y "!FMOD_WASM!" "!EXPORT_DIR!\" >nul
    echo [fmod] side module copied next to the html
) else (
    echo === WARNING: libFmodGodot web side module not found under addons\FmodGodot\bin\web ===
    echo === The exported web build will have NO audio: the extension cannot be fetched.
)

rem Prove the pck really contains the subset .fontdata (not the full 10 MB ones).
rem This catches the silent failure mode where Godot re-imports mid-export and the
rem package quietly grows 40-50 MB back.
if defined FONT_SUBSET_ACTIVE (
    !PY! "%ROOT%tools\subset_fonts.py" verify --pck "!EXPORT_DIR!\ProjectKeynes.pck" ^
        --cache "%ROOT%tmp\web_font_subset"
    if errorlevel 1 (
        echo === ERROR: the exported pck does not carry the subset fonts ===
        exit /b 1
    )
)

rem Same guard for the banks: prove the pck carries the q37 HTML5 set (49.7 MB)
rem and not the q70 Desktop one (91.4 MB). A mid-export reimport puts the big
rem files back silently; the only symptom is a package 40 MB heavier.
if defined BANK_SWAPPED (
    !PY! "%ROOT%tools\web_bank_downgrade.py" verify --pck "!EXPORT_DIR!\ProjectKeynes.pck"
    if errorlevel 1 (
        echo === ERROR: the exported pck still carries the Desktop ^(q70^) banks ===
        exit /b 1
    )

    rem 发布 era bank：它们已经不在 pck 里，运行期由 GameAudio 按时代 fetch
    rem （scripts/audio/game_audio_service.gd 的 _ensure_era_bank）。必须放在
    rem precompress 之前 —— .br 边车由 tools\serve_web.py 那一遍统一生成，
    rem manifest.json 也会顺带收录它们。
    echo [bank] publishing the per-era banks next to the html ...
    !PY! "%ROOT%tools\web_bank_downgrade.py" publish --out "!EXPORT_DIR!"
    if errorlevel 1 (
        echo === ERROR: publishing the per-era banks FAILED ===
        exit /b 1
    )
)

rem --- 5. web shell watchdog (memory telemetry + 2 GiB OOM flood guard) --------
rem Godot Web runs in one wasm32 heap capped at 2 GiB by the official templates.
rem Long 10x sessions can fill it; after that every mouse move re-enters wasm and
rem the console fills with "Cannot enlarge memory" / "table index is out of bounds"
rem (one pair per input event) while the page looks half-alive. The injected
rem page-side script reports pk_heap to /_log every 10 s and replaces that flood
rem with a single readable overlay. It is plain JS copied next to the page, so it
rem does not depend on template internals; re-running is idempotent.
if not defined PY call :find_python
if defined PY (
    !PY! "%ROOT%tools\patch_web_shell.py" --web-root "!EXPORT_DIR!"
    if errorlevel 1 (
        echo === ERROR: web shell watchdog injection FAILED ===
        exit /b 1
    )
) else (
    echo === WARNING: Python not found; web shell watchdog not injected ===
)

rem --- 5.5 per-era music packs --------------------------------------------------
rem Emitted next to the boot pck; the game fetches `music_<era>.pck` (and
rem `music_trans.pck` for era fanfares) after entering the world and mounts them with
rem engine.rtenv.copyToFS + ProjectSettings.load_resource_pack. Skipped when the
rem gate above was turned off (music is inside the boot pck then).
rem Skip with: set PK_WEB_SKIP_MUSIC_SPLIT=1
if defined PY (
    if /i not "%PK_WEB_DEFER_MUSIC%"=="0" (
        if not defined PK_WEB_SKIP_MUSIC_SPLIT (
            echo [music] emitting per-era music packs ...
            !PY! "%ROOT%tools\web_music_pack.py" build --project "%ROOT%Project\project-keynes" --out "!EXPORT_DIR!"
            if errorlevel 1 (
                echo === ERROR: music pack split FAILED ===
                exit /b 1
            )
        ) else (
            echo [music] split skipped ^(PK_WEB_SKIP_MUSIC_SPLIT=1^): no music will play on web
        )
    )
)

rem --- 6. wire size: pre-compressed sidecars + payload manifest -----------------
rem The release payload is ~146 MB raw. tools/serve_web.py negotiates br/gzip and
rem revalidates with ETags, but a plain static host (nginx/S3/itch.io) only gets
rem compression for free when a `<file>.br` / `<file>.gz` sidecar sits next to it.
rem Generating them here means both paths are fast, and the sidecars are deleted
rem at the top of :export_web so a rebuild can never leave a stale one behind.
rem Skip with: set PK_WEB_SKIP_PRECOMPRESS=1
if defined PY (
    if not defined PK_WEB_SKIP_PRECOMPRESS (
        echo [payload] generating .br/.gz sidecars ...
        !PY! "%ROOT%tools\serve_web.py" --precompress --root "!EXPORT_DIR!" ^
            --precompress-quality 9 --precompress-gzip-quality 9
        if errorlevel 1 (
            echo === WARNING: sidecar precompression failed; the export itself is fine ===
        )
    ) else (
        echo [payload] sidecar precompression skipped ^(PK_WEB_SKIP_PRECOMPRESS=1^)
    )
    echo [payload] writing manifest.json ...
    !PY! "%ROOT%tools\web_manifest.py" write --root "!EXPORT_DIR!"
    if errorlevel 1 (
        echo === ERROR: manifest.json generation FAILED ===
        exit /b 1
    )
    set "BUILD_ID="
    for /f "usebackq delims=" %%i in (`!PY! "%ROOT%tools\web_manifest.py" id --root "!EXPORT_DIR!"`) do set "BUILD_ID=%%i"
    if defined BUILD_ID (
        echo.
        echo [deploy] content build id: !BUILD_ID!
        echo [deploy] for a versioned deploy, copy !EXPORT_DIR! to /builds/!BUILD_ID!/ on the
        echo [deploy] host and serve it with: python tools\serve_web.py --root ^<dir^> --immutable
        echo [deploy] ^(that sends "public, max-age=31536000, immutable"; without it the server
        echo [deploy] sends "no-cache" + ETag, so a rebuild is picked up on the next refresh^)
    )
) else (
    echo === WARNING: Python not found; sidecars + manifest.json not generated ===
)
exit /b 0

rem ---------------------------------------------------------------------------
:find_godot
rem %1 = candidate path. Accepts it only when it names an existing regular file
rem (a bare `if exist` also matches a directory with that exact name, which is
rem how a Godot zip extracted into "Godot_vX.y.z.exe\" traps this script).
if defined GODOT exit /b 0
if not exist "%~1" exit /b 0
if exist "%~1\" exit /b 0
set "GODOT=%~1"
exit /b 0
