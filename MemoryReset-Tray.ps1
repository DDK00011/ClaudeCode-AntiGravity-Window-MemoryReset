#Requires -Version 5.1
<#
.SYNOPSIS
    Memory Reset 의 시스템 트레이 데몬 — 메모리 모니터링 + 임계치 알림 + 빠른 회수 실행.

.DESCRIPTION
    Windows 알림 영역에 아이콘으로 상주하며 다음을 수행합니다:

      · 30초마다 메모리 사용률 체크 (툴팁으로 실시간 표시)
      · 임계치(기본 90%) 도달 시 BalloonTip 알림 — 자동 회수는 안 함, 사용자 결정 보장
      · 우클릭 메뉴: 기본 회수 / 깊은 회수 / 진단 / 이력 보기 / 임계치 설정 / 종료
      · 단일 인스턴스 보장 (mutex)
      · 회수 작업은 MemoryReset.ps1 에 위임 (UAC 자동 승격)

    설정은 같은 폴더의 tray-settings.json 에 저장.

.NOTES
    Tray.bat 으로 숨김 창에서 실행 권장.
    데몬 자체는 관리자 권한 불필요 — 회수 트리거 시 MemoryReset.ps1 가 UAC 승격.
#>

[CmdletBinding()]
param()

# ════════════════════════════════════════════════════════════════════
# 1. 어셈블리 로드 (mutex 검사 전에 미리 — MessageBox 사용 가능하도록)
# ════════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ════════════════════════════════════════════════════════════════════
# 2. 단일 인스턴스 mutex
#    Local\ scope (사용자 세션) — Global\ 은 권한 이슈 가능
# ════════════════════════════════════════════════════════════════════
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, 'Local\MemoryReset-Tray-Singleton', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "Memory Reset Tray 가 이미 실행 중입니다.`n시스템 트레이 (시계 옆) 의 메모리 아이콘을 확인하세요.",
        "Memory Reset",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}

# ════════════════════════════════════════════════════════════════════
# 3. 설정 (tray-settings.json)
# ════════════════════════════════════════════════════════════════════
$script:scriptDir    = $PSScriptRoot
$script:mainScript   = Join-Path $scriptDir 'MemoryReset.ps1'
$script:settingsPath = Join-Path $scriptDir 'tray-settings.json'
$script:historyPath  = Join-Path $scriptDir 'recovery-history.csv'
$script:logPath      = Join-Path $scriptDir 'tray-debug.log'

# 디버그 로그 헬퍼 (Tray 데몬은 콘솔이 숨겨져 있어 silent failure 추적 어려움 — 파일로 남김)
function Write-TrayLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $script:logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # 로그 실패는 무시 (런타임에 영향 없음)
    }
}
Write-TrayLog "트레이 데몬 시작 (PID=$PID)"

$defaultSettings = @{
    AlertThresholdPct = 90    # 알림 발동 메모리 사용률
    CheckIntervalSec  = 30    # 폴링 주기 (초)
    AlertCooldownMin  = 10    # 알림 후 재알림 금지 시간 (분)
}

function Load-Settings {
    if (Test-Path $script:settingsPath) {
        try {
            $loaded = Get-Content $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $merged = @{}
            foreach ($k in $defaultSettings.Keys) {
                $merged[$k] = if ($null -ne $loaded.$k) { $loaded.$k } else { $defaultSettings[$k] }
            }
            return $merged
        } catch {
            return $defaultSettings.Clone()
        }
    } else {
        return $defaultSettings.Clone()
    }
}

function Save-Settings {
    param([hashtable]$Settings)
    try {
        $Settings | ConvertTo-Json | Set-Content -Path $script:settingsPath -Encoding UTF8
    } catch {
        # 저장 실패는 silent — 다음 부팅에서 default 사용
    }
}

$script:settings = Load-Settings

# ════════════════════════════════════════════════════════════════════
# 4. 메모리 측정 헬퍼
# ════════════════════════════════════════════════════════════════════
function Get-MemoryUsage {
    $os       = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $null }
    $totalMB  = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMB   = [math]::Round($os.FreePhysicalMemory   / 1024)
    $usedMB   = $totalMB - $freeMB
    $usedPct  = [math]::Round(($usedMB / $totalMB) * 100, 1)
    [PSCustomObject]@{
        TotalMB  = $totalMB
        UsedMB   = $usedMB
        FreeMB   = $freeMB
        UsedPct  = $usedPct
    }
}

# ════════════════════════════════════════════════════════════════════
# 5. NotifyIcon + 컨텍스트 메뉴
# ════════════════════════════════════════════════════════════════════
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Text = "Memory Reset (시작 중...)"
$icon.Visible = $true

# 회수 작업 트리거 (MemoryReset.ps1 호출, UAC 자동 승격)
function Invoke-RecoveryAction {
    param([string]$ExtraArgs = '')
    if (-not (Test-Path $script:mainScript)) {
        $icon.ShowBalloonTip(5000, "오류",
            "MemoryReset.ps1 을 같은 폴더에서 찾을 수 없습니다.",
            [System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:mainScript`"")
    if ($ExtraArgs) { $argList += $ExtraArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) }
    try {
        # MemoryReset.ps1 가 내부에서 UAC 승격 처리
        Start-Process powershell.exe -ArgumentList $argList -ErrorAction Stop
    } catch {
        $icon.ShowBalloonTip(5000, "실행 실패", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# 컨텍스트 메뉴 구성
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System

# 헤더 (현재 메모리 — 클릭 불가)
$mnuHeader = $menu.Items.Add("Memory Reset")
$mnuHeader.Enabled = $false
$mnuStatus = $menu.Items.Add("(메모리 측정 중...)")
$mnuStatus.Enabled = $false
$menu.Items.Add('-') | Out-Null

# 회수 액션
$mnuBasic = $menu.Items.Add("기본 회수 (Basic)")
$mnuBasic.Add_Click({ Invoke-RecoveryAction })

$mnuDeep = $menu.Items.Add("깊은 회수 (Deep)")
$mnuDeep.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-Deep' })

$mnuDeepShell = $menu.Items.Add("최대 회수 (Deep + Shell 재시작)")
$mnuDeepShell.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-Deep -IncludeShell' })

$menu.Items.Add('-') | Out-Null

# 진단/이력
$mnuDiag = $menu.Items.Add("진단 (Diagnose)")
$mnuDiag.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-Diagnose' })

$mnuDryRun = $menu.Items.Add("드라이런 (대상만 확인)")
$mnuDryRun.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-DryRun' })

$mnuHistory = $menu.Items.Add("회수 이력 보기 (CSV)")
$mnuHistory.Add_Click({
    if (Test-Path $script:historyPath) {
        try {
            Start-Process $script:historyPath
        } catch {
            # CSV 연결 프로그램이 없으면 메모장으로 열기
            Start-Process notepad.exe -ArgumentList "`"$script:historyPath`""
        }
    } else {
        $icon.ShowBalloonTip(3000, "이력 없음",
            "아직 회수 기록이 없습니다. 회수를 1회 이상 실행 후 다시 확인하세요.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$menu.Items.Add('-') | Out-Null

# 설정
$mnuSettings = $menu.Items.Add("설정 (임계치 변경)")
$mnuSettings.Add_Click({
    $current = $script:settings.AlertThresholdPct
    $input = [Microsoft.VisualBasic.Interaction]::InputBox(
        "메모리 사용률 알림 임계치 (%, 50~99 권장)`n현재: $current %",
        "Memory Reset — 임계치 설정",
        $current.ToString()
    )
    if ($input -match '^\d+$') {
        $val = [int]$input
        if ($val -ge 50 -and $val -le 99) {
            $script:settings.AlertThresholdPct = $val
            Save-Settings -Settings $script:settings
            $icon.ShowBalloonTip(3000, "설정 저장됨",
                "알림 임계치: $val %",
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

$menu.Items.Add('-') | Out-Null

# 종료
$mnuExit = $menu.Items.Add("종료")
$mnuExit.Add_Click({
    $icon.Visible = $false
    $icon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$icon.ContextMenuStrip = $menu

# 좌클릭 시 빠른 회수 메뉴 표시 (DoubleClick 으로 변경 가능)
$icon.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        # NotifyIcon 의 ShowContextMenu 는 private 메서드 — reflection 우회 (PS 5.1+ 검증됨)
        try {
            $methodInfo = [System.Windows.Forms.NotifyIcon].GetMethod(
                'ShowContextMenu',
                [System.Reflection.BindingFlags]'Instance, NonPublic'
            )
            if ($methodInfo) {
                $methodInfo.Invoke($icon, $null)
            } else {
                # reflection 실패 시 fallback: 메뉴 직접 표시 (커서 위치)
                $icon.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position)
            }
        } catch {
            Write-TrayLog "좌클릭 메뉴 표시 실패: $($_.Exception.Message)" 'WARN'
            try { $icon.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position) } catch {}
        }
    }
})

# ════════════════════════════════════════════════════════════════════
# 6. 폴링 타이머 — 메모리 체크 + 임계치 알림
# ════════════════════════════════════════════════════════════════════
$script:lastAlert = $null

# Tick 로직을 명명 함수로 분리 — 즉시 호출 + 타이머 모두 동일 코드 사용 (reflection 의존성 제거)
function Invoke-MemoryTick {
    try {
        $m = Get-MemoryUsage
        if ($null -eq $m) {
            Write-TrayLog "Get-MemoryUsage returned null (CIM 접근 실패?)" 'WARN'
            return
        }

        # 툴팁 업데이트 (NotifyIcon.Text 는 최대 63자 — Windows API 제한)
        $tooltip = "Memory: {0}% used ({1}/{2} GB)" -f $m.UsedPct, [math]::Round($m.UsedMB/1024,1), [math]::Round($m.TotalMB/1024,1)
        if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
        $icon.Text = $tooltip

        # 메뉴 헤더 업데이트
        $mnuStatus.Text = (" 사용 {0}% / 가용 {1:N0} MB" -f $m.UsedPct, $m.FreeMB)

        # 임계치 알림 (쿨다운 적용)
        if ($m.UsedPct -ge $script:settings.AlertThresholdPct) {
            $now = Get-Date
            $shouldAlert = ($null -eq $script:lastAlert) -or
                           (($now - $script:lastAlert).TotalMinutes -ge $script:settings.AlertCooldownMin)
            if ($shouldAlert) {
                $msg = "메모리 사용률 {0}% 도달.`n트레이 아이콘 우클릭 → '깊은 회수 (Deep)' 권장." -f $m.UsedPct
                $icon.ShowBalloonTip(8000, "메모리 임계치 알림", $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
                $script:lastAlert = $now
                Write-TrayLog ("임계치 알림 발동: {0}% (임계치 {1}%)" -f $m.UsedPct, $script:settings.AlertThresholdPct)
            }
        }
    } catch {
        Write-TrayLog "Tick 처리 실패: $($_.Exception.Message)" 'ERROR'
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:settings.CheckIntervalSec * 1000
$timer.Add_Tick({ Invoke-MemoryTick })
$timer.Start()

# 즉시 1회 측정 (사용자가 30초 기다리지 않도록)
Invoke-MemoryTick

# ════════════════════════════════════════════════════════════════════
# 7. 시작 알림 + 메시지 루프
# ════════════════════════════════════════════════════════════════════
$icon.ShowBalloonTip(3000,
    "Memory Reset Tray 시작됨",
    ("메모리 모니터링 중. 임계치: {0}% / 폴링: {1}초" -f $script:settings.AlertThresholdPct, $script:settings.CheckIntervalSec),
    [System.Windows.Forms.ToolTipIcon]::Info)

try {
    Write-TrayLog "메시지 루프 진입"
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-TrayLog "메시지 루프 예외: $($_.Exception.Message)" 'ERROR'
} finally {
    Write-TrayLog "트레이 데몬 종료 (정리 시작)"
    try { $timer.Stop()    } catch {}
    try { $timer.Dispose() } catch {}
    if ($icon -and $icon.Visible) { $icon.Visible = $false }
    try { $icon.Dispose()  } catch {}
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        try { $mutex.Dispose()      } catch {}
    }
    Write-TrayLog "트레이 데몬 정리 완료"
}
