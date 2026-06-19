$ErrorActionPreference = 'Continue'
$scons = "C:\Users\hkinghuang\AppData\Local\Programs\Python\Python313\Scripts\scons.exe"
$gdext = "d:\Godot\ProjectKeynes\Project.Keynes\gdext"
$bin   = "d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\addons\dots_ext\bin\windows"
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
Set-Location $gdext

& $scons platform=windows target=template_debug dev_build=no -j8 2>&1 | Select-Object -Last 5
$d1 = $LASTEXITCODE
& $scons platform=windows target=template_release dev_build=no -j8 2>&1 | Select-Object -Last 5
$d2 = $LASTEXITCODE

Write-Output "BUILD_DONE debug_exit=$d1 release_exit=$d2"
Get-ChildItem "$bin\*.template_debug.x86_64.dll","$bin\*.template_release.x86_64.dll" | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
