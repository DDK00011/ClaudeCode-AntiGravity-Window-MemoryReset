@echo off
:: Memory Reset Tray 를 Windows 시작프로그램에 등록 (사용자 권한, UAC 불필요)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tray-AutoStart.ps1"
pause
