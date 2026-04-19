# Contributing to MemoryReset

기여 환영합니다. 본 문서는 PR/이슈 제출 시 따라야 할 가이드입니다.

## 호환성 요구사항 (Compatibility requirements)

**MUST**:
- PowerShell **5.1** 호환 (Windows 10/11 기본 PS, 추가 설치 없이 동작해야 함)
- UTF-8 **BOM** 보존 (한글 메시지가 ANSI 로 오인 안 되도록)
- C# (P/Invoke) 부분은 .NET Framework 4.x 호환

**SHOULD**:
- PowerShell 7+ 에서도 동작하도록 작성 (단, PS 7 전용 구문 금지)
- ASCII-only 식별자 (변수/함수명)
- 영문 주석 우선 (한글 주석은 사용자 설명용으로 한정)

## 변경 사항 검증 (Verification)

### 1. 파스 검증
```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    '.\MemoryReset.ps1', [ref]$null, [ref]$errors)
if ($errors.Count) { $errors | Format-List }
```

### 2. 패턴 회귀 검증
프로세스 식별 로직 (`Get-TargetProcesses`) 변경 시 반드시 실행:
```powershell
.\Test-Patterns.ps1
```
- Claude Desktop 보존: `[PASS]` 확인
- 자기 자신 PID 제외: `[PASS]` 확인
- 새 카테고리 추가 시 Test-Patterns.ps1 의 분류 로직도 동기화

### 3. 드라이런
실제 종료 없이 동작 확인:
```cmd
Run-DryRun.bat
```

### 4. UTF-8 BOM 확인
```powershell
$bytes = [System.IO.File]::ReadAllBytes('.\MemoryReset.ps1')
if ($bytes[0..2] -join ',' -ne '239,187,191') { 'BOM 누락' }
```

## 커밋 메시지

Conventional Commits 권장:
```
feat: <기능 추가 한 줄 요약>

세부 설명...

Closes #123
```

타입: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

## PR 체크리스트

- [ ] 파스 에러 0
- [ ] `Test-Patterns.ps1` PASS (해당 시)
- [ ] `Run-DryRun.bat` 으로 실측 검증
- [ ] CHANGELOG.md 의 `[Unreleased]` 섹션에 항목 추가
- [ ] 새 P/Invoke 추가 시 권위 있는 출처 (MSDN/phnt 헤더) 인용
- [ ] 한국어/영어 메시지 양쪽 업데이트 (사용자 출력 추가/변경 시)

## 스타일 가이드

- 들여쓰기: 4 스페이스 (탭 금지)
- 행 길이: 120자 이내 권장
- 함수명: `Verb-Noun` PowerShell 컨벤션 (`Get-`, `Set-`, `Invoke-`, `Stop-` 등)
- 변수명: `$camelCase`
- 상수: `$UPPER_SNAKE` 또는 C# 측의 `public const`

## 위험한 변경 (Sensitive changes)

다음 변경은 추가 리뷰가 필요합니다:

1. `Get-TargetProcesses` 의 화이트리스트/블랙리스트 — 잘못 매칭 시 사용자 데이터 손실
2. `taskkill` 인수 변경 — `/T` 제거 시 helper 프로세스 누락
3. P/Invoke 시그니처 변경 — 마샬링 오류로 메모리 손상 가능
4. UAC 승격 로직 변경 — 권한 우회 우려

PR 시 위험 부분 명시 + 회귀 검증 결과 첨부 권장.
