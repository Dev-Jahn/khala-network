# D18 r1 — 하위 작업자 자동 수신 + 최신 Claude Code/Codex 기준 conduit 정리 (2026-10-21)

기준: 정본 `main` `5fdec0a`(khala 0.9.10 + 미릴리스 정리 커밋), hippo 1.16.0, khala-network-codex 0.2.1(`861b832`),
Claude Code 2.1.305(mbp)·2.1.306(windows), codex-cli 0.162.1. 유저 요청(10-21): windows `jahns-vsr`에서 하위 작업자가 스스로
신원을 만들어 메인에 보고한 현상을 **살려서 쓰고 싶다**. 답장은 하위 작업자가 자동으로 받지 못했다. 주 사용처는 **Claude Code
메인 → codex 레인**(hippo `hippo:lane` → `hippo dispatch` → `codex exec`). 메인 쪽 conduit도 최신 버전 기준으로 정리할 수 있는지 본다.

## 1. 실측 (windows jahns-vsr, 10-15 ~ 10-21)

- **신원을 만든 쪽은 전부 codex 레인이다.** 메인 `b6988d16`의 Claude 하위 작업자 255개(hippo:lane 233, general-purpose 17,
  fork 5) 중 khala를 쓴 것은 없다. hippo:lane은 codex 레인을 띄우고 지켜보는 중계일 뿐이다. 10월 codex 레인 rollout 675개 중
  14개가 khala를 썼다. 10개는 신원을 썼고(처음 4개는 작업 폴더 이름이나 지시문 제목으로 **스스로 지음**), 4개는 신원이 없다며 멈췄다.
  레인들은 Codex용 khala SKILL을 직접 읽고 `KHALA_SESSION=<name> …/khala-codex bind|send|inbox --drain`을 썼다.
  메인이 50분 뒤 알아채고 이후 지시문에 이름을 넣었다("`KHALA_SESSION=<name>`, 10분마다 drain").
- **레인 → 메인은 잘 된다.** 메인은 소켓 초인종 210회, drain 233회. 레인 편지 169통, 보낸 뒤 읽기까지 중앙값 4 s(p90 19 s).
- **메인/다른 세션 → 레인은 레인이 스스로 확인해서만 받았다.** 레인 이름으로 온 편지 150통(메인 61, 클러스터 관리자 53, …)
  중 144통 읽힘. 약 800번의 `inbox --drain`, 읽기까지 중앙값 ~2분. codex 초인종 16건은 **하나도 작업 중에 닿지 않았다**:
  12건은 작업이 끝나는 순간 새 턴으로 들어와 프로세스 종료와 함께 버려졌고, 4건은 다음 재개 때 들어왔다. 8건은 아직
  `~/.codex/queue_1.sqlite`에 걸려 있다.
- **수명 불일치**: `khala-codex bind`가 띄운 브리지는 실행 한 번이 끝나면 죽는다("owning Codex process has exited"). 재개된 실행은
  다시 등록되지 않는다(시작 훅은 시작 시점에 `KHALA_SESSION`이나 `.khala-codex-session`이 있어야 바인드하는데, 레인은 명령마다
  앞에 변수를 붙였을 뿐이다). 낡은 바인딩 2개(`run/codex/*.json`)가 같은 이름의 재바인드를 막는다.
- **조용한 실패**: 아무도 소유하지 않은 이름으로 보내도 성공한다(`diffusion-speed@windows` 1통, `text-pixel-mask@windows`
  5통이 41~45 h째 미읽음). 메인은 미읽음 감시를 24번 다시 걸고, 레인 편지 파일을 손으로 `mv`했다(khala의 읽음 처리 우회).
- **환경 누수**: `hippo dispatch`는 `os.environ` 전체를 넘긴다(`hippo_cli.py:3134-3138, 3174-3177`). 레인은 메인의
  `CLAUDE_CODE_SESSION_ID`·`CLAUDE_CODE_MESSAGING_SOCKET`·`CLAUDE_CODE_MESSAGING_TOKEN`을 물려받는다(추론, 살아 있는 자식 셸로
  확인). 레인이 Claude 경로 `khala bind`를 쓰면 메인 소켓에 묶여 그 이름의 편지가 메인을 울린다(`runtime.go:835-839`).
- **현재 문제(별건)**: windows에 `claude --resume jahns-vsr`가 두 개(pid 11256, 407039) 떠 있다. 10-21 15:22부터 conduit이
  "Claude registry pid/socket mismatch"로 메인 등록을 검증하지 못한다.

## 2. 플랫폼 사실 (최신판)

**Codex 0.162.1**
- `codex exec`는 밖에서 입력을 넣을 통로가 없다(앱서버가 프로세스 안에만 있고 소켓이 없다. 턴 하나 뒤 종료, 외부 입력은
  SIGINT뿐). hippo는 모든 레인을 이것으로 띄운다.
- **훅은 exec 레인에서도 돈다**(0.160 레인 로그에 SessionStart/UserPromptSubmit/Stop 확인). `PostToolUse`·`SessionStart`·
  `UserPromptSubmit`의 `additionalContext`는 다음 모델 요청에 들어간다. `Stop`이 `{"decision":"block","reason":…}`을 돌려주면
  **같은 턴이 그 reason을 프롬프트로 이어 간다**(`core/src/session/turn.rs:675-691`).
- app-server(실험적): `turn/steer`가 진행 중인 턴에 입력을 더하지만 소비 시점은 다음 모델 요청이다. 즉 **도구 호출 경계에서
  들어간다는 점은 훅과 같다**. 레인을 app-server로 띄워야 하고 프로토콜 버전에 묶인다.
- `codex queue`는 스레드가 idle일 때만 새 턴으로 넣는다. exec 레인에서는 위 실측대로 쓸모없다.
  MCP 서버 알림은 모델에 닿지 않는다(Claude 채널에 해당하는 것이 없음).

**Claude Code 2.1.306**
- 세션 소켓(`CLAUDE_CODE_MESSAGING_SOCKET`, `crossSessionInbound: accept`)이 **"스크립트가 실행 중인 세션에 글을 넣는 길"로 문서화**됐다
  (cross-session-messaging). 기본으로 켜져 있고 실행 플래그가 필요 없다. 첫 줄 `{"type":"auth","token":…}`는 macOS/Linux에서 선택,
  **native Windows에서 필수**. 30 s 안에 완전한 줄이 없으면 닫는다. 인증 줄 뒤의 형식은 **문서에 없다**(우리 프레임은 실측 형식).
- MCP 채널은 여전히 research preview다. 실행 플래그가 필요하고, v2 MCP 런타임에서 2026-07-28 개정을 협상한 서버는 채널로 등록되지 않는다.
- 하위 작업자(Agent 도구): 밖에서 직접 넣는 공식 경로는 없다. 메인의 `SendMessage(to: agentId)`, 하위 작업자 안에서 도는
  `PostToolUse` 훅(입력에 `agent_id`가 있고 `additionalContext` 가능), `SubagentStop` block, mod의 `$.session.send({to:{agentId}})`,
  하위 작업자가 띄운 백그라운드 Bash가 끝나면 깨우기(2.1.243에서 수정)가 있다.
- 새로 생긴 것: Bash 자식에 `CLAUDE_CODE_MESSAGING_TOKEN`, 레지스트리에 `peerProtocol:1`·`peerFeatures`·`procStart`.

## 3. 핵심 판단

1. **exec 레인에는 "초인종"이 아니라 "도구 경계 배달"이 맞다.** 레인은 한 턴 안에서 도구를 수백 번 부른다. 그 경계마다
   훅이 자기 받은편지함을 보고 새 편지를 **문맥에 직접 넣으면** 지연은 도구 한 번 길이다. 데몬·소켓·등록 경쟁이 없다. app-server
   `turn/steer`도 소비 시점이 같으니, 레인 실행 방식을 바꿀 이유가 약하다.
2. **신원은 레인이 짓지 않고 디스패처가 정한다.** 실행 사이에 유지되고, 재개해도 같아야 한다.
3. **레인이 끝난 뒤 온 편지는 부모에게 알린다.** 레인은 끝나면 다시 들을 수 없다. 편지가 썩지 않게 부모(디스패치한 메인)에게
   알림을 보내고, 부모가 레인을 재개(`codex exec resume`)하거나 직접 처리한다.
4. **메인 conduit은 "문서화된 소켓 하나"로 단순화할 수 있다.** 채널은 플래그·미리보기·MCP 개정 위험을 안고 있고, 소켓이 공식이 됐다.

## 4. 설계안

### 4.1 레인 신원 (hippo + khala-codex)
- `hippo dispatch`가 레인마다 `KHALA_SESSION=<lane>`과 `KHALA_PARENT=<메인 identity>@<node>`를 넣는다. `<lane>`은 hippo 작업 slug,
  겹치면 `-2`, `-3`. 레인 워크트리에 `.khala-codex-session`도 써서 `exec resume`이 같은 이름으로 다시 바인드되게 한다.
- 같은 자리에서 `CLAUDE_CODE_MESSAGING_SOCKET`·`CLAUDE_CODE_MESSAGING_TOKEN`·`CLAUDE_CODE_SESSION_ID`·`CLAUDECODE`를 지운다
  (레인은 Claude 세션이 아니다). khala 쪽도 방어한다: `CODEX_THREAD_ID`가 있으면 Claude 소켓 바인드를 거부한다(codex 경로는 이미 거부함).
- SKILL 문구: "신원이 없으면 짓지 말고 멈춰서 보고" 유지, "레인은 `KHALA_SESSION`이 이미 주어진다" 추가.

### 4.2 레인 배달 = 훅 (khala-network-codex "lane mode")
- 조건: `codex exec`(TUI 아님)이면서 신원이 있음. 브리지·`codex queue`를 띄우지 않는다.
- `PostToolUse`: `inbox/<lane>/new`가 비어 있으면 아무것도 하지 않는다(디렉터리 stat 한 번, 빠른 경로).
  편지가 있으면 `khala inbox --drain --as <lane>`(기존 상한 `--max-n/--max-bytes`)의 출력을 `additionalContext`로 넣는다.
  drain이 읽음 처리를 하므로 "문맥에 들어감 = 읽음"이 된다.
- `Stop`: 미읽음이 있으면 `decision:block` + reason = drain 출력, 연속 상한 3회(`stop_hook_active` 확인). 레인이 끝나기 직전에
  온 답장도 반영된다.
- `SessionEnd`: lease 해제, 낡은 `run/codex/<lane>.json` 정리, 큐에 남은 초인종 정리.
- 도구 하나가 오래 걸리면(클러스터 대기 등) 그동안은 닿지 않는다. 이건 app-server로 바꿔도 같다. 필요하면 레인 지시문에
  "오래 기다릴 때는 짧게 끊어 기다려라"를 넣는다.

### 4.3 끝난 레인의 편지 → 부모 알림 (khala core)
- 레인 바인딩에 `parent`를 기록한다. conduit은 lease가 없는 신원에 새 편지가 생겼고 그 신원에 parent가 기록돼 있으면, parent에게
  **알림(notice) 1건**을 보낸다: "lane `<lane>` 종료, 미읽음 N, 재개: `hippo dispatch … resume …`". 같은 미읽음 묶음에는 한 번만 보낸다.
- 부모는 레인을 재개하거나 편지를 직접 읽는다(`khala inbox read --as <lane>`. 손으로 `mv` 하지 않게).

### 4.4 조용한 실패 없애기 (khala core)
- `khala send`: 대상 이름을 클러스터 presence나 lease에서 한 번도 본 적 없으면 경고한다("이 이름을 쓴 세션이 없음; 보관은 됨"). 거부는 하지 않는다(나중에
  생길 신원 = store-and-forward).
- `.ear` 스냅샷/`khala presence`에 "주인 없는 받은편지함(미읽음 N, 가장 오래된 것 Xh)"을 표시한다.

### 4.5 메인 conduit 정리 (khala core + plugin)
- **소켓 인증 줄**: SessionStart 훅이 `CLAUDE_CODE_MESSAGING_TOKEN`을 등록(0600)에 저장하고, conduit은 첫 줄로 auth를 보낸다.
  Windows native 대비, 앞으로 토큰이 필수가 돼도 버틴다.
- **경로 하나로**: Claude는 소켓만 쓴다. 채널(`plugin/channel/server.ts`, `--dangerously-load-development-channels`)은 opt-in으로 남기거나
  폐기한다 — **유저 결정**.
- **버전 하한 2.1.239로**(Windows 메시징, 소켓 디렉터리 강화). 그 아래를 위한 우회는 실측 확인 후 제거한다: `healLease`(resume 시 레지스트리가
  늦게 생김), 채널 자식의 stale `CLAUDE_CODE_SESSION_ID` 보정(2.1.235), "레지스트리에 session id가 없을 수 있음" 분기, peer 안내문
  버전별 분기. 각 항목은 현재 버전에서 재현 실험으로 필요 여부를 확인한 뒤에만 지운다.
- **프로세스 검증**: 레지스트리의 `procStart`로 pid 재사용을 판정하면 `ps lstart` 파싱(C 로케일 고정)을 없앨 수 있다. 형식 확인이 먼저다.
- **같은 세션 이중 resume**(windows 실측): 레지스트리 두 개가 같은 sessionId를 가질 때 conduit이 어느 쪽도 못 울린다. 최근에 시작한
  쪽을 고르고 나머지는 경고로 보인다.
- **카나리아**: 인증 줄 뒤 프레임 형식이 문서에 없으므로, CC 업그레이드마다 도는 실제 왕복 점검을 둔다(`khala status`의 마지막 배달 결과 활용).

### 4.6 Claude 하위 작업자 (후순위)
- 같은 "도구 경계 배달"을 Claude 쪽에도 할 수 있다. 플러그인 `PostToolUse` 훅이 `agent_id`를 보고 그 하위 작업자에 묶인 신원의
  편지를 `additionalContext`로 넣는다. 신원은 `SubagentStart`에서 하위 작업자 이름이나 지시문의 선언으로 묶는다.
- 메인 경유가 더 간단한 경우: conduit이 메인을 울리고 메인이 `SendMessage(agentId)`로 넘긴다(지금도 가능, 메인 턴 비용 있음).
- mod(`$.session.send({to:{agentId}})`)는 메인 턴 없이 직접 넣는 유일한 공식 경로지만 새 표면이다. 스파이크로만.

## 5. 단계

1. **레인 수신(주 사용처)**: 4.1(hippo + khala-codex) + 4.2(khala-codex lane mode) + 4.3(parent 알림) + 4.4(경고).
   검증: mbp에서 메인 → hippo 레인 → 레인이 보고 → 메인 답장 → 레인이 다음 도구 경계에서 받음 → 레인이 끝난 뒤 온 편지 → 부모 알림 → resume.
2. **메인 정리**: 4.5. 소켓 인증 줄과 이중 resume 처리 먼저, 우회 제거는 항목별 실측 뒤.
3. **선택**: 4.6, app-server 레인(도구 하나가 아주 긴 레인에서 실측으로 부족할 때만).

손대는 저장소: khala core(`bin/khala`, `link/conduit*.go`, `plugin/`), khala-network-codex(훅, SKILL), hippo(dispatch 환경·신원, 별도 저장소).
codex 훅을 바꾸면 노드마다 신뢰 해시를 다시 받아야 한다(`~/.codex/config.toml [hooks.state]`). 롤아웃 단계에 넣는다.

## 6. 유저 결정

1. 레인 배달 방식: **훅 기반 도구 경계 배달**(추천) vs 레인을 app-server로 띄우는 방식.
2. 레인 신원 형식: hippo 작업 slug(추천) vs 디스패치 id vs 지시문에서 메인이 지정.
3. 끝난 레인의 편지: 부모에게 알림(추천) vs 보낸 사람에게 반송 vs 그대로 보관.
4. Claude 채널 경로: opt-in으로 유지 vs 폐기(소켓 하나로).
5. hippo 수정 범위(신원 주입·환경 정리·resume 시 재바인드)를 이 작업에 포함할지.

## r2 — 유저 결정 (2026-10-21)

1. 레인 수신은 **훅 기반 도구 경계 배달**. 단 **편지가 없을 때는 레인에 영향이 없어야 한다**: 빠른 경로는 출력 0바이트(빈
   `additionalContext`도 넣지 않음), 디렉터리 stat 수준의 비용, 훅 자체의 오류·시간 초과는 레인을 막거나 실패시키지 않는다
   (실패는 훅 로그에만 남김). Stop block은 미읽음이 있을 때만이다.
2. 끝난 레인의 편지는 **띄운 메인(parent)에게 알림**(4.3안 그대로).
3. Claude 메인 경로는 **소켓 하나**. MCP 채널(`plugin/channel/`, 채널 등록·검증·echo 분기)은 **폐기**.
4. **hippo 수정 포함**(4.1안: 레인 신원·parent 주입, Claude 환경 변수 제거, `.khala-codex-session`으로 resume 재바인드).
