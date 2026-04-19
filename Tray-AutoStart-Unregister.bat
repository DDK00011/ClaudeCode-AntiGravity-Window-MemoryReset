@echo off
:: Memory Reset Tray 시작프로그램 등록 해제
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tray-AutoStart.ps1" -Remove
pause
