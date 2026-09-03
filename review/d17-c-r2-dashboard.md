# D17-C r2 — 함대 지도: 노드 conduit의 `.ear` 스냅샷 + 읽기 전용 대시보드 (0.9.0/0.9.1, 2026-09-03)

> 계보: D17 초안 §4(`d17-three-lanes-draft.md`, 유저 승인 09-02, 순서 A→C→B) → GPT-Pro 자문 §4 C1·C2
> (`gpt-pro-d17-review.md`) → r1(`d17-c-r1-dashboard.md`, 429f814) → **eddy 게이트 GO-라이더**
> (`eddy-d17-c-r1-gate.md`: 정의 1 ring 게이트 일치·독자 상한·rsync push 글롭·두 태그 롤·불변식 +5)
> → GPT-Pro r1 검토(`gpt-pro-d17-c-review.md`, 도착 시 §10에 접합) → **r2 = 라이더 접합·규범화.**
> 근거 코드 행은 정본 7228ceb(khala 0.8.2) 기준. 조사 시트 `d17-c-factsheet.md`(0.8.1 행 번호; Open 2의 "every pass"는 시트에서도 정정).
> 다음: LINK·CLI 두 레인 발사(§8) → 병합 게이트(eddy) → 0.9.0(CLI) → 0.9.1(LINK) 순차 릴리스(§7).

## 0. 한 문장

**노드 conduit이 "지금 이 노드에서 누가 듣고 있는가"를 파일 하나(`presence/conduit@<node>.ear`)로
60초마다 적고 링크가 그것을 다른 presence처럼 나른다.** 대시보드는 그 복제본과 이미 복제되는
파일들(presence·minds·streams)만 읽는 **관찰자**다 — 쓰는 것이 없고, 세션에 손대는 버튼이 없고,
없어도 칼라는 성립한다(R11).

## 1. 오늘의 구멍 (설계가 메우는 것)

1. **원격 노드의 "귀 열림"을 알 수 있는 파일이 함대에 없다.** 등록·lease·전달 저널은 runtime dir
   (`/run/user/<uid>/khala/{sessions,identities,deliveries,channels}`)에만 있고 복제 밖이다
   (link/runtime.go:122-161). `khala presence`의 WATCHING 열은 옛 `khala watch` 마커(`.watching`)만
   본다. 0.7.3부터 `khala watch`는 conduit이 있으면 마커 없이 양보하므로(bin/khala `cmd_watch`) 실제
   함대에서 이 열은 사실상 항상 `-`다.
2. **presence는 활동 기록이지 생존 기록이 아니다.** heartbeat는 `send/say/inbox`만 쓴다. 조용한 세션은
   `asleep`으로 보이고, 편지를 넣으면 몇 초 안에 초인종이 울릴지는 알 수 없다. **asleep인데 듣는 중**이
   정상 상태다.
3. **"마지막 드레인 시각"이 어디에도 없다.** 드레인은 편지를 `new→cur`로 옮기고 touch하며 heartbeat를
   갱신하지만 신원별 드레인 기록은 없다. B6(듣고는 있는데 처리가 없음)의 재료가 없다.
4. **`.ear` 접미사는 0.8.0 링크가 이미 받아 나르지만(link/config.go:592, install_test.go:125) CLI는
   모른다.** 오늘 `presence/`에 `.ear` 파일이 하나라도 생기면 `khala presence`는 `valid_address` 검사에서
   **전체가 실패**하고(bin/khala:5047-5053), `khala reconcile`은 **정리 pass(retention-interval, 300 s)
   마다** `sync_error`를 낸다(prune_presence는 `reconcile_retention=1`일 때만 돌고, 스탬프는 sweep 전에
   찍힌다 — eddy 정정; 그 사이 pass는 rc 0이라 링크의 age-governed scan은 5분에 한 번 건너뛴다).
   → **CLI를 먼저 롤하고 conduit을 나중에 롤한다**(§7). 이 순서는 A5의 링크 우선 순서와 반대다.
5. **한 노드는 함대의 노드 목록을 모른다.** `spool/for/*`·`presence/*@node`는 근사일 뿐이다. 스냅샷
   파일의 존재 자체가 노드 목록이 된다.
6. **"왜 안 듣는가"는 conduit 메모리에만 있다**(`verificationReasons`, link/conduit.go:87; 로그에는
   전이 때만). 대시보드가 답해야 할 질문인데 재료가 없다 — 스냅샷이 enum 하나로 싣는다(§3.1 토큰 13).

## 2. 구성 요소

| 구성요소 | 위치 | 릴리스 | 역할 |
|---|---|---|---|
| 스냅샷 독자 | `bin/khala presence/minds` | 0.9.0 | WATCHING 열이 `.watching` ∪ 신선한 `.ear`를 본다; 상한 위반 파일은 경고 1줄 후 무시 |
| 드레인 스탬프 | `bin/khala inbox --drain` | 0.9.0 | `run/drained/<identity>` 원자 쓰기 |
| rsync 폴백 push | `bin/khala exchange_with_endpoint` | 0.9.0 | `*@self.ear`를 push 글롭에 추가(2039-2041) |
| 예약 이름 | `bin/khala`(작성·독자 양쪽), `khala-link runtime` | 0.9.0 / 0.9.1 | `conduit`·`gateway`·`operator`는 얻을 수 없고 표에도 안 뜬다 |
| 래퍼 | `bin/khala dashboard` | 0.9.0 | `khala-link dashboard` exec(`cmd_status` 관례) |
| 스냅샷 작성자 | `khala-link conduit` | 0.9.1 | 60 s마다·전이 시 `presence/conduit@<self>.ear` 원자 교체 |
| 스냅샷 설치 가드 | `khala-link` installer | 0.9.1 | `.ear`의 `generation` 퇴행 거부(`.watcher` 가드와 같은 자리) |
| 대시보드 | `khala-link dashboard` | 0.9.1 | 임베드 HTML/JS 1벌, `/api/fleet` JSON, 토큰, 무상태 |

새 상주 프로세스는 없다. 대시보드는 `khala status`처럼 **온디맨드 포그라운드**다: 켜 두고 싶으면 사용자가
tmux에 두면 된다. systemd/launchd 유닛은 넣지 않는다(§9-1; eddy 동의).

## 3. 온디스크 명세 (DESIGN §9.6에 추가할 문면)

### 3.1 `presence/conduit@<node>.ear` — 노드 귀 스냅샷

한 노드에 파일 하나. 작성자는 그 노드의 conduit 하나뿐(단일 작성자). `$KHALA_HOME/tmp/`에 쓰고
`presence/`로 rename(§9.6 "같은 FS 안 tmp/ 경유 후 mv"). 줄 단위 텍스트, LF.

```
ears 1
node b200
generation 1788402001
interval 60
conduit 0.9.1
mailbox mini
link 3
identity steno socket ready 2.1.258 0 0 - 0 0 1788398112 1788401900 -
identity ink none ready 2.1.258 1 0 3fa9c2d1 1788401950 2 1788402000 1788401800 lease
```

- `ears 1` — 1행 고정(스키마 버전). 다른 값이면 독자는 파일 전체를 무시한다.
- `node <name>` — 파일명의 노드와 같아야 한다(다르면 무시).
- `generation <epoch>` — 작성 시각. 작성자 안에서 단조 증가: conduit은 시작 때 기존 파일의 값을 읽어
  두고 언제나 `max(now, last+1)`을 쓴다(시계가 뒤로 가도, 기존 파일이 미래여도 퇴행하지 않는다).
- `interval <s>` — 작성 주기(기본 60). 독자의 신선도 기준.
- `conduit <version>` — 링크 바이너리의 릴리스 버전(link/main.go에 새 상수 `linkVersion`; HELLO의
  `implVersion`(0.5.0, 프로토콜 구현 버전)은 그대로 둔다).
- `mailbox <name...>` — config의 mailbox 줄 그대로(허브 판정: 다른 노드가 나를 mailbox로 적으면 허브).
  자기 자신뿐이면 `-`.
- `link <age-s>` — `run/link.fresh`의 나이(초). 없으면 `-`.
- `identity` 행 — **신원마다 정확히 한 행**. 신원 집합 = 등록 ∪ lease(`khala status`와 같은 합집합).
  행은 그 신원의 **lease를 가진 등록**(conduit이 실제로 울릴 대상)이다. lease 보유 등록이 없으면
  `reclaimLeases`와 같은 순서(StartedAt 내림차순, 동률이면 instanceId 오름차순, link/conduit.go:565-580)로
  등록 하나를 행으로 삼고 경로 `none`·reason `lease`; 등록이 하나도 없으면(lease만) reason `noreg`.
  등록이 여럿인 신원(resume 경합·fork)도 이것으로 하나로 정해진다. 이름순 정렬.
  토큰은 **13개 이상**이며 독자는 13개까지만 해석하고 초과분을 무시한다(0.10.0이 열을 더해도 0.9.x
  독자가 깨지지 않는다):
  1. `identity` 2. 이름 3. 경로 `socket|channel|none`
  4. phase(`ready|starting`, 등록 없으면 `-`) 5. CC 버전(없으면 `-`)
  6. 대기 ring 수(inbox/new의 message + urgent notice) 7. 대기 info notice 수
  8. 대기 generation 앞 8 hex(대기 없으면 `-`) 9. 그 generation을 conduit이 처음 본 epoch(0=없음)
  10. 그 generation에 쓴 초인종 수 11. 마지막으로 초인종을 **쓴** epoch(신원 기준, 0=없음)
  12. 마지막 드레인 epoch(`run/drained/<identity>` 1토큰, 0=없음)
  13. `reason` — 경로가 `none`인 이유, 고정 enum: `-`(듣는 중) `noreg`(lease만 있고 등록 없음)
     `boot` `phase` `optin` `pid` `session` `socket` `registry`(이상 `verifyRegistration`의 사유 순서,
     link/conduit.go:442-494) `lease`(등록은 검증됐지만 lease epoch/instance/pid/pidStart/sessionId가
     어긋남 — ring 게이트 830-832). 자유 텍스트·경로 금지.
- **경로(듣고 있음)의 정의 = ring 게이트와 동일**(eddy 라이더 1a): `conduitVerified ∧ phase ready ∧
  lease.instance==reg.instance ∧ lease.epoch>0 ∧ lease.epoch==reg.leaseEpoch ∧ pid·pidStart·
  claudeSessionId 일치`(link/conduit.go:830-832)를 통과할 때만 `socket`, 거기에 `channelSocket≠"" ∧
  channelVerified`면 `channel`. 그 외 전부 `none` + reason. **듣고 있음 = 경로 ≠ none.** 행이 없으면
  듣지 않는 것이다(누락 = not listening).
- 작성자 상한: identity 64행·16 KiB. 65행째부터는 싣지 않고 마지막에 `truncated <n>` 한 줄.
- 없는 것: 소켓 경로, pid, instance/session UUID, 제목, 본문, ssh 좌표, 토큰.
- 알 수 없는 키 줄은 독자가 **무시**한다. `node`·`generation`·`interval`이 중복되면 파일 전체를
  무시한다(제어 헤더 중복 거부).
- **독자 상한(불변식, bash·Go 둘 다)**: 파일이 16 KiB를 넘거나, 행이 80을 넘거나, 토큰이 13개 미만인
  identity 행이 하나라도 있으면 **파일 전체를 경고 1줄로 무시**한다. 위협 모델은 다른 노드의 버그·위조
  파일이다. bash 독자는 read 루프에서 누적 `${#line}`(LC_ALL=C이므로 바이트)과 행 수로 판정한다 —
  stat/wc fork 없음.

작성 시점: conduit 시작 직후 첫 scan 뒤; 그 후 `interval`마다; **듣는 집합의 전이**(경로 획득·상실,
reason 변화, 등록 reap, `runtime release`)가 있으면 2 s 디바운스 뒤 즉시. 대기 편지 수 변화는 전이가
아니다(초당 쓰기를 막는다 — 대기 수는 최대 `interval`만큼 늦을 수 있고 화면은 "n초 전 기준"으로 적는다).
정상 종료(SIGTERM/SIGINT) 시 **identity 행이 없는 마지막 스냅샷**을 한 번 쓴다 — 삭제는 복제되지
않으므로 "이 노드는 지금 아무도 못 듣는다"를 파일로 말하는 유일한 방법이다. 재시작(systemd restart·
`node ensure`)은 종료 스냅샷 → 새 conduit의 첫 스냅샷이 수 초 안에 잇따르므로 화면에 잠깐 "듣는 세션
0"이 비쳤다 돌아온다; 이것은 사실이다(그 몇 초 동안 초인종은 울리지 않는다).

### 3.2 신선도·복제·보존

- **신선도는 독자 로컬 mtime으로 판정한다**: `now − mtime ≤ 2 × interval`이면 fresh, 아니면 stale.
  네이티브 OFFER 경로는 설치 시각을 mtime으로 남기고(link/install.go:244-250, Chtimes 없음) rsync 폴백은
  원본 mtime을 보존하므로(`-a`, bin/khala `mailbox_rsync`) 어느 경로든 mtime ≤ 독자 시계이고, 다중 홉은
  "마지막 홉 도착 후 경과"를 잰다. 원격 시계와 `generation`을 직접 비교하지 않는다. `now − mtime < 0`
  (독자 시계 지연)이면 **fresh로 클램프**, 오류 아님(eddy 2b).
- **rsync 폴백 push 글롭에 `*@self.ear` 추가**(bin/khala:2039-2041; 지금은 heartbeat·`.watching`·
  `.watcher`뿐 — 링크 없는 노드가 자기 스냅샷을 올릴 유일한 길, eddy 2a).
- **설치 가드**(link/install.go, `.watcher` 가드 옆): 들어온 `.ear`의 `generation`이 기존 파일의 것보다
  **작으면** 버리고 로그; 같고 바이트가 다르면 기존을 두고 로그(작성자가 하나이므로 정상 경로에서는 생기지
  않는다 — 생기면 버그·위조 신호); 파싱 불가면 그냥 교체(가드는 순서만 지키고 검열하지 않는다).
  **rsync 경로에는 가드가 없다**: pull(`-a`)이 허브의 옛 사본으로 내 `.ear`를 덮을 수 있고, 다음 주기의
  `max(now,last+1)`가 복구하므로 최대 1 interval 퇴행을 수용한다(eddy 2c, 문서화).
- **보존**: `prune_presence`가 `.ear`를 heartbeat로 파싱하지 않고 **mtime이 `retain`일보다 오래되면
  삭제**한다(정리 pass에서 stat 한 번). reconcile의 매 pass 경로는 `.ear`를 열지도 stat하지도 않는다.
- **접미사는 `.ear` 단수**다. GPT-Pro 초안의 `.ears`는 링크가 모르는 접미사라 바이너리 선행 롤이 필요하지만
  `.ear`는 0.8.x 링크가 이미 나른다(link/config.go:592).

### 3.3 `run/drained/<identity>` — 드레인 스탬프 (복제 안 됨)

`khala inbox --drain`이 요약 줄을 찍기 직전 `run/drained/<identity>`에 한 줄
`<epoch> <letters> <notices> <streams>`를 원자 쓰기(tmp+mv). `--mail-only`/`--notices-only`, 아무것도
출력하지 않은 드레인도 쓴다. list/read 모드는 쓰지 않는다. lock 실패로 드레인이 안 된 경우 이전 스탬프를
건드리지 않는다. conduit은 1토큰(epoch)만 읽어 12열에 싣는다(형식 불량이면 0, 로그 1회).

### 3.4 예약 이름

`conduit`, `gateway`, `operator`는 **주체 예약 이름**이다(GPT-Pro X1-4). `valid_name`은 바뀌지 않는다
(파일명 문법 불변).

- **획득 거부**(0.9.0 CLI): `session_name`(→ `KHALA_SESSION`·`.khala-session`·`--as`·`watch --session`·
  mind/profile/join/bind 전부), `notify --as`, `watcher declare|beat|retire <name>`, `retire`,
  `send`/`notify` 수신자의 세션 부분. 메시지 `예약된 이름입니다: <name>`, rc 1.
  (0.9.1 Go) `runtime register|bind|register-channel`의 identity(link/runtime.go:715 `invalid identity`
  옆): `reserved identity %q`.
- **독자 건너뜀**(eddy 4): 남의 노드가 만든 `presence/conduit@x`(heartbeat)·`minds/x/conduit`이 표에
  행으로 뜨지 않도록 `khala presence`·`minds`·대시보드가 예약 이름 주소를 건너뛴다(경고 없음 — 흔적은
  파일 자체).
- 기존 함대 presence에 이 셋과 충돌하는 신원은 없다(09-03 실측). `gateway`·`operator`는 B가 쓸 이름을
  지금 잠그는 것이다.

## 4. `khala presence`·`minds`의 변경 (0.9.0)

- WATCHING 열 = `.watching`(있고 신선) **또는** 그 노드의 `.ear`가 fresh이고 그 신원 행의 경로가 `socket|
  channel`이면 `yes`. 범례 줄에 "`.ear` = 노드 conduit이 듣는 중"을 덧붙인다.
- `.ear`는 세션 표에 행으로 나오지 않는다(`*.watching|*.watcher|*.ear` skip). `khala minds`의 주소 합집합도
  `.ear` 접미사에서 `conduit@node`를 만들지 않는다.
- 파싱 불가·상한 초과 `.ear`는 **경고 1줄 후 없는 것으로** 본다(hard fail 금지 — 다른 노드의 결함이 내
  화면을 막지 않는다).
- 비용: presence/minds는 `.ear` 파일(노드 수 ≤ 8)마다 stat 1회(mtime) + read 루프 1회. reconcile은 건드리지
  않는다. **`khala presence` 소요 시간(.ear 8개 포함)을 실측**해 보고서에 적는다(eddy).

## 5. 대시보드 (0.9.1)

### 5.1 명령

```
khala dashboard [--listen ADDR] [--token-file PATH] [--with-text]
```

`cmd_status` 관례로 `khala-link dashboard`를 exec한다(`KHALA_HOME` 상속). 0.9.0 CLI + 0.8.x 바이너리에서는
바이너리가 `dashboard`를 모른다는 오류가 나며, 그것으로 충분하다(0.9.1 롤 전). Go 쪽 규칙:

- `--listen` 기본 `127.0.0.1:47000`. 루프백이 아닌 주소에는 `--token-file`이 **필수**(없으면 bind 전에
  exit 2, 루프백 폴백 없음). 포트 사용 중이면 exit 1(다른 포트로 조용히 옮기지 않는다).
- **토큰은 항상 요구한다.** `--token-file`이 없으면 실행마다 32바이트 난수 토큰을 만들어 stdout에
  `dashboard: http://127.0.0.1:47000/` / `token: <base64url>` 두 줄로 알린다(파일에 남기지 않는다).
  `--token-file`은 정규 파일·0600·소유자 본인이 아니면 exit 2. b200처럼 다중 사용자 호스트에서 루프백은
  경계가 아니다. 페이지는 토큰을 사용자가 한 번 붙여 넣으면 **sessionStorage**에만 둔다(localStorage
  금지 — 같은 origin `127.0.0.1:47000`을 나중에 다른 사용자가 점유하면 저장된 토큰을 읽는다). 토큰은
  `Authorization` 헤더로만 오간다(URL·쿼리·로그 금지).
- `--with-text`: 제목·편지 본문·focus/stance·스트림 본문을 API에 싣는다. `--listen`이 없으면(로컬 기본)
  자동 on, 비루프백이면 명시할 때만 on. 메타데이터 모드는 GPT-Pro C2의 "노출 금지" 목록을 그대로 지킨다.
- 종료: SIGINT/SIGTERM에 0. 쓰는 파일 없음(로그도 stderr뿐). **runtime dir은 열지 않는다**(대시보드는
  `$KHALA_HOME` 복제본만 읽는다; 자기 노드의 등록 상세도 자기 `.ear`에서 읽는다).

### 5.2 HTTP 계약

| 경로 | 내용 |
|---|---|
| `GET /` `/app.js` `/app.css` | 임베드 정적 파일(`embed`), 외부 CDN 없음, 인라인 스크립트 없음 |
| `GET /api/fleet` | 함대 JSON 1건(§5.3). `Authorization: Bearer <token>` 필수, 아니면 401 |
| `GET /api/letter?id=<Id>` | `--with-text`일 때만(아니면 404). 로컬 노드 신원의 `inbox/<id>/{new,cur}/<Id>` 본문. `Id`는 message-id 문법으로 검증(link/config.go `messageIDPattern`), 아니면 400 |

응답 헤더(모든 응답): `Cache-Control: no-store`, `Content-Security-Policy: default-src 'none'; script-src
'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'`,
`X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`. CORS 헤더 없음(동일 출처만). 토큰
비교는 `crypto/subtle` 상수 시간. 클라이언트가 준 경로로 파일을 여는 API는 없다. **여는 모든 파일**(편지·
presence·minds·streams·config·link.fresh)은 `Lstat` 정규 파일 검사 후 연다(심링크 추적 없음). 상태를
바꾸는 엔드포인트는 없다(GET 외 전부 405).

### 5.3 `/api/fleet` 내용 (읽는 파일 = 전부 로컬 `$KHALA_HOME`)

- `nodes[]`: 스냅샷 파일마다 하나 — `node, hub(bool), snapshotAge, fresh, conduitVersion, linkAge,
  identities[]`(§3.1의 13열을 이름 붙인 객체로; `listening = route≠none`). 스냅샷이 없지만 presence에
  `@node`가 있는 노드는 `snapshot: null`인 카드로.
- `sessions[]`: presence heartbeat ∪ minds 현재 세대 — `address, state(alive-here|alive-elsewhere|asleep|
  unknown), lastSeen, listening, model, effort, role, charge, freshness`(+ `focus, stance`는 with-text).
  워처 신원(`.watcher` 비은퇴)과 예약 이름 주소는 제외. **`listening`은 `.ear`에서만 오며 presence
  STATE와 무관하다**(asleep + listening이 정상).
- `watchers[]`: `.watcher` 마커(0.8.2 6행; 5행도 수용) — `name, node, owner, cadence, last, state, since`.
- `streams[]`: `name, entries, latest`; `localUnread{identity: n}`은 자기 노드 세션의 join/cursor로
  (conduit.go `pendingStreams`와 같은 규칙, Go 재사용). with-text면 최근 20건 `{id, from, date, subject,
  body}`.
- `letters[]`(자기 노드 신원, with-text): `inbox/<id>/{new,cur}` 최근 50건 `{id, identity, from, date, type,
  urgency, subject, state(new|cur), age}`.
- `self{node, mailbox, version}`, `generatedAt`.

원격 노드의 inbox 본문·제목은 복제되지 않으므로 **애초에 없다** — "원격은 presence 뷰 + 스냅샷, 로컬은
전부"라는 한계 문장을 화면 머리에 그대로 적는다.

### 5.4 화면 (vanilla JS, 5 s 폴링, ~400행)

- 머리: 함대 합계 — 노드(스냅샷 fresh/전체) · **듣는 세션(`.ear` 기준)** · 대기 ring 합 · silent 워처 수 ·
  "n초 전 기준".
- 노드 카드 그리드: 이름 · 허브 배지 · link ● / ○(age) · conduit 버전 · 스냅샷 age → 세션 행: 이름 ·
  상태 배지(alive-here/elsewhere/asleep) · **듣는 중 ✓(socket|channel) 또는 reason** · model/effort ·
  role · charge · focus(with-text) · pending ring/info · 마지막 초인종 · 마지막 드레인 · last seen.
- 워처 표(SINCE 포함), 스트림 탭, 편지 탭(with-text; 클릭하면 `/api/letter` 본문).
- 없는 것: 세션에 대한 어떤 버튼(재시작·종료·보내기 없음 — 보내기는 B에서), 원격 본문, 인증 체계 2개째.

## 6. 릴리스 전 필수 불변식 (레인이 테스트로 먼저 고정할 것)

1. `.ear`가 `presence/`에 있어도 0.9.0 `khala presence`·`minds`·`reconcile`은 실패하지 않는다; 파싱 불가
   `.ear`는 경고 1줄 후 무시된다.
2. WATCHING은 `.watching` 신선 ∨ (`.ear` fresh ∧ 행 경로≠none)에서만 `yes`; stale `.ear`(mtime>2×interval)
   은 `-`; 미래 mtime은 fresh.
3. 스냅샷은 소켓 경로·pid·UUID·제목·본문·ssh 좌표를 **한 바이트도** 싣지 않는다(테스트가 파일 전체를 grep).
4. 스냅샷 쓰기는 초당 1회 이하이고 대기 편지 수 변화만으로는 쓰지 않는다; 전이 후 ≤ 3 s 안에 새 파일.
5. 설치 가드: 낮은 `generation`은 설치되지 않는다; 같은 generation·다른 바이트는 기존을 유지한다.
6. `prune_presence`는 `.ear`를 mtime>retain일에만 지우고 결코 파싱하지 않는다.
7. `run/drained/<identity>`는 `--drain`에서만 쓰이고 내용은 4토큰이다; 드레인 실패 시 쓰지 않는다.
8. 예약 이름 셋은 §3.4의 모든 획득 지점에서 거부되고 모든 표에서 건너뛰어진다; `valid_name` 불변.
9. 대시보드: 토큰 없는 `/api/*`는 401; 비루프백 `--listen`에 `--token-file` 없음은 exit 2; 0600이 아닌
   토큰 파일은 exit 2; 잘못된 `id`는 400; `--with-text` 없으면 `/api/letter`는 404이고 `/api/fleet`에
   subject·body·focus·stance 키가 **존재하지 않는다**; 응답마다 §5.2 헤더(`frame-ancestors 'none'` 포함);
   GET 외 405; 토큰이 URL·로그에 나타나지 않는다.
10. 대시보드 프로세스는 `$KHALA_HOME` 아래 어떤 파일도 만들지 않고 runtime dir을 열지 않는다(테스트가
    실행 전후 트리를 대조하고 strace 없이 코드 경로로 증명).
11. reconcile 게이트 pass 시간(0.8.1 실측 b200 0.2-0.3 s)이 0.9.0에서 늘지 않는다; **`khala presence`
    소요(.ear 8개 포함)**도 함께 — 실제 트리 사본 실측을 보고서에 적는다.
12. 독자 상한: 17 KiB 파일·81행 파일·12토큰 identity 행을 각각 넣어도 표는 살고 경고 1줄; 13토큰 초과
    행은 초과분이 무시된다.
13. lease가 어긋난 등록(epoch·instance·pid·sessionId 중 하나라도)은 경로 `none` + reason `lease`;
    conduit_runtime_test에 케이스.
14. 정상 종료 스냅샷은 identity 행 0개; 재시작 시 기존 파일의 generation이 미래여도 단조 증가 유지.
15. rsync 폴백이 `*@self.ear`를 push한다(hardening 또는 exchange 테스트).
16. 신원마다 행 하나: 등록이 둘인 신원(resume 경합)에서 lease 보유 등록만 행이 된다; lease 보유 등록이
    없는 신원(released lease + 잔존 등록)은 가장 최근 StartedAt 등록이 경로 `none`·reason `lease`로 한 행;
    lease만 있는 신원은 reason `noreg`로 한 행.

## 7. 릴리스·롤아웃 — 같은 설계를 두 태그로 (eddy 3)

혼재 창(conduit 0.9 + CLI 0.8)을 사람 규율이 아니라 릴리스 구조로 막는다.

1. **0.9.0 = CLI 레인**(독자·스탬프·rsync 글롭·예약 이름·래퍼·문서). `.ear` 작성자가 없으므로 어느 순서로
   깔아도 무해. GitHub Release v0.9.0에는 0.8.1 링크 바이너리를 다시 첨부한다(autofetch 경로 유지).
   8노드 CLI 롤 + 마켓 핀. 검증: 8노드 `khala version` = 0.9.0.
2. **0.9.1 = LINK 레인**(스냅샷 작성자·가드·dashboard·예약 identity·`linkVersion`) + CLI 버전 문자열만
   0.9.1. **8노드 CLI가 전부 0.9.0 이상임을 확인한 뒤에만** 태그·릴리스한다(롤 스크립트가 각 노드의
   `khala version`을 먼저 읽고 0.9.0 미만이면 abort). 바이너리 롤 + conduit·link 재시작 → 곧 `.ear`가
   생기고 0.8.x 링크·serve도 나른다.
3. 검증(노드마다): `ls presence/conduit@*.ear` 8개, `khala presence`에 등록 세션 WATCHING `yes`,
   `khala reconcile` rc 0, b200 `khala dashboard`에 카드 8장·듣는 세션 수가 각 노드 `khala status`의
   verified 합과 일치.
4. 장수 플러그인 세션의 CLI 되돌림 함정은 hook의 "새 버전일 때만 덮어쓰기"(plugin/hooks/lib.sh
   `khala_version_newer`)로 막혀 있다 — 롤 뒤 `sha` 대조는 그대로.

## 8. 레인 분할 (파일 소유 분리, 심볼 결합 없음; 둘 다 정본 7228ceb에서 시작)

| 레인 | 릴리스 | 소유 파일 | 내용 |
|---|---|---|---|
| **CLI** (bash) | 0.9.0 | `bin/khala`(=`plugin/bin/khala`), `test/ears.sh`(신규), `test/watchers.sh`, `test/hardening.sh`, `test/minds.sh`(버전), `test/channel-mcp-client.py`(버전), `plugin/.claude-plugin/plugin.json`, `plugin/channel/server.ts`(버전 문자열만), `plugin/skills/khala/SKILL.md`, README, DESIGN §9.6, `report/ears-cli-v09.md` | `.ear` 독자(presence/minds, 상한) · prune · 드레인 스탬프 · rsync 글롭 · 예약 이름(획득+독자) · `khala dashboard` 래퍼 · 문서 |
| **LINK** (Go) | 0.9.1 | `link/*.go`, `link/*_test.go`, `link/dashboard/*`(임베드 자산), `test/conduit.sh`(H21+), `report/ears-dashboard-v09.md` | 스냅샷 작성자(ring 게이트 정의·reason·first-seen 추적·재시작 복원) · 설치 가드 · `dashboard` 서브커맨드(서버+UI) · `runtime` 예약 identity · `linkVersion` |

두 레인이 공유하는 계약은 §3.1 형식과 §5.1 플래그뿐이며 둘 다 이 문서에 고정돼 있다. CLI 레인의 `khala
dashboard` 테스트는 가짜 `khala-link`(인자를 echo)로 exec 인자를 검증한다. 병합 게이트는 eddy(레인 결과
diff 기준). 검증 레인 1개(스냅샷 유출 grep·가드·토큰·헤더·트리 무변경·독자 상한)가 두 레인 병합 뒤 tempdir
에서 재현한다.

## 9. 열린 항목

1. **상주 여부**: 온디맨드. B(0.10.0)의 `khala gateway`가 상주하면 대시보드는 그 안의 `--dashboard` 플래그로
   흡수되고 그때 systemd/launchd 유닛을 한 번에 넣는다(eddy 동의).
2. **`deliveries/` 저널은 아무도 지우지 않는다**(시트 §10). 11열의 재료라 conduit이 60 s마다 훑는다. 정리는
   0.9.x 소품(hippo `fix/deliveries-retention`: boot 다른 것·30일 지난 것 삭제).
3. **B6 경보 문면**은 B의 몫이다. 0.9.x는 재료(9·10·12·13열)만 싣는다.
4. **`khala watch`의 `.watching`**: 유지. 없애지 않는다(D15 불변식 "watch 경로 제거 금지" 조건이 아직 다
   닫히지 않았다).
5. **토큰 UX**(유저 결정 후보): 새 탭마다 토큰을 한 번 붙여 넣는다. 1인 Mac(mini)에서 루프백 전용
   `--no-token`을 원하면 0.9.x 소품으로 추가할 수 있다 — 기본은 항상 토큰.

## 10. GPT-Pro r1 검토 접합 (도착 시 채움)

(`gpt-pro-d17-c-review.md` 도착 전. 접합 뒤 이 절에 P0/P1 항목별 반영 여부를 적고 §1-§9의 해당 문면을 고친다.)
