@echo off
rem ===========================================================================
rem Project.Keynes - one-click deploy of WebBuild\ to the Windows/IIS server.
rem
rem   scripts\Deploy-Cloud.cmd              zip + upload + swap in place
rem   scripts\Deploy-Cloud.cmd --health     is the receiver reachable?
rem   scripts\Deploy-Cloud.cmd --dry-run    build the zip, print the plan
rem   scripts\Deploy-Cloud.cmd --init       write the local config
rem
rem Server, port, token and IIS app name come from ~\.pk_cloud_deploy.json
rem (created by --init); nothing site-specific is stored in this repository.
rem The server side is tools\remote\pk_web_receiver.ps1, installed once with
rem -Install; its previous-version backup stays next to the site directory.
rem ===========================================================================
setlocal
cd /d "%~dp0.."

rem Readable Chinese output: the tool prints UTF-8 and switches this console to
rem code page 65001 for the duration of the window.
chcp 65001 >nul
set "PYTHONIOENCODING=utf-8"

set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
    where py >nul 2>nul && set "PY=py -3"
)
if not defined PY (
    echo === ERROR: Python 3 not found on PATH ===
    exit /b 1
)

if "%~1"=="" goto :default
%PY% tools\deploy_cloud.py %*
exit /b %errorlevel%

:default
%PY% tools\deploy_cloud.py
exit /b %errorlevel%
