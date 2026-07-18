@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Project.Keynes Economy Validator

for %%I in ("%~dp0.") do set "REPO_ROOT=%%~fI"
set "TOOL_ROOT=%REPO_ROOT%\tools\supply-chain-explorer"
set "SCENARIO=%TOOL_ROOT%\scenario.stone_age.example.json"
if not "%~1"=="" set "SCENARIO=%~f1"
set "OUTPUT_ROOT=%REPO_ROOT%\tmp\economy-balance"
set "REPORT_PATH=%OUTPUT_ROOT%\balance_report.html"
set "REPORT_JSON=%OUTPUT_ROOT%\balance_report.json"

where python >nul 2>nul
if errorlevel 1 goto missing_python
where node >nul 2>nul
if errorlevel 1 goto missing_node

echo Running Project.Keynes offline economy validator...
if exist "%REPORT_PATH%" del /q "%REPORT_PATH%"
if exist "%REPORT_JSON%" del /q "%REPORT_JSON%"
python "%TOOL_ROOT%\balance_validator.py" --scenario "%SCENARIO%" --repo-root "%REPO_ROOT%" --output-dir "%OUTPUT_ROOT%" --node node
set "VALIDATOR_EXIT=%ERRORLEVEL%"

if exist "%REPORT_PATH%" (
    echo Opening report: %REPORT_PATH%
    start "" "%REPORT_PATH%"
    exit /b %VALIDATOR_EXIT%
)

echo.
echo Validation failed before a report was generated.
pause
exit /b 1

:missing_python
echo Python was not found. Install Python 3.10 or newer and retry.
pause
exit /b 1

:missing_node
echo Node.js was not found. Install Node.js 18 or newer and retry.
pause
exit /b 1
