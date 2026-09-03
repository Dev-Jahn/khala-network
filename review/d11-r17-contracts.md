# D11 r17 — 3자 종합: 규범 계약 4 + lane A2 (r16.1)

> 입력 셋: eddy 리뷰(`eddy-r16-review.md` — 프레임 승인, B-1~4/R-1~2/F1~F5),
> GPT Pro 리뷰(`~/.insane-review/out/response_khala-network_20260812_102127_*.md` —
> **조건부 GO**: S0 계약 4개 선명문화, "가장 큰 위험은 fsnotify가 아니라 역할이 다른
> 스풀 사본들을 '한 트리의 미러'로 오해하는 것"), ink 코드 검증(아래 표).
> 지위: r16 프레임(세 기관·ssh stdio·허브 FS 버스)은 **양 리뷰 공히 승인** — r17은
> 프레임 변경이 아니라 문면을 규범 계약으로 조이는 것.

## 0. Pro 주장 대 코드 — ink 검증 결과

| Pro 주장 | 검증 | 판정 |
|---|---|---|
| S0-2 send→spool 공백: send는 outbox/new에만 안착, spool 물질화는 sync (a)에서만 | `cmd_send` + `copy_outbox_to_spool` 확인 | **실재** — r16 §4의 "send 안착 → 링크가 즉시 push"는 현행 코드로는 성립 안 함 |
| S0-3 동시 sync 불안전: `atomic_copy`가 존재확인→mv(원자 no-clobber 아님), `record_delivered`가 전체복사+rename(동시 갱신 유실) | 코드 확인 | **실재** — 오늘 프로덕션이 이미 ink·pen watch 2개로 sync_cycle을 동시 실행 중 |
| S0-4 같은 Id ≠ 같은 바이트: infra id는 결정적(`epoch.pid.cksum(type:ref).from`)인데 Date/Expires는 재생성 시각 도장 | `new_infra_message_id`·`write_generated_message` 확인 | **실재** — ack 재생성(정상 경로)마다 같은 파일명·다른 바이트 |
| §7 self-spool echo: exchange가 로컬 `spool/for/self`를 허브로 선푸시 — §9.6 push 범위(X≠self) 위반 | `exchange_with_endpoint` 첫 rsync 확인 | **실재** — 스펙/코드 불일치. 현행 rsync에선 dedup에 가려지나 live 링크에선 echo 증폭기 |
| S0-1 소유권·삭제 수명표 부재 | 설계 문서 검토 | **실재** — r16 한 문장("하나의 트리의 사본")이 대칭 미러로 오독 가능 |

## 1. 뿌리 문장 정제 (r16 → r17)

> **모든 노드는 하나의 논리 트리에서 자기 소유 경로와 필요한 투영을 디스크에 가진다.
> 신경은 누락된 불변(immutable) 객체만 보충하고, 소비와 의미론적 삭제는 경로
> 소유자인 뇌만 결정한다.** (Pro 문안 채택 — "사본(mirror)"이 아니라 "소유권 있는
> 투영(projection)")

미학 판정: 이것은 층의 추가가 아니라 한 문장의 정밀화다. r16의 그림(세 기관, 허브
버스, 저하 모드)은 전부 그대로 산다.

## 2. 규범 계약 4 (lane B 발사 전 고정 — Pro S0 ↔ eddy 대응 통합)

### C1. 경로별 소유권·수명표 (S0-1 = eddy B-3/R-2의 완성형)

| 경로 (노드 관점) | 링크 동작 | 삭제 소유자 |
|---|---|---|
| `outbox/new/*` | 전송 안 함 — **reconcile 트리거로만 감시** | 발신 뇌 (ack/만료 시) |
| 스포크 `spool/for/X/*` (X≠self) | 허브로 offer | message: 뇌(e2e ack 시) / infra: 뇌(STORED 통지 후) |
| 허브 `spool/for/X/*` | **X 담당 serve만** X로 offer | 허브 serve — **X의 STORED 후** (v0.1 pull `--remove-source-files`의 프로토콜 대응물) |
| 스포크 `spool/for/self/*` | 설치만, **상류 반사 금지** | 수신 뇌 (배달·ack 생성 후) |
| `presence/*` (자기 명의) | owner→hub→전 스포크 복제 | TTL/신선도 (삭제 비전파 유지) |
| `inbox/ log/ outbox/acked|dead tmp/` | **링크 범위 밖** | 로컬 뇌 |

- **일반 삭제 전파(tombstone)는 만들지 않는다** — 표의 명시 항목이 전부다.
- **eddy B-3 정제**: "링크는 unlink하지 않는다"는 **스포크 파일**에 대해 문자 그대로
  유지. 허브 transit 사본의 STORED-후-삭제는 v0.1에서 이미 rsync pull이 하던
  **전송 계층의 소비**이므로 serve의 것 — 뇌 의미론 침범이 아니라 기존 의미론의
  프로토콜 번역이다. **(eddy 합의 완료, 라이더 포함)**:
  - **STORED의 정의 (eddy 라이더 1)**: "tmp에 전량 수신 → fsync(file) → rename →
    fsync(dir) 완료 후에만 STORED 발신." fsync 없이는 전원 단절 시 rename은 살고
    내용이 죽는 창이 있어 "내구 보유"가 문자 그대로가 아니게 된다. (v0.1 rsync도
    보장 안 하던 것 — 회귀 아닌 상향.)
  - **의존 명시**: C1의 허브 삭제가 안전한 것은 **C3(같은 이름 = 같은 바이트)이
    전제**이기 때문 — 삭제 직전 같은 이름 재착지가 있어도 지워지는 건 항상 수신자가
    이미 내구 보유한 바이트다. lane B 브리프에 이 의존을 명시할 것.
- 신경이 뇌에 넘기는 유일한 사실 = **transport commit** ("원격이 이 파일을 내구
  보유"). 신경은 여전히 헤더를 해석하지 않는다 — 경로 역할과 STORED만 안다.

### C2. reconcile 분리 + 뇌 단일 작성자 (S0-2 + S0-3)

- `sync_cycle`을 두 패스로 분해: **reconcile** = (a) outbox→spool 물질화 + (c) 배달·
  정산·위생 (네트워크 0) / **exchange** = (b) rsync 교환. `khala sync` =
  reconcile → exchange → reconcile (외부 인터페이스·의미론 불변 — 기존 코드의 재배치).
- 링크의 뇌 찌르기 = **reconcile만** (도착 배치당 1회, dirty-bit 합침). 도착마다
  full sync를 부르면 링크와 rsync가 경쟁한다 (Pro §2).
- send는 안착 직후 자기 편지 1건의 spool 물질화를 best-effort 시도 (실패해도 send는
  성공 — 다음 reconcile이 나름). 링크는 outbox/new를 트리거로 감시하므로 어느 쪽이든
  즉시성 성립.
- **brain lock**: 의미론적 변이(reconcile 전체, `inbox --drain`의 new→cur, delivered
  로그 기록·프루닝)는 `$KHALA_ROOT/run/brain.lock.d` **mkdir 락** 아래 단일 작성자로.
  (flock(1)은 mac 기본 부재 — mkdir가 bash 3.2+coreutils에서 원자 create-if-absent.
  락 보유 중 mtime touch로 갱신, 정체(2×기대치) 시 소리 내고 회수.) rsync 교환은
  brain lock **밖** — 20s 네트워크 타임아웃이 로컬 배달을 막으면 안 된다(R10).
  교환은 별도 exchange.lock으로 노드당 1개.
- **crash 복구 규칙**: `delivered 로그에 있거나 inbox new/cur에 있으면 배달된 것 —
  필요 시 로그 수리, ack만 재생성.` (inbox 복사 후·로그 기록 전 crash의 재배달 차단)
- `atomic_copy`는 진짜 no-clobber로: tmp에 복사 후 **ln(2) 원자 생성**(존재 시 실패
  = 성공 반환) — check-then-mv 틈 제거.

### C3. Id ⇒ 바이트 불변 + no-clobber (S0-4)

> **각주 (lane B AMBIGUOUS 비준, eddy 2026-08-12)**:
> **(A) presence는 no-clobber의 예외다** — C3의 Id⇒바이트 불변은 스풀 Id 객체의
> 계약이고, presence 파일은 Id 없는 **가변 lease**(D12의 epoch 갱신이 본질)라
> 적용 범위 밖. no-clobber를 강제하면 heartbeat 갱신 자체가 불가능하다. 링크는
> presence만 원자 교체(full-sync 후 rename)한다. 알고 받아들인 경주 하나: 링크는
> 내용을 읽지 않으므로 순서 역전 fan-out이 presence 사본을 일시 후퇴시킬 수 있다
> — 다음 heartbeat 전파가 초 단위로 덮고, presence는 표시 전용(라우팅 무의존)
> 이라 무해.
> **(B) 중단 전송 tmp는 24h 포렌식 창 후 quarantine 이송**(삭제 아님) — spool
> 위생 30일 규칙의 축소 계보(상수만 다름). quarantine은 **의도적으로 자동 정리
> 대상이 아니다**: 포렌식 공간이고, 이상 상황에서만 자라므로 평시엔 빈 디렉터리
> — "안 지운다"는 누락이 아니라 선택.

- 재생성 infra 메시지의 Date/Expires를 **ref에서 결정적으로 유도** (재생성 시각
  아님) — 같은 Id는 언제 어디서 재생성돼도 같은 바이트. (ack는 fire-and-forget이라
  Expires의 의미 부담 없음 — 원문 Expires 상속이 자연스러운 선택.)
- 최종 설치는 전 경로 no-clobber: 같은 경로 존재 시 digest 동일 → HAVE(스킵),
  digest 상이 → **덮어쓰기 금지, quarantine + 큰 오류** (silent 소멸 금지 계보).
- message id의 `$RANDOM` 유래 충돌은 S2로 잔류 — no-clobber가 검출기 역할을 하므로
  v0.2에서 강화 불요.

### C4. 이벤트는 힌트, 진실은 스캔 (S1 = eddy B-1/B-2/B-4의 일반형)

- 모든 파일 이벤트는 "이 경로가 dirty할 수 있다"는 힌트 — 실제 상태는 stat/scan으로
  재계산. 이벤트 유실·중복·역전·병합·rename 표현 차이를 전부 허용하는 fault model.
- 감시 등록 → 초기 전체 스캔 → 이벤트 루프 (B-1). Overflow/에러/재접속 → 전체 재스캔
  (B-2). 저빈도 주기 스캔(기본 30s)이 에러 통지 유실까지 치유. 스캔 범위는 역할별
  eligible view만 (C1 표 — 전체 ~/.khala가 아님).
- tmp는 감시 밖, 설치는 tmp→rename (B-4). 단 트리거 종류에 의미를 두지 않는다 —
  최종 경로의 현존·정규 파일 여부·이름 검증만 (Pro §5).

## 3. 프로토콜 확정 사항 (lane B 브리프에 반영)

- 프레임: HELLO(magic+major/minor+alias+role) / OFFER(id, class, node, basename,
  size, digest) / HAVE / NEED / DATA / STORED / PING·PONG / ERROR. **경로 문자열을
  받지 않는다** — class+node+basename에서 수신측이 경로 구성 (../·절대경로 원천 차단).
- 방향당 in-flight 1(작은 상수), 큐엔 경로만, DATA 전 원본 전독+digest 확정
  (head-of-line 차단과 R10 wedge 대비 — **유한 크기 상한 + whole-object 재전송**),
  resume·delta·압축·멀티플렉스 없음 (Pro §6.6 금지 목록 채택 — "둘 이상 필요해지면
  자체 펌프의 우위가 사라진다: 그때 long-poll+rsync 재평가").
- ssh 캐리어: `-T`, BatchMode, stdout=프로토콜 전용/stderr=로그(2>&1 금지), 원격
  명령은 절대경로 `exec ~/.local/bin/khala link --serve` (절차서와 문면 일치).
- ready ≠ alive: watch가 원격 sync를 생략하는 마커는 **프로토콜 진행 증거**(최근
  PONG/전송)로만 touch — half-open ssh·잠든 mac 대비 (Pro §10.2 = eddy R-1 합치).
- 싱글턴: Go 쪽은 flock(플랫폼 전부 지원), 상태 파일은 grep 가능 평문. 업그레이드
  overlap(구/신 serve 동시)은 프로토콜이 견딘다 — no-clobber+HAVE가 그 보증.

## 4. 판정 유보 1건 → eddy 합의로 확정

- **watching lease 토큰화** (Pro §8: 재-arm 경쟁으로 W1 trap이 W2 마커 삭제).
  실측 창 = 다음 루프 galvanize까지 ≤interval(30s) 자가 치유, 유일 실해악은 같은
  세션 이중 arm 시 이중 wake — wake는 사실상 멱등(깨어난 턴이 드레인하면 두 번째는
  빈 inbox 확인). **처방 확정 = 세션당 watch 싱글턴**(mkdir 락, D9 훅의 이중 arm도
  원천 차단 — lease 구조 변경 없이 D12 평면 유지). lease는 부족 실측 시 재론.
  - **stale 회수 (eddy 라이더 2)**: 싱글턴 락은 brain lock과 동일 문면 — 락 디렉터리
    + PID 기록, 죽은 PID 또는 정체(2×기대치) 시 소리 내고 회수. kill -9 잔해가
    "영원히 arm 불가"로 굳는 것 방지.
  - **실전 근거 (2026-08-12 11:1x, ink 프로덕션)**: r17 회신 대기 중 구형 watch
    (V2 편지 후 arm한 것)가 정리 누락으로 잔존 → ink 앞 watch 2개가 eddy의 같은
    편지에 **이중 wake** — 유보 논거의 시나리오가 그대로 발생했고, 해악도 예측
    그대로(두 번째 wake는 빈 드레인)였다. 싱글턴이 이 실수 계급을 원천 차단한다.

## 5. lane 계획

- **lane A2 (bash, 뇌 경화 — C1~C3의 bash 몫)**: self-spool 선푸시 제거(스펙 정합),
  reconcile/exchange 분해 + brain/exchange 락, crash 복구 규칙, atomic_copy
  no-clobber(ln), infra Date/Expires 결정화, watch 세션 싱글턴. 수용 속성에 Pro §11
  중 bash 소관: 동시 sync×2+drain에서 로그 유실·재출현 0 / inbox 복사 직후 kill 후
  재실행 시 재배달 없이 ack 재생성 / spool/for/self 생성 시 상류 echo 0 / ack 재생성
  바이트 동일성 / 기존 4 스위트 회귀.
- **lane B (Go, `khala link`)**: 브리프 초안(link-v02-draft.md)에 C1~C4·§3 반영 후
  발사. 수용 속성에 Pro §11 프로토콜 소관 전량(동일 digest HAVE / 상이 digest
  quarantine / outbox-kill-restart 수렴 / 이벤트 drop 후 스캔 수렴 / B serve 2개
  동시 / 링크+rsync 동시 / 프로토콜 major 불일치 명시 종료 / PONG 없는 alive 링크의
  마커 stale). **발사 게이트 = eddy의 r17 합의** (야간 체제: 양 세션 합의 = 확정).
- 순서: A2 먼저 (뇌가 단일 작성자가 되기 전의 링크는 S0-3 경쟁을 증폭한다).

## 6. 정직한 비용 문장 (유저 보고용, Pro §9.2)

"목표가 5–10초라면 long-poll+rsync가 구현 위험 대비 더 나은 선택일 가능성이 크고,
등록 목표(A→B ≤2s, 허브 중계 ≤3s)라면 Go 펌프가 정당하다. long-poll을 런타임
폴백으로 되살릴 필요는 없다 — 수동 `khala sync`가 저하 모드이자 differential
oracle로 남는다." — r16의 선택(펌프)은 active 개입 + 하나의 설계 미학과 함께
이 목표치를 전제로 한다. 목표치가 완화되면 선택도 재평가 대상.
