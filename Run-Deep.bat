@echo off
:: 깊은 회수: Tier A (Memory Compression flush + System WS + 네트워크 캐시)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -Deep %*
exit /b %ERRORLEVEL%
