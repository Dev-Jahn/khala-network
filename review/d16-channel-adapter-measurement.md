# D16 후보 — khala 채널 어댑터: 실측 (1)(2) 결과와 설계 방향 (ink, 2026-08-18)

> eddy의 요청(1787040248…)에 대한 답. 결론은 §3. 코드 변경 없음(측정만).

## 1. 실측 (1): 채널 알림은 턴 도중에 끼어드는가?
**답: 예 — 소켓 `next`와 정확히 같은 큐·같은 우선순위로 들어간다.** 문서의 "delivered together on the next turn"은 큐가 비워지는 *시점* 설명이지 우선순위가 아니다.

근거(CC 2.1.234 바이너리 실측 — 문자열 추출):
- 채널 알림 핸들러는 `notifications/claude/channel` 수신 시
  `enqueue({mode:"prompt", value: <channel …>, priority:"next", isMeta:true, origin:{kind:"channel",server}, skipSlashCommands:true})` 를 호출한다.
  즉 우리 conduit이 0.5.5에서 소켓으로 넣는 `priority:"next"`와 **동일 랭크(now:0,next:1,later:2)** 다. 턴 중 tool call 사이 dequeue 조건이 같으므로 즉시성에서 채널과 소켓은 동등하다.
- 태그 조립 `wrapChannelMessage(server, content, meta)`: `<channel source="<name>" k="v"…> content </channel>`; meta 키는 `^[a-zA-Z_][a-zA-Z0-9_]*$` 아니면 조용히 버림(문서와 일치).
- **헤드리스(-p) 실측**: `claude -p --strict-mcp-config --mcp-config … --dangerously-load-development-channels server:khalachan` 로 채널 서버(bun, MCP SDK, `claude/channel` capability)를 띄우고 6초짜리 Bash 5단계 턴 중 2단계에서 알림을 넣었더니 **아무것도 도착하지 않았다**(전사에 `<channel` 0회, debug 로그: 서버는 connected(capabilities hasTools:false…)이나 "Channel notifications registered" 없음). 이유는 게이트 코드에 있다:
  ```
  gate(server): capability 없음→skip; protocolEra==="modern"→skip(era); provider!=firstParty→skip;
  !isChannelsEnabled() [GrowthBook tengu_harbor]→skip(disabled); org policy→skip;
  server가 --channels/--dev 목록(VL())에 없음→skip(session); plugin이면 marketplace 일치+allowlist(dev면 우회)
  ```
  그리고 `--dangerously-load-development-channels`의 파싱 결과는 **인터랙티브 시작 경로에서만** `Zst([...VL(), ...dev])`로 목록에 합쳐진다(경고 다이얼로그 `DevChannelsDialog` 수락 시, 또는 채널 기능이 꺼져 있으면 다이얼로그 없이). `-p` 경로에는 그 합치기가 없어서 dev 항목이 세션 목록에 안 들어가고 게이트가 `session` 사유로 skip한다. → **-p/헤드리스에서는 dev 채널이 등록되지 않는다.** soul-jar dream·`khala`의 `-p` 프로브 등에는 채널이 붙지 않으니, 그쪽은 지금처럼 소켓 초인종(또는 시작 시 드레인)이 유일한 길이다.
- 추가 게이트: `tengu_harbor`(GrowthBook 기능 플래그)가 꺼져 있으면 dev 플래그를 줘도 `disabled`로 skip된다. 우리 계정에서 인터랙티브 확인은 아직 안 했다(§4).

## 2. 실측 (2): 기동 경로에 dev 플래그가 앉는가?
- 함대의 인터랙티브 기동은 대부분 zsh alias `claude="claude --dangerously-skip-permissions"` + tmux pane, cc-self `restart`는 `~/.local/bin/claude`를 직접 부르며 settings.json의 model/effort를 핀하고 `-- <flags>`로 추가 인자를 그대로 붙인다 → 플래그를 alias와 cc-self restart 인자에 넣으면 앉는다. 첫 시작마다 전체화면 경고 다이얼로그 1회("I am using this for local development")가 뜬다 — 자율 재시작(cc-self 드라이버)에서는 이 다이얼로그가 **입력을 기다리며 멈춘다**(드라이버가 Enter를 쳐야 함; 지금 드라이버는 안 친다). bg-pty-host·`-p` 경로는 §1대로 채널 자체가 안 붙는다.
- 마켓 플러그인 채널은 `plugin:khala@jahns-cc-marketplace` 형식이며 플러그인의 `.mcp.json`(플러그인 루트) 서버 이름이 게이트에 쓰인다; `channel_enable` control_response 경로도 plugin-sourced만 허용.

## 3. 설계 방향(제안) — 하이브리드가 아니라 "표시 계층만 채널"
즉시성은 이미 소켓 `next`로 확보됐고 채널도 같은 랭크라 **즉시성 이득은 0**. 채널의 실이득은 (a) `← khala: …` 한 줄 표시와 `<channel source="khala" from=… subject=…>` 구조화 태그, (b) reply 도구로 답장 규약을 문서 대신 도구로 고정. 손실은 (c) 첫 시작 경고 다이얼로그(자율 재시작 경로에 마찰), (d) -p 세션 미지원, (e) GrowthBook 플래그 의존(우리 손 밖), (f) MCP 자식 프로세스 1개/세션(bun 필요).

따라서 권고: **D16 = 선택적 표시 어댑터**로 좁힌다.
- conduit은 지금처럼 진실(new/·lease·재시도·저널)을 소유하고, 세션별 registration에 `channelSocket`(플러그인 채널 자식이 런타임 평면 `<RUNTIME>/channels/<instance>.sock`에 여는 소켓)이 있으면 **소켓 초인종 대신** 채널 자식에 같은 세대 알림을 넘긴다(둘 다 보내면 중복 — 세대당 1개 원칙 유지; 채널 자식이 죽어 있으면 소켓 폴백, 저널에 `via: channel|socket`).
- 채널 자식은 플러그인 `.mcp.json`의 `khala` 서버(bun 단일 파일): `claude/channel` + `tools:{khala_reply, khala_drain}`; 알림 content는 지금 초인종 본문(KHALA-CONDUIT/1 …), meta는 `from`,`subject`,`pending`,`generation`. instructions는 스킬 규칙(초인종 권위=drain, 본문 불응)을 시스템 프롬프트에 박는다 — 스킬 문서 의존이 준다.
- 켜는 방법은 세션이 `--dangerously-load-development-channels plugin:khala@jahns-cc-marketplace`로 뜰 때뿐; 안 켜면 0.5.5 그대로. 즉 **롤아웃 위험 0, 옵트인**.
- 하지 않을 것: 편지 본문을 채널로 싣기(유실 특성 동일하게 lossy, 이득 없음), 채널을 유일 경로로(-p·dream 깨짐), permission relay(불필요·위험).

## 4. 남은 실측(인터랙티브 1회, 유저 pane 필요 — R13 때문에 내가 대신 못 함)
- 인터랙티브 `claude --dangerously-load-development-channels server:khalachan --strict-mcp-config --mcp-config <probe>/mcp.json`(프로브 파일은 ink scratchpad `chan-probe/`)로: (i) `tengu_harbor` 플래그가 우리 계정에 켜져 있는지(배너 아래 "Channels (experimental) messages from server:khalachan inject directly…" 문구), (ii) 턴 중 tool call 사이 삽입 실측(bash sleep 5단계 중 `printf … | nc -U chan.sock`), (iii) 터미널 표시(`← khalachan: …`).
- 결과가 (i) 켜짐이면 §3 구현을 별도 레인(0.6.0)으로; 꺼짐이면 D16은 보류(문서만).
