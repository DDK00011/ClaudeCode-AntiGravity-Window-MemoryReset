# 초기 개발 일지 — 2026-04-19

> 본 문서는 MemoryReset v1.0 의 초기 개발 과정에서 작성된 내부 로그입니다.
> 동기, 설계 결정, 다단계 검토 결과, 검증 매트릭스를 기록합니다.

## 동기

- **현상**: 가용 RAM 3~5% 까지 떨어지는 메모리 병목
- **원인**: Antigravity (VS Code fork) 가 Claude Code 확장으로 phase 마다 12 세션을 spawn → 100+ `claude.exe` 프로세스가 동시 실행
- **실측 (작업 시점)**:
  - Claude CLI 67 개 (Antigravity 확장 경로) → **31.6 GB**
  - Antigravity 본체 32 개 → **6.6 GB**
  - Claude CLI standalone 1 개 → 0.5 GB
  - npm 글로벌 CLI 1 개 → 0.7 GB
  - **총 39.4 GB / 101 프로세스 회수 가능**
- **기존 해결책 한계**: 재부팅 → 모든 작업 강제 종료
- **목표**: Claude Code + Antigravity **만** 안전하게 종료하고 Windows 의 회수 지연(Standby List / File Cache)까지 해소

## 산출물 (`.\`)

| 파일 | 역할 |
|------|------|
| `MemoryReset.ps1` | 메인 스크립트 (573 줄, UTF-8 BOM, PowerShell 5.1+) |
| `Run.bat` | 더블클릭 런처 (UAC 자동 승격) |
| `Run-DryRun.bat` | 드라이런 런처 (실제 종료/회수 없음) |
| `Test-Patterns.ps1` | 패턴 검증 전용 (실제 종료 안 함) |
| `README.md` | 사용 안내 |
| `docs/2026-04-19-initial-development.md` | 본 작업 기록 |

## 설계 결정

### 1. 형태: PowerShell 단일 스크립트
- 설치/컴파일 불필요, 어떤 Windows 10/11 에서도 즉시 동작
- 추후 시스템 트레이 GUI(C# WPF) 로 발전 가능 (현 단계 미진행)

### 2. 회수 파이프라인 (5 단계)
```
[1] CloseMainWindow              ← graceful 저장 기회 (8초 대기)
[2] taskkill /T /F               ← 잔존 프로세스 트리 강제 종료
[3] EmptyWorkingSet              ← 모든 프로세스 working set → standby 강등
[4] SetSystemFileCacheSize(-1,-1)← 시스템 파일 캐시 트림
[5] FlushModifiedList → PurgeStandbyList ← dirty 페이지 flush 후 standby 회수
```
**핵심 통찰**: 단계 5 의 `MemoryFlushModifiedList` 를 `PurgeStandbyList` *직전에* 호출 → dirty 페이지가 standby 로 이동 후 함께 회수되어 회수율 추가 향상 (Round 2 Codex 리뷰 반영)

### 3. P/Invoke 사용 API
| DLL | 함수 | 용도 |
|-----|------|------|
| `psapi.dll` | `EmptyWorkingSet` | 프로세스 working set 비우기 |
| `kernel32.dll` | `SetSystemFileCacheSize` | 파일 캐시 트림 |
| `kernel32.dll` | `OpenProcess` | 핸들 획득 (PROCESS_SET_QUOTA 만으로 충분) |
| `ntdll.dll` | `NtSetSystemInformation` | Standby List 정리 (SystemMemoryListInformation=80) |
| `advapi32.dll` | `OpenProcessToken` / `LookupPrivilegeValue` / `AdjustTokenPrivileges` | `SeProfileSingleProcessPrivilege` 활성화 |

### 4. Claude Desktop 보존 (안전성 핵심)
사용자 시스템에는 다음이 공존:
- **Claude Code CLI** (kill 대상): `\.antigravity\extensions\anthropic.claude-code-*\`, `\Claude\claude-code\`, `\npm\node_modules\@anthropic-ai\claude-code\`
- **Claude Desktop 앱** (보존): `\WindowsApps\Claude_*\`, `\AnthropicClaude\app-*\`, `\Programs\claude-desktop\`, `\Program Files\Claude\`

→ 화이트리스트(설치 경로) + 명시적 블랙리스트 이중 안전장치.
→ 실측 검증: Desktop 앱 9/9 PID 모두 종료 대상에서 정확히 제외.

## Round 1 — 셀프 리뷰 + 실환경 검증

### 발견 이슈 (4건, 모두 수정)

1. **CRITICAL: `^claude\.exe$` 가 Claude Desktop 도 매칭**
   → 화이트리스트 (CLI 설치 경로) + 블랙리스트 (`\WindowsApps\Claude_`) 도입
2. **`AdjustTokenPrivileges` 후 `ERROR_NOT_ALL_ASSIGNED` 미감지**
   → `EnablePrivilegeChecked` 로 분리, `Marshal.GetLastWin32Error()` 명시 호출 + 주석으로 타이밍 보존
3. **`Get-Process | .Handle` 가 `PROCESS_ALL_ACCESS` 요구 → 보호 프로세스 실패**
   → `EmptyWorkingSetByPid(uint pid)` 로 분리, `OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION)` 사용
4. **`taskkill` exit 128 (이미 종료됨) 을 실패로 분류**
   → `[GONE]` 로 별도 표시, 실패 카운트 제외

### 검증
- `Test-Patterns.ps1` 실행: Claude Desktop **9/9 보존**, 자기 자신 PID 제외 PASS
- 회수 가능량 측정: **39.4 GB / 101 프로세스**

## Round 2 — Codex 독립 리뷰 + 추가 개선

### Codex 리뷰 결과
- **P0 (동작 불가)**: 0건 — 핵심 로직 검증
- **P1 (정확성)**: 3건 (모두 OK, 일부 보강)
- **P2 (개선)**: 다수 — 선별 적용

### 외부 출처로 검증된 사항 (Process Hacker phnt 헤더 / MSDN)
- `SystemMemoryListInformation = 80` (0x50) — 정확
- `MemoryPurgeStandbyList = 4` — 정확
- `EmptyWorkingSet` 권한 = `PROCESS_SET_QUOTA` + (`PROCESS_QUERY_INFORMATION` | `PROCESS_QUERY_LIMITED_INFORMATION`) — 시그니처 정확
- `SetSystemFileCacheSize((SIZE_T)-1, (SIZE_T)-1, 0)` — Windows 10 documented 동작
- `SeProfileSingleProcessPrivilege` 가 Standby Purge 의 필수 권한 — 사전 활성화 정확

### 적용한 개선 (3건)

1. **Modified Page List Flush 추가** (가장 큰 회수 효과)
   - `MemoryFlushModifiedList = 3` enum 추가
   - `FlushModifiedPageList()` API 추가
   - `Invoke-MemoryRecovery` 에서 Standby Purge **직전에** 호출
2. **NTSTATUS 친화적 메시지 매핑**
   - `Format-NTStatus` 헬퍼 함수 추가
   - `0xC0000022` → `STATUS_ACCESS_DENIED (관리자 권한 미승격?)` 등
3. **Claude Desktop 블랙리스트 보강**
   - `\Programs\claude-desktop\`, `\Program Files\Claude\Claude.exe$`, `\Program Files (x86)\Claude\Claude.exe$` 추가
   - 직접 설치 / Squirrel / 32-bit 호환 모두 커버

### 적용 보류
- `MemoryEmptyWorkingSets = 2` (NT 레벨 일괄 호출): EmptyWorkingSet 루프와 중복, 효과 미검증
- 회수 이력 CSV 로깅: 시스템 트레이 GUI 단계에서 도입 예정

## 운영 가이드 (요약)

```cmd
:: 일반 실행 (대화형 확인)
.\Run.bat

:: 사전 확인만
.\Run-DryRun.bat

:: 자동화
powershell -File .\MemoryReset.ps1 -SkipConfirmation -KeepAlive
```

## 향후 개선 (선택)

- [ ] 시스템 트레이 GUI (C# WPF, NotifyIcon) — 가용 RAM 임계치 자동 트리거
- [ ] 회수 이력 CSV 로깅 + 트렌드
- [ ] PID/제목 화이트리스트로 특정 세션만 살리는 옵션
- [ ] 작업 스케줄러 통합 (예: 30분마다 자동 실행)
- [ ] Antigravity 확장 자체 비활성화 → 종료 후 재spawn 방지 (현재 단순 재실행 권장)

## 검증 매트릭스

| 항목 | 결과 | 검증 방법 |
|------|------|-----------|
| UTF-8 BOM | OK | 바이트 0xEF 0xBB 0xBF 확인 |
| PowerShell 5.1 파스 | error 0 | `[Parser]::ParseFile` |
| C# Add-Type 컴파일 | OK | 별도 컴파일 시도 |
| Claude Desktop 보존 | 9/9 PASS | 실측 — 종료 대상에 0개 포함 |
| 자기 자신 PID 제외 | PASS | Test-Patterns.ps1 |
| 화이트리스트 매칭 | 101개 (39.4GB) | 4 카테고리 모두 정확히 분류 |
| Codex 독립 리뷰 P0 | 0건 | general-purpose agent 외부 출처 검증 |

## 참고 자료

- [MS Docs — EmptyWorkingSet](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-emptyworkingset)
- [MS Docs — SetSystemFileCacheSize](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-setsystemfilecachesize)
- [Process Hacker / System Informer phnt 헤더](https://github.com/winsiderss/systeminformer/blob/master/phnt/include/ntexapi.h)
- [Geoff Chappell — SYSTEM_INFORMATION_CLASS](https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi/system_information_class.htm)
