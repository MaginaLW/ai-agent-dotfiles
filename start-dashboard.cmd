@echo off
chcp 65001 >nul
setlocal
where pwsh >nul 2>&1
if errorlevel 1 (
    echo 未检测到 PowerShell 7 ^(pwsh^)，请先安装 PowerShell 7。
    pause
    exit /b 1
)
pwsh -NoProfile -File "%~dp0scripts\dashboard.ps1"
set "DASHBOARD_EXIT=%ERRORLEVEL%"
if not "%DASHBOARD_EXIT%"=="0" (
    echo 启动可视化监控台失败（退出码 %DASHBOARD_EXIT%），请查看上方错误信息。
    pause
    exit /b %DASHBOARD_EXIT%
)
exit /b 0
