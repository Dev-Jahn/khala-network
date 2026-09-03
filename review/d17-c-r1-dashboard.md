# D17-C r1 — 함대 지도: 노드 conduit의 `.ear` 스냅샷 + 읽기 전용 대시보드 (0.9.0, 2026-09-03)

> 계보: D17 초안 §4(`d17-three-lanes-draft.md`, 유저 승인 09-02 "전부 승인", 순서 A→C→B) →
> GPT-Pro 자문 §4 C1·C2, §5 X1-5·X1-6(`gpt-pro-d17-review.md`) → **r1 = 자문 접합·규범화.**
> 근거 코드 행은 정본 HEAD e429ac9(khala 0.8.1) 기준이며, 조사 시트는 `review/d17-c-factsheet.md`.
> 다음: eddy 게이트 → (필요 시 GPT-Pro 재검토) → LINK·CLI 두 레인 발사.

## 0. 한 문장

**노드 conduit이 "지금 이 노드에서 누가 듣고 있는가"를 파일 하나(`presence/conduit@<node>.ear`)로
60초마다 적고 링크가 그것을 다른 presence처럼 나른다.** 대시보드는 그 복제본과 이미 복제되는
파일들(presence·minds·streams)만 읽는 **관찰자**다 — 쓰는 것이 없고, 세션에 손대는 버튼이 없고,
없어도 칼라는 성립한다(R11).

## 1. 오늘의 구멍 (설계가 메우는 것)

1. **원격 노드의 "귀 열림"을 알 수 있는 파일이 함대에 없다.** 등록·lease·전달 저널은 runtime dir
   (`/run/user/<uid>/khala/{sessions,identities,deliveries,channels}`)에만 있고 복제 밖이다
   (link/runtime.go:122-161). `khala presence`의 WATCHING 열은 옛 `khala watch` 마커(`.watching`)만
   본다(bin/khala:5083-5084). 0.7.3부터 `khala watch`는 conduit이 있으면 마커 없이 양보하므로
   (bin/khala:4517-4531) 실제 함대에서 이 열은 사실상 항상 `-`다.
2. **presence는 활동 기록이지 생존 기록이 아니다.** heartbeat는 `send/say/inbox`만 쓴다(bin/khala:3191,
   3457, 4759). 조용한 세션은 `asleep`으로 보이고, 편지를 넣으면 몇 초 안에 초인종이 울릴지는 알 수 없다.
3. **"마지막 드레인 시각"이 어디에도 없다.** 드레인은 편지를 `new→cur`로 옮기고 touch하며 heartbeat를
   갱신하지만(bin/khala:4846-4851, 4759) 신원별 드레인 기록은 없다. B6(듣고는 있는데 처리가 없음)의
   재료가 없다.
4. **`.ear` 접미사는 0.8.0 링크가 이미 받아 나르지만(link/config.go:592, install_test.go:125) CLI는
   모른다.** 오늘 `presence/`에 `.ear` 파일이 하나라도 생기면 `khala presence`는 `valid_address` 검사에서
   **전체가 실패**하고(bin/khala:5047-5053) `khala reconcile`은 매 pass `sync_error`를 낸다(2714-2744).
   → **CLI를 먼저 롤하고 conduit을 나중에 롤한다**(§7). 이 순서는 A5의 링크 우선 순서와 반대다.
5. **한 노드는 함대의 노드 목록을 모른다.** `spool/for/*`·`presence/*@node`는 근사일 뿐이다(§8 시트).
   스냅샷 파일의 존재 자체가 노드 목록이 된다.

## 2. 구성 요소

| 구성요소 | 위치 | 역할 |
|---|---|---|
| 스냅샷 작성자 | `khala-link conduit` (link/conduit.go) | 60 s마다·전이 시 `presence/conduit@<self>.ear` 원자 교체 |
| 스냅샷 설치 가드 | `khala-link` installer (link/install.go) | `.ear`의 `generation` 퇴행 거부(`.watcher` 가드와 같은 자리) |
| 스냅샷 독자 | `bin/khala presence/minds` | WATCHING 열이 `.watching` ∪ 신선한 `.ear`를 본다 |
| 드레인 스탬프 | `bin/khala inbox --drain` | `run/drained/<identity>` 원자 쓰기 (conduit이 읽어 스냅샷에 싣는다) |
| 대시보드 | `khala-link dashboard` + `bin/khala dashboard` | 임베드 HTML/JS 1벌, `/api/fleet` JSON, 토큰, 무상태 |
| 예약 이름 | `bin/khala`·`khala-link runtime` | `conduit`·`gateway`·`operator`는 세션·워처·수신자로 쓸 수 없다 |

새 상주 프로세스는 없다. 대시보드는 `khala status`처럼 **온디맨드 포그라운드**다(bin/khala:4282-4290 관례):
켜 두고 싶으면 사용자가 tmux에 두면 된다. systemd/launchd 유닛은 0.9.0에 넣지 않는다(§9 열린 항목).

## 3. 온디스크 명세 (DESIGN §9.6에 추가할 문면)

### 3.1 `presence/conduit@<node>.ear` — 노드 귀 스냅샷

한 노드에 파일 하나. 작성자는 그 노드의 conduit 하나뿐(단일 작성자). `$KHALA_HOME/tmp/`에 쓰고
`presence/`로 rename(§9.6의 "같은 FS 안 tmp/ 경유 후 mv" 원칙 그대로 — 링크 스캔이 반쯤 쓰인 파일을
집어 가지 않는다). 줄 단위 텍스트, LF, **16 KiB·64행 상한.**

```
ears 1
node b200
generation 1788402001
interval 60
conduit 0.9.0
mailbox mini
link 3
identity steno socket ready 2.1.258 0 0 - 0 0 1788398112 1788401900
identity ink channel ready 2.1.258 1 0 3fa9c2d1 1788401950 2 1788402000 1788401800
```

- `ears 1` — 1행 고정(스키마 버전). 다른 값이면 독자는 파일 전체를 무시한다.
- `node <name>` — 파일명의 노드와 같아야 한다(다르면 무시).
- `generation <epoch>` — 작성 시각. 작성자 안에서 단조 증가: conduit은 시작 때 기존 파일의 값을 읽어
  두고 언제나 `max(now, last+1)`을 쓴다(시계가 뒤로 가도 원격 설치 가드에 걸리지 않는다).
- `interval <s>` — 작성 주기(기본 60). 독자의 신선도 기준.
- `conduit <version>` — 링크 바이너리의 릴리스 버전. link/main.go의 `implVersion`(0.5.0, HELLO 프레임의
  Impl 필드, link/pump.go:125)은 프로토콜 구현 버전이라 그대로 두고, 별도 `linkVersion` 상수를 두어
  릴리스마다 올린다.
- `mailbox <name...>` — config의 mailbox 줄 그대로(허브 판정용: 다른 노드가 나를 mailbox로 적으면 허브).
  자기 자신이면 `-`.
- `link <age-s>` — `run/link.fresh`의 나이(초). 없으면 `-`. (link/pump.go:679가 touch하는 그 파일.)
- `identity` 행 12토큰, 이름순 정렬, 노드의 **등록 파일이 있거나 lease를 가진 신원 전부**(phase 무관):
  1. `identity` 2. 이름 3. 경로 `socket|channel|none`
  4. phase(`ready|starting`, 등록 없으면 `-`) 5. CC 버전(없으면 `-`)
  6. 대기 ring 수(inbox/new의 message + urgent notice) 7. 대기 info notice 수
  8. 대기 generation 앞 8 hex(대기 없으면 `-`) 9. 그 generation을 conduit이 처음 본 epoch(0=없음)
  10. 그 generation에 쓴 초인종 수 11. 마지막으로 초인종을 **쓴** epoch(신원 기준, 0=없음)
  12. 마지막 드레인 epoch(`run/drained/<identity>` 1토큰, 0=없음)
- 경로 정의: `channel` = 등록이 `conduitVerified` ∧ `channelSocket≠""` ∧ `channelVerified`;
  `socket` = `conduitVerified` ∧ 소켓 있음; 그 외 `none`. **듣고 있음 = 경로 ≠ none.** 행이 없으면
  듣지 않는 것이다(누락 = not listening; GPT-Pro C1).
- 65행째부터는 싣지 않고 마지막에 `truncated <n>` 한 줄을 쓴다.
- 없는 것: 소켓 경로, pid, instance/session UUID, 제목, 본문, ssh 좌표, 토큰. (GPT-Pro C2 목록 그대로.)
- 알 수 없는 키 줄은 독자가 **무시**한다(0.10.0이 줄을 더해도 0.9.0 독자가 깨지지 않는다). 단 `node`·
  `generation`·`interval`이 중복되면 파일 전체를 무시한다(제어 헤더 중복 거부).

작성 시점: conduit 시작 직후 첫 scan 뒤; 그 후 `interval`마다; **듣는 집합의 전이**(검증 획득·상실,
등록 reap, `runtime release`)가 있으면 2 s 디바운스 뒤 즉시. 대기 편지 수 변화는 전이가 아니다(초당
쓰기를 막는다 — 대기 수는 최대 `interval`만큼 늦을 수 있고 화면은 "n초 전 기준"으로 적는다).
정상 종료(SIGTERM/SIGINT) 시 **identity 행이 없는 마지막 스냅샷**을 한 번 쓴다 — 삭제는 복제되지 않으므로
"이 노드는 지금 아무도 못 듣는다"를 파일로 말하는 유일한 방법이다.

### 3.2 신선도·복제·보존

- **신선도는 독자 로컬 mtime으로 판정한다**: `now − mtime ≤ 2 × interval`이면 fresh, 아니면 stale.
  네이티브 OFFER 경로는 설치 시각을 mtime으로 남기고(link/install.go:244-250, Chtimes 없음) rsync
  폴백은 원본 mtime을 보존하므로(`-a`, bin/khala:1857) 어느 경로든 "받은 쪽 시계 기준 최근성"이거나 그보다
  보수적이다. 원격 시계와 `generation`을 직접 비교하지 않는다(GPT-Pro C1 시계 skew 지적).
- **설치 가드**(link/install.go, `.watcher` 가드 옆): 들어온 `.ear`의 `generation`이 기존 파일의 것보다
  **작으면** 버리고 로그. 같고 바이트가 다르면 기존을 두고 로그(작성자가 하나이므로 정상 경로에서는 생기지
  않는다 — 생기면 버그·위조 신호다). 파싱 불가면 그냥 교체(가드는 순서만 지키고 검열하지 않는다).
- **보존**: `prune_presence`가 `.ear`를 heartbeat로 파싱하지 않고 **mtime이 `retain`일보다 오래되면
  삭제**한다. reconcile 핫패스(1 s)에서 `.ear`는 파싱되지 않는다 — 정리 pass(300 s)에서 stat 한 번뿐.
- **접미사는 `.ear` 단수**다. GPT-Pro 초안의 `.ears`는 링크가 모르는 접미사라 바이너리 선행 롤이 필요하지만
  `.ear`는 0.8.0/0.8.1 링크가 이미 나른다(link/config.go:592) — 링크 롤 없이 복제가 시작된다.

### 3.3 `run/drained/<identity>` — 드레인 스탬프 (복제 안 됨)

`khala inbox --drain`이 요약 줄을 찍기 직전 `run/drained/<identity>`에 한 줄
`<epoch> <letters> <notices> <streams>`를 원자 쓰기(tmp+mv). `--mail-only`/`--notices-only`도 쓴다.
드레인 이외의 inbox 모드(list/read)는 쓰지 않는다. conduit은 1토큰(epoch)만 읽어 12열에 싣는다.
run/은 복제 밖이므로 원격 노드는 스냅샷을 통해서만 본다.

### 3.4 예약 이름

`conduit`, `gateway`, `operator`는 **주체 예약 이름**이다(GPT-Pro X1-4: 주체 클래스를 이름에서 추론하지
말고 예약하라). 거부 지점: 세션 신원 해석(`session_name`, bin/khala:283-310), `--as`, `watcher declare`,
`send`/`notify` 수신자의 세션 부분, Go `runtime register/bind`의 identity(link/runtime.go:715의
`invalid identity` 검사 옆). 메시지: `예약된 이름입니다: <name>`. 기존 함대 presence에 이 셋과 충돌하는 신원은 없다(09-03 실측). `gateway`·`operator`는 B가 쓸
이름을 지금 잠그는 것이고 0.9.0에서는 거부 외의 의미가 없다.

## 4. `khala presence`·`minds`의 변경

- WATCHING 열 = `.watching`(있고 신선) **또는** 그 노드의 `.ear`가 fresh이고 그 신원 행의 경로가 `socket|
  channel`이면 `yes`. 범례 줄에 "`.ear` = 노드 conduit이 듣는 중"을 덧붙인다.
- `.ear`는 세션 표에 행으로 나오지 않는다(`*.watching|*.watcher|*.ear` skip). `khala minds`의 주소 합집합
  (bin/khala:3930-3937)도 `.ear` 접미사를 벗겨 `conduit@node`를 만들지 않는다.
- 파싱 불가한 `.ear`는 **경고 후 없는 것으로** 본다(hard fail 금지 — 오늘의 heartbeat 오류가 표 전체를
  죽이는 것과 달리, 다른 노드의 결함이 내 화면을 막지 않는다).
- 구현 제약: presence는 `.ear` ≤ 8개를 한 번씩 read 루프로 읽어 "듣는 주소 목록" 문자열을 만들고 행마다
  `case` 매칭한다 — fork 없음. reconcile은 건드리지 않는다.

## 5. 대시보드

### 5.1 명령

```
khala dashboard [--listen ADDR] [--token-file PATH] [--with-text]
```

`cmd_status` 관례로 `khala-link dashboard`를 exec한다(`KHALA_HOME` 상속). Go 쪽 규칙:

- `--listen` 기본 `127.0.0.1:47000`. 루프백이 아닌 주소에는 `--token-file`이 **필수**(없으면 exit 2, 루프백
  폴백 없음). 포트 사용 중이면 exit 1(다른 포트로 조용히 옮기지 않는다).
- **토큰은 항상 요구한다.** `--token-file`이 없으면 실행마다 32바이트 난수 토큰을 만들어 stdout에
  `dashboard: http://127.0.0.1:47000/` / `token: <base64url>` 두 줄로 알린다(파일에 남기지 않는다).
  b200처럼 다중 사용자 호스트에서 루프백은 경계가 아니다. 페이지는 토큰을 한 번 받아 localStorage에 둔다.
- `--with-text`: 제목·편지 본문·focus/stance·스트림 본문을 API에 싣는다. `--listen`이 없으면(로컬 기본)
  자동 on, 비루프백이면 명시할 때만 on. 메타데이터 모드는 GPT-Pro C2의 "노출 금지" 목록을 그대로 지킨다.
- 종료: SIGINT/SIGTERM에 0. 쓰는 파일 없음(로그도 stderr뿐).

### 5.2 HTTP 계약

| 경로 | 내용 |
|---|---|
| `GET /` `/app.js` `/app.css` | 임베드 정적 파일(`embed`), 외부 CDN 없음, 인라인 스크립트 없음 |
| `GET /api/fleet` | 함대 JSON 1건(§5.3). `Authorization: Bearer <token>` 필수, 아니면 401 |
| `GET /api/letter?id=<Id>` | `--with-text`일 때만. 로컬 노드 신원의 `inbox/<id>/{new,cur}/<Id>` 본문. `Id`는 message-id 문법으로 검증(link/config.go:494), 아니면 400; 파일은 `Lstat`로 정규 파일만 |

응답 헤더: `Cache-Control: no-store`, `Content-Security-Policy: default-src 'none'; script-src 'self';
style-src 'self'; connect-src 'self'; img-src 'self' data:`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: no-referrer`. CORS 헤더 없음(동일 출처만). 토큰 비교는 `crypto/subtle` 상수 시간.
클라이언트가 준 경로로 파일을 여는 API는 없다. 상태를 바꾸는 엔드포인트는 없다(POST 전부 405).

### 5.3 `/api/fleet` 내용 (읽는 파일 = 전부 로컬)

- `nodes[]`: 스냅샷 파일마다 하나 — `node, hub(bool), snapshotAge, fresh, conduitVersion, linkAge,
  identities[]`(§3.1의 12열을 이름 붙인 객체로; `listening = route≠none`). 스냅샷이 없지만 presence에
  `@node`가 있는 노드는 `snapshot: null`인 카드로.
- `sessions[]`: presence heartbeat ∪ minds 현재 세대 — `address, state(alive-here|alive-elsewhere|asleep|
  unknown), lastSeen, listening, model, effort, role, charge, freshness` (+ `focus, stance`는 with-text).
  워처 신원은 제외(`.watcher` 비은퇴).
- `watchers[]`: `.watcher` 마커 — `name, node, owner, cadence, last, state, since`(0.8.2 6행 마커면 since).
- `streams[]`: `name, entries, latest`; `localUnread{identity: n}`은 자기 노드 세션의 join/cursor로
  (conduit.go:1140-1197과 같은 규칙, Go 재사용). with-text면 최근 20건 `{id, from, date, subject, body}`.
- `letters[]`(자기 노드 신원, with-text): `inbox/<id>/{new,cur}` 최근 50건 `{id, identity, from, date, type,
  urgency, subject, state(new|cur), age}`.
- `self{node, mailbox, version}`, `generatedAt`.

원격 노드의 inbox 본문·제목은 복제되지 않으므로 **애초에 없다** — "원격은 presence 뷰 + 스냅샷, 로컬은
전부"라는 GPT-Pro C2의 한계 문장을 화면 머리에 그대로 적는다.

### 5.4 화면 (vanilla JS, 5 s 폴링, ~400행)

- 머리: 함대 합계 — 노드(스냅샷 fresh/전체) · 듣는 세션 · 대기 ring 합 · silent 워처 수 · "n초 전 기준".
- 노드 카드 그리드: 이름 · 허브 배지 · link ● / ○(age) · conduit 버전 · 스냅샷 age → 세션 행: 이름 ·
  상태 배지(alive-here/elsewhere/asleep) · **듣는 중 ✓(socket|channel)** · model/effort · role · charge ·
  focus(with-text) · pending ring/info · 마지막 초인종 · 마지막 드레인 · last seen.
- 워처 표, 스트림 탭, 편지 탭(with-text; 클릭하면 `/api/letter` 본문).
- 없는 것: 세션에 대한 어떤 버튼(재시작·종료·보내기 없음 — 보내기는 B에서), 원격 본문, 인증 체계 2개째.

## 6. 릴리스 전 필수 불변식 (레인이 테스트로 먼저 고정할 것)

1. `.ear`가 `presence/`에 있어도 0.9.0 `khala presence`·`minds`·`reconcile`은 실패하지 않는다; 파싱 불가
   `.ear`는 경고 1줄 후 무시된다.
2. WATCHING은 `.watching` 신선 ∨ (`.ear` fresh ∧ 행 경로≠none)에서만 `yes`; stale `.ear`(mtime>2×interval)
   은 `-`.
3. 스냅샷은 소켓 경로·pid·UUID·제목·본문·ssh 좌표를 **한 바이트도** 싣지 않는다(테스트가 파일 전체를 grep).
4. 스냅샷 쓰기는 초당 1회 이하이고 대기 편지 수 변화만으로는 쓰지 않는다; 전이 후 ≤ 3 s 안에 새 파일.
5. 설치 가드: 낮은 `generation`은 설치되지 않는다; 같은 generation·다른 바이트는 기존을 유지한다.
6. `prune_presence`는 `.ear`를 mtime>retain일에만 지우고 결코 파싱하지 않는다.
7. `run/drained/<identity>`는 `--drain`에서만 쓰이고 내용은 4토큰이다; 드레인 실패 시 쓰지 않는다.
8. 예약 이름 셋은 §3.4의 모든 지점에서 거부된다; `valid_name` 자체는 바뀌지 않는다(파일명 문법 불변).
9. 대시보드: 토큰 없는 `/api/*`는 401; 비루프백 `--listen`에 `--token-file` 없음은 exit 2; 잘못된 `id`는
   400; `--with-text` 없으면 `/api/letter`는 404이고 `/api/fleet`에 subject·body·focus·stance 키가
   **존재하지 않는다**; 응답마다 §5.2 헤더; POST는 405.
10. 대시보드 프로세스는 `$KHALA_HOME` 아래 어떤 파일도 만들지 않는다(테스트가 실행 전후 트리를 대조).
11. reconcile 게이트 pass 시간(0.8.1 실측 b200 0.2-0.3 s)이 0.9.0에서 늘지 않는다 — 실제 트리 사본 실측을
    보고서에 적는다(0.8.0 사고의 재발 방지, memory `khala-reconcile-sweep-starvation`).

## 7. 롤아웃 순서 (A5·0.8.0과 반대 — CLI 먼저)

1. **CLI 0.9.0을 8노드 전부**에(수동 scp + 마켓 핀). 이 시점 `.ear`는 아직 없다 — 무해.
2. **link 바이너리 0.9.0 + conduit·link 재시작**을 노드별로. 재시작한 conduit이 곧 `.ear`를 쓰고 링크가
   나른다(0.8.x 링크·serve도 나른다 — 가드만 없다).
3. 검증(노드마다): `ls presence/conduit@*.ear` 8개, `khala presence`에 등록 세션 WATCHING `yes`,
   `khala reconcile` rc 0, b200 `khala dashboard`에 카드 8장·듣는 세션 수가 `khala status` 합과 일치.
4. 혼재 창: (CLI 0.9.0 + conduit 0.8.1) = 스냅샷 없음, 카드만 비어 있음. (conduit 0.9.0 + CLI 0.8.1) =
   그 노드 `khala presence` 전체 실패 — **순서 위반이므로 금지**; 롤 스크립트가 CLI 버전을 먼저 확인한다.
5. 장수 플러그인 세션의 CLI 되돌림 함정(memory `khala-plugin-cli-downgrade`)은 그대로 — 롤 뒤 `sha` 대조.

## 8. 레인 분할 (파일 소유 분리, 심볼 결합 없음)

| 레인 | 소유 파일 | 내용 |
|---|---|---|
| **LINK** (Go) | `link/*.go`, `link/*_test.go`, `link/dashboard/*`(임베드 자산), `test/conduit.sh`(H21+), `report/ears-dashboard-v09.md` | 스냅샷 작성자(first-seen 추적·재시작 복원 포함) · 설치 가드 · `dashboard` 서브커맨드(서버+UI) · `runtime register/bind` 예약 이름 · `linkVersion` |
| **CLI** (bash) | `bin/khala`(=`plugin/bin/khala`), `test/ears.sh`(신규), `test/watchers.sh`(WATCHING 범례), README, DESIGN §9.6, `plugin/.claude-plugin/plugin.json`, `plugin/channel/server.ts`(버전 문자열만), `test/channel-mcp-client.py`, `test/minds.sh`(버전) , `report/ears-cli-v09.md` | `.ear` 독자(presence/minds) · prune · 드레인 스탬프 · 예약 이름 · `khala dashboard` 래퍼 · 문서 |

두 레인이 공유하는 계약은 §3.1 형식과 §5.1 플래그뿐이며 둘 다 이 문서에 고정돼 있다. CLI 레인의 `khala
dashboard` 테스트는 가짜 `khala-link`(인자를 echo)로 exec 인자를 검증한다 — 실제 서버는 LINK 레인의 Go
테스트(`httptest`)와 conduit.sh가 맡는다. 검증 레인 1개(GPT-Pro 자문 우선순위: 스냅샷 유출 grep·가드·
토큰·헤더·트리 무변경)가 두 레인 병합 뒤 tempdir에서 재현한다.

## 9. 열린 항목

1. **상주 여부**: 0.9.0은 온디맨드다. B(0.10.0)의 `khala gateway`가 상주하면 대시보드는 그 안의 `--dashboard`
   플래그로 흡수된다(초안 C1의 원안). 그때 systemd/launchd 유닛을 한 번에 넣는다.
2. **`deliveries/` 저널은 아무도 지우지 않는다**(시트 §10 열린 1). 스냅샷 11열의 재료라 0.9.0이 읽기는
   하되 정리는 0.9.x 소품으로: boot 다른 것·30일 지난 것 삭제.
3. **B6 경보 문면**은 B의 몫이다. 0.9.0은 재료(9·10·12열)만 싣는다.
4. **0.8.2 6행 `.watcher`**(레인 진행 중)와의 순서: C의 CLI 레인은 0.8.2 병합 뒤 그 HEAD에서 시작한다
   (`print_watcher_table`·`read_watcher_marker`를 둘 다 만지므로 직렬화).
5. **`khala watch`의 `.watching`**: 유지. 0.9.0에서 없애지 않는다(D15 불변식 "watch 경로 제거 금지" 조건이
   아직 다 닫히지 않았다).
