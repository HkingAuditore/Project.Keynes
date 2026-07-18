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
set "VENV_ROOT=%REPO_ROOT%\.venv-economy-validator"
set "PYTHON_BIN=%VENV_ROOT%\Scripts\python.exe"
set "REQUIREMENTS=%TOOL_ROOT%\requirements.txt"

where python >nul 2>nul
if errorlevel 1 goto missing_python
where node >nul 2>nul
if errorlevel 1 goto missing_node

python -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>nul
if errorlevel 1 goto unsupported_python

if not exist "%PYTHON_BIN%" (
    echo Creating validator environment...
    python -m venv "%VENV_ROOT%"
    if errorlevel 1 goto venv_failed
)

"%PYTHON_BIN%" -c "import numpy, scipy" >nul 2>nul
if errorlevel 1 (
    echo Installing validator dependencies...
    "%PYTHON_BIN%" -m pip install -r "%REQUIREMENTS%"
    if errorlevel 1 goto dependency_failed
    "%PYTHON_BIN%" -c "import numpy, scipy" >nul 2>nul
    if errorlevel 1 goto dependency_failed
)

echo Running Project.Keynes offline economy validator...
if exist "%REPORT_PATH%" del /q "%REPORT_PATH%"
if exist "%REPORT_JSON%" del /q "%REPORT_JSON%"
"%PYTHON_BIN%" "%TOOL_ROOT%\balance_validator.py" --scenario "%SCENARIO%" --repo-root "%REPO_ROOT%" --output-dir "%OUTPUT_ROOT%" --node node
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

:unsupported_python
echo Python 3.10 or newer is required.
pause
exit /b 1

:missing_node
echo Node.js was not found. Install Node.js 18 or newer and retry.
pause
exit /b 1

:venv_failed
echo Failed to create the validator environment: %VENV_ROOT%
pause
exit /b 1

:dependency_failed
echo Failed to install validator dependencies from: %REQUIREMENTS%
echo Check the network connection and retry.
pause
exit /b 1
