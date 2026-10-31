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

rem --- 4. Godot Web export ----------------------------------------------------
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
call :tex_end
call :font_subset_restore
echo.
echo === Web export FAILED ===
exit /b 1

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
for %%X in (html js pck wasm png) do del /q "%EXPORT_DIR%\*.%%X" 2>nul
del /q "%EXPORT_DIR%\*.worklet.js" 2>nul
echo [export] Godot %EXPORT_FUNC% Web preset ^(%EXPORT_MODE%^) ...
"%GODOT%" --headless --path "%ROOT%Project\project-keynes" %EXPORT_FUNC% "Web" ^
    "%EXPORT_DIR%\ProjectKeynes.html" >"%LOG_DIR%\%EXPORT_LOG%" 2>&1
if errorlevel 1 (
    echo === ERROR: Godot Web export FAILED ^(see "%LOG_DIR%\%EXPORT_LOG%"^) ===
    exit /b 1
)
echo [export] ok

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
