# Bleank

[English](README.md) | 한국어

Claude Code의 상태를 MagSafe 3 LED로 표시합니다.

| Claude 상태 | LED |
|---|---|
| 생각 중 | 주황색 점멸 |
| 응답 중 | 초록색 점멸 |
| 응답 완료 | 초록색 점등 |
| 입력 대기 (질문/권한 요청) | 주황색 점등 |
| 세션 없음 | macOS 기본 제어로 복귀 |

**빨간색이 아니라 주황색입니다.** MagSafe LED는 주황/초록 2색 부품이라 빨간색 소자가 없습니다.
더 나은 값을 찾으면 [main.swift](Sources/ClaudeLED/main.swift)의 `let amber`를 바꾸세요.

**MagSafe 연결 시에만 보입니다.** USB-C 충전 중에는 아무것도 켜지지 않습니다. MagSafe 포트가
없는 Mac에는 `ACLC` 키 자체가 없습니다(데몬이 `SMC result = 132`를 출력).

## 동작 원리

SMC 쓰기에는 root 권한이 필요하고, 점멸에는 루프가 필요합니다. 그래서 root 데몬 하나가
상태 파일을 폴링하고, 사용자 권한으로 실행되는 훅은 그 파일에 단어 하나만 씁니다.
핫 패스에 `sudo`가 없습니다.

## Pi 코딩 에이전트

Pi는 Claude Code의 `hooks.json`을 읽지 못하므로, [`.pi/extensions/claude-led.ts`](.pi/extensions/claude-led.ts)가
Pi 확장(extension)으로 훅을 동일하게 구현합니다. 상태와 상태 파일은 동일합니다:

| Pi 이벤트 | 상태 |
|---|---|
| `input`(명령어 제외), `before_agent_start`, `tool_execution_start` | thinking |
| `message_start` / `message_update` (assistant) | responding |
| `agent_settled` | done |
| `question` 도구 시작 | waiting |
| `session_shutdown` | system |

전역으로 한 번 설치하면 모든 프로젝트에서 동작합니다:

```bash
mkdir -p ~/.pi/agent/extensions && cp .pi/extensions/claude-led.ts ~/.pi/agent/extensions/
```

Pi를 재시작하거나 `/reload` 후 프롬프트를 보내보세요. 프로젝트 로컬로는 이 저장소 안에서
Pi를 실행해도 됩니다 — `.pi/extensions/`는 프로젝트 신뢰(trust) 후 자동 탐지됩니다.
Claude Code 훅과 함께 써도 무방하며, 마지막에 쓴 쪽이 이깁니다.

## 설치

```bash
tuist generate --no-open && tuist xcodebuild build -scheme ClaudeLED -destination "platform=macOS"
```

빌드 결과물은 `DerivedData/Bleank/Build/Products/Debug/claude-led`에 생깁니다. 구조체 레이아웃 가정을 확인:

```bash
./DerivedData/Bleank/Build/Products/Debug/claude-led selftest
```

MagSafe를 연결하고 하드웨어가 반응하는지 확인 — 주황, 초록, 꺼짐, 그리고 원상 복구:

```bash
sudo ./DerivedData/Bleank/Build/Products/Debug/claude-led test
```

데몬 설치:

```bash
sudo cp DerivedData/Bleank/Build/Products/Debug/claude-led /usr/local/bin/ && sudo cp com.bleank.claude-led.plist /Library/LaunchDaemons/ && sudo launchctl load /Library/LaunchDaemons/com.bleank.claude-led.plist
```

훅을 Claude Code 전역 설정에 병합(백업 먼저):

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null; jq -s '.[0] * .[1]' ~/.claude/settings.json hooks.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

Claude Code를 재시작하고 프롬프트를 보내보세요.

## 제거

```bash
sudo launchctl unload /Library/LaunchDaemons/com.bleank.claude-led.plist && sudo rm /Library/LaunchDaemons/com.bleank.claude-led.plist /usr/local/bin/claude-led
```

데몬은 종료 시 LED를 시스템 제어로 되돌립니다. `~/.claude/settings.json`에서 `hooks` 블록을 제거하세요.

## 알려진 한계

- 점멸은 1.25 Hz. SMC가 더 빠른 쓰기를 견디는지는 미검증 — `halfPeriod`.
- macOS가 충전 상태 변화 시 LED 제어를 되찾아가므로, 데몬은 변화가 없어도 5초마다 다시 씁니다.
- Claude Code 세션 두 개가 상태 파일과 LED 하나를 공유: 마지막에 쓴 쪽이 이깁니다.
- 에이전트가 세션 종료 훅 없이 죽으면(crash, `kill -9`) 상태 파일이 낡은 채 남습니다.
  10분 후 데몬이 LED를 macOS 제어로 되돌립니다 — `staleTimeout`.
