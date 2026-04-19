# Security Policy

## 보안 특성 (Security characteristics)

MemoryReset 는 다음 동작을 수행하는 **고권한 도구**입니다:

- 관리자 권한으로 자동 승격 (UAC)
- 임의 프로세스의 강제 종료 (`taskkill /F /T`)
- 모든 프로세스의 working set 조작 (`EmptyWorkingSet`)
- 커널 메모리 리스트 조작 (`NtSetSystemInformation`)
- `SeProfileSingleProcessPrivilege` 활성화
- System File Cache 직접 트림

스크립트 사용 전 반드시 **소스 코드 (특히 `Get-TargetProcesses` 함수)** 를 검토하세요.
배포본을 신뢰하기 어려운 경우 GitHub releases 의 SHA256 해시와 직접 다운로드한 파일의 해시를 비교하세요.

## 지원 버전 (Supported versions)

| Version | Supported |
|---------|-----------|
| 1.0.x | ✅ |
| < 1.0 | ❌ |

## 취약점 보고 (Reporting a vulnerability)

다음 경로 중 하나로 비공개 보고해 주세요:

1. **GitHub Security Advisories** (권장) — repository 의 Security 탭 → Report a vulnerability
2. GitHub Issue 로 보고하지 마세요 (공개 노출되어 악용 가능)

### 응답 시간

- 접수 확인: 5 영업일 이내
- 수정/완화 일정 공유: 14일 이내

### 보고에 포함해 주세요

- 영향받는 버전
- 재현 절차
- 영향 범위 / 위협 시나리오
- (가능하면) 제안된 수정안

## 알려진 위험 (Known risks)

| 위험 | 완화 방법 |
|------|-----------|
| Claude Desktop 앱이 잘못 종료될 가능성 | 다중 경로 블랙리스트 + `Run-DryRun.bat` 사전 확인 |
| 자기 자신(스크립트 PID) 종료 | `$PID` 명시적 제외 |
| 종료 후 자동 재실행 (Antigravity 자동 복구) | 단순 재실행으로 대응. 영구 차단은 Antigravity 설정에서 |
| 다른 사용자의 프로세스 종료 (관리자 권한 시) | 본 스크립트는 현재 사용자 프로세스만 enumerate. 다중 사용자 시스템에서는 `Get-TargetProcesses` 의 SID 필터 추가 권장 |

## 책임 한계 (Disclaimer)

본 도구는 MIT 라이선스 하에 "AS IS" 로 제공됩니다. 사용으로 인한 데이터 손실, 시스템 불안정, 작업 손실에 대한 책임은 사용자에게 있습니다. 프로덕션 환경 사용 전 반드시 테스트 환경에서 검증하세요.
