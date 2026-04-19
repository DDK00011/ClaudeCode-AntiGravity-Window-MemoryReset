#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code 와 Antigravity 를 안전하게 종료하고 Windows RAM 을 회수합니다.

.DESCRIPTION
    Windows 는 종료된 프로세스의 메모리를 즉시 free list 로 반환하지 않고
    Standby List / File Cache 에 남기는 경향이 있어 가용량 회복이 더딥니다.
    이 스크립트는 다음 5단계로 회수율을 끌어올립니다.

      1) Claude Code / Antigravity 프로세스 graceful 종료 (CloseMainWindow)
      2) Timeout 후 잔존 프로세스 트리 강제 종료 (taskkill /T /F)
      3) 남은 모든 프로세스의 Working Set 비우기 (EmptyWorkingSet, PROCESS_SET_QUOTA)
      4) System File Cache 트림 (SetSystemFileCacheSize)
      5) Modified Page List flush → Standby List 정리 (NtSetSystemInformation)
         * flush 를 purge 직전에 호출하여 dirty 페이지까지 회수

.PARAMETER GracefulTimeoutSec
    CloseMainWindow 후 대기할 시간 (초). 기본 8초.

.PARAMETER DryRun
    실제 종료/회수 없이 대상 프로세스만 표시.

.PARAMETER SkipConfirmation
    Y/n 프롬프트를 건너뜁니다 (자동화/스케줄러용).

.PARAMETER KeepAlive
    완료 후 키 입력 대기 없이 즉시 종료.

.PARAMETER Deep
    [v1.1+] Tier A 추가 회수 — Memory Compression Store flush + System Working Set empty + 네트워크 캐시 정리.
    재부팅과의 차이를 좁히기 위한 안전한 추가 단계.

.PARAMETER IncludeShell
    [v1.1+] Tier B 추가 — Explorer.exe + Windows Search 서비스 재시작.
    데스크톱이 1~2초 깜빡이며 열린 탐색기 창이 닫힘. -Deep 와 함께 사용.

.PARAMETER Diagnose
    [v1.1+] 회수 없이 진단만 수행 — 메모리 리스트 분포, 압축 store, 상위 점유 프로세스 표시.
    UAC 불필요.

.EXAMPLE
    .\MemoryReset.ps1                                     # 기본 회수
    .\MemoryReset.ps1 -DryRun                             # 사전 확인
    .\MemoryReset.ps1 -Diagnose                           # 메모리 분석만
    .\MemoryReset.ps1 -Deep                               # Tier A 추가
    .\MemoryReset.ps1 -Deep -IncludeShell                 # Tier A + B
    .\MemoryReset.ps1 -SkipConfirmation -KeepAlive        # 자동화

.NOTES
    관리자 권한 필요 (-DryRun / -Diagnose 제외). 미보유 시 자동 elevation 시도.
#>

[CmdletBinding()]
param(
    [int]$GracefulTimeoutSec = 8,
    [switch]$DryRun,
    [switch]$SkipConfirmation,
    [switch]$KeepAlive,

    # v1.1 추가 ─────────────────────────────────────────────
    [switch]$Deep,           # Tier A: Memory Compression flush + System WS empty + 네트워크 캐시
    [switch]$IncludeShell,   # Tier B: Explorer.exe + Windows Search 재시작 (Deep 와 함께 사용)
    [switch]$Diagnose        # 회수 전 메모리 분포 상세 표시
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ════════════════════════════════════════════════════════════════════
# 1. 관리자 권한 검사 + 자동 승격
# ════════════════════════════════════════════════════════════════════
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    if ($DryRun -or $Diagnose) {
        # DryRun / Diagnose 는 read-only → 관리자 권한 불필요, 그대로 진행
        Write-Host "[i] 읽기 전용 모드: 관리자 권한 없이 진행" -ForegroundColor DarkGray
    } else {
        Write-Host "[!] 관리자 권한이 필요합니다. UAC 승격을 시도합니다..." -ForegroundColor Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($SkipConfirmation)  { $argList += '-SkipConfirmation' }
        if ($KeepAlive)         { $argList += '-KeepAlive' }
        if ($Deep)              { $argList += '-Deep' }
        if ($IncludeShell)      { $argList += '-IncludeShell' }
        if ($PSBoundParameters.ContainsKey('GracefulTimeoutSec')) {
            $argList += @('-GracefulTimeoutSec', $GracefulTimeoutSec)
        }
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        } catch {
            Write-Host "[X] 승격 실패: $_" -ForegroundColor Red
            exit 1
        }
        exit 0
    }
}

# IncludeShell 은 Deep 없이는 무의미 — 자동 활성화
if ($IncludeShell -and -not $Deep) {
    Write-Host "[i] -IncludeShell 단독 사용 — -Deep 도 자동 활성화" -ForegroundColor DarkGray
    $Deep = $true
}

# ════════════════════════════════════════════════════════════════════
# 2. Win32 API P/Invoke 정의
# ════════════════════════════════════════════════════════════════════
$signature = @'
using System;
using System.Runtime.InteropServices;

public static class MemoryAPI {
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetSystemFileCacheSize(IntPtr MinimumFileCacheSize, IntPtr MaximumFileCacheSize, int Flags);

    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAll, ref TOKEN_PRIVILEGES NewState, uint Length, IntPtr Prev, IntPtr Ret);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public int  PrivilegeCount;
        public long Luid;
        public int  Attributes;
    }

    public const uint SE_PRIVILEGE_ENABLED        = 0x00000002;
    public const uint TOKEN_QUERY                 = 0x0008;
    public const uint TOKEN_ADJUST_PRIVILEGES     = 0x0020;

    public const uint PROCESS_QUERY_INFORMATION   = 0x0400;
    public const uint PROCESS_QUERY_LIMITED_INFO  = 0x1000;
    public const uint PROCESS_SET_QUOTA           = 0x0100;

    // SYSTEM_MEMORY_LIST_COMMAND (Process Hacker / phnt 헤더 검증)
    public const int  SystemMemoryListInformation        = 80;
    public const int  MemoryEmptyWorkingSets             = 2;  // 모든 프로세스 working set 비우기 (NT 레벨)
    public const int  MemoryFlushModifiedList            = 3;  // dirty 페이지 → standby 로 flush (purge 전 호출 시 회수율 ↑)
    public const int  MemoryPurgeStandbyList             = 4;
    public const int  MemoryPurgeLowPriorityStandbyList  = 5;

    public const int  ERROR_NOT_ALL_ASSIGNED             = 1300;

    // Returns: 0 = success, 1 = OpenProcessToken failed, 2 = LookupPrivilegeValue failed,
    //          3 = AdjustTokenPrivileges API failed, 4 = privilege not held (ERROR_NOT_ALL_ASSIGNED)
    public static int EnablePrivilegeChecked(string privilege) {
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                return 1;

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Attributes     = (int)SE_PRIVILEGE_ENABLED;
            if (!LookupPrivilegeValue(null, privilege, out tp.Luid))
                return 2;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                return 3;

            // CRITICAL: GetLastWin32Error MUST be called immediately after AdjustTokenPrivileges,
            // before any other P/Invoke. AdjustTokenPrivileges returns TRUE even when ERROR_NOT_ALL_ASSIGNED
            // is the actual outcome — only GetLastError reveals the real status.
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_ALL_ASSIGNED) return 4;

            return 0;
        } finally {
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    public static bool EnablePrivilege(string privilege) {
        return EnablePrivilegeChecked(privilege) == 0;
    }

    // Empty working set with minimal access rights — works on more processes than .Handle (PROCESS_ALL_ACCESS).
    // Returns: true on success, false on failure (process is protected or already dead).
    public static bool EmptyWorkingSetByPid(uint pid) {
        IntPtr h = OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFO, false, pid);
        if (h == IntPtr.Zero) return false;
        try {
            return EmptyWorkingSet(h) != 0;
        } finally {
            CloseHandle(h);
        }
    }

    public static uint InvokeMemoryListCommand(int command) {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        EnablePrivilege("SeIncreaseQuotaPrivilege");

        IntPtr ptr = Marshal.AllocHGlobal(sizeof(int));
        try {
            Marshal.WriteInt32(ptr, command);
            return NtSetSystemInformation(SystemMemoryListInformation, ptr, sizeof(int));
        } finally {
            Marshal.FreeHGlobal(ptr);
        }
    }

    public static uint FlushModifiedPageList() {
        return InvokeMemoryListCommand(MemoryFlushModifiedList);
    }

    public static uint PurgeStandbyList(bool lowPriorityOnly) {
        return InvokeMemoryListCommand(lowPriorityOnly ? MemoryPurgeLowPriorityStandbyList : MemoryPurgeStandbyList);
    }

    public static bool ClearFileSystemCache() {
        EnablePrivilege("SeIncreaseQuotaPrivilege");
        return SetSystemFileCacheSize((IntPtr)(-1), (IntPtr)(-1), 0);
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'MemoryAPI').Type) {
    Add-Type -TypeDefinition $signature -Language CSharp
}

# ════════════════════════════════════════════════════════════════════
# 3. NTSTATUS 친화적 디코딩
# ════════════════════════════════════════════════════════════════════
function Format-NTStatus {
    param([uint32]$Status)
    $name = switch ($Status) {
        0x00000000 { 'STATUS_SUCCESS' }
        0xC0000022 { 'STATUS_ACCESS_DENIED (관리자 권한 미승격?)' }
        0xC0000061 { 'STATUS_PRIVILEGE_NOT_HELD (SeProfileSingleProcessPrivilege 미보유)' }
        0xC0000005 { 'STATUS_ACCESS_VIOLATION' }
        0xC000000D { 'STATUS_INVALID_PARAMETER' }
        0xC0000002 { 'STATUS_NOT_IMPLEMENTED (이 Windows 버전에서 미지원)' }
        default    { 'UNKNOWN' }
    }
    '0x{0:X8} ({1})' -f $Status, $name
}

# ════════════════════════════════════════════════════════════════════
# 4. 메모리 상태 표시
# ════════════════════════════════════════════════════════════════════
function Get-MemoryStatus {
    $os      = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024)
    $usedMB  = $totalMB - $freeMB
    $pctFree = [math]::Round(($freeMB / $totalMB) * 100, 1)

    [PSCustomObject]@{
        TotalMB = $totalMB
        UsedMB  = $usedMB
        FreeMB  = $freeMB
        PctFree = $pctFree
    }
}

function Show-MemoryStatus {
    param([string]$Label)
    $m = Get-MemoryStatus
    $color = if ($m.PctFree -lt 10)      { 'Red' }
             elseif ($m.PctFree -lt 25)  { 'Yellow' }
             else                        { 'Green' }
    Write-Host ""
    Write-Host "── $Label ──" -ForegroundColor Cyan
    Write-Host (" 전체:   {0,8:N0} MB" -f $m.TotalMB)
    Write-Host (" 사용중: {0,8:N0} MB" -f $m.UsedMB)
    Write-Host (" 가용:   {0,8:N0} MB ({1}%)" -f $m.FreeMB, $m.PctFree) -ForegroundColor $color
    return $m
}

# ════════════════════════════════════════════════════════════════════
# 5. 대상 프로세스 식별
#    핵심 안전장치: Claude Desktop 앱은 절대 매칭 금지 (다중 설치 경로 블랙리스트).
#    오직 CLI / Antigravity 확장 / 표준 Node 패키지만 종료 대상.
# ════════════════════════════════════════════════════════════════════
function Get-TargetProcesses {
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue

    # ── Claude Code CLI 식별 ──
    # 화이트리스트(설치 경로) 기반: 아래 위치에서 실행되는 claude.exe/node.exe 만 대상.
    #   1) %USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\
    #   2) %USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\
    #   3) %APPDATA%\Claude\claude-code\<version>\claude.exe
    #   4) %APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe (npm global)
    #   5) node.exe with @anthropic-ai/claude-code in command line
    #   6) claude.exe with --output-format stream-json (CLI signature arg)
    # 명시적 블랙리스트: Claude Desktop 앱의 알려진 모든 설치 경로 → 절대 매칭 금지.
    $claude = $allProcs | Where-Object {
        $exe = if ($_.ExecutablePath) { $_.ExecutablePath } else { '' }
        $cmd = if ($_.CommandLine)    { $_.CommandLine }    else { '' }

        # 블랙리스트: Claude Desktop 앱은 무조건 제외 (MSIX / Squirrel / 직접설치 / OS-wide)
        if ($exe -match '(?i)\\WindowsApps\\Claude_')                                    { return $false }
        if ($exe -match '(?i)\\AnthropicClaude\\.*?\\Claude\.exe$' -and $cmd -notmatch '(?i)claude-code') { return $false }
        if ($exe -match '(?i)\\Programs\\claude-desktop\\.*?\\Claude\.exe$')             { return $false }
        if ($exe -match '(?i)\\Program Files\\Claude\\Claude\.exe$')                     { return $false }
        if ($exe -match '(?i)\\Program Files \(x86\)\\Claude\\Claude\.exe$')             { return $false }

        # 화이트리스트: CLI 경로 또는 시그니처 인수
        ($_.Name -match '(?i)^claude\.exe$' -and (
            $exe -match '(?i)\\\.antigravity\\extensions\\anthropic\.claude-code-' -or
            $exe -match '(?i)\\\.cursor\\extensions\\anthropic\.claude-code-' -or
            $exe -match '(?i)\\Claude\\claude-code\\' -or
            $exe -match '(?i)\\claude-code\\.*?\\claude\.exe$' -or
            $exe -match '(?i)\\npm\\node_modules\\@anthropic-ai\\claude-code\\' -or
            $cmd -match '(?i)--output-format\s+stream-json'
        )) -or
        ($_.Name -eq 'node.exe' -and $cmd -match '(?i)@anthropic-ai[\\/]claude-code')
    }

    # ── Antigravity 식별 ──
    # 정확한 설치 경로: %LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe
    # ExecutablePath 기준이 가장 안전 (모든 helper/renderer 포함).
    $antigravity = $allProcs | Where-Object {
        ($_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\') -or
        ($_.ExecutablePath -match '(?i)\\Google\\Antigravity\\') -or
        ($_.Name -match '(?i)^Antigravity(\.exe)?$' -and $_.ExecutablePath -match '(?i)Antigravity')
    }

    # 중복 제거 + 자기 자신(현재 PowerShell) 제외
    $self = $PID
    $merged = @($claude) + @($antigravity) |
        Where-Object { $_.ProcessId -ne $self } |
        Sort-Object ProcessId -Unique

    return $merged
}

# ════════════════════════════════════════════════════════════════════
# 6. 프로세스 종료 (Graceful → Wait → Force tree-kill)
# ════════════════════════════════════════════════════════════════════
function Stop-TargetProcesses {
    param(
        [array]$Processes,
        [int]$TimeoutSec = 8,
        [switch]$DryRun
    )

    if ($Processes.Count -eq 0) {
        Write-Host "[i] 종료할 대상 프로세스가 없습니다." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "── [1/4] Graceful 종료 시도 (CloseMainWindow) ──" -ForegroundColor Cyan
    foreach ($p in $Processes) {
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        if ($DryRun) {
            Write-Host " [DRY] CloseMainWindow → $tag" -ForegroundColor DarkGray
            continue
        }

        try {
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                $null = $proc.CloseMainWindow()
                Write-Host " [OK] CloseMainWindow → $tag" -ForegroundColor Green
            } else {
                Write-Host "  ·   No window     → $tag (다음 단계에서 강제 종료)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host " [!] Graceful 실패: $tag — $_" -ForegroundColor Yellow
        }
    }

    if ($DryRun) { return }

    Write-Host ""
    Write-Host "── [2/4] ${TimeoutSec}초 대기 (저장/정리 시간 확보) ──" -ForegroundColor Cyan
    for ($i = $TimeoutSec; $i -gt 0; $i--) {
        Write-Host -NoNewline ("`r 남은 시간: {0,2} 초 " -f $i)
        Start-Sleep -Seconds 1
    }
    Write-Host "`r 대기 완료.            "

    Write-Host ""
    Write-Host "── [3/4] 잔존 프로세스 트리 강제 종료 (taskkill /T /F) ──" -ForegroundColor Cyan
    $survivors = $Processes | Where-Object {
        Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    }

    if ($survivors.Count -eq 0) {
        Write-Host " [OK] 모든 프로세스가 graceful 종료됨." -ForegroundColor Green
        return
    }

    foreach ($p in $survivors) {
        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        $null = & taskkill.exe /F /T /PID $p.ProcessId 2>&1
        # 0=success, 128=process already gone (cascaded by parent kill) → both OK
        if ($LASTEXITCODE -eq 0) {
            Write-Host " [KILL] $tag" -ForegroundColor Yellow
        } elseif ($LASTEXITCODE -eq 128) {
            Write-Host " [GONE] $tag (이미 종료됨)" -ForegroundColor DarkGray
        } else {
            Write-Host " [X] taskkill 실패: $tag (exit=$LASTEXITCODE)" -ForegroundColor Red
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 7. 메모리 회수 (EmptyWorkingSet + FileCache + Flush + Purge)
# ════════════════════════════════════════════════════════════════════
function Invoke-MemoryRecovery {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [4/4] 메모리 회수 ──" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host " [DRY] EmptyWorkingSet / ClearFileSystemCache / PurgeStandbyList 호출 예정" -ForegroundColor DarkGray
        return
    }

    # 0) 필수 권한 사전 확인 (Standby Purge / FileCache 정리에 필요)
    $privReport = @{
        'SeProfileSingleProcessPrivilege' = [MemoryAPI]::EnablePrivilegeChecked('SeProfileSingleProcessPrivilege')
        'SeIncreaseQuotaPrivilege'        = [MemoryAPI]::EnablePrivilegeChecked('SeIncreaseQuotaPrivilege')
    }
    foreach ($k in $privReport.Keys) {
        $rc = $privReport[$k]
        $msg = switch ($rc) {
            0 { '[OK]   ' + $k }
            1 { '[!] OpenProcessToken 실패: ' + $k }
            2 { '[!] LookupPrivilegeValue 실패: ' + $k }
            3 { '[!] AdjustTokenPrivileges API 실패: ' + $k }
            4 { '[!] 권한 미보유 (NOT_ALL_ASSIGNED): ' + $k + ' — 관리자 권한이라도 SeProfileSingleProcess 가 없을 수 있음. 로컬 보안 정책 확인 필요.' }
        }
        $color = if ($rc -eq 0) { 'DarkGray' } else { 'Yellow' }
        Write-Host " · $msg" -ForegroundColor $color
    }

    # 6-1. 모든 프로세스 작업 집합 비우기 (PROCESS_SET_QUOTA 최소 권한)
    Write-Host -NoNewline " · 작업 집합 비우는 중 ..."
    $ok = 0; $fail = 0
    Get-Process | ForEach-Object {
        try {
            if ([MemoryAPI]::EmptyWorkingSetByPid([uint32]$_.Id)) { $ok++ } else { $fail++ }
        } catch { $fail++ }
    }
    Write-Host " [OK] 성공 $ok / 접근불가 $fail" -ForegroundColor Green

    # 6-2. 파일 시스템 캐시 트림
    Write-Host -NoNewline " · System File Cache 트림 ..."
    $r = [MemoryAPI]::ClearFileSystemCache()
    if ($r) { Write-Host " [OK]" -ForegroundColor Green }
    else    { Write-Host " [!] 실패 (Win32Error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" -ForegroundColor Yellow }

    # 6-3. Modified Page List flush (dirty 페이지 → standby 로 이동, purge 직전에 호출)
    Write-Host -NoNewline " · Modified Page List flush ..."
    $rcFlush = [MemoryAPI]::FlushModifiedPageList()
    if ($rcFlush -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0} (계속 진행)" -f (Format-NTStatus $rcFlush)) -ForegroundColor Yellow
    }

    # 6-4. Standby List 정리 (핵심 — 이 단계가 가장 큰 회수 효과)
    Write-Host -NoNewline " · Standby List 정리 ..."
    $rc = [MemoryAPI]::PurgeStandbyList($false)
    if ($rc -eq 0) {
        Write-Host " [OK] (전체 standby 정리)" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0} → 저우선만 재시도" -f (Format-NTStatus $rc)) -ForegroundColor Yellow
        $rc2 = [MemoryAPI]::PurgeStandbyList($true)
        if ($rc2 -eq 0) {
            Write-Host "   재시도 [OK] (저우선 standby 정리됨)" -ForegroundColor Green
        } else {
            Write-Host ("   재시도 실패 NTSTATUS={0}" -f (Format-NTStatus $rc2)) -ForegroundColor Red
            Write-Host "   원인 후보: 관리자 권한 미승격 / SeProfileSingleProcessPrivilege 미보유 (보안 정책 확인)" -ForegroundColor DarkYellow
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 6.5. -Diagnose: 회수 전 메모리 분포 상세 표시
# ════════════════════════════════════════════════════════════════════
function Show-MemoryDiagnostics {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║                메모리 진단 (Diagnostics)                  ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

    # 1. PerfCounter 기반 메모리 리스트 분포
    Write-Host ""
    Write-Host "── 메모리 리스트 분포 ──" -ForegroundColor Cyan
    try {
        $counters = @(
            '\Memory\Available MBytes',
            '\Memory\Cache Bytes',
            '\Memory\Modified Page List Bytes',
            '\Memory\Standby Cache Normal Priority Bytes',
            '\Memory\Standby Cache Reserve Bytes',
            '\Memory\Standby Cache Core Bytes',
            '\Memory\Free & Zero Page List Bytes'
        )
        $samples = (Get-Counter -Counter $counters -ErrorAction Stop).CounterSamples
        foreach ($s in $samples) {
            $name = ($s.Path -replace '.+\\Memory\\', '')
            $val  = if ($name -eq 'Available MBytes') { '{0,8:N0} MB' -f $s.CookedValue }
                    else { '{0,8:N0} MB' -f ($s.CookedValue / 1MB) }
            Write-Host (" · {0,-44} {1}" -f $name, $val)
        }
    } catch {
        Write-Host " [!] PerfCounter 조회 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2. Memory Compression Store
    Write-Host ""
    Write-Host "── Memory Compression Store ──" -ForegroundColor Cyan
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        Write-Host (" · MemoryCompression 활성화: {0}" -f $mm.MemoryCompression)
        $compProc = Get-Process -Name 'Memory Compression' -ErrorAction SilentlyContinue
        if ($compProc) {
            $compMB = [math]::Round($compProc.WorkingSet64 / 1MB, 1)
            Write-Host (" · 'Memory Compression' 프로세스 사용량: {0,8:N1} MB" -f $compMB) -ForegroundColor Yellow
            Write-Host "   → -Deep 모드로 flush 가능"
        } else {
            Write-Host " · 'Memory Compression' 프로세스 정보 없음 (관리자 권한이거나 일부 빌드에서 숨겨짐)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] MMAgent 조회 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 3. 상위 점유 프로세스 Top 15 (working set 기준)
    Write-Host ""
    Write-Host "── 점유 상위 프로세스 Top 15 (Working Set 기준) ──" -ForegroundColor Cyan
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 |
        ForEach-Object {
            $wsMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
            $cmMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
            Write-Host (" · {0,-30} PID={1,-7} WS={2,8} MB  Commit={3,8} MB" -f $_.ProcessName, $_.Id, $wsMB, $cmMB)
        }

    # 4. 종료 대상 프로세스 카운트 (실제 회수 가능량 미리보기)
    Write-Host ""
    Write-Host "── 종료 대상 프로세스 (Claude/Antigravity) ──" -ForegroundColor Cyan
    $targets = Get-TargetProcesses
    if ($targets.Count -eq 0) {
        Write-Host " (없음)" -ForegroundColor DarkGray
    } else {
        $tWS = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" · 총 {0} 개 프로세스 / Working Set 합계 {1:N1} MB 회수 가능" -f $targets.Count, $tWS)
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║  진단 완료. 회수를 진행하려면 -Diagnose 없이 재실행.       ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
}

# ════════════════════════════════════════════════════════════════════
# 7-A. Tier A: 깊은 회수 (-Deep)
#      Memory Compression Store flush + System Working Set + 네트워크 캐시
# ════════════════════════════════════════════════════════════════════
function Invoke-DeepRecovery {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [Deep] Tier A — 추가 회수 ──" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host " [DRY] MMAgent 재시작 / System WS / 네트워크 캐시 호출 예정" -ForegroundColor DarkGray
        return
    }

    # A1. Memory Compression Store flush
    #     원리: MemoryCompression 을 disable 했다가 다시 enable 하면 압축된 페이지가 해제됨
    #     주의: 일시적으로 메모리 사용 spike 가능 (압축 해제 시) → standby 정리 후 호출하므로 여유 있음
    Write-Host -NoNewline " · Memory Compression Store flush ..."
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        if ($mm.MemoryCompression) {
            Disable-MMAgent -MemoryCompression -ErrorAction Stop
            Start-Sleep -Milliseconds 800
            Enable-MMAgent -MemoryCompression -ErrorAction Stop
            Write-Host " [OK] (압축 페이지 해제됨)" -ForegroundColor Green
        } else {
            Write-Host " [skip] 이미 비활성화 상태" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # A2. System-wide Working Set empty (NT 레벨 일괄)
    #     6-1 의 per-process 루프와 별도로 system 프로세스까지 포함
    Write-Host -NoNewline " · System Working Set empty (NT) ..."
    $rcWs = [MemoryAPI]::InvokeMemoryListCommand([MemoryAPI]::MemoryEmptyWorkingSets)
    if ($rcWs -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0}" -f (Format-NTStatus $rcWs)) -ForegroundColor Yellow
    }

    # A3. 네트워크 캐시 정리 (DNS / NetBIOS / ARP)
    Write-Host -NoNewline " · DNS 캐시 ..."
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host -NoNewline " · NetBIOS 캐시 ..."
    $null = & nbtstat.exe -R 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [!] nbtstat exit=$LASTEXITCODE" -ForegroundColor DarkGray
    }

    Write-Host -NoNewline " · ARP 캐시 ..."
    $null = & netsh.exe interface ip delete arpcache 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [!] netsh exit=$LASTEXITCODE" -ForegroundColor DarkGray
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-B. Tier B: 셸 재시작 (-IncludeShell)
#      Explorer.exe + Windows Search 재시작 — 200~500MB 추가 회수
#      주의: 데스크톱이 1~2초 깜빡임, 열린 탐색기 창 닫힘
# ════════════════════════════════════════════════════════════════════
function Invoke-ShellRestart {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [Deep+Shell] Tier B — 셸 재시작 ──" -ForegroundColor Cyan
    Write-Host "  ! 데스크톱이 잠시 깜빡이며 열린 탐색기 창이 닫힙니다." -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host " [DRY] explorer.exe + WSearch 재시작 예정" -ForegroundColor DarkGray
        return
    }

    # B1. Explorer.exe 재시작
    Write-Host -NoNewline " · Explorer 재시작 ..."
    try {
        $explorers = Get-Process -Name explorer -ErrorAction SilentlyContinue
        $beforeMB = if ($explorers) { [math]::Round((($explorers | Measure-Object WorkingSet64 -Sum).Sum / 1MB), 1) } else { 0 }
        $explorers | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        # Windows 가 자동으로 explorer 를 재시작하지 않는 경우 수동 시작
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath explorer.exe
        }
        Write-Host (" [OK] (이전 사용량 {0} MB)" -f $beforeMB) -ForegroundColor Green
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # B2. Windows Search 서비스 재시작
    Write-Host -NoNewline " · Windows Search 재시작 ..."
    try {
        $svc = Get-Service -Name WSearch -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Restart-Service -Name WSearch -Force -ErrorAction Stop
            Write-Host " [OK]" -ForegroundColor Green
        } else {
            Write-Host " [skip] 서비스가 실행 중이 아님 ($($svc.Status))" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ════════════════════════════════════════════════════════════════════
# 8. Main
# ════════════════════════════════════════════════════════════════════
try { $Host.UI.RawUI.WindowTitle = 'Memory Reset — Claude Code & Antigravity' } catch {}

Clear-Host
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      Memory Reset  —  Claude Code & Antigravity          ║" -ForegroundColor Cyan
Write-Host "║      (graceful kill + working-set + standby purge)       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun)   { Write-Host "[i] DRY-RUN 모드 — 실제 종료/회수 없음" -ForegroundColor Magenta }
if ($Diagnose) { Write-Host "[i] DIAGNOSE 모드 — 진단만 수행 (read-only)" -ForegroundColor Magenta }
if ($Deep)     { Write-Host "[i] DEEP 모드 — Tier A (Memory Compression flush + System WS + 네트워크 캐시) 추가" -ForegroundColor Magenta }
if ($IncludeShell) { Write-Host "[!] SHELL 재시작 모드 — 데스크톱이 잠시 깜빡입니다 (Tier B)" -ForegroundColor Yellow }

# Diagnose 모드는 진단만 출력하고 종료
if ($Diagnose) {
    Show-MemoryDiagnostics
    if (-not $KeepAlive) {
        Write-Host ""
        Write-Host "[i] 아무 키나 누르면 창이 닫힙니다."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit 0
}

$before = Show-MemoryStatus -Label "현재 메모리 상태"

Write-Host ""
Write-Host "── 종료 대상 프로세스 ──" -ForegroundColor Cyan
$targets = Get-TargetProcesses
if ($targets.Count -eq 0) {
    Write-Host " (대상 없음 — Standby List 정리만 수행됩니다)" -ForegroundColor DarkGray
} else {
    # 카테고리별 그룹: Antigravity / Claude Code CLI 분류
    $categorize = {
        param($p)
        if ($p.ExecutablePath -match '(?i)\\Programs\\Antigravity\\')                              { return 'Antigravity' }
        if ($p.ExecutablePath -match '(?i)\\\.antigravity\\extensions')                            { return 'Claude(Antigravity ext)' }
        if ($p.ExecutablePath -match '(?i)\\\.cursor\\extensions')                                 { return 'Claude(Cursor ext)' }
        if ($p.ExecutablePath -match '(?i)\\npm\\node_modules\\@anthropic-ai\\claude-code')        { return 'Claude(npm global)' }
        if ($p.ExecutablePath -match '(?i)\\Claude\\claude-code\\')                                { return 'Claude(standalone)' }
        if ($p.Name -eq 'node.exe')                                                                { return 'Claude(node)' }
        return '기타(unknown)'
    }

    $grouped = $targets | Group-Object { & $categorize $_ } | Sort-Object Name
    $grandTotal = 0
    foreach ($g in $grouped) {
        $catTotalMB = [math]::Round((($g.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        $grandTotal += $catTotalMB
        Write-Host ("`n  ▶ [{0}]  {1}개  /  {2:N1} MB" -f $g.Name, $g.Count, $catTotalMB) -ForegroundColor Yellow
        # 처음 3개만 상세 표시 (PID/경로), 나머지는 요약
        $shown = 0
        foreach ($p in ($g.Group | Sort-Object WorkingSetSize -Descending)) {
            if ($shown -lt 3) {
                $memMB = [math]::Round($p.WorkingSetSize / 1MB, 1)
                $path  = if ($p.ExecutablePath) { $p.ExecutablePath } else { '<경로없음>' }
                # 경로가 너무 길면 축약
                if ($path.Length -gt 70) { $path = '...' + $path.Substring($path.Length - 67) }
                Write-Host ("     PID={0,-7} WS={1,7} MB  {2}" -f $p.ProcessId, $memMB, $path) -ForegroundColor DarkGray
                $shown++
            }
        }
        if ($g.Count -gt 3) {
            Write-Host ("     ... 외 {0}개 동일 경로" -f ($g.Count - 3)) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host (" ── 총 합계: {0:N1} MB  ({1} 개 프로세스)" -f $grandTotal, $targets.Count) -ForegroundColor Cyan

    # Claude Desktop 앱이 보존되었는지 확인 표시 (안전성 검증용)
    $desktopApp = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
        Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
    if ($desktopApp) {
        $dCount = @($desktopApp).Count
        $dMB = [math]::Round((($desktopApp | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" ── 보존 (종료 안 함): Claude Desktop 앱 {0}개 / {1:N1} MB" -f $dCount, $dMB) -ForegroundColor Green
    }
}

if (-not $SkipConfirmation -and -not $DryRun -and $targets.Count -gt 0) {
    Write-Host ""
    $confirm = Read-Host "위 프로세스를 종료하고 메모리 회수를 진행할까요? [Y/n]"
    if ($confirm -match '^[nN]') {
        Write-Host "[i] 사용자 취소." -ForegroundColor DarkGray
        if (-not $KeepAlive) {
            Write-Host "[i] 아무 키나 누르면 종료..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        exit 0
    }
}

Stop-TargetProcesses -Processes $targets -TimeoutSec $GracefulTimeoutSec -DryRun:$DryRun
Invoke-MemoryRecovery -DryRun:$DryRun

# v1.1: 옵션 단계
if ($Deep)         { Invoke-DeepRecovery -DryRun:$DryRun }
if ($IncludeShell) { Invoke-ShellRestart -DryRun:$DryRun }

$after = Show-MemoryStatus -Label "회수 후 메모리 상태"

if (-not $DryRun) {
    $recovered = $after.FreeMB - $before.FreeMB
    $pctChange = $after.PctFree - $before.PctFree
    $sign = if ($recovered -ge 0) { '+' } else { '' }
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host (" 회수된 RAM: {0}{1:N0} MB   ({2}{3:N1}%p)" -f $sign, $recovered, $sign, $pctChange) -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

if (-not $KeepAlive) {
    Write-Host ""
    Write-Host "[i] 완료. 아무 키나 누르면 창이 닫힙니다."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
