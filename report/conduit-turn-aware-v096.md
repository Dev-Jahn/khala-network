# Conduit turn-aware re-ring — 0.9.6

## 결론

Stop hook은 해석된 신원의 turn 종료를 노드 로컬 스탬프로 남기고, conduit은 이미 쓴 프레임의 사다리 기한이 지난
경우에만 이를 읽는다. 유효한 스탬프가 있는 신원은 마지막 outstanding 쓰기 이후의 turn 증거가 있어야 한 번 더
울린다. 스탬프가 없거나 잘못되었으면 0.9.5 bounded ladder를 그대로 적용한다.

스탬프 문법은 선택 필드 없이 정확히 다음 한 줄이다.

```
turn 1 <epoch>
```

Claude session id는 판정에 필요하지 않고 문법과 노출 면적만 늘리므로 넣지 않았다. Stop hook은
`khala_resolve_session 0 0`으로 SessionStart drain 경로와 같은 identity를 고른 뒤 `$KHALA_HOME/tmp`의 0600
임시 파일을 `run/turns/<identity>`로 옮긴다. `run/`과 `run/turns/`는 0700이다. CLI, 네트워크, lock, drain,
프로세스 신호를 사용하지 않는다.

## RED 증거

기준 HEAD `7153337`에 테스트만 추가한 커밋은 `8813955`다.

- Go: parked case가 `received 5 frames, want 1`, restart case가 `got 2 frames`, malformed 경고가
  `count=0 want 1`로 실패했다.
- `test/conduit.sh`: H24가 `parked session received 6 frames, want 1`로 실패했다.
- `test/plugin.sh`: case 8이 `valid Stop did not write a regular turn stamp`로 실패했다.
- RED 명령에서는 `gofmt`를 PATH export보다 먼저 호출해 `command not found`가 발생했고, 마지막 테스트 보강 때는
  `link/` 작업 디렉터리에서 다시 `link/conduit_runtime_test.go`를 지정해 `lstat` 오류가 발생했다. 두 경우 모두 테스트는
  별도로 정상 실행됐고, 포맷은 `/NHNHOME/jahn/go-toolchain/bin/gofmt`와 절대 대상 경로로 즉시 다시 수행했다.

## 속성별 결과

| 속성 | 결과 | 증거 |
|---|---|---|
| P1 parked session | PASS | Go `TestConduitTurnStampGatesEachRering`; shell H24는 26개 pending 중 1 frame 유지 |
| P2 ignored doorbell | PASS | 같은 Go 테스트와 H24에서 새 turn 하나당 re-ring 하나만 허용 |
| P3 stamp 없음 | PASS | 기존 `TestConduitBoundsUndrainedGenerationChanges`와 H23 무수정 통과 |
| P4 drain 우선 | PASS | 기존 `TestConduitDrainResetsOutstandingLadder`와 H13 무수정 통과 |
| P5 restart | PASS | `TestConduitRestartRestoresTurnGate`; 기존 H8 통과 |
| P6 hook | PASS | plugin case 8: 문법·0600/0700·overwrite·재귀/no-identity·시간·동일 resolver 확인 |
| P7 process binding | PASS | 기존 `TestConduitOutstandingStateDoesNotCrossProcesses` 무수정 통과 |
| P8 hot path | PASS | 5회 중앙값 2.601897 ms → 2.618382 ms = 1.0063x |
| P9 docs | PASS | DESIGN §9.6 layout과 §3.3 정책 갱신; README에는 현재 re-ring 설명이 없어 무변경 |

malformed regular file과 symlink는 `openRegular` 경로에서 거부하며, 신원별 로그 한 줄 뒤 stamp absent로 처리한다.
`TestConduitMalformedTurnStampFailsOpenOnce`는 기한 전 파일을 읽지 않는 것과 fail-open ladder를 함께 고정하고,
`TestConduitTurnStampRefusesSymlink`는 `O_NOFOLLOW` 거부와 로그 1회를 고정한다.

## Hot-path 측정

환경: b200, `nice -n 19 taskset -c 20-71`, `GOMAXPROCS=8`,
`go test -run '^TestConduitScanHotPathCost$' -count=5 -v .`.

| 상태 | 5회 median scan | 5개 값의 중앙값 | base 대비 |
|---|---|---:|---:|
| base `7153337` | 2.601897 / 2.587206 / 2.749518 / 2.714466 / 2.575838 ms | 2.601897 ms | 1.000x |
| after `fc3da9d` | 2.618382 / 2.407917 / 2.356269 / 2.683890 / 2.662738 ms | 2.618382 ms | 1.0063x |

## 의도적으로 제외한 것

- ladder 상수, frame 문법, `from:` sender, drain-stamp 계약은 바꾸지 않았다.
- `.ear` 형식과 버전 문자열, CLI 복사본, channel server, dashboard는 바꾸지 않았다.
- Stop hook은 drain이나 CLI 호출을 하지 않으며 turn stamp는 복제하지 않는다.
- restart용 sidecar 필드는 추가하지 않았다. 기존 journal의 outstanding write 시각과 디스크 stamp만 사용한다.
- journal retention은 별도 `fix/deliveries-retention` 작업으로 남겼다.

## 검증 기록

- 구현 전 기준 성능: PASS, 위 표 참조.
- RED Go/H24/plugin: 예상 실패, 위 RED 증거 참조.
- 구현 후 targeted Go turn/drain/restart/process tests: PASS.
- 구현 후 `test/conduit.sh`: `RESULT: PASS`, H1–H24 PASS.
- 최종 `go vet ./...`: PASS (stdout 없음).
- 최종 `go test -p 2 ./...`: PASS, `ok github.com/Dev-Jahn/khala-network/link 7.049s`.
- 최종 `test/plugin.sh`: `RESULT: PASS`; Stop hook 22 ms; 모든 내장 회귀 suite PASS.
- 최종 `test/channel.sh`: `RESULT: PASS`.

## stdout summary

```
RESULT: PASS
Conduit H1-H24 delivery, channel routing, lease, hook, restart, watch, runtime, ears, and dashboard properties passed

RESULT: PASS
Claude Code plugin conduit hooks, lease lifecycle, and regressions passed

RESULT: PASS
Channel E1 opt-in/capability gate plus H21 fast, late-resume, socketpair EOF, re-attach, stale-env, env-fallback, tools, doorbell, and cleanup properties passed
```
