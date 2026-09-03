# GPT Pro (GPT-5.6 Sol, effort pro) — D15 r0 자문 회신 (2026-08-15)

> 질문 원문: `.hippo/briefs/`가 아니라 스크래치에서 발사됨 — 아래 §0에 질문 요지 첨부. 회신 원문은 그대로.

## §0 질문 요지

> # Consultation: redesigning khala's "last mile" around Claude Code's native session inbox socket
> 
> You are advising on a design decision for **khala-network**, a small store-and-forward mail system that links Claude Code (CC) sessions across a fleet of ~6 personal machines (Linux servers, macOS, WSL) with no shared filesystem, split across two tailnets, and — a first-class requirement — **independent of which Anthropic account each machine uses**. It exists because CC's built-in cross-session messaging is same-machine-only (unix socket) or goes through Anthropic servers (Remote Control, account-bound).
> 
> Please think hard and answer the concrete questions at the end. Be adversarial toward my proposal; I want to know where it breaks. Do not restate my facts back to me at length.
> 
> ## Established facts (measured, not speculation)
> 
> **khala today (v0.4.2, bash + a Go "link" process):**
> - Every node has `~/.khala/` (a "brain"): maildir-style `inbox/<session>/{new,cur}`, `outbox`, `streams/`, `presence/`, `minds/`. A durable letter = an immutable file, addressed `session@node`. Delivery is at-least-once, receiver-idempotent by Id.
> - Between nodes, a Go daemon `khala-link` (one per node, spokes dial the hub over ssh/tailnet) replicates immutable objects and installs letters into the receiving node's brain. That part works: 20+ letters/day between two nodes, zero loss/dup, sub-second when both are up. Nothing here needs to change.
> - **The broken part is the last mile — how a letter that has landed on disk reaches the *live CC session* it is addressed to.** Today: each session runs a foreground-blocking `khala watch` in CC's `run_in_background` Bash. When a letter lands, `watch` *exits*, which is the only way to make CC wake the session (a background command finishing = a notification). The session then runs `khala inbox --drain` and must re-arm a new `watch`. A Stop hook blocks the session from resting until the watch is re-armed.
> … (A–F 여섯 질문: hold 정책 / 비공식 와이어·ack / late-bind·다중 신원 / priority / herald 위치 / 놓친 것)

## 회신 원문

# 1. 판정

## **GO-with-changes**

**가장 강한 이유:** daemon-as-ear 자체는 현재의 arm/re-arm lifecycle 결함을 제거하지만, **소켓 write 성공을 delivery commit으로 간주하면 durable store-and-forward를 best-effort IPC 수준으로 강등**시킵니다.

반드시 다음 불변식을 가져야 합니다.

```
inbox/new/<letter-id>          ← authoritative, 아직 미소비        │        ├─ socket notify 성공  ← 그대로 new에 남음        ├─ hold/refuse/drop    ← 그대로 new에 남음        ├─ CC/session crash    ← 그대로 new에 남음        └─ receiver ack/drain  → inbox/cur/<letter-id>
```

즉, **CC socket은 lossy doorbell**이고, `~/.khala`가 계속 source of truth여야 합니다. 이 변경을 받아들이면 GO입니다. 현재 제안처럼 write 직후 `new→cur`라면 NO-GO입니다.

초기 릴리스에서는 full letter injection보다 다음과 같은 coalesced notification만 보내는 편이 안전합니다.

```
KHALA-NOTIFY/1recipient: eddygeneration: sha256:...pending: 3ids: id-1,id-2,id-3attempt: 7f0c...
```

Claude에는 plugin instruction으로 `khala inbox --drain --generation ...`을 실행하도록 알려줍니다. `attempt`만 재시도마다 바꾸고, letter ID는 안정적으로 유지합니다.

---

# 2. A–F

## A. Hold policy

### 권고

Socket 기반 D15를 지금 배포한다면 **문서화된 `crossSessionInbound: "accept"`를 사용**하는 쪽이 token 전달보다 견고합니다. 가능하면 khala용 launcher의 `--settings`로 session-scoped하게 설정하고, 그 운영 모델이 불가능하면 user setting으로 명시적으로 설정하십시오. Project/local setting은 더 관대한 `accept`를 강제하는 신뢰 경계로 사용할 수 없습니다. [![](https://www.google.com/s2/favicons?domain=https://docs.anthropic.com&sz=128)Claude Platform Docs](https://docs.anthropic.com/en/docs/claude-code/settings)

다만 보안 경계를 정확히 정의해야 합니다.

`accept`는 “khala herald만 허용”이 아닙니다. 공식 문서는 이를 전체 inbound cross-session peer 정책으로 설명하며, same-machine peer는 local socket을 사용하지만 타 머신 peer는 Remote Control을 통해 Anthropic 경로로 도착합니다. 따라서 `accept`를 **same-UID local process만 추가 신뢰하는 설정**으로 간주해서는 안 됩니다. 문서 구조상 local poster뿐 아니라 해당 session에 도달 가능한 다른 cross-session peer도 자동 수락 대상으로 보는 것이 안전한 해석입니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude](https://code.claude.com/docs/en/cross-session-messaging)

권장 의사결정은 다음과 같습니다.

| 환경 | 선택 |
| --- | --- |
| 개인 단독 UID, 모든 로컬 프로세스와 Remote Control peer를 신뢰 | `accept` 사용 가능 |
| 같은 UID로 untrusted build/plugin/application을 실행 | 전역 `accept` 부적절 |
| Remote Control/account compromise를 별도 위협으로 취급 | 전역 `accept` 부적절 |
| 위 신뢰 확대를 허용할 수 없음 | CC-managed Channel 또는 session-local child relay 사용 |

### Token 전달은 주 경로로 쓰지 말 것

공식 계약은 token을 “자기 session의 hook/Bash child가 자기 socket에 게시하는 경우”에 한정해 설명합니다. Linux/WSL에서는 process evidence를 사용할 수 있고, macOS에서는 child가 종료된 후처럼 ancestry evidence가 없을 때 token을 사용합니다. Resident herald에 token을 넘기는 행위가 현재 구현에서 동작할 수는 있어도, **non-child daemon을 own-child로 승격하는 capability delegation은 문서화된 의미가 아닙니다.** [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude+1](https://code.claude.com/docs/en/cross-session-messaging)

추가 문제도 있습니다.

- Session별 secret을 registration file에 저장하게 됩니다.
- stale registration, backup, 잘못된 replication scope, 로그를 통한 유출면이 생깁니다.
- Anthropic이 token과 process ancestry를 동시에 검증하도록 강화하면 즉시 중단됩니다.
- Linux와 macOS의 동작이 달라질 수 있습니다.

따라서 token mode는 **실험용 compatibility mode**로만 두고 기본값으로 삼지 마십시오.

### 정책이 변경되는 날의 동작

Herald는 다음과 같이 fail-safe해야 합니다.

1. Registration에 `ccVersion`, `adapterVersion`, `sessionInstanceId`를 기록합니다.
2. 알려지지 않은 CC version에는 full body를 보내지 않고 harmless doorbell만 시험합니다.
3. hold/refuse/unknown 또는 status 부재는 `new` 상태를 바꾸지 않습니다.
4. 일정 횟수 실패 후 해당 session을 `native-degraded`로 표시합니다.
5. `khala status`와 다음 SessionStart에서 한 번만 명시적으로 경고합니다.
6. 이후 delivery는 SessionStart drain으로 저하되며, silent loss는 발생하지 않습니다.

### 실패 모드

- **`accept` 없이 non-child herald 사용:** bypass session에서 hold 후 expiry/drop.
- **token laundering 의존:** CC 정책 강화 또는 플랫폼 차이로 갑작스러운 전면 중단.
- **global `accept`:** same-UID 또는 Remote Control peer가 bypass session에 prompt를 삽입할 수 있는 신뢰 확대.
- **실패를 감지하지 않고 `cur`로 이동:** 완전한 silent loss.

---

## B. Undocumented wire protocol과 ack

### 권고

**Socket write를 ack로 취급하지 마십시오.** Unix domain stream write 성공은 kernel이 bytes를 받았다는 의미에 가깝고, 다음을 증명하지 않습니다.

- JSON frame을 CC가 parse했는가
- auth/policy를 통과했는가
- accepted queue에 들어갔는가
- rate limit/dedup에 걸리지 않았는가
- model turn에 포함되었는가
- session이 enqueue 직후 종료되지 않았는가

따라서 세 상태를 분리해야 합니다.

```
transport attempt     herald가 socket write 시도transport observation CC status frame 등으로 hold/refuse/accepted 관측consumer ack          khala inbox/ack가 letter를 소비했다고 확정
```

권장 저장 구조는 다음과 같습니다.

```
inbox/<identity>/new/<letter-id>deliveries/<identity>/<session-instance>/<attempt-id>.json{  "letterIds": [...],  "attemptedAt": "...",  "ccVersion": "...",  "socketResult": "written|failed",  "peerStatus": "accepted|held|refused|unknown"}
```

`deliveries/` journal은 delivery telemetry이며, `new/`의 소유권을 변경하지 않습니다.

### v1에서는 doorbell만 보내는 것이 낫다

당장 full body를 socket frame에 싣지 마십시오.

1. Herald가 pending letter IDs와 generation만 보냅니다.
2. Model이 기존 `khala inbox --drain`을 실행합니다.
3. 기존 drain path가 `new→cur`와 end-to-end ack를 담당합니다.
4. Herald는 pending generation이 바뀔 때까지 한 개의 outstanding wake만 유지합니다.

이 방식은 arm/re-arm을 완전히 제거하면서 기존 durability semantics를 거의 그대로 유지합니다.

Full body inline이 반드시 필요하다면 다음 단계가 추가로 필요합니다.

- Frame에 안정적인 `Letter-Id` 포함.
- Model이 `khala ack <id...>`를 호출하도록 plugin-level instruction 제공.
- `ack`는 idempotent.
- 자연어 reply는 ack로 인정하지 않음.
- ack 전까지 재시도 가능.
- 재시도 frame에는 새로운 `Attempt-Id`를 넣어 CC identical-content dedup을 피함.

**Model의 답장 자체를 ack로 쓰는 것은 부적절합니다.** 답장은 일부 letter만 처리했거나, ID를 누락했거나, 별도 대화에 대한 응답일 수 있습니다.

### `peer_message_status`

확인할 가치는 높지만, durability primitive로 사용해서는 안 됩니다. 다음 black-box matrix를 먼저 돌려야 합니다.

- `accept`, default hold, explicit hold, refuse
- accepted queue full
- rate limit
- socket write 직후 session kill
- 동일 `msg_id` 재시도
- 동일 content + 다른 `msg_id`
- Linux, WSL, macOS
- interactive, `-p`

확인되더라도 `peer_message_status=delivered`는 우선 **CC transport acceptance**로만 정의하십시오. `new→cur`의 근거로 쓰지 말고 retry suppression과 diagnostics에만 사용해야 합니다.

공식 Channel API도 notification write 완료와 Claude 처리 완료를 구분하며, 처리 ack가 필요하면 별도 reply tool/state tracking을 사용하라고 명시합니다. 이는 socket path에서도 동일한 경계를 적용해야 한다는 강한 설계 신호입니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude+1](https://code.claude.com/docs/en/channels-reference)

### “write 후 cur + SessionStart safety net”은 충분한가

**충분하지 않습니다.**

SessionStart가 `new/`만 drain한다면, write 직후 `cur/`로 이동한 letter는 더 이상 safety net의 대상이 아닙니다. 이를 보완하려고 SessionStart가 “unacked cur”까지 다시 읽게 만들면 `cur`의 의미가 깨집니다. 별도 attempt journal을 두는 편이 명확합니다.

### 실패 모드

- CC가 frame을 drop했지만 herald가 `cur`로 이동: silent loss.
- herald crash가 write 직후 발생: journal 여부에 따라 duplicate 또는 loss.
- 동일 frame retry가 CC dedup에 걸림: pending인데도 wake가 재발하지 않음.
- retry nonce를 무제한 변경: duplicate prompt flood.
- model reply를 ack로 간주: 일부 letter가 처리되지 않았는데 소비 처리.

---

## C. Late bind, registration race, duplicate identity

### 권고: registration을 identity 파일 하나로 만들지 말 것

다음 구조가 필요합니다.

```
runtime/sessions/<session-instance-uuid>.jsonruntime/identities/<identity>.lease
```

예시:

```
JSON{  "identity": "eddy",  "sessionInstanceId": "random-per-process",  "claudeSessionId": "stable-conversation-id",  "pid": 12345,  "pidStart": "...",  "socketPath": null,  "kind": "interactive",  "phase": "starting",  "startedAt": "...",  "ccVersion": "2.1.233"}
```

`<identity>`라는 단일 filename은 두 번째 claimant가 첫 번째 registration을 덮어쓰므로 사용하면 안 됩니다.

### Late bind 처리

SessionStart 시 socket 변수가 없다면:

1. `socketPath:null`, `phase:"starting"`으로 등록합니다.
2. Herald는 CC session registry create/modify를 감시하고 주기적으로 rescan합니다.
3. socket이 나타나면 registration에 resolved path를 연결합니다.
4. `ENOENT`, `ECONNREFUSED` 시 cached path를 폐기하고 registry를 다시 읽습니다.
5. backoff는 짧게 시작하되 장기 polling으로 전환합니다.
6. 이 기간에도 letter는 `new/`에 남습니다.

권장 backoff 예시는 `100ms → 300ms → 1s → 3s → 10s → 30s`입니다. 새 registry event 또는 새 letter arrival 시 즉시 retry할 수 있습니다.

Socket path를 PID로 직접 재구성하지 마십시오. `TMPDIR`, `CLAUDE_CODE_TMPDIR`, launchd 환경, path-length handling이 달라질 수 있습니다. 공식 문서도 cold-start feature flag 때문에 SessionStart 시 변수가 없고 이후 bind될 수 있음을 명시합니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude+1](https://code.claude.com/docs/en/cross-session-messaging)

### PID liveness만으로 prune하지 말 것

`kill(pid, 0)`만 사용하면 PID reuse 때문에 wrong-session delivery가 가능합니다. 최소한 다음을 묶어 검증해야 합니다.

- PID
- process start time
- Claude session ID
- socket path
- socket owner UID
- registration instance UUID

Registration file은 temp-write + fsync + atomic rename으로 갱신해야 합니다.

### 같은 identity를 두 session이 claim하는 경우

기본 정책은 **exclusive lease + collision stop**이어야 합니다.

- 첫 live claimant가 owner.
- 두 번째 claimant는 receive-disabled.
- 두 session 모두 collision 경고를 받음.
- `khala bind --takeover` 또는 별도 identity로 명시적 해결.
- owner가 실제로 종료되면 lease epoch를 증가시키며 자동 승계.
- `fanout`은 명시된 letter 또는 stream에서만 허용.

**Deliver-to-all은 기본값으로 부적절합니다.** 같은 작업 지시가 두 agent에서 실행되어 중복 commit, 파일 충돌, 중복 외부 side effect가 발생할 수 있습니다.

**Newest-wins도 부적절합니다.** 잠깐 실행된 `claude -p`, fork, 잘못 resume된 session이 기존 interactive owner를 탈취할 수 있습니다.

### Startup drain과 herald의 이중 delivery race

SessionStart hook이 pending mail을 drain하는 동안 herald가 registration을 보고 같은 letter를 inject할 수 있습니다. Registration phase가 필요합니다.

```
starting → SessionStart drain 완료 → ready
```

Herald는 `ready` session에만 wake를 보냅니다. Hook이 중간에 죽으면 timeout 후 `degraded-ready`로 전환하되 letter는 그대로 유지합니다.

### 실패 모드

- identity filename overwrite: wrong session 또는 한 session 누락.
- PID reuse: 완전히 다른 CC process에 delivery.
- newest-wins: transient worker가 mail 탈취.
- deliver-to-all: 중복 실행.
- SessionStart drain과 herald 동시 동작: 같은 letter 두 번 전달.
- stale socket path reuse: 새 session에 잘못된 편지 전달.

---

## D. Priority와 turn boundary

### 권고

**일반 letter의 기본값은 `later`가 맞습니다.**

Khala letter는 interrupt가 아니라 mail입니다. Tool call 하나가 아니라 **turn 전체를 application-level transaction boundary**로 보는 것이 더 안전합니다. `next`는 실행 중인 단일 tool을 끊지는 않지만, agentic turn의 두 tool call 사이에 새 목적을 삽입합니다. 공식 문서도 일반 cross-session message가 active turn의 tool call 사이에 읽히며, 실행 중인 tool 자체는 중단하지 않는다고 설명합니다. 즉, OS-level interruption은 아니지만 plan-level interleaving은 발생합니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude](https://code.claude.com/docs/en/cross-session-messaging)

권장 mapping:

| Khala 의미 | CC priority |
| --- | --- |
| 일반 letter | `later` |
| dependency invalidation, 다음 tool 전에 반드시 봐야 함 | `next` |
| “중단하고 확인” 성격의 operator control | `now` |
| 일반 stream | 전송하지 않음 |
| `Wake: yes` stream | 기본 `later` |
| 명시적 emergency stream | ACL 확인 후 `next` |

`now`/`next`는 remote sender가 임의로 지정하게 하지 말고 local policy가 mapping해야 합니다. `Wake`, `Priority`, `Interrupt` 같은 control header는 authenticated envelope field여야 하며 body text에서 파싱하면 안 됩니다.

### `later`로 잃는 것

- 현재 turn이 긴 경우 coordination latency가 길어집니다.
- 장시간 agent loop에서는 메시지가 상당 시간 지연될 수 있습니다.
- “그 파일을 더 수정하지 마라” 같은 dependency invalidation이 늦을 수 있습니다.
- `-p`가 현재 turn 종료와 함께 process를 종료하면 처리 기회가 없을 수 있습니다.

따라서 `next`는 제거하지 말고 **명시적 urgency class**로 유지해야 합니다.

자동으로 일정 시간 후 `later→next` 승격하는 정책은 초기 버전에서는 권하지 않습니다. 재현하기 어려운 context interruption을 다시 만듭니다.

### 실패 모드

- 모든 letter를 `next`: turn 계획 오염, partial commit sequence, 불필요한 context switching.
- 모든 letter를 `later`: 긴 turn에서 coordination starvation.
- sender-controlled `now`: prompt-based denial of service.
- `now`를 hard cancel로 오해: 실행 중 tool이나 외부 process는 실제로 중단되지 않을 수 있음.

---

## E. Go link daemon에 넣을 것인가

### 권고

**별도 process인 `khala-herald`로 분리하되, 같은 Go module 또는 같은 binary의 subcommand로 배포**하십시오.

```
khala-link     network replication, node reconciliationkhala-herald   local session registry, CC adapter, wake journal
```

또는 하나의 binary:

```
khala node-linkkhala node-heraldkhala node ensure
```

분리 이유는 기능적 미학이 아니라 failure containment입니다.

- CC protocol parser/policy 변경이 network replication을 죽이면 안 됩니다.
- malformed registration/frame 처리 panic이 link를 중단시키면 안 됩니다.
- herald의 file descriptor leak나 retry storm이 inter-node transfer를 막으면 안 됩니다.
- link는 안정적인 durable transport이고, herald는 불안정한 vendor adapter입니다.
- 각각 독립적으로 restart/update/disable할 수 있어야 합니다.

Cross-session messaging은 2026년 8월 7일 v2.1.224에서 추가된 뒤, 8월 8일 headless hold 처리, 8월 11일 startup inbox, 8월 13일 socket hardening 등 관련 수정이 연속적으로 들어갔습니다. 이것은 현재 adapter의 변화율이 link보다 훨씬 높다는 직접적인 신호입니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude+1](https://code.claude.com/docs/en/changelog)

### Reconcile ownership

Reconcile은 기존처럼 `khala-link` 한 process만 소유하게 두는 것이 낫습니다. Herald는 다음만 수행합니다.

- inbox directory event 감시
- periodic pending rescan
- session registration 관리
- wake attempt journal
- socket/channel delivery

Link가 죽어도 이미 도착한 local pending letter는 herald가 전달할 수 있고, herald가 죽어도 link는 새 letter를 안전하게 spool할 수 있습니다.

### Process supervision

“SessionStart가 최초 daemon을 시작하고 daemon이 outlive한다”는 것은 service manager가 없으면 충분히 강한 보장이 아닙니다. 기존 watcher와 마찬가지로 process-tree cleanup, terminal teardown, logout에 연루될 수 있습니다.

권장 순서:

- macOS: LaunchAgent
- Linux: `systemd --user`
- WSL with systemd: `systemd --user`
- 그 외 WSL: locked `setsid`/double-fork fallback
- SessionStart: daemon을 직접 child로 장시간 소유하지 말고 service `ensure`만 수행

### Bash가 아닌 Go

Bash 구현은 다시 watcher lifecycle, quoting, partial JSON, concurrent registration, filesystem event handling 문제를 가져옵니다. Herald는 Go가 맞습니다.

### 실패 모드

- 동일 process: herald adapter crash가 network delivery까지 중단.
- 동일 release cadence: CC patch 대응 때문에 stable link를 매번 재배포.
- hook child로만 daemonize: session/process tree 종료 시 함께 사망.
- 두 process가 reconcile: 다시 node-wide lock contention 발생.

---

## F. 추가로 빠진 문제

| 문제 | 실패 형태 | 요구되는 통제 |
| --- | --- | --- |
| **Full body를 그대로 high-priority prompt로 삽입** | remote prompt injection이 bypass session에서 즉시 tool action을 유도 | sender/node ACL, 가능하면 envelope signature, body와 control metadata 분리 |
| **`from`을 인증 정보로 취급** | forged sender 표시와 잘못된 신뢰 판단 | `from`은 display-only. 실제 인증은 khala envelope/transport에서 수행 |
| **Reply footer를 매 letter에 추가** | body가 footer를 spoof하거나 model이 native `SendMessage`로 답장 시도 | reply 규칙은 plugin instruction에 고정하고 `khala reply`/MCP tool 제공 |
| **등록 파일이 `~/.khala/run`에 존재** | stale state, backup/replication, token 유출 | `$XDG_RUNTIME_DIR/khala` 또는 secure per-user runtime dir 사용. boot ID 포함 |
| **SessionEnd cleanup 신뢰** | SIGKILL/crash에서 stale registration 잔존 | SessionEnd는 optimization. PID start time/socket/session ID 검증이 authoritative |
| **한 letter당 한 frame** | queue cap, rate limit, token 비용, wake storm | identity/session당 outstanding wake 1개. 여러 letter를 generation으로 coalesce |
| **CC dedup 의존** | legitimate retry가 사라지거나 구현 변경 시 duplicate | stable Letter-Id + unique Attempt-Id. khala 자체 idempotency가 authoritative |
| **retry마다 sender를 변경** | CC rate limit 우회 및 queue flood | sender identity는 안정적으로 유지. backoff와 per-identity quota 적용 |
| **frame size 무제한** | parser rejection, memory pressure, oversized prompt | UTF-8 검증, byte cap, subject/ID preview. 큰 body는 `khala show`로 fetch |
| **body에 XML-like delimiter 포함** | wrapper boundary confusion 또는 prompt spoofing | body quoting/escaping, 최대 길이 제한, local-generated header/footer 분리 |
| **`-p`가 interactive identity를 상속** | transient worker가 exclusive lease를 획득하고 mail을 소비한 뒤 종료 | `-p`, fork, background worker는 receive opt-in. 기본 interactive-main only |
| **`--bare` 또는 feature-disabled session** | registration은 있으나 socket이 영원히 없음 | capability를 명시적으로 기록하고 disk-only fallback |
| **macOS event watcher 의존** | kqueue/FSEvents coalescing으로 arrival event 누락 | event는 optimization. 주기적 full rescan 필수 |
| **TMPDIR/socket path 재구성** | launchd와 shell의 temp root 차이로 wrong/missing path | registration에 전달된 exact path 또는 CC registry 사용 |
| **herald crash 직후 재시작** | 동일 frame 재전송 | attempt intent를 먼저 journal하고 ambiguous attempt는 idempotent retry |
| **startup hook와 herald 경쟁** | 동일 pending mail 이중 전달 | registration `starting/ready` phase와 startup generation barrier |
| **stream folding cursor 없음** | 같은 stream이 반복 첨부되거나 영구 누락 | identity 또는 session-instance별 stream watermark |
| **기존 e2e ack와 read ack 혼합** | sender가 “brain 설치”와 “model 소비”를 구분하지 못함 | `transport-ack`, `local-accepted`, `consumed/read` semantics 분리 |
| **CC auto-update 무관심** | wire field 변경 후 조용한 중단 | version-tagged adapter, black-box compatibility suite, degraded state |
| **관측성 부족** | held/refused/queue full을 “메일 없음”으로 오판 | `khala status`: pending, owner, adapter version, last attempt/status/ack 표시 |

특히 `-p`와 `--bare`는 별도 정책이 필요합니다. 공식 문서상 `-p`는 socket을 bind하지만 approval dialog를 표시할 수 없고, `--bare`는 socket을 bind하지 않습니다. 따라서 `-p`는 explicit `accept`와 unique identity가 있을 때만 receiver로 활성화하는 편이 안전합니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude](https://code.claude.com/docs/en/cross-session-messaging)

또한 native inbox availability 자체가 provider 및 feature-flag evaluation에 의존합니다. Bedrock, Google Cloud Agent Platform, Microsoft Foundry 등에서는 cross-session messaging을 사용할 수 없고, 일부 telemetry/feature-flag 관련 환경 변수도 기능을 비활성화할 수 있습니다. Herald가 “late bind 중”과 “이 session에서는 영구적으로 unavailable”을 구분하지 못하더라도, 적어도 일정 시간 후 명시적인 degraded 상태로 전환해야 합니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude](https://code.claude.com/docs/en/cross-session-messaging)

---

# 3. 릴리스 전 필수 invariant

다음 조건을 모두 만족하기 전에는 기존 watch path를 제거하지 않는 것이 좋습니다.

1. Socket write 경로 어디에도 `new→cur`가 없다.
2. Unknown CC version에서도 letter는 `new`에 남는다.
3. Identity collision 시 자동 delivery가 중단된다.
4. `-p`/fork는 명시적 opt-in 없이는 identity owner가 될 수 없다.
5. Session별 outstanding wake는 최대 1개다.
6. Retry마다 Letter-Id는 동일하고 Attempt-Id만 바뀐다.
7. SessionStart drain과 herald 사이에 startup barrier가 있다.
8. Token이 brain, log, backup, replication 대상에 들어가지 않는다.
9. Herald crash와 link crash가 서로를 종료시키지 않는다.
10. Linux, WSL, macOS에서 kill/write/restart fault-injection test를 통과한다.

---

# 4. 더 단순한 대안: CC Channel 기반

1. `khala-channel`을 custom Claude Code Channel/MCP plugin으로 구현합니다.
2. CC가 session별 child process를 직접 spawn하고 stdio lifecycle을 관리합니다.
3. Channel child는 identity와 session instance를 local herald에 등록합니다.
4. Herald는 여전히 node당 하나이며 brain을 감시합니다.
5. Pending letter를 Channel child에 전달하고, child는 공식 `notifications/claude/channel` event를 emit합니다.
6. `khala_ack`와 `khala_reply` MCP tool을 노출합니다.
7. Ack 전까지 letter는 `new`에 유지합니다.
8. `crossSessionInbound`, socket token 전달, undocumented peer frame이 모두 사라집니다.
9. Cross-machine backbone은 기존 khala-link이므로 account-independent 조건도 유지됩니다.
10. 단점은 Channels가 research preview이고 session별 `--channels` opt-in이 필요하며, custom channel은 현재 allowlist/development flag 제약이 있다는 점입니다. [![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude+2![](https://www.google.com/s2/favicons?domain=https://code.claude.com&sz=128)Claude+2](https://code.claude.com/docs/en/channels-reference)
11. 따라서 **즉시 배포용은 coalesced socket doorbell**, 중기 목표는 Channel adapter가 적절합니다.
