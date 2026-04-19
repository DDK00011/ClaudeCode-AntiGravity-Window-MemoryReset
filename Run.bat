@echo off
:: ════════════════════════════════════════════════════════════════════
::  Memory Reset — 더블클릭 런처
::  PowerShell 스크립트가 내부에서 자동으로 UAC 승격합니다.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" %*
exit /b %ERRORLEVEL%
