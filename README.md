# MemoryReset

> Windows 의 RAM 가용량을 **재부팅 없이** 회수하는 PowerShell 스크립트.
> Claude Code 와 Antigravity (Google 의 VS Code fork) 의 다중 세션 점유를 안전하게 해소합니다.

[한국어](#korean) · [English](#english)

---

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6?logo=windows)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Status: stable](https://img.shields.io/badge/Status-stable-success)

## 실측 결과 (Real-world result)

| 측정 시점 | 메모리 사용률 | 상황 |
|-----------|---------------|------|
| 실행 전 | **95%** | Antigravity 32 + Claude CLI 67 + helpers = 101 프로세스, ~39 GB 점유 |
| 실행 후 | **31%** | Antigravity·Claude CLI 완전 종료 + Standby/File Cache 회수 |
| **회수량** | **−64%p (~40 GB)** | 재부팅 없이, 다른 앱(브라우저·메신저 등) 영향 없이 |

> **측정 환경**: Windows 10 LTSC 2021 (build 19044, 21H2 기반) · DDR4 64 GB RAM
> **실행 시간**: 약 15초 (graceful 8초 + 회수 7초)

---

<a id="korean"></a>
## 🇰🇷 한국어

### 왜 필요한가

- **현상**: Antigravity 가 phase 마다 12 세션을 spawn 하면서 100+ `claude.exe` 프로세스가 누적 → 가용 RAM 5% 이하로 떨어짐
- **Windows 의 한계**: Linux/macOS 와 달리 종료된 프로세스의 메모리를 즉시 free list 로 반환하지 않고 Standby List / File Cache 에 유지 → 가용량 회복이 더딤
- **기존 해결책의 단점**: 재부팅은 모든 작업을 강제 종료시킴

### 어떻게 동작하나 (5 단계 파이프라인)

| 단계 | 동작 | API |
|------|------|-----|
| 1 | Claude CLI / Antigravity 의 graceful 종료 | `CloseMainWindow()` + 대기 |
| 2 | 잔존 프로세스 트리 강제 종료 | `taskkill /F /T` |
| 3 | 모든 프로세스의 Working Set 비우기 | `EmptyWorkingSet` (psapi) |
| 4 | System File Cache 트림 | `SetSystemFileCacheSize(-1, -1, 0)` |
| 5 | Modified Page List flush → Standby List 정리 | `NtSetSystemInformation` (ntdll) |

**핵심**: 5단계의 `MemoryFlushModifiedList` 를 standby purge 직전에 호출 → dirty 페이지가 standby 로 이동 후 함께 회수되어 효율 추가 향상.

### 안전성

- **Claude Desktop 앱은 절대 종료하지 않음** — 다중 설치 경로 블랙리스트 (`\WindowsApps\Claude_*`, `\AnthropicClaude\*\Claude.exe`, `\Programs\claude-desktop\*`, `\Program Files\Claude\Claude.exe`) 로 보존
- **자기 자신 PID 제외** — 스크립트가 자신을 죽이지 않도록 PID 필터
- **Graceful 우선** — 8초간 정상 종료 기회 제공 후에만 force kill
- **드라이런 모드** — `Run-DryRun.bat` 으로 어떤 프로세스가 종료될지만 미리 확인

### 빠른 시작

```cmd
:: 1. 사전 확인 (실제 종료 없음)
Run-DryRun.bat

:: 2. 본 실행 (UAC 프롬프트 → 승인)
Run.bat
```

또는 PowerShell 에서 직접:

```powershell
# 일반 실행
.\MemoryReset.ps1

# 자동화/스케줄러용
.\MemoryReset.ps1 -SkipConfirmation -KeepAlive

# 옵션
.\MemoryReset.ps1 -GracefulTimeoutSec 12 -DryRun
```

| 옵션 | 의미 | 기본값 |
|------|------|--------|
| `-GracefulTimeoutSec <n>` | CloseMainWindow 후 대기 (초) | `8` |
| `-DryRun` | 종료/회수 없이 대상만 표시 (UAC 불필요) | off |
| `-SkipConfirmation` | Y/n 프롬프트 생략 | off |
| `-KeepAlive` | 완료 후 키 입력 대기 없이 즉시 종료 | off |

### 종료 대상 식별 규칙

**Claude Code CLI** (다음 경로의 `claude.exe` 또는 `node.exe` 만):
- `%USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\`
- `%USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\`
- `%APPDATA%\Claude\claude-code\<version>\`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\`
- `--output-format stream-json` 인수를 가진 `claude.exe`
- `@anthropic-ai/claude-code` 가 커맨드라인에 포함된 `node.exe`

**Antigravity** (다음 경로의 모든 `*.exe`):
- `%LOCALAPPDATA%\Programs\Antigravity\`
- `%LOCALAPPDATA%\Google\Antigravity\`
- → Electron 의 GPU/Renderer/Utility helper, language server 모두 자동 포함

**절대 종료하지 않음** (Claude Desktop 앱):
- `\WindowsApps\Claude_*` (MSIX 설치)
- `\AnthropicClaude\app-*\Claude.exe` (Squirrel 설치)
- `\Programs\claude-desktop\*\Claude.exe` (직접 설치)
- `\Program Files\Claude\Claude.exe` (OS-wide 설치)

### 요구사항

- Windows 10 / 11
- PowerShell 5.1 이상 (Windows 기본 포함)
- 관리자 권한 (스크립트가 자동으로 UAC 승격 시도)

### 트러블슈팅

| 증상 | 원인 / 해결 |
|------|-------------|
| `NTSTATUS=0xC0000061` (Standby Purge) | `SeProfileSingleProcessPrivilege` 미보유 → 로컬 보안 정책 확인 (`secpol.msc` → 로컬 정책 → 사용자 권한 할당) |
| `NTSTATUS=0xC0000022` | 관리자 권한 미승격 → UAC 다시 승인 |
| 회수량이 작음 | Antigravity / Claude Code 외 다른 앱이 점유 중 → `Run-DryRun.bat` 으로 점유 프로세스 확인 |
| 한글 깨짐 | 콘솔 폰트를 `Consolas` / `D2Coding` 등 유니코드 폰트로 변경 |
| 스크립트가 안 뜸 | 파일이 차단됨 — 파일 우클릭 → 속성 → "차단 해제" 체크 |

### 향후 개선 (Roadmap)

- [ ] 시스템 트레이 GUI (C# WPF, NotifyIcon) — 가용 RAM 임계치 자동 트리거
- [ ] 회수 이력 CSV 로깅 + 트렌드 차트
- [ ] PID/제목 화이트리스트로 특정 세션만 살리는 옵션
- [ ] 작업 스케줄러 통합 (예: 30분마다 자동 실행)
- [ ] 영문 메시지 i18n

### 기여 / 보안 보고

- 기여 가이드: [CONTRIBUTING.md](CONTRIBUTING.md)
- 취약점 보고: [SECURITY.md](SECURITY.md)
- 개발 일지: [docs/2026-04-19-initial-development.md](docs/2026-04-19-initial-development.md)

---

<a id="english"></a>
## 🇺🇸 English

### Why

- **Problem**: Antigravity spawns 12 sessions per phase, accumulating 100+ `claude.exe` processes → free RAM drops below 5%
- **Windows constraint**: Unlike Linux/macOS, Windows retains memory in Standby List / File Cache after process termination → free memory recovers slowly
- **Status quo limit**: Reboot forces termination of all work

### How it works (5-stage pipeline)

| Stage | Action | API |
|-------|--------|-----|
| 1 | Graceful close of Claude CLI / Antigravity | `CloseMainWindow()` + wait |
| 2 | Force-kill surviving process trees | `taskkill /F /T` |
| 3 | Empty working set of all processes | `EmptyWorkingSet` (psapi) |
| 4 | Trim system file cache | `SetSystemFileCacheSize(-1, -1, 0)` |
| 5 | Flush Modified Page List → purge Standby List | `NtSetSystemInformation` (ntdll) |

**Key insight**: Stage 5 calls `MemoryFlushModifiedList` *before* the standby purge, so dirty pages are flushed to standby and reclaimed together.

### Safety

- **Claude Desktop app is never terminated** — multi-path blacklist preserves it (MSIX / Squirrel / direct install / OS-wide)
- **Self-PID exclusion** — script never kills itself
- **Graceful first** — 8-second window for normal save/cleanup before force kill
- **Dry-run mode** — preview targets via `Run-DryRun.bat`

### Quick start

```cmd
:: Preview (no termination, no admin required)
Run-DryRun.bat

:: Real run (UAC prompt → approve)
Run.bat
```

Or directly via PowerShell:

```powershell
# Interactive
.\MemoryReset.ps1

# Automation / scheduler
.\MemoryReset.ps1 -SkipConfirmation -KeepAlive

# Custom graceful timeout + dry-run
.\MemoryReset.ps1 -GracefulTimeoutSec 12 -DryRun
```

| Option | Meaning | Default |
|--------|---------|---------|
| `-GracefulTimeoutSec <n>` | Wait time after `CloseMainWindow` (seconds) | `8` |
| `-DryRun` | List targets only, no termination/recovery (no UAC needed) | off |
| `-SkipConfirmation` | Skip Y/n prompt | off |
| `-KeepAlive` | Exit immediately on completion (no keypress wait) | off |

### Requirements

- Windows 10 / 11
- PowerShell 5.1+ (built-in)
- Administrator privileges (script auto-elevates via UAC)

### Target identification rules

**Claude Code CLI** — `claude.exe` or `node.exe` from these paths only:
- `%USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\`
- `%USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\`
- `%APPDATA%\Claude\claude-code\<version>\`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\`
- Any `claude.exe` invoked with `--output-format stream-json`
- Any `node.exe` whose command line contains `@anthropic-ai/claude-code`

**Antigravity** — all `*.exe` from these paths (covers GPU/Renderer/Utility helpers and language servers):
- `%LOCALAPPDATA%\Programs\Antigravity\`
- `%LOCALAPPDATA%\Google\Antigravity\`

**Never terminated** (Claude Desktop app):
- `\WindowsApps\Claude_*` (MSIX install)
- `\AnthropicClaude\app-*\Claude.exe` (Squirrel install)
- `\Programs\claude-desktop\*\Claude.exe` (direct install)
- `\Program Files\Claude\Claude.exe` (OS-wide install)

### Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `NTSTATUS=0xC0000061` | Missing `SeProfileSingleProcessPrivilege` → check local security policy (`secpol.msc`) |
| `NTSTATUS=0xC0000022` | Not elevated → re-approve UAC |
| Low reclamation | Other apps holding memory → run `Run-DryRun.bat` to see exactly which processes are targeted |
| Korean characters garbled | Switch console font to a Unicode font (Consolas / D2Coding) |
| Script blocked | File marked as downloaded — right-click → Properties → check "Unblock" |

### License

MIT — see [LICENSE](LICENSE).

### Acknowledgments

- API references verified against [MS Docs](https://learn.microsoft.com/en-us/windows/win32/api/), [Process Hacker / System Informer phnt headers](https://github.com/winsiderss/systeminformer/blob/master/phnt/include/ntexapi.h), and [Geoff Chappell's research](https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi/system_information_class.htm).
- Inspired by Sysinternals RAMMap's standby-list purge technique.

### Disclaimer

This script forcibly terminates processes and manipulates kernel memory lists. While extensively validated (zero false positives on Claude Desktop preservation across 9 PIDs in production environment), use at your own risk. **Always run `Run-DryRun.bat` first** to verify targets in your environment.
