$ErrorActionPreference = 'Continue'
$scons = "C:\Users\hkinghuang\AppData\Local\Programs\Python\Python313\Scripts\scons.exe"
$gdext = "d:\Godot\ProjectKeynes\Project.Keynes\gdext"
$bin   = "d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\addons\dots_ext\bin\windows"
$src   = "d:\Godot\ProjectKeynes\Project.Keynes\gdext\src"
$deadline = (Get-Date).AddMinutes(30)

Write-Output "WAITING_FOR_GODOT_CLOSE (poll every 3s, timeout 30min)"
while ((Get-Date) -lt $deadline) {
    $g = Get-Process | Where-Object { $_.ProcessName -match 'Godot' }
    if (-not $g) { break }
    Start-Sleep -Seconds 3
}
$g = Get-Process | Where-Object { $_.ProcessName -match 'Godot' }
if ($g) { Write-Output "TIMEOUT_GODOT_STILL_RUNNING"; exit 1 }

# small grace period so the OS releases the file handle after process exit
Start-Sleep -Seconds 2
Write-Output "GODOT_CLOSED_START_BUILD"

# Force fresh recompile+relink of world_ext for the two referenced targets.
# (Prior incident: scons skipped the DLL link as "up to date"; deleting target
#  DLL + obj guarantees world_ext.cpp lake-suppression fix is compiled & linked.)
$targets = @(
    "$bin\dots_ext.windows.template_debug.x86_64.dll",
    "$bin\dots_ext.windows.template_release.x86_64.dll",
    "$src\world_ext.windows.template_debug.x86_64.obj",
    "$src\world_ext.windows.template_release.x86_64.obj"
)
foreach ($t in $targets) {
    if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue; Write-Output "DELETED $t" }
    else { Write-Output "ABSENT  $t" }
}

Set-Location $gdext
Write-Output "=== SCONS template_debug ==="
& $scons platform=windows target=template_debug dev_build=no -j8 2>&1 | Select-Object -Last 12
$d1 = $LASTEXITCODE
Write-Output "=== SCONS template_release ==="
& $scons platform=windows target=template_release dev_build=no -j8 2>&1 | Select-Object -Last 12
$d2 = $LASTEXITCODE

Write-Output "BUILD_DONE debug_exit=$d1 release_exit=$d2"
Get-ChildItem "$bin\dots_ext.windows.template_debug.x86_64.dll","$bin\dots_ext.windows.template_release.x86_64.dll" | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
