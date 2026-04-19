# 패턴 검증용 테스트 스크립트 (실제 종료 안 함)
# MemoryReset.ps1 의 Get-TargetProcesses 함수만 추출해서 실행 — 안전성 검증 도구.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 같은 폴더의 MemoryReset.ps1 을 읽어서 함수 정의 추출
$mainScript = Join-Path $PSScriptRoot 'MemoryReset.ps1'
if (-not (Test-Path $mainScript)) {
    Write-Host "[ERR] MemoryReset.ps1 을 같은 폴더에서 찾을 수 없음: $mainScript" -ForegroundColor Red
    exit 1
}
$src = Get-Content $mainScript -Raw -Encoding UTF8
# Get-TargetProcesses 함수 추출 (정규식)
if ($src -match '(?ms)function Get-TargetProcesses \{.*?^\}') {
    $funcDef = $Matches[0]
    Invoke-Expression $funcDef
} else {
    Write-Host "함수 추출 실패" -ForegroundColor Red
    exit 1
}

$targets = Get-TargetProcesses

Write-Host "== 종료 대상 분류 =="
$targets | Group-Object {
    if ($_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\') { 'Antigravity 본체' }
    elseif ($_.ExecutablePath -match '(?i)\\\.antigravity\\extensions') { 'Claude CLI (Antigravity 확장)' }
    elseif ($_.ExecutablePath -match '(?i)\\Claude\\claude-code\\') { 'Claude CLI (standalone)' }
    elseif ($_.Name -eq 'node.exe') { 'Claude CLI (node)' }
    else { '기타' }
} | ForEach-Object {
    $ws = [math]::Round((($_.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
    '{0,-40} {1,4} 개  {2,10:N1} MB' -f $_.Name, $_.Count, $ws
}

Write-Host ""
Write-Host "== Claude Desktop 보존 검증 =="
$desktop = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
    Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
$inTargets = $targets | Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
'Desktop 앱 PID 수: {0}' -f @($desktop).Count
'그 중 종료 대상에 잘못 포함된 수: {0}' -f @($inTargets).Count
if (@($inTargets).Count -eq 0) {
    Write-Host "[PASS] Claude Desktop 안전하게 보존됨" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Claude Desktop 이 종료 대상에 포함됨!" -ForegroundColor Red
    $inTargets | Select-Object Name, ProcessId, ExecutablePath | Format-List
}

Write-Host ""
Write-Host "== 합계 =="
$totalMB = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
'종료 시 회수 가능 (working set 기준): {0:N1} MB ({1} 프로세스)' -f $totalMB, @($targets).Count

Write-Host ""
Write-Host "== '기타' 카테고리 상세 (예상치 못한 매칭 확인) =="
$unknown = $targets | Where-Object {
    $_.ExecutablePath -notmatch '(?i)\\Programs\\Antigravity\\' -and
    $_.ExecutablePath -notmatch '(?i)\\\.antigravity\\extensions' -and
    $_.ExecutablePath -notmatch '(?i)\\Claude\\claude-code\\' -and
    $_.Name -ne 'node.exe'
}
if ($unknown) {
    $unknown | Select-Object Name, ProcessId, ExecutablePath, @{N='WS_MB';E={[math]::Round($_.WorkingSetSize/1MB,1)}} | Format-List
} else {
    Write-Host "(없음)"
}

Write-Host ""
Write-Host "== 자기 자신(현재 PowerShell PID=$PID) 제외 검증 =="
$selfIncluded = $targets | Where-Object { $_.ProcessId -eq $PID }
if ($null -eq $selfIncluded) {
    Write-Host "[PASS] 자기 자신 제외됨" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 자기 자신이 대상에 포함됨!" -ForegroundColor Red
}

# v1.1 신규 기능 smoke test
Write-Host ""
Write-Host "== v1.1 신규 함수/플래그 smoke test =="

# 1. 신규 함수가 스크립트에 정의되어 있는지 확인
$expectedFunctions = @('Show-MemoryDiagnostics', 'Invoke-DeepRecovery', 'Invoke-ShellRestart')
foreach ($fn in $expectedFunctions) {
    if ($src -match "(?ms)^function\s+$fn\b") {
        Write-Host "[PASS] 함수 정의 존재: $fn" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 함수 정의 누락: $fn" -ForegroundColor Red
    }
}

# 2. 신규 파라미터 선언 확인
$expectedParams = @('Deep', 'IncludeShell', 'Diagnose')
foreach ($p in $expectedParams) {
    $pattern = '\[switch\]\$' + $p + '\b'
    if ($src -match $pattern) {
        Write-Host "[PASS] 파라미터 정의: -$p" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 파라미터 누락: -$p" -ForegroundColor Red
    }
}

# 3. v1.1.1 안전 가드 검증 (Round 1 패치 추적)
if ($src -match 'finally\s*\{[\s\S]*?Enable-MMAgent') {
    Write-Host "[PASS] MMAgent Disable→Enable try/finally 가드 존재" -ForegroundColor Green
} else {
    Write-Host "[WARN] MMAgent try/finally 가드 미확인 — Disable 후 Enable 실패 시 시스템 압축 영구 비활성화 위험" -ForegroundColor Yellow
}

if ($src -match 'availMB\s*-lt\s*1024') {
    Write-Host "[PASS] 압축 해제 spike OOM 가드 존재 (가용 RAM < 1GB 시 skip)" -ForegroundColor Green
} else {
    Write-Host "[WARN] OOM 가드 미확인" -ForegroundColor Yellow
}

if ($src -match 'restartedByWindows\s*=\s*\$true') {
    Write-Host "[PASS] Explorer 재시작 폴링 루프 존재" -ForegroundColor Green
} else {
    Write-Host "[WARN] Explorer 폴링 루프 미확인 — 셸 확장 많은 시스템에서 1.5초 부족 가능" -ForegroundColor Yellow
}

# 6. v1.1.2 elevation safety: Explorer 자동 재시작에만 의존 (Round 2 패치)
if ($src -match '의도적으로\s*elevated\s*explorer\.exe\s*직접\s*실행하지\s*않음') {
    Write-Host "[PASS] Explorer elevation 위험 회피 (자동 재시작 전용)" -ForegroundColor Green
} else {
    Write-Host "[WARN] elevated explorer 자동 시작 가드 미확인 — 일반 앱이 권한 부족 겪을 위험" -ForegroundColor Yellow
}

# 7. v1.1.2 MMAgent sleep 1500ms (Round 2 패치)
if ($src -match 'Start-Sleep\s+-Milliseconds\s+1500') {
    Write-Host "[PASS] MMAgent decompress 대기 1500ms (이전 800ms 에서 증가)" -ForegroundColor Green
} else {
    Write-Host "[WARN] MMAgent sleep 1500ms 미확인" -ForegroundColor Yellow
}
