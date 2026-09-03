# D15 r0 — 귀는 노드가 갖는다: herald + CC 네이티브 인박스 (초안, 2026-08-15)

> 계보: 유저 지시 3건("무장 0회 자동 접속", "native messaging처럼", "막히면 ChatGPT")
> + 함대 VOC 6통(eddy·steno·reel·cc-self·newton·clawd) + ink 실측(소켓 미개방 원인,
> 와이어 형식, hold 정책, 훅 환경변수). GPT Pro 자문 발사됨(회신 접합 대기).
> **상태: r0 초안 — 게이트 전. 결정: 유저.**

## 0. 한 문장

**편지가 노드에 닿는 것**(link)은 이미 잘 된다. 안 되는 건 **닿은 편지가 살아 있는
세션 안으로 들어가는 마지막 한 뼘**이다. 지금은 세션마다 "귀"(watch)를 손으로 세우고,
편지 하나에 귀가 눕고, 다시 세운다. D15는 귀를 세션에서 떼어 **노드 상주 프로세스
하나(herald)** 에 주고, herald가 CC가 원래 갖고 있는 **세션 인박스 소켓**에 편지를 밀어
넣는다. 세션은 아무것도 무장하지 않는다. 편지는 `<cross-session-message>`로 다음 턴
머리에 놓인다 — CC 네이티브 메시징과 같은 모양, 같은 시점.

## 1. 실측 사실 (설계의 발판 — 전부 2026-08-15 이 세션이 잰 것)

### 1.1 CC 소켓이 b200에서 안 열리던 원인은 우리 심링크였다
- CC 2.1.229+ 는 소켓 디렉터리(`${XDG_RUNTIME_DIR:-${CLAUDE_CODE_TMPDIR:-os.tmpdir()}}/cc-socks`)를
  만들기 전에 경로 안전성 검사(`UqS`)를 한다. 규칙 중 하나: **잎이 심링크면 거부**
  (`leaf_shape: sockets directory is a symlink — refusing`). 조상은 "0700 내 소유 or
  sticky(/tmp)" 이어야 한다.
- b200 `/tmp/cc-socks`는 8/11에 우리가 TMPDIR 불일치를 우회하려고 심링크(→ `~/tmp/cc-socks`)로
  만든 것. 2.1.228까지는 검사가 없어 열렸고(옛 eddy), 이후 모든 새 세션이 조용히 거부됐다.
  bw2(`/run/user/1001/cc-socks`, 실디렉터리)는 2.1.233도 잘 연다.
- **조치 완료**: 심링크 제거 → 0700 실디렉터리. 새 `-p` 세션이 즉시 바인드, `ListAgents`에 등장.
  살아 있는 세션(ink·eddy·steno)은 late-bind가 GrowthBook 갱신 때만 일어나 **재시작 전까지 dark**.
- 함대 다른 노드: bw2·spark1 정상, mini·mbp는 `$TMPDIR/cc-socks` 없음(세션이 안 떠 있어서일 뿐, 심링크 아님).

### 1.2 인박스 와이어 형식 (2.1.233 바이너리 역공학 + 실측)
- 줄단위 JSON. 수신 프레임:
  `{"type":"user","message":{"role":"user","content":"<비어있지 않은 문자열>"},"from":"<문자열>","priority":"now|next|later","msg_id"?,"uuid"?,"session_id"?}`
  선택적 첫 줄 `{"type":"auth","token":"<CLAUDE_CODE_MESSAGING_TOKEN>"}`. `control` 프레임(`rename`, `peer_message_status`)도 있음.
- 모델에게는 `origin.kind="peer"`, `isMeta:true`, `skipSlashCommands:true`인 프롬프트로 큐잉되어
  **다음 턴 머리(또는 툴 라운드 사이)** 에 `<cross-session-message from="…" from-name="…">본문</cross-session-message>`
  꼴로 놓인다. `priority` 기본 `next`.
- **`content`에 래퍼를 미리 씌우면 안 된다** — CC가 래퍼를 파싱해 origin으로 흡수하고 본문이
  비어 보인다(실측: 래핑 프레임은 모델에 안 보였고, 평문 프레임은 보였다). 평문만 보낼 것.

### 1.3 hold 정책 실측 (bypassPermissions `-p` 세션, 외부 프로세스가 소켓에 게시)
| 설정 | 무인증 프레임 | 토큰 인증 프레임 |
|---|---|---|
| `crossSessionInbound` 미설정 | **미도착**(hold → 5분 후 폐기) | **미도착** |
| `crossSessionInbound: accept` | 도착 | 도착 |
- 즉 bypass 세션에는 **accept 설정이 필수**다. 토큰(own-child) 경로는 `-p`에서 통하지 않았다 —
  문서상 own-child 판정은 "설정 미적용 시" 예외인데, 실측에선 `-p` bypass에서 hold됐다.
  (인터랙티브 세션에서의 재실측은 소켓이 열린 세션이 필요 → 재시작 후 과제.)
- 도착한 프레임을 모델은 "다른 Claude 세션이 보낸 메시지"로 인식하고 사용자 지시가 아니라고
  스스로 경계했다 — 정확히 원하는 격리 의미론이다.

### 1.4 SessionStart 훅은 소켓 경로·토큰을 받는다
- 훅 환경: `CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<pid>.sock`, `CLAUDE_CODE_MESSAGING_TOKEN`(32자).
  두 번의 새 세션 모두 SessionStart 시점에 이미 설정돼 있었다(플래그 캐시된 상태). 문서: 첫 설치
  직후엔 늦게 설정될 수 있음.

### 1.5 함대 VOC 요약 (6통, 원문은 ink 수신함 cur/)
- **만장일치**: 무장 0회 자동 접속. 재무장 왕복이 최대 불편(하루 15회+, 좀비 watch, 트리 정리에 딸려 죽음, Stop 훅 오판).
- 신원이 cwd basename으로 **조용히 생성** → 유령 발신자 하루 3회(reel/clawd). "없으면 에러로 멈춰라".
- watch가 reconcile을 소유 → 노드당 귀 N개가 1초 주기로 lock 다툼(10분당 ~40 게이트 실패; mini는 60회 연패도).
- 실행 중 CLI 제자리 덮어쓰기(scp)로 watch가 bash 파스 오류로 사망(cc-self·newton) — 롤은 tmp+mv만.
- 스트림 항목이 편지와 같은 wake 경로 → 정보성 브로드캐스트가 함대 턴을 태움. no-wake·버스트 합치기.
- 그 외: 서브커맨드 `--help`, `--subject/--message` 별칭, In-Reply-To, watch 종료사유 구조화, 편지/스트림 시각 분리, 편지 단위 read.
- **좋았던 것**: 편지 유실·중복 0(reel 20통+, eddy, newton), 지연 없음, "파일은 각자·메시지만 확실히" 설계 지지.
- ink 자체 실측 버그: `inbox --drain | head`가 중간에 끊기면 같은 편지가 **두 번 드레인**됨(SIGPIPE가 new→cur 이동 전에 끊음). 0.4.1은 락만 고쳤다.

## 2. 설계

### 2.1 뿌리 문장 증보
> …**세션은 귀를 갖지 않는다. 귀는 노드가 갖는다(herald). 편지의 마지막 한 뼘은 CC의 세션
> 인박스 소켓이며, herald는 그 소켓의 자격 있는 게시자다.**

### 2.2 구성 요소
| 이름 | 무엇 | 어디 | 수명 |
|---|---|---|---|
| **herald** | 노드 상주 귀. `inbox/*/new`를 지켜보다 편지를 해당 신원의 살아 있는 세션 소켓에 게시 | 노드당 1 (khala-link 안 또는 별도 — §3.E) | 노드 수명 |
| **registration** | 세션→소켓 바인딩. `~/.khala/run/sessions/<identity>` = pid, socketPath, cwd, startedAt | 세션당 1 | 세션 수명(Stop/SessionEnd에서 제거, herald가 dead pid 정리) |
| SessionStart 훅 | (a) 신원 확정 — `KHALA_SESSION` → `.khala-session` → **없으면 거부+안내** (cwd 추론 폐지); (b) registration 기록; (c) 밀린 편지 드레인(기존); (d) herald ensure(기존 link ensure 확장) | 세션 시작 | 1회 |
| Stop 훅 | **재무장 block 삭제.** registration 유지만(세션은 계속 산다) | — | — |
| SessionEnd 훅 | registration 제거 | 세션 종료 | 1회 |

### 2.3 편지 한 통의 여정 (D15 이후)
1. `khala send eddy@b200 …` → 발신 노드 outbox 안착(성공) → link가 b200 `inbox/eddy/new/`에 설치. (변경 없음)
2. b200 herald가 inotify로 새 파일을 본다 → `run/sessions/eddy` 읽음 → 소켓 존재·pid 생존 확인 → 프레임 게시:
   `content` = "From/Subject/Date 헤더 요약 + 본문 + 한 줄 꼬리(답장: `khala send <from> …`)", `from`=`khala:<from주소>`, `priority`=`next`(§3.D), `msg_id`=편지 Id.
3. 소켓 쓰기 성공 → 편지 `new→cur` (+ `Delivered-To: pid@ts` 부기). 실패(소켓 없음/거부/pid 사망) → `new/`에 그대로 → 백오프 재시도 → 그 신원의 다음 SessionStart 드레인이 안전망.
4. 세션의 다음 턴 머리에 `<cross-session-message from="khala:reel@bw2" …>` 로 놓인다. 세션은 읽고, 답하려면 `khala send`.
5. 스트림 항목: 기본 wake 안 함. herald는 편지 프레임 꼬리에 "스트림 N건 대기 — `khala inbox --streams`"만 붙이거나, `Wake: yes` 헤더가 있으면 편지처럼 게시.

### 2.4 reconcile 소유권
- herald(=link)가 유일한 주기적 reconcile 주체. 세션 측 `khala watch`는 **폐지**(호환 alias로 남기되 "herald가 있으면 아무것도 안 함").
- link.fresh가 stale(link 죽음)일 때의 폴백: SessionStart 훅이 `link ensure`로 되살린다. 세션이 reconcile을 돌리는 경로는 없앤다 → lock 경합 구조적 소멸(eddy (c) 채택).

### 2.5 신원
- 결정 순서 `KHALA_SESSION` → `.khala-session` → **거부**. 훅은 거부 시 "이 세션의 칼라 이름을 정하라: `echo <name> > .khala-session`" 한 줄만 찍고 나머지 훅 동작(드레인·registration)을 건너뛴다. 유령 신원 클래스 종결.
- 같은 신원을 두 세션이 동시에 등록하면(resume+fork): registration은 pid별 다중 허용, herald는 **가장 최근 startedAt 하나**에만 게시하고 나머지에는 안 보낸다(§3.C 자문 대기).

### 2.6 CLI 표면 (VOC 반영, 소품)
- 모든 서브커맨드 `--help`; `send --subject/--message` 별칭; `In-Reply-To:` 헤더(`send --reply-to <Id>`); `inbox --drain` SIGPIPE 시 이동 순서 수정(먼저 new→cur 원자 이동, 그다음 출력); `inbox read <Id>` 편지 단위; watch 종료사유 첫 줄 구조화(호환 기간 동안).

## 3. 열린 질문 (GPT Pro 자문 회부 — 회신 접합 예정)
- **A. hold 정책**: 함대 전체 `crossSessionInbound: accept`(같은 uid 로컬 게시자 전부 수용 — 신뢰 확장 허용?) vs 토큰 own-child 경로(실측 `-p`에서 불통) vs 기타. CC가 정책을 바꾸는 날의 대비.
- **B. 비공식 와이어**: 필드명 바뀌면 조용히 dark. 배달 실패 감지 방법(peer_message_status가 외부 게시자에게도 오는지 미확인). 앱 레벨 ack를 둘지, "소켓 쓰기 성공=cur 이동 + SessionStart 드레인 안전망"으로 at-least-once 충분한지.
- **C. late-bind·경합**: 등록됐는데 소켓 없음 → 백오프? 같은 신원 다중 세션 → 전부/최신/거부?
- **D. priority**: 편지는 항상 `later`(턴 끝)? `next`와의 득실.
- **E. herald 위치**: link(Go) 안 vs 별도 프로세스(장애 독립).
- **F. 놓친 것**: 유실/중복/오배달 시나리오, CC 자체 dedup·rate-limit(동일 재시도 단기 드롭)과 at-least-once 재시도의 충돌, macOS, `-p` 워커.

## 4. 비목표
- CC Remote Control 경로 사용(계정 결합) — 공존만.
- link/브레인의 on-disk 포맷 변경 — 없음. 편지 파일·streams·minds 그대로.
- 파일 전송 — 여전히 안 함(reel: "파일은 각자, 메시지만 확실히"가 옳았다).

## 5. 다음 단계 (유저 결정 대기)
1. GPT Pro 자문 접합 → r1 → eddy 게이트.
2. 인터랙티브 세션 소켓 실측(ink·eddy·steno 재시작 필요 — 지금은 dark). 특히 hold 정책·own-child 토큰 경로·`later` 체감.
3. r1 GO 시 lane 2개: (a) herald + registration + 훅 개편(플러그인), (b) CLI 소품(VOC).
