@echo off
:: 종료/회수 없이 대상 프로세스만 미리 확인하는 모드
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -DryRun
exit /b %ERRORLEVEL%
