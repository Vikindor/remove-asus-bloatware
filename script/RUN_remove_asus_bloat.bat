@echo off
:: =========================================================
:: RUN_remove_asus_bloat.bat v1.0.2
:: Run remove_asus_bloat.ps1 with elevation and correct host
:: =========================================================

setlocal
set "SCRIPT=%~dp0remove_asus_bloat.ps1"
set "SCRIPT_ARGS=%*"

:: 1) Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrative privileges...
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath 'cmd.exe' -Verb RunAs -ArgumentList @('/c', '\"%~f0\" %SCRIPT_ARGS%')"
    exit /b
)

:: 2) Detect PowerShell Core (pwsh) or Windows PowerShell
where pwsh >nul 2>&1
if %errorLevel% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)

endlocal
