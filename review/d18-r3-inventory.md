# D18 r3 — 2단계 코드 목록 (정본 `8b77348` 기준, 2026-10-28)

결정은 `review/d18-subagent-inbound-r1.md` r3. 이 문서는 구현용 위치 목록이다(Plan 조사, 읽기 전용). 줄 번호는 `8b77348` 기준.

## 바탕 사실
- Codex 어댑터가 부르는 것: `runtime root`, `runtime register --harness codex`, `runtime register-channel --instance --session-id
  --channel-socket --caller-pid --verified`, `runtime release`, `runtime daemon-status` (`khala-network-codex/lib/channel.mjs:92-117`,
  `lib/launch.mjs:23`). `register-channel --clear`, `--help` 탐지, `runtime whoami`, `runtime session`은 안 부른다.
- Codex는 채널 요청의 `content`를 문자열인지만 보고, `meta.{generation,pending,urgent,retry,later}`만 읽는다(`lib/channel.mjs:11-21`).
  라이브 시험은 `.ear` `route=channel cc=codex:`와 `component conduit`의 `release=`만 본다.
- 어댑터는 `bin/khala`와 릴리스 자산만 vendor한다. `plugin/channel` 삭제는 동기에 영향 없다.
- MCP 서버는 `khala_drain`·`khala_reply` 도구도 제공한다(`plugin/channel/server.ts:286-345`). 소켓 프레임은 이미 `read: khala inbox --drain`
  (`link/conduit.go:1391`)이고 답장은 `khala send --reply-to`.
- 코드에 따로 "MCP 어댑터" 이름은 없다. `runtime status`는 검증된 Claude 등록에 `socket-v1`(`runtime.go:1260-1261`). MCP 전용 라벨은
  `route=channel+socket`/`via=channel+socket`, Claude 등록의 `route=channel`/`via=channel`.
- 낡은 브랜치 `task/d17-b-cli-conduit`(미병합)는 `server.ts`, `test/hardening.sh:168`, `channelRequest` meta, SKILL, README, DESIGN,
  `session-start.sh`를 고친다 — 나중에 rebase할 때 `server.ts` 덩어리를 버리고 답장 안내를 `khala send` SKILL 문구로 옮긴다.

## A. MCP 채널 경로 제거

| 위치 | 분류 | 조치 |
|---|---|---|
| `link/runtime.go:32-35` ChannelSocket/PID/PIDStart/Verified | 공용(Codex) | 유지 |
| `runtime.go:95-98` `whoami`·`session` 분기 | MCP 전용 | 삭제 |
| `runtime.go:99-100` `register-channel`, `:158` channels 디렉터리 | 공용 | 유지 |
| `runtime.go:343-347` 로케일 고정 주석("channel child") | 공용 코드 | 코드 유지, 주석만 고침(Codex 브리지·훅 vs launchd conduit) |
| `runtime.go:486-488` `matchingRegistry`의 Codex 건너뛰기 | Codex | 유지 |
| `runtime.go:570-601` `runtimeSession` | MCP 전용(`server.ts:103`) | 삭제 |
| `runtime.go:603-638` `runtimeWhoami` (CLI `khala whoami` 아님) | MCP 전용(`server.ts:440,495`) | 삭제 |
| `runtime.go:641-644` `register-channel --help` | MCP 전용(`server.ts:383-390`) | 삭제 |
| `runtime.go:652,674-690` `--clear` | MCP 전용(Codex는 `release`) | 삭제. `conduit_runtime_test.go:1602,1647`은 clear 없는 호출로 |
| `runtime.go:651,715` `--verified` | 공용 | 유지 |
| `runtime.go:664-716` attach·검증 | 공용 | 유지 + `firstNonempty(reg.Harness,"claude") != "codex"`면 거부("Claude sessions use the session socket") |
| `runtime.go:825-848` Codex 가드 | Codex | 유지 |
| `runtime.go:1243,1253-1256` CHANNEL 열 | 공용 | 유지(Codex만 `yes` 선택) |
| `runtime.go:1263-1268` `codex-channel-v1` | Codex | 유지 |
| `runtime.go:1352-1361` Codex `watch-ready` | Codex | 유지 |
| `runtime.go:1376-1378` "conduit path unverified" | MCP 전용 | 삭제 |
| `link/conduit.go:43-44` `Via`, `ChannelError` | 공용 | 유지 |
| `conduit.go:68` `echoLogged` + `:631,:1074,:1093,:1172-1174,:1321-1323` | MCP 전용 | 삭제 |
| `conduit.go:702-707` Codex 검증 | Codex | 유지 |
| `conduit.go:1158-1162` 채널 쓰기 | 공용 | `reg.Harness=="codex"`일 때만 |
| `conduit.go:1163-1181` 미검증 채널 + 소켓 echo | MCP 전용 | 삭제 |
| `conduit.go:1182-1186`, `:1193-1195` | Codex | 유지 |
| `conduit.go:1187-1191` 채널 실패 뒤 Claude 소켓 폴백 | MCP 전용 | 삭제 |
| `conduit.go:1196-1198` 소켓 쓰기 | Claude 유일 경로 | 유지 |
| `conduit.go:1431-1463` `channelRequest` | 공용 | 유지("run khala_drain" 문구와 표시용 meta 정리는 선택 — `conduit_runtime_test.go:781-789`) |
| `conduit.go:1465-1495` `verifyChannelSocket`, `:1613-1652` `writeChannelNotification` | Codex | 유지 |
| `link/ears.go:311,442` route 문법의 `channel+socket` | 공용 와이어 형식(구버전 노드) | 유지. `bin/khala:1106`, `link/dashboard/app.js:547`도 |
| `ears.go:520` Codex 사유 | Codex | 유지 |
| `ears.go:799-806` route 선택 | MCP 전용 분기 | Codex면 `channel`, 나머지 `socket` |
| `bin/khala:5674-5678`(= `plugin/bin/khala`) watch의 "conduit path unverified" | MCP 전용 | 두 사본 모두 삭제 |

- 플러그인: `plugin/.mcp.json`, `plugin/channel/server.ts`, `package.json`, `bun.lock` 삭제. `plugin/.claude-plugin/plugin.json`·`plugin/hooks/*`는 채널 코드 없음.
- SKILL(`plugin/skills/khala/SKILL.md`): `:3` 설명에서 `khala_drain` 제거, `:113-122` "When the khala channel is on" 삭제, `:196`·`:201` "CC inbox socket (Claude) or Codex receiver channel".
- 시험: `test/channel.sh`, `test/channel-mcp-client.py` 삭제. `test/channel-listener.py` 유지(Codex 프로토콜, `test/conduit.sh:107-121`).
  `test/conduit.sh` H20(`:184-256`) → `--harness codex` 사례로 재작성(via=channel, 소켓 안 씀, 죽은 채널은 폴백 없이 실패 기록).
  H10(`:793-811`) 미검증 채널 절반 삭제, 검증 절반(`:812-818`)은 Claude 소켓만으로. `test/plugin.sh:149-159` 삭제·`:166` 메시지,
  `plugin/.mcp.json` 부재 검사 추가. `test/hardening.sh:168-172` server.ts 예약어 루프 삭제. `test/lib/isolate.sh:97` `KHALA_CHANNEL_SERVER` 삭제.
  `link/conduit_runtime_test.go`: route 루프(`:110-165`)의 `channel+socket` 하위 사례 삭제·`channel`은 Codex로, `TestUnverifiedChannelEchoesSocketRing`
  (`:1386-1417`) 삭제, `TestVerifiedChannelDoesNotEchoSocketRing`(`:1419-1448`) 삭제 또는 Codex로, `TestNoticeClassificationShapesSocketAndChannelDoorbells`(`:734`) 유지.
  `link/ears_test.go:172,189` 채널 가진 Claude 등록 → `route=socket`; `:80`, `:424-436` 유지. `link/codex_harness_test.go:124-136` 유지 + Claude 등록 거부 시험.
- 문서: `README.md:317-331` 한 줄로, `DESIGN.md:648-653`(`channel+socket`은 0.9.11 이하 legacy, `:650` 로케일 근거), `:774-775`,
  `docs/GLOSSARY.md` `:92,:100,:194,:258,:282-283,:309,:314`, `docs/GATEWAY.md:239`. `review/`·`report/`는 기록이라 손대지 않음.
- 위험: 살아 있는 세션은 재시작 전까지 옛 MCP 자식을 가진다. 그 자식의 종료 시 `--clear` 호출은 실패해도 무해(exit 0). conduit은 Claude 등록의
  `ChannelSocket`을 무시해야 한다. `--dangerously-load-development-channels plugin:khala@…`를 쓰는 실행 설정은 롤아웃 때 뺀다.

## B. 소켓 인증 줄 + 하한
- 쓰기: `writeNotification` `conduit.go:1589-1611`(250 ms, 한 줄, 응답 안 읽음), 프레임 `frame()` `:1381-1404`, A 뒤 호출은 `:1198` 하나.
- 등록: `session-start.sh:100`이 `CLAUDE_CODE_MESSAGING_SOCKET`을 읽고 `:108-111`,`:122-127`에서 `khala bind --register … --socket`,
  `bin/khala:5299-5312` → `khala-link runtime register`(환경 상속). 소켓 지정 `runtime.go:854-863`, 레지스트리 덮어쓰기 `:871-875`,
  기록 `writeRegistration` `:535-539` → `writeAtomicJSON`(`:248-299`, 0600), 디렉터리 0700(`:166-195`).
- 최소 변경: `runtime.go:23-47`에 `MessagingToken`·`MessagingTokenSocket`(omitempty). `runtimeRegister`에서 `:875` 뒤, harness claude이고
  `--socket`이 명시됐고 그 값이 `os.Getenv("CLAUDE_CODE_MESSAGING_SOCKET")`와 같을 때만 `CLAUDE_CODE_MESSAGING_TOKEN`을 그 소켓과 함께 저장(argv 아님,
  훅 수정 불필요). `writeNotification(socketPath, token, frame)`: 토큰이 있으면 auth 줄+프레임을 한 번에 쓴다. 호출부는
  `reg.MessagingTokenSocket == reg.SocketPath`일 때만 토큰을 넘긴다.
- 시험: 새 Go 파일(기존 픽스처 리스너 `conduit_runtime_test.go:224-227`은 첫 줄만 읽음), `newNotifierFixture`(`:78-82`)에 두 환경 변수
  `t.Setenv`(Go 시험은 살아 있는 세션 안에서 돈다), `test/conduit-listener.py:44-50` 전체 줄 모드, `conduit.sh` H15 뒤(~`:621`) 새 사례:
  토큰 있으면 auth 줄 먼저, 없으면 한 줄, 등록 파일 0600, 토큰이 `runtime status`·`.ear`에 없음.
- 하한: `install.sh:8`, `plugin/install.sh:8`(바이트 동일) `KHALA_MIN_CLAUDE_VERSION=2.1.229` → `2.1.239`(검사 `:263-273`).
  `test/install.sh:94`(가짜 기본 2.1.235 → 2.1.239 이상), `:299`,`:311-312`, `:305`,`:310`(2.1.228 → 2.1.238). `docs/SETUP-second-node.md:27`.
  런타임 하한 검사는 없다(선택: SessionStart 1회 경고, `lib.sh:62-76` `khala_version_newer`).

## C. 이중 resume
- 경로: A가 `claude --resume S`로 인스턴스 I(pid A, 소켓 SA) 등록 → B가 같은 resume, `runtime.go:784-792`가 I를 재사용, `:859-863`이 SB를 받고
  `--pid 0`이라 pid A 유지(`:868`), `matchingRegistry`(`:489-503`)는 SB와 pid A를 둘 다 요구해 못 찾음 → I = (pid A, 소켓 SB), lease는 owner(`:1063-1065`).
  conduit `verifyRegistration`이 pid(`conduit.go:698`)·소켓(`:711-716`)은 통과하고 `:717-719`에서 "Claude registry pid/socket mismatch"(`.ear` 사유 `registry`,
  `ears.go:522`). A가 끝나면 SessionEnd(`session-end.sh:12` → `runtime.go:1164-1167`)가 I를 놓아 B는 다음 SessionStart까지 등록 없음.
- (a) 등록에서 예방: `runtime.go:859` 앞, 등록이 있고 명시 `--socket`이 비지 않았고 저장된 소켓과 다르며 `*pid <= 1`이면 `reg.PID`·`reg.PIDStart`를
  비워 새 소켓의 레지스트리(B)에서 pid를 찾게 한다. `claimLease`(`:1083-1088`)가 같은 인스턴스·epoch 안에서 lease를 B로 옮긴다. A의 늦은
  SessionEnd는 B가 살아 있고 A의 조상이 아니므로 I를 놓지 않는다(H16 유지). H15는 `--pid`를 명시하므로 무관.
- (b) conduit 복구(이미 나빠진 등록): `claudeRegistry`(`runtime.go:70-77`)에 `StartedAt`(ms)·`ProcStart` 추가, 로더 `:460-467`. `verifyRegistration`
  (`conduit.go:681-688`)에서 Claude 등록의 엄격 일치가 실패하면 같은 `sessionId`의 살아 있는 레지스트리 중 `startedAt` 최대(동률은 프로세스 시작,
  pid)를 골라 pid·소켓·시작 시각을 채택. 인스턴스·고른 pid당 한 번 로그("session S open in pids A,B; ringing newest B; A will not be rung"),
  `verificationReasons` 같은 맵으로 중복 제거. `leaseNeedsHeal`(`:775-784`)를 같은 인스턴스·epoch·세션 id 안에서 lease가 등록을 따라가게 완화
  (안 하면 `:1135-1137`에서 막힘). `.ear` 사유 열거형은 와이어 형식이라 바꾸지 않는다.
- 시험: 새 Go 파일(살아 있는 pid 둘: 시험 프로세스와 `sleep`, 같은 세션의 레지스트리 둘, `startedAt` 다름), `conduit.sh` H16 뒤(~`:660`) 새 사례
  (`start_listener` 두 번, 같은 세션 id; `conduit.sh:100-102` 레지스트리 작성기에 `startedAt`). DESIGN D18 절에 한 줄.

## 구버전 우회 (유지)
- `healLease`(`conduit.go:739-784`) 유지 — 이중 resume 복구가 기댄다. `ps lstart`(`runtime.go:312-352`) 유지 — lease, 싱글턴, 회수,
  parent 생존, Codex가 쓴다. 레지스트리 `procStart`는 UTC 문자열이라 비교하려면 파싱이 필요하다(Linux 형식 미측정).
- 세션 id 별칭(`runtime.go:462` `session_id`, `claudeSessionId`; `conduit.go:720`)은 노드별 `grep -L '"sessionId"' ~/.claude/sessions/*.json` 측정 전에는 유지.
- 채널 자식 stale 세션 id 보정은 A와 함께 사라진다.

## 분할 (A 먼저 병합, B·C는 rebase)
- A: 위 A 전부 + `bin/khala`·`plugin/bin/khala` watch 분기, SKILL, README, DESIGN, GLOSSARY. 약 −1,880/+120.
- B: `runtime.go` 등록 구조체 필드 + `:875` 뒤 토큰 블록, `conduit.go` `writeNotification`과 `:1198` 호출부(A와 유일한 예상 충돌),
  새 `link/socket_auth_test.go`, `test/conduit-listener.py`, `conduit.sh` H15 뒤 사례, 설치 하한. 약 +150/−10.
- C: `runtime.go` `claudeRegistry`·로더·`:859` 앞 pid 초기화·최신 레지스트리 도우미, `conduit.go` `verifyRegistration`·`healLease`/`leaseNeedsHeal`,
  새 `link/double_resume_test.go`, `conduit.sh` H16 뒤 사례, DESIGN. 약 +200/−10.
- 버전 올림(`bin/khala`, `plugin.json`, `link/main.go`, `test/minds.sh`)은 별도 릴리스 커밋.
