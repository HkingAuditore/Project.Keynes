$ErrorActionPreference = 'Continue'
$scons = "C:\Users\hkinghuang\AppData\Local\Programs\Python\Python313\Scripts\scons.exe"
$gdext = "d:\Godot\ProjectKeynes\Project.Keynes\gdext"
$bin   = "d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\addons\dots_ext\bin\windows"
$src   = "d:\Godot\ProjectKeynes\Project.Keynes\gdext\src"

# Release DLL lock by stopping Godot, then force a clean relink.
Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Output "GODOT_KILLED_START_BUILD"

$targets = @(
    "$bin\dots_ext.windows.template_debug.x86_64.dll",
    "$bin\dots_ext.windows.template_release.x86_64.dll",
    "$src\world_ext.windows.template_debug.x86_64.obj",
    "$src\world_ext.windows.template_release.x86_64.obj"
)
foreach ($t in $targets) {
    if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue; Write-Output "DELETED $t" }
}

Set-Location $gdext
Write-Output "=== SCONS template_debug ==="
& $scons platform=windows target=template_debug dev_build=no -j8 2>&1 | Tee-Object -FilePath "$gdext\_p3_debug.log" | Select-String -Pattern "error C|error LNK|fatal|Compiling|Linking|done building" | Select-Object -Last 20
$d1 = $LASTEXITCODE
Write-Output "=== SCONS template_release ==="
& $scons platform=windows target=template_release dev_build=no -j8 2>&1 | Tee-Object -FilePath "$gdext\_p3_release.log" | Select-String -Pattern "error C|error LNK|fatal|Compiling|Linking|done building" | Select-Object -Last 20
$d2 = $LASTEXITCODE

Write-Output "BUILD_DONE debug_exit=$d1 release_exit=$d2"
Get-ChildItem "$bin\dots_ext.windows.template_debug.x86_64.dll","$bin\dots_ext.windows.template_release.x86_64.dll" | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
