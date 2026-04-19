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
