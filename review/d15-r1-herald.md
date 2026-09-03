# D15 r1 — 귀는 노드가 갖는다: herald + CC 인박스 도어벨 (2026-08-15)

> 계보: r0 초안(`d15-herald-draft.md`) → GPT Pro 자문(`gpt-pro-d15-review.md`, GO-with-changes)
> → **r1 = 자문 접합·규범화.** 함대 VOC 6통 반영. 다음: eddy 게이트 → 유저 결정.
> 정직성 문면: r0의 "소켓 쓰기 성공 = 배달"은 **철회**한다(자문 판정 NO-GO 조건).

## 0. 한 문장

**CC 세션 인박스 소켓은 초인종(lossy doorbell)이고, `~/.khala/inbox/<id>/new/`가 편지의
진실이다.** 노드 상주 herald가 새 편지를 보면 그 신원의 살아 있는 세션 소켓을 한 번
누른다(어떤 편지가 몇 통 기다리는지 한 줄). 세션은 다음 턴 머리에 그 초인종을
`<cross-session-message>`로 보고 `khala inbox --drain` 한 번으로 읽는다 — 그 drain이
지금처럼 `new→cur`와 e2e ack를 담당한다. 세션은 아무것도 무장하지 않는다.

왜 초인종이지 편지 본문이 아닌가: 본문을 프레임에 실으면 모델이 읽은 뒤 `khala ack`를 따로
쳐야 한다(1 tool call). 초인종이면 `drain` 한 번이 읽기+ack다(1 tool call). **비용은 같고,
초인종 쪽만이 소켓이 프레임을 버려도(hold/거부/파싱 변경/세션 크래시) 편지를 잃지 않는다.**
"native처럼"의 실체는 "무장 없이, 다음 턴 머리에, 대화 안으로 도착"이며 초인종이 그것을 준다.

## 1. 뿌리 문장 증보 (r17 + D14 문장에 한 절 추가)
> …**세션은 귀를 갖지 않는다. 귀는 노드가 갖는다(herald). 편지의 마지막 한 뼘은 CC의
> 세션 인박스 소켓이지만 그것은 초인종일 뿐 — `new/`의 편지는 소비자(drain)만 옮긴다.**

## 2. 구성 요소

| 이름 | 무엇 | 어디·수명 |
|---|---|---|
| **khala-herald** | 노드 상주 귀. `inbox/*/new` 감시(inotify + 주기 재스캔) → 신원별 lease 소유 세션의 소켓에 도어벨. wake 시도 저널. | Go, `khala-link`와 **별도 프로세스**(같은 바이너리 서브커맨드 가능). 노드 수명. `systemd --user`(Linux/WSL) / LaunchAgent(macOS) / 그 외 setsid 폴백. |
| **khala-link** | 지금 그대로: 노드 간 복제 + **reconcile 유일 소유자** | 변경 없음 |
| **registration** | 세션 인스턴스 파일 `$XDG_RUNTIME_DIR/khala/sessions/<instance-uuid>.json` (identity, pid, pidStart, claudeSessionId, socketPath|null, kind, phase, ccVersion, startedAt) | 세션 수명. tmp+fsync+rename. `~/.khala/run`이 아니라 runtime dir(백업·복제 밖). |
| **identity lease** | `$XDG_RUNTIME_DIR/khala/identities/<identity>.lease` — 배타 소유(첫 live claimant), epoch | 소유자 종료 시 승계 |
| SessionStart 훅 | (a) 신원: `KHALA_SESSION`→`.khala-session`→**거부+안내**(cwd 추론 폐지) (b) registration `phase:starting` (c) 밀린 편지 드레인(기존) (d) `phase:ready` (e) `khala node ensure`(herald·link 서비스 ensure만, 자식으로 소유하지 않음) | 1회 |
| Stop 훅 | **재무장 block 삭제.** 아무것도 안 함(또는 삭제) | — |
| SessionEnd 훅 | registration 제거 (최적화; 권위는 pid+start time+socket 검증) | 1회 |
| 플러그인 스킬 문서 | "초인종 `<cross-session-message from="khala:…">`이 오면 `khala inbox --drain`" 규칙 고정. reply 규칙도 문서에(편지마다 꼬리 안 붙임). | — |

## 3. 편지 한 통의 여정 (r1)
1. `khala send eddy@b200 …` → 발신 노드 outbox → link → b200 `inbox/eddy/new/<Id>`. (변경 없음)
2. herald: 이벤트 → `identities/eddy.lease` 소유자 registration → `phase==ready` && 소켓 존재 && pid·pidStart·claudeSessionId 일치 확인.
3. **도어벨 프레임** 1개(세션당 outstanding 1개, generation = pending Id 집합 해시):
   ```
   {"type":"user","message":{"role":"user","content":"KHALA-NOTIFY/1\nrecipient: eddy@b200\npending: 3\nfrom: reel@bw2, clawd@mini\nsubjects: [VOC] bw2/reel; Re: 개울 이사; …\ngeneration: <sha>\nattempt: <uuid>\nread: khala inbox --drain"},"from":"khala:herald@b200","priority":"later","msg_id":"<generation>:<attempt>"}
   ```
   `from`은 표시용. 본문 미리보기는 UTF-8 검증·바이트 상한·XML류 구분자 이스케이프.
4. 소켓 쓰기 결과는 `deliveries/<identity>/<instance>/<attempt>.json`에 저널만(`written|failed`, `peerStatus: accepted|held|refused|unknown`). **`new/`는 건드리지 않는다.**
5. 세션 다음 턴 머리(`later`): 초인종을 보고 `khala inbox --drain` → 기존 경로가 `new→cur` + ack.
6. drain이 T 안에 안 일어나면(generation 그대로) 백오프 재시도 — Letter-Id 동일, attempt만 갱신(CC 동일내용 dedup 회피). 새 편지 도착 → generation 바뀜 → 즉시 새 초인종.
7. 소켓 없음/거부/알 수 없는 CC 버전 → 저널에 남기고 편지는 `new/`. N회 실패 시 그 세션 `native-degraded` 표시, `khala status`와 다음 SessionStart에서 한 번 경고. SessionStart 드레인이 안전망(지금과 동일).
8. 스트림 항목: 기본 wake 안 함. 도어벨의 `pending`에 "스트림 N건"만 부기(신원별 watermark). `Wake: yes`는 **인증된 envelope 필드**일 때만 편지처럼(본문 파싱 금지).

## 4. 정책 결정 (자문 채택)
- **hold**: `crossSessionInbound: "accept"` (문서화된 경로). 토큰 own-child 위임은 비문서 의미라 주 경로 금지(실험 모드만). **신뢰 확장 명시**: accept는 "같은 uid 로컬 게시자"뿐 아니라 그 세션에 닿는 **Remote Control 피어(계정 경유)** 도 자동 수락한다. 이 함대는 단일 uid·본인 머신·계정 본인이라 허용 가능하나 **유저 결정 사항**.
- **priority**: 편지 기본 `later`(턴 끝). `next`는 명시적 긴급 클래스(dependency invalidation), `now`는 operator control. 원격 발신자가 아니라 로컬 정책이 매핑. 자동 승격 없음.
- **다중 신원**: 배타 lease + 충돌 시 수신 중단(양쪽 경고, `khala bind --takeover`로 해소). deliver-to-all·newest-wins 둘 다 거부. `-p`/fork/워커는 **receive opt-in**(기본 interactive-main만).
- **herald 위치**: link와 별도 프로세스, 같은 Go 모듈. link만 reconcile. 감독은 서비스 매니저.
- **관측성**: `khala status`에 pending, lease owner, adapter/CC 버전, last attempt/status/ack.

## 5. 릴리스 전 필수 불변식 (자문 §3, 그대로 채택 — 이 10개 전에 watch 경로 제거 금지)
1. 소켓 쓰기 경로 어디에도 `new→cur` 없음. 2. 알 수 없는 CC 버전에서도 편지는 `new`.
3. 신원 충돌 시 자동 배달 중단. 4. `-p`/fork는 opt-in 없이 lease 못 가짐. 5. 세션당 outstanding wake ≤1.
6. 재시도마다 Letter-Id 동일·Attempt-Id만 변경. 7. SessionStart drain ↔ herald 사이 phase 장벽.
8. 토큰은 brain·로그·백업·복제 어디에도 안 들어감. 9. herald·link 크래시가 서로를 죽이지 않음.
10. Linux/WSL/macOS kill/write/restart 결함주입 테스트 PASS.

## 6. 호환 기간
- `khala watch`는 남기되 herald가 `ready`인 노드에서는 "herald가 귀를 맡고 있음"만 찍고 종료(0). Stop 훅 block은 herald 배포와 동시에 제거. 함대 롤: 노드별 `khala node ensure` → herald 기동 확인 → 그 노드 세션들 재시작(소켓 열림).
- 중기: CC **Channels**(공식 알림 API + ack 도구) 어댑터로 교체 — research preview 해제·allowlist 조건 풀리면. 소켓 도어벨은 그때까지의 즉시 배포용.

## 7. VOC 소품 (D15 lane B — 독립)
서브커맨드 `--help`; `send --subject/--message`·`--reply-to <Id>`(In-Reply-To); `inbox --drain` 출력 전 `new→cur` 원자 이동(SIGPIPE 중복 종결); `inbox read <Id>`; 편지/스트림 시각 분리; watch 종료사유 첫 줄 구조화; 롤 스크립트 tmp+mv 강제.

## 8. 유저 결정 항목
1. `crossSessionInbound: accept` 함대 전체 채택(신뢰 확장 §4 인지) — **YES/NO**.
2. herald 감독을 systemd --user / LaunchAgent로(노드별 1회 설치) — **YES/NO**.
3. r1 GO 시 레인 발사: A(herald+registration+훅 개편, Go+bash) / B(VOC 소품). eddy 게이트 후.

## 9. 실측 열린 항목 (구현 lane이 먼저 닫을 것)
- 인터랙티브 bypass 세션에서 accept 시 외부 프레임 도착·`later` 체감(소켓 열린 세션 필요 — 재시작 후).
- `peer_message_status` 컨트롤 프레임이 외부 게시자에게 회신되는지(회신되면 저널·재시도 억제에만 사용).
- CC 버전별 black-box 호환 매트릭스(accept/hold/refuse, 큐 상한, rate limit, 동일 msg_id 재시도, Linux/macOS, interactive/-p).
