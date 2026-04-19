@echo off
:: Memory Reset Tray 데몬 — 숨김 창에서 시작
:: (트레이 아이콘만 보이고 콘솔은 안 보임)
:: -Sta : WinForms / NotifyIcon 은 STA 스레드 필수 (PS 5.1 기본은 MTA)
chcp 65001 >nul
start "" /b powershell.exe -Sta -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset-Tray.ps1"
exit /b 0
