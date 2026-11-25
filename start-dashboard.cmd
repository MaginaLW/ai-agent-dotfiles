@echo off
setlocal
where pwsh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell 7 was not found on PATH. Please install PowerShell 7 first.
    if /i not "%DASHBOARD_NO_PAUSE%"=="1" pause
    exit /b 1
)
pwsh -NoProfile -File "%~dp0scripts\dashboard.ps1" %*
set "DASHBOARD_EXIT=%ERRORLEVEL%"
if not "%DASHBOARD_EXIT%"=="0" (
    echo [ERROR] Failed to start ai-agent-dotfiles dashboard - exit code %DASHBOARD_EXIT%.
    if /i not "%DASHBOARD_NO_PAUSE%"=="1" pause
    exit /b %DASHBOARD_EXIT%
)
exit /b 0
