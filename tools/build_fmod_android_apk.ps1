# Build an installable Android APK that carries FMOD (extension + banks + Java stubs).
#
# Two build modes are supported, picked by export_presets.cfg:
#   use_gradle_build=true  -> org.fmod is compiled from android/build/src/main/java,
#                             native libs are compressed by AGP. No post-processing.
#   use_gradle_build=false -> plain APK export, org.fmod arrives via a secondary dex
#                             (inject_fmod_java_stub.py) and libs stay STORED; run
#                             tools/android_repack_libs.py afterwards to compress them.
#
# Why a loop: export_presets.cfg is written by other processes too (another agent,
# the editor). Setting the ABI and exporting once is a race; this script sets the
# ABI, exports, checks the APK's lib/<abi>/ directory, and retries if the preset
# was flipped underneath us.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_fmod_android_apk.ps1 -Abi arm64
#   ... -Abi x86_64 -Out Build\ProjectKeynes-fmod-emulator.apk -Attempts 2
#
# ASCII only on purpose (Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM).

param(
    [ValidateSet('arm64', 'x86_64')]
    [string]$Abi = 'arm64',
    [string]$Out = '',
    [int]$Attempts = 2,
    [string]$GodotExe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe',
    [switch]$SkipStubs
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $root
try {
    $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (-not $Out) { $Out = "Build\ProjectKeynes-fmod-$Abi.apk" }
    $projectPath = (Resolve-Path 'Project\project-keynes').Path
    $apkPath = Join-Path (Resolve-Path 'Build').Path ([IO.Path]::GetFileName($Out))
    $libDir = if ($Abi -eq 'arm64') { 'arm64-v8a' } else { 'x86_64' }

    # Gradle build compiles org.fmod from the template's java source set instead of
    # injecting a secondary dex afterwards. android/ is gitignored and the template
    # can be reinstalled at any time, so sync the sources on every build.
    $gradleBuild = (Select-String -Path 'Project\project-keynes\export_presets.cfg' `
        -Pattern 'gradle_build/use_gradle_build=true' -Quiet)
    if ($gradleBuild) {
        $javaDir = Join-Path $projectPath 'android\build\src\main\java\org\fmod'
        $null = New-Item -ItemType Directory -Force -Path $javaDir
        Copy-Item 'tools\fmod_java_stub\org\fmod\*.java' $javaDir -Force
        Write-Host '[build] gradle build: org.fmod java sources synced into template'
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Host "[build] attempt $attempt/$Attempts : abi=$Abi"
        python tools/set_android_abi.py $Abi | ForEach-Object { Write-Host "  $_" }

        & $GodotExe --headless --path $projectPath --export-debug 'Android' $apkPath 2>&1 |
            Select-String -Pattern 'export\]|failed|Invalid|configuration errors' |
            Select-Object -Last 3 | ForEach-Object { Write-Host "  $($_.Line)" }

        if (-not (Test-Path $apkPath)) { Write-Host '[build] export produced nothing'; continue }

        $probe = python -c "import sys,zipfile,collections;z=zipfile.ZipFile(sys.argv[1]);print(','.join(sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})))" $apkPath
        Write-Host "  apk abis: $probe"
        if ($probe -match [regex]::Escape($libDir)) {
            Write-Host "[build] APK carries $libDir"
            break
        }
        Write-Host "[build] preset was flipped during export (expected $libDir); retrying"
    }

    if (-not (Test-Path $apkPath)) { throw 'no apk produced' }

    # With use_gradle_build=true the APK already carries org.fmod in classes*.dex.
    # Injecting again would add a second copy of the same classes, so probe first.
    $stubState = python -c "import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);print('yes' if any(b'org/fmod' in z.read(n).lower() for n in z.namelist() if n.endswith('.dex')) else 'no')" $apkPath
    if ($SkipStubs -or "$stubState".Trim() -eq 'yes') {
        Write-Host "[build] dex already carries org.fmod; skipping secondary-dex injection"
    }
    else {
        $jni = [IO.Path]::ChangeExtension($apkPath, '.jni.apk')
        python tools/inject_fmod_java_stub.py $apkPath -o $jni 2>&1 |
            Select-String -Pattern 'injected|signed apk|failed' | ForEach-Object { Write-Host "  $($_.Line)" }
        if (Test-Path $jni) { $apkPath = $jni }
    }

    python tools/verify_audio_packaging.py --apk $apkPath 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host "[build] ready: $apkPath"
    Write-Host '[build] install with:  adb install -r "' + $apkPath + '"'
}
finally {
    Pop-Location
}
