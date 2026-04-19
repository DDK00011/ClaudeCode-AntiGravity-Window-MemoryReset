@echo off
:: 메모리 진단만 (회수 안 함, UAC 불필요)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -Diagnose %*
exit /b %ERRORLEVEL%
