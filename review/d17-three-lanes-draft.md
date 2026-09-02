# D17 초안 — 세 갈래: notice(워처 분리) · 사용자 레인(한 봇으로 수십 세션) · 대시보드 (ink, 2026-09-02)

유저 요청(09-02): ① 로컬 웹 대시보드 ② Telegram 봇 1개=세션 1개 한계를 넘는 오케스트레이션 ③ 세션 간 메시징과
non-세션(워처) 메시징의 확실한 구분. steno@b200 실측 회신(09-02)과 코드 실측을 반영한 **결정 요청용 초안**이다.
구현은 아직 없다. 각 절 끝의 "결정"이 유저 몫이다.

## 0. 한 줄 요약

- 세 요청은 한 축 위에 있다: **편지의 종류(Type)를 봉투에 명시**하고, 종류마다 초인종·표시·보존 규칙을 달리한다.
  `message`(세션↔세션) 외에 `notice`(기계→세션)와 `user`(사람→세션)를 1급으로 올린다.
- 대시보드와 Telegram 브리지는 코어 밖의 **관찰자·어댑터**로 둔다(R11: 없어도 칼라는 성립). 둘 다 같은 상주
  프로세스 `khala gateway`(khala-link 하위 명령, Go, 의존성 최소)로 묶고, 어댑터는 설정으로 켠다.
- 권장 순서: **A(notice, 0.8.0) → C(대시보드, 0.9.0) → B(사용자 레인+Telegram, 0.10.0)**. A는 이미 운용 중인
  배선(steno·clawd)의 통증을 바로 줄이고 B·C가 쓰는 헤더·마커를 먼저 깐다.

## 1. 오늘의 사실 (설계가 기대는 실측 — 코드 행은 정본 HEAD c813c1f 기준)

1. **편지 헤더**: `cmd_send`가 `Khala/Id/From/To/Date/Type: message/Subject?/In-Reply-To?/Priority: later?/Expires`
   순으로 쓴다(bin/khala:2620-2637). `Type`은 `message|ack|bounce|notice|entry`가 존재하고 **`notice`는 선언만 있고
   아무도 만들지 않는다**(DESIGN §9.6; deliver_infrastructure:1961이 `bounce|notice`를 fire-and-forget으로 배달할 준비는
   돼 있음). conduit은 봉투에서 `From/Subject/Priority`만 읽고 `Type`은 안 읽는다(link/conduit.go:669-703).
2. **`--later`의 실체**는 `Priority: later` 헤더 한 줄뿐이다. 초인종 우선순위는 "대기 편지 전부가 later일 때만
   later"(conduit.go:1042-1052). 채널 경로는 CC가 무조건 `next`로 큐잉하므로 `meta.later="1"`만 붙는다.
3. **stale ring의 원인**: `scan()`이 `inbox/<id>/new`를 읽어 pending·generation을 만든 뒤 `maybeRing`이 쓸 때까지
   **재확인이 없다**(conduit.go:389-393, 734-760). 그 사이 drain이 new→cur로 옮기면 "pending 1, drain 0통"이 된다.
   later 초인종은 idle에 표면화되므로 이 창이 가장 길게 보인다. 마커가 남는 게 아니라 스냅샷 경쟁이다.
   steno 전사 타임라인이 정합한다: later 편지 08:30:36Z → turn 중 즉시 편지와 묶여 08:31:3x drain(2통) → turn 종료 →
   08:32:34Z idle에서 초인종 1회 더(pending 1, drain 0).
4. **presence는 heartbeat 파일**이다. `send/say/inbox`가 `presence/<session>@<node>`에 epoch를 쓴다(bin/khala:403-416,
   2614). 그래서 `send --as gpu-guard`만으로 `gpu-guard@b200`이 `alive-here`로 뜬다 — steno 회신 (a)(e)의 뿌리.
5. **등록·lease·전달 저널은 runtime dir**(`/run/user/<uid>/khala/{sessions,identities,deliveries,channels}`)에만 있고
   복제·백업 밖이다(link/runtime.go:122-160). 링크가 나르는 것은 `spool/presence/streams/minds` 네 부류뿐
   (link/install.go:37-84). 따라서 **원격 노드의 "지금 귀 열림"을 알 수 있는 파일은 함대 어디에도 없다**. `khala presence`의
   WATCHING 열은 옛 `khala watch` 마커(`.watching`)만 본다.
6. **보존 구멍**: `inbox/<id>/cur`, `outbox/acked`, `outbox/dead`는 아무도 지우지 않는다. `new/`에 들어간 편지는 Expires가
   지나도 불멸이다(만료는 발신측·스풀 단계에서만 검사). 2분 주기 워처가 며칠 돌면 cur/가 알림으로 찬다 — steno (d).
7. **`session_name` 우선순위**: `--as` > `KHALA_SESSION`(set-ness 기준 — 빈 값도 이김) > `$PWD/.khala-session`(1행·유효명)
   > 오류(bin/khala:190-212). steno의 `env -u KHALA_SESSION; cd /`는 불필요하지만 무해하다. 빈 `KHALA_SESSION`이
   `.khala-session`을 가리고 실패하는 건 함정이다.
8. **CC 2.1.258 채널 게이트**(바이너리 문자열 실측): 공식 마켓 밖 플러그인 채널은 여전히 "not on the approved channels
   allowlist (use --dangerously-load-development-channels for local dev)". 함대 기본형(플래그 없음)은 계속 **소켓 초인종**이다.
   설계는 소켓 프레임을 진실로 두고 채널은 표시 어댑터로 유지한다(D16 결론 그대로).
9. **Telegram 플러그인이 세션당 봇 1개인 구조적 이유**: MCP 자식이 세션 안에서 `getUpdates`를 독점한다(플러그인
   server.ts:58-61 "exactly one getUpdates consumer per token… 409 Conflict"). 봇 토큰당 폴러 1개라는 Telegram 규칙 때문에
   세션 N개 = 봇 N개가 된다. 해법은 폴링을 세션 밖 한 곳으로 빼고 **칼라 편지로 팬아웃**하는 것이다.
10. **Go 측 수급**: `github.com/go-telegram/bot v1.25.0`이 proxy.golang.org에서 받아지고 `CreateForumTopic`,
    `SendMessageParams.MessageThreadID`, `Message.IsTopicMessage`를 갖췄다(scratchpad 프로브). CGO 없이 정적 빌드
    가능 → 기존 khala-link 4종 자산에 얹힌다. bun은 필요 없다.
11. **idle 세션 초인종 → 새 턴 개시: 실측 완료**(steno@b200 전사 집계 09-02, ink 독립 재집계 일치). steno 세션 전사
    (08-27~09-02, CC 2.1.248→2.1.258, 소켓 경로, skip-permissions)에서 user 턴으로 남은 초인종 **29건 전부 idle→새 턴**
    (예외 0), idle 지속 최대 10,761 s(≈3 h)·중앙값 278 s, 같은 노드 지연 <1~2 s, mini→b200 링크 경유 2 s. ink 세션에서도
    재현(보고 후 145 s idle에 steno 편지가 새 턴을 열었다). 구분자는 CC 래퍼 문구 — turn 중 도착은 tool_result에
    "…sent a message **while you were working**:", idle 도착은 새 user 턴 "Another Claude session sent a message:".
    **남은 미측**: 채널 경로(khala_drain), permission 프롬프트 대기 중, compact·종료 중(SessionStart 드레인으로만 관측).
    B 착수 전 별도 실측은 불필요하고, permission 프롬프트 상태 1건만 선택 항목이다(유저 pane 필요).

## 2. 제안 A — `notice`: 기계 알림을 편지와 분리한다 (0.8.0)

목표: steno 회신 §4를 그대로 채택하되 코드의 기존 틈(fire-and-forget 배달, 선언된 `notice` 타입)에 맞춘다.
스트림 강제 이관(c)은 하지 않는다 — 알림은 owner 1명의 사적 사건이고 wake가 필요한 경우가 있으며, 아무 세션이나
join하면 남의 GPU 알림을 받는다(steno §4-6 동의).

### A1. 봉투와 CLI

```
Type: notice
Urgency: urgent | info        # 봉투 전용. 본문은 절대 읽지 않는다(d15-r2 control-field 원칙)
From: gpu-guard@b200          # 워처 신원(§A5), To: steno@b200
Expires: <기본 now+172800>    # notice 기본 2일. -e로 조절
```

- `khala notify <session@node> --as <watcher> -s "제목" [--urgent] [-e SEC]` (본문 stdin; heredoc 규율 동일).
  `--urgent` 없으면 `info`. `notify`는 `--as`가 **필수**다(세션 자기 이름으로 알림을 만들지 않게).
- `send --as`는 그대로 동작(호환). 스킬 문서는 "기계 알림은 notify"로 바꾸고, `send --as`에는 한 줄 경고를 찍는다
  ("세션이 아닌 발신자라면 khala notify"). 강제 전환은 안 한다 — steno·clawd 배선을 안 깨기 위해.
- `Refs`는 쓰지 않는다(§9.6의 `Refs`는 ack/bounce용). `In-Reply-To`도 없음: notice는 대화가 아니다.

### A2. 전달 경로 — durable하되 ack·outbox 흔적이 없게

- notice는 **outbox를 거치지 않고 인프라 편지처럼 스풀에 직접 태어난다**(`queue_infrastructure_message` 경로,
  bin/khala:1402-1416; 목적지가 자기 노드면 inbox에 직접 배달). 발신측에 `outbox/new|acked` 흔적이 남지 않는다 → steno (d)의
  acked 축적 해소. 배달 보장은 링크의 STORED 확인·rsync 성공 뒤 스풀 삭제(`remove_pushed_infrastructure`:1626이 이미
  `notice`를 안다)로 지금의 ack/bounce와 같은 수준이다(R4: 잠든 세션에도 배달된다).
- 만료: 스풀에서 Expires가 지나면 bounce 없이 조용히 삭제. **`inbox/<id>/new`와 `cur`의 notice는 reconcile 주기에
  Expires로 prune**한다(오늘은 new/도 cur/도 영구 — 사실 6). `message`의 cur/ 보존은 별도 결정(§6-5).
- `inbox --drain`: notice도 new→cur 이동 후 출력(진실은 여전히 new/, 초인종 경로는 아무것도 옮기지 않는다는 불변식 유지).

### A3. drain 출력과 상한

```
--- letter <id> ---            # 편지 먼저, 지금 그대로
...
=== notices (3) ===             # 그 다음 알림 블록. 없으면 헤더도 없음
--- notice <id> --- gpu-guard@b200 · urgent · [gpu-guard] GPU2 FOREIGN 25m
<본문>
...
=== streams ===                 # 스트림은 마지막(지금과 같음)
```

- 옵션 `--mail-only` / `--notices-only`. 상한은 분리: 편지 20건·64KB(현행) + 알림 10건·16KB(기본). 초과분은
  "알림 N건 더 (gpu-queue 4, b1-monitor 2)"처럼 **워처별 건수**로 요약 — 편지가 알림에 묻히지 않는다(steno (c)).
- SessionStart 훅 보고: `편지 N건·알림 M건 드레인`.

### A4. 초인종 — urgency가 곧 정책

프레임에 두 줄을 더한다(`KHALA-CONDUIT/1`은 그대로, 필드 추가는 호환):

```
pending: 1        # message만
notices: 3        # notice 수 (urgent 1 / info 2 는 subjects 줄 앞에 U/I 표시)
```

- **generation(=울릴지 결정하는 집합)은 message + urgent notice의 Id로만** 만든다. info notice는 프레임 수에는
  잡히지만 **단독으로는 절대 울리지 않고** 다음 초인종·다음 drain·SessionStart에 편승한다(steno §4-4). 이것이
  `--later`보다 강한 약속이다(`later`는 CC가 idle에 표면화하므로 결국 깨울 수 있다).
- `Priority: later`(message)는 현행 유지. `khala_reply`/채널 메타는 `notices`·`urgency`를 같이 싣는다.
- 채널 경로 content 줄: `gpu-guard@b200 · U · <subject>`.

### A5. 워처 신원 클래스와 dead-man

```
khala watcher declare gpu-guard --cadence 600 --owner steno [--note "GPU 0-5 lock+mem"]
khala watcher list | retire <name>
```

- 파일: `presence/<name>@<node>.watcher` — 3행(`declared-epoch`, `cadence`, `owner`). `.watching` 마커와 같은
  꼴이라 링크의 presence 부류로 **복제된다**(단, link/config.go:116의 `presenceNode`가 `.watching`만 벗기므로
  **링크를 먼저 함대에 롤**해야 구 노드가 `.watcher` 오퍼를 거절하지 않는다. 거절은 조용하고 치명적이지 않다).
- `notify --as <name>`은 heartbeat를 **`presence/<name>@<node>`에 쓰지 않는다**. 대신 `.watcher` 마커의 last-notify
  epoch(4행째)를 갱신한다. 그래서 워처는 `khala presence` 본 표에서 사라지고, `khala presence --watchers`(또는 표 아래
  "watchers" 절)에 `NAME OWNER CADENCE LAST STATE(active|silent)`로 뜬다. `khala minds`는 `.watcher` 신원을 제외한다.
- 선언 없이 `notify --as <name>`을 부르면 **자동 선언**(cadence 미상 → dead-man 없음)하고 stderr에 한 줄 안내.
- **lease 금지**: `bind`는 `.watcher`가 선언된 이름에 lease를 주지 않는다(세션이 워처 이름을 실수로 차지 못함).
- **dead-man**: owner가 있는 노드의 brain reconcile이 `now - last > 2×cadence`로 `silent` 전이를 보면 owner에게
  urgent notice 1통(`[watcher] gpu-guard silent 25m (cadence 600s)`)을 **전이당 1회**만 만든다. 회복 시 info 1통.
  steno (e)와 현재 "세션 쪽 매시 cron이 로그 mtime으로 대신 봄"을 대체한다.
- `.watcher` 삭제는 복제되지 않으므로(링크는 삭제를 나르지 않음) `retire`는 마커 내용을 `retired <epoch>`로 바꾼다
  (presence retire와 같은 관례).

### A6. stale ring 수정 (사실 3)

- `maybeRing`이 소켓/채널에 **쓰기 직전** `new/`를 한 번 더 읽어 generation을 재계산한다. 비면 state를 버리고
  안 울린다. 창은 ms 단위로 준다(완전 제거는 아님 — drain은 브레인 락 아래, conduit은 락 밖).
- drain이 0통일 때 첫 줄에 `drained 0 — 초인종이 앞선 drain에 소진됨` 을 찍어 모델이 유실을 의심하지 않게 한다
  ([phantom-doorbell] 교훈: 유실 주장은 저널로 검증).
- 옵션(작음): `KHALA_SESSION`이 **빈 문자열로 set**이면 "unset"으로 보고 stderr 경고 — 조용한 폴백이 아니라 경고 있는
  정정. 결정 §6-5에 묶음.

### A7. steno·clawd 이행

- steno: `khala_notify.sh`의 `send … --as "$AS"` → `notify … --as "$AS" [--urgent]`(즉시=`--urgent`, `--later`=기본
  info). 한 줄 변경. `khala watcher declare` 3건(cadence 600/600/120).
- clawd@mini: `KHALA_SESSION=ghwatch khala send clawd@mini` → 동일. 순서: link·CLI 롤 → 워처 선언 → 스크립트 교체.
- 이행 기간엔 `send --as`도 계속 배달된다(경고만).

## 3. 제안 B — 사용자 레인: 봇 1개로 수십 세션을 부린다 (0.10.0)

### B0. 진단과 방향

봇 1개=세션 1개는 Telegram 규칙(토큰당 폴러 1개)과 "폴러가 세션 안에 산다"는 플러그인 구조의 곱이다. 폴러를 세션 밖
**상주 게이트웨이 1개**로 빼고, 받은 말을 **칼라 편지(`Type: user`)로 해당 세션에 배달**하면 세션 수와 봇 수가 분리된다.
회신도 편지다: 세션이 `user@<gateway-node>`에게 보내면 게이트웨이가 그 세션의 Telegram 토픽에 게시한다.

칼라 코어에 새로 들어가는 것은 **`user` 타입과 예약 신원 `user` 뿐**이다. Telegram은 게이트웨이의 어댑터 하나이고
설정으로 켠다(R7·R11: 코어는 제3자 없이 성립; R12: 토큰·chat id는 선언 설정). 평문이 Telegram 서버를 지나는 점은
기존 telegram 플러그인과 동일하며, 유저가 명시적으로 켠 어댑터에서만 일어난다. DESIGN §8 "사람은 각 세션의 유저로서만
등장"은 유지된다 — `user`는 함대의 주소가 아니라 **각 세션에 대한 그 세션 유저의 목소리**이고, From이 `user@<node>`인
것은 어느 게이트웨이가 대필했는지의 표시다.

### B1. 구성요소 `khala gateway` (khala-link 하위 명령, Go)

- 함대에 봇 토큰당 정확히 1개(권장: mini, 24/7·launchd 이미 있음). 노드 서비스로 `khala node ensure`가 함께 감독.
- 설정 `~/.khala/gateway.conf`(0600): `telegram token <…>`, `telegram chat <supergroup-id>`, `telegram allow <user-id>…`,
  `dashboard listen 127.0.0.1:47000`, `notices forward off|urgent|all`.
- 역할: ① Telegram 폴러+토픽 매핑 ② `user` 편지 발신·수신(자기 inbox `user/`를 drain하는 유일한 프로세스) ③ 대시보드
  HTTP(§4). 어댑터 인터페이스는 `inbound(text, origin-ref) / outbound(topic, text)` 두 함수라 Discord·Slack도 같은 레인에
  얹을 수 있다.

### B2. 봉투 `Type: user`

```
Type: user
From: user@mini                # 예약 신원. 게이트웨이만 만든다
To: steno@b200
Origin: telegram               # telegram | web
Origin-Ref: -1001234/57/9081   # chat/thread/message. 회신 스레딩용, 봉투 전용
Subject: (첫 줄 80자)
```

- 일반 CLI 경로에는 `user` 타입을 만드는 플래그가 **없다**(실수 위조 방지). 게이트웨이 내부 호출만 만든다. 같은 uid의
  프로세스가 마음먹으면 위조할 수 있다는 점은 위협 모델(DESIGN §5.6 "전부 유저 본인 머신") 밖이다.
- 세션 → 사용자: `khala send user@mini -s "..."`(평범한 message). 게이트웨이가 From 세션의 토픽(없으면 생성)에 게시.
  **In-Reply-To가 user 편지를 가리키면 그 Telegram 메시지에 답글 스레딩**(Origin-Ref 사용).

### B3. 수신 세션 규약 (스킬·채널 instructions에 박는다)

- user 편지 = **이 세션 유저의 말**. 초인종 프레임은 `user: N`을 따로 세고 항상 `next`로 울린다(`Priority`와 무관).
  drain 출력 최상단 `=== user (1) ===`.
- 답은 반드시 `khala send user@<node> --reply-to <id>`(또는 `khala_reply`)로 한다 — 사용자는 폰을 본다, 터미널 출력은
  닿지 않는다(telegram 플러그인 instructions와 같은 문장).
- CC 소켓 프레임 래퍼의 "not typed by your user" 문구는 봉투 규약이고, **편지 `Type: user`가 권위**임을 스킬에 명시.
  (프레임은 초인종일 뿐이고 편지 본문은 drain으로만 읽는다는 현행 원칙과 충돌하지 않는다.)
- permission relay(폰에서 권한 승인)는 v1 비목표 — 함대는 `--dangerously-skip-permissions`로 돈다.

### B4. Telegram 매핑 — 슈퍼그룹 + Topics

- 새 슈퍼그룹 1개(Topics 켜기), 새 봇 1개(admin + "Manage Topics"). 기존 세션별 봇과 토큰이 다르므로 병행 가능.
- **General 토픽 = 함대 콘솔**: `/sessions`(presence+minds 요약), `/open steno@b200`(토픽 생성), `/close`, `/say <stream> …`,
  `/notices steno@b200 urgent|off`. 봇의 자연어 처리는 없다 — 명령은 접두 `/`뿐, 나머지 텍스트는 General에선 무시.
- **토픽 1개 = 세션 주소 1개**(토픽 이름 = 주소). 매핑은 `~/.khala/gateway.state`(thread_id↔address, 0600)에 저장하고
  토픽 생성 이벤트(`forum_topic_created`)로 복구. 토픽에 쓴 글 → `user` 편지. 세션 회신 → 그 토픽.
- 세션이 먼저 말 걸기(`send user@mini`) → 토픽 없으면 만들어 게시. **워처 notice는 기본 전달 안 함**(폰 소음). 토픽별
  `/notices … urgent`로 켜면 urgent만 요약 1줄로 전달. 사용자에게 보고할 내용은 세션이 정리해서 보내는 게 정석이다.
- 제약 반영: 그룹당 봇 20 msg/min(Bots FAQ) → 토픽별 큐·합치기; 4096자 청킹(플러그인과 동일 규칙); 봇은 히스토리를 못
  읽는다 → 편지가 기록(`inbox/user/cur`)이고 대시보드에서 본다; 토픽 수 상한은 Bot API에 문서화돼 있지 않다(실측 항목).
- 폴러 단일성: 게이트웨이도 `getUpdates` 1개다. 다른 노드에서 실수로 두 번 뜨면 409 — `gateway.conf`가 있는 노드만
  `node ensure`가 띄운다(R12: 선언).

### B5. 왜 자체 앱이 아니라 Telegram + 웹인가

- 폰 **푸시**가 핵심 가치인데 자체 앱 푸시는 APNs/FCM(제3자)과 앱 배포가 필요하다. Telegram은 그 푸시를 대신하는
  어댑터이고, tailnet 안 웹 대시보드(§4)가 "자체 앱" 몫(전체 조망·편지 열람·보내기)을 한다. 둘 다 같은 `user` 레인 위다.
- 나중에 자체 앱을 만들더라도 게이트웨이의 어댑터 하나를 더하는 일이지 코어 변경이 아니다.

## 4. 제안 C — 대시보드: 읽기 전용 함대 지도 (0.9.0)

### C1. 형태

- `khala dashboard` → `khala-link gateway --dashboard-only`(게이트웨이 없이 단독 실행 가능). 기본 `127.0.0.1:47000`,
  `--listen <tailscale-ip>:47000 --token <…>`로 tailnet 공개(토큰 없으면 루프백만). Go stdlib `net/http` + 임베드 단일
  HTML/JS(외부 CDN 없음, 오프라인 동작). `/api/fleet.json` 5초 폴링(SSE는 후순위).
- 읽는 것(전부 로컬 파일 = 복제된 진실): `presence/`(+`.watching`·`.watcher`·`.ear` 마커), `minds/`, `streams/`(최근 N),
  `join/`·`cursor/`(로컬 세션의 미독 수), `inbox/<id>/{new,cur}` 건수·제목(로컬 신원), `config`(self/peer/mailbox),
  `spool/for/*`(노드 목록 근사), `run/link.fresh` mtime(신경 상태), runtime `conduit.status.json`·`sessions/*.json`·
  `identities/*.lease`(로컬 노드의 등록·lease·phase·CC 버전·마지막 전달). 쓰는 것: 없음(B가 켜지면 "user 보내기" 박스만).

### C2. 화면

- 노드 카드(허브 표시, link fresh ●/○, conduit 상태, 등록 세션 수) → 세션 행: 이름 · 상태 배지(alive-here/elsewhere/asleep +
  **듣고 있음 ✓**) · 모델/effort · role · charge · focus(stance, freshness) · pending new · last seen 상대시간.
- 워처 절(A5 마커: owner·cadence·last·silent), 스트림 탭(최근 엔트리), 편지 탭(로컬 inbox cur 최근 제목, 클릭 시 본문),
  헤더에 함대 합계(노드/세션/듣는 중/알림 미처리).
- 하지 않는 것: 세션 프로세스에 대한 어떤 조작(재시작·종료 버튼 없음 — R13 정신), 원격 노드 inbox 본문 열람(복제
  안 됨), 인증 체계(토큰 1개로 충분 — tailnet이 경계).

### C3. `.ear` 마커 — 원격 노드의 "듣고 있음"을 함대에 알린다 (사실 5의 구멍)

- conduit이 **검증 완료(ready·lease·소켓 확인)된 등록**마다 `presence/<id>@<node>.ear`(3행: epoch, interval 60,
  `socket|channel` + CC 버전)를 60초마다 갱신하고 해제·사망 감지 시 삭제한다. 링크의 presence 부류로 복제된다.
- 삭제는 복제되지 않으므로 소비자(`khala presence`, 대시보드)는 `now - epoch > 2×interval`이면 무시한다
  (`.watching`과 같은 age 규칙). `khala presence`의 WATCHING 열은 `.watching`(옛 ear)·`.ear`(conduit) 둘 다 `yes`로 본다.
- 이것으로 "asleep = 칼라 활동 없음 ≠ 죽음"의 안개가 걷힌다: 듣고 있으면 편지가 몇 초 내 초인종으로 닿는다는 뜻이다.
- 롤아웃 주의는 A5와 같다(구 링크의 suffix 파싱 → 링크 먼저 롤).

## 5. 크기·순서·검증

| 단계 | 내용 | 변경 파일 | 크기 | 선행 실측 |
|---|---|---|---|---|
| 0.8.0 A | notify·Urgency·drain 분리·watcher 클래스·dead-man·stale ring 재확인·cur/new notice prune | bin/khala, link/conduit.go, link/config.go, link/brain.go, plugin/{skills,hooks,channel}, README/DESIGN §9.6, test/notices.sh + conduit 테스트 | 중 | 없음. steno 워처 3개로 실전 시험(제안 받음) |
| 0.9.0 C | `.ear` 마커, `gateway --dashboard-only`, 임베드 HTML, presence WATCHING 통합 | link/{conduit,runtime,gateway,dashboard}.go, bin/khala presence, README | 중 | 없음 |
| 0.10.0 B | `user` 타입·예약 신원, gateway Telegram 어댑터(go-telegram/bot v1.25), 스킬·채널 규약, 대시보드 보내기 | link/gateway*.go, bin/khala(send user 경로·drain 최상단), plugin, DESIGN | 큼 | ① idle→새 턴: 완료(§1-11) ② 포럼 토픽 생성·스레드 왕복 실측(봇·그룹 준비 후 20분) ③ 선택: permission 프롬프트 대기 중 초인종 1건(유저 pane) |

- 각 단계는 D-라운드 관례(eddy 게이트, 필요 시 GPT-Pro 리뷰 — directive "설계가 막히면 ChatGPT")를 따른다. 이 초안은
  push 후 GPT-Pro 검토 후보다(§6-6).
- 링크 롤 순서(A5·C3의 suffix): link 전 노드 → CLI → 마커 생성. 구버전 링크는 새 마커를 조용히 거절하므로 순서가
  틀려도 데이터 손상은 없고 표시만 늦는다.

## 6. 결정 요청

1. **순서** A → C → B 로 간다. (대안: B를 먼저 — 폰 통합이 더 급하면. 그 경우 A1·A4의 헤더만 선행.)
2. **게이트웨이 상주 노드** = mini. (b200은 컨테이너 재생성 이력, mbp는 전원 불안정.)
3. **Telegram**: 브리지 전용 새 봇 + Topics 켠 새 슈퍼그룹(봇 admin·Manage Topics). 기존 세션별 봇은 원하면 병행.
4. **notice의 Telegram 전달 기본 off**, 토픽별 `urgent`만 opt-in.
5. 묶음 소품: `inbox/cur`·`outbox/acked`·`dead`에 보존기간 30일 도입 / 빈 `KHALA_SESSION` 경고 처리 — A에 같이 넣을지.
6. 이 초안을 public dev에 push하고 **GPT-Pro 리뷰**를 받을지(D14·D15 때처럼).

## 부록 — steno@b200 회신 요지 (2026-09-02, 원문은 ink inbox cur)

워처 3개(gpu-guard 10분·b1-monitor 10분·gpu-queue 2분)가 host cron one-shot으로 `send --as`만 호출(등록·lease·join 없음,
단방향). 수신은 소켓 초인종→drain→From/subject 접두 분기. 행동 사건은 울려야 하고 정보 사건은 다음 drain에 보이기만
하면 됨(`--later -e 172800`으로 표현). 사고: presence/minds 오염, later 편지 stale ring, drain에서 편지·알림 혼재, cur/acked
축적, 워처 dead-man 부재, 레인이 세션 이름으로 보내 답장이 섞인 사고(clawd). 원하는 모습: notice 1급 타입 + 워처 신원
클래스(dead-man) + drain/doorbell 분리 + urgency 초인종 + 짧은 보존; 스트림 이관은 반대. 초안 나오면 워처 3개로 시험 제안.
