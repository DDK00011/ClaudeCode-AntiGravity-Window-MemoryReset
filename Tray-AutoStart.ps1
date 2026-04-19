#Requires -Version 5.1
<#
.SYNOPSIS
    MemoryReset Tray 의 Windows 시작프로그램 등록/해제 토글.

.DESCRIPTION
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ 에 .lnk 바로가기 생성/삭제.
    관리자 권한 불필요 (사용자 시작프로그램에만 등록).

.PARAMETER Remove
    등록 해제 (기본은 등록).

.EXAMPLE
    .\Tray-AutoStart.ps1            # 등록
    .\Tray-AutoStart.ps1 -Remove    # 해제
#>

[CmdletBinding()]
param(
    [switch]$Remove
)

$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'MemoryReset-Tray.lnk'
$trayBat = Join-Path $PSScriptRoot 'Tray.bat'

if ($Remove) {
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "[OK] 시작프로그램에서 해제됨: $shortcutPath" -ForegroundColor Green
    } else {
        Write-Host "[i] 시작프로그램에 등록되어 있지 않음." -ForegroundColor DarkGray
    }
    exit 0
}

# 등록
if (-not (Test-Path $trayBat)) {
    Write-Host "[X] Tray.bat 을 같은 폴더에서 찾을 수 없음: $trayBat" -ForegroundColor Red
    exit 1
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $shortcut = $WshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath        = $trayBat
    $shortcut.WorkingDirectory  = $PSScriptRoot
    $shortcut.WindowStyle       = 7    # 7 = Minimized (콘솔 잠깐도 안 보이도록)
    $shortcut.Description       = "Memory Reset 시스템 트레이 데몬 — 메모리 임계치 알림"
    $shortcut.Save()
    Write-Host "[OK] 시작프로그램 등록됨: $shortcutPath" -ForegroundColor Green
    Write-Host "    → 다음 Windows 부팅 시 자동으로 트레이 데몬 시작" -ForegroundColor DarkGray
    Write-Host "    → 해제하려면: .\Tray-AutoStart.ps1 -Remove" -ForegroundColor DarkGray
} catch {
    Write-Host "[X] 등록 실패: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
