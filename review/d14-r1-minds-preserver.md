# D14 r1 — 세 번째 발걸음: minds(3층 자아) + preserver(기억의 수탁)

> 계보: r0 스케치(`d14-minds-preserver-draft.md`) → 자문 2건(`eddy-d14-r0-
> consult.md`, `gpt-pro-d14-review.md`) → 유저 입력(profile 축) → eddy 접합
> 4건 → **r1 = 그 전부의 규범화**. 선행 조건: D13 경화 레인(S0-0) 머지.
> **게이트 통과: eddy GO (r1 gate `eddy-d14-r1-gate.md`, 2026-08-13) —
> 라이더 R1·R2 접합 완료(§1.2), 재게이트 불요 판정.** 결정: 유저(자율진행
> 위임 하 — "쭉 자율진행").

## 0. 뿌리 문장 증보 (r17 문장에 두 절 추가)

> 모든 노드는 하나의 논리 트리에서 자기 소유 경로와 필요한 투영을 디스크에
> 가진다. 신경은 누락된 불변 객체만 보충하고, 소비와 의미론적 삭제는 경로
> 소유자인 뇌만 결정한다. stream 항목은 발행 노드의 샤드에만 태어나는 불변
> 객체이고, 다른 모든 노드는 그 투영을 보충받는다. 합류와 커서는 세션 소유의
> 로컬 상태다. **mind는 명의가 소유하는 불변 세대(generation)들의 열이고,
> 현재값은 그 최대 세대다. archive는 preserver 노드가 관측한 불변 객체에
> 부여하는 복제 밖의 두 번째 로컬 경로다.**

정직성 문면 셋 (Pro 최종 판정 채택):

1. mind는 presence의 가변 파일이 아니라, 명의가 소유하는 불변 세대형
   register다.
2. preserver는 만료 시 삭제를 가로채는 특례가 아니라, 관측한 stream 객체를
   로컬 archive에 먼저 정착시키고 기존 retention prune을 그대로 통과시키는
   역할이다.
3. retain은 함대의 live 복제·가시성 지평이며, 이미 공유된 stream 데이터의
   소거 보장은 아니다. (절연 정밀화: 절연은 미래의 연결·자동 공유를 중단할
   뿐, 이미 공유된 사실의 소급 삭제를 보장하지 않는다. 단 mind에는 실제
   철회가 있다 — clear 세대는 지연된 구세대에 의해 되살아나지 않는다.)

## 1. minds — 3층 자아 (동적 mind + 반정적 profile + 기계적 presence)

### 1.1 유저 요구 (개시 입력)

"presence 시에 누가 어떤 모델·어떤 effort이고, 역할이 뭔지, 뭘 개발하거나
담당하는 세션인지 알 방법이 마땅치 않다."

### 1.2 세 층의 구분 (경계 기준 = eddy ①)

| 층 | 성격 | 필드 | 갱신 주체 | 변화 리듬 |
|---|---|---|---|---|
| presence | 기계가 쓰는 사실 | heartbeat epoch, watching | 발화·훅 (기존 불변) | 발화마다 |
| **profile** | 반정적 선언 — "서 있는 것" | model, effort, role, charge | 훅(Start, model·effort) + 명시 선언(role·charge) | 세션 생애·스위칭 |
| **mind** | 동적 선언 — "지금 하는 것" | focus(한 줄), stance | **명시 발화만** (`khala mind`, say/send --mind) | 시간 단위 |

경계 자: **"이번 시간의 과제가 바뀌어서 값이 바뀔 수 있으면 mind 소속."**
(charge와 focus의 중복 표류 방지.)

훅 불가침 규칙 (Pro §2 + eddy ③): 훅은 profile 필드만 쓴다(Start 시점).
mind 본문(focus·stance)은 어떤 훅도 생성·수정하지 않는다 — 훅은 대화 내용을
모르므로, 아는 척하는 순간 거짓 상태가 된다.

**eddy 게이트 라이더 (r1 gate, 2026-08-13 — M3·M4의 규범 문면화)**:

- **R1 — Stop·wake 훅은 어떤 세대도 생성하지 않는다.** 세대를 만들 수 있는
  훅은 SessionStart뿐(profile 필드만). incarnation token 없이 세션 ABA(M3)를
  피하는 유일한 길이 Stop·wake의 침묵이다 — 선의의 "Stop phase 세대"가
  정확히 M3를 깨는 구현이므로 금지를 명문으로.
- **R2 — 세대 갱신 이월 규칙 (일반형)**: 새 세대는 자기 필드족만 변경하고,
  타 필드족은 **값과 Declared를 바이트 그대로 이월**한다. 특히 훅(Start)
  세대는 State(cleared 포함)·Focus·Stance를 이월한다 — Start 훅이 State를
  active로 초기화하면 clear가 훅에 풀려 M4가 깨진다(Pro 절연 동작의 세대판).

### 1.3 기질 — 단일 작성자 불변 세대형 register (Pro S0-1, eddy 합류)

```
minds/<node>/<session>/<generation>     # 세대 파일 = 불변 객체
```

- **작성자**: `<node>`의 뇌만, brain lock 아래. 투영 노드는 설치만(반사 금지).
- **세대 번호**: brain lock 아래 `(max(now, last_generation_epoch), counter)`
  — 시계가 뒤로 가도 새 선언이 과거보다 작아지지 않는다(단조성). 파일명
  문법은 스트림 Id와 같은 계열(epoch 접두)로 정렬·나이가 내장.
- **현재값 = 유효 세대 중 최대.** 지연 복제·순서 역전·세션 ABA가 전부 구조로
  무해화된다: 늦게 도착한 구세대는 max에서 선택되지 않을 뿐이다.
- **clear·retire도 상위 세대다** (`State: cleared`) — 삭제가 아니라 갱신이라
  전파되고, 지연 구세대가 철회를 되살릴 수 없다. retire는 presence retired
  갱신과 함께 mind clear 세대를 만든다.
- 같은 세대·다른 바이트 = quarantine (C3 그대로).
- 낮은 세대는 로컬 GC(더 높은 세대를 본 노드가 제거 가능), 최대 세대는
  retain 후 GC. **freshness ≠ retain** (Pro S0-3): 표시용 의미 유효기간은
  별도 상수(레인 브리프에서 확정, 기본 후보 1h) — `khala minds`는 나이를
  상대 표기하고 stale을 fresh처럼 출력하지 않는다.
- 세대 파일 포맷: RFC822류 헤더(grep 원칙) — Generation/Session/Node/
  Declared(필드별 선언 시각)/State(active|cleared)/Model/Effort/Role/Charge/
  Focus/Stance. **필드별 Declared 나이** = eddy ② (model 미끄러짐 실측 —
  선언값임을 아는 채로 읽게). 세대 갱신 시 변하지 않은 필드의 Declared는
  보존(Pro §2 — 훅 갱신이 낡은 focus를 새것처럼 보이게 하지 않게).

### 1.4 신경·귀 접촉면

- 링크: OFFER class `mind` 추가(minor +1). 불변 객체라 기존 no-clobber 설치
  기계 그대로. **watch 비각성·drain 비대상·커서 무관** (eddy 요청 — 수용
  속성 M7). presence처럼 deleteAfterStored 비설정.
- 구버전 협상: min(minor) — 구링크엔 mind OFFER 없음, sync가 나른다(저하).
- sync(bash): push = 자기 노드 샤드만(`minds/<self>/`), pull = 전체 merge —
  스트림 다리와 대칭.

### 1.5 CLI

```sh
khala mind -m "지금 하는 일 한 줄" [--stance focused|stuck|...]
khala mind --clear
khala profile [--role "..."] [--charge "..."]     # 명시 선언
khala minds          # 3층 조인 표: 명의 | presence | profile(나이) | mind(나이)
```

- SessionStart 훅: model·effort를 profile 세대로 선언(하니스가 훅에 모델
  정보를 주는지 레인이 프로브 — 없으면 스킬 규율로 세션이 선언). mind는
  불가침.
- retire → mind clear 세대 동반(§1.3).

## 2. preserver — 기억의 수탁 (관측 시 정착)

### 2.1 역할 정의 (Pro 구조 채택)

preserver는 prune의 특례가 아니다. **자기 live 투영에 도달한 불변 객체에
복제 밖의 두 번째 로컬 경로(archive)를 부여하는 역할**이다:

```
reconcile (preserver 노드):
  (신규) capture 단계: preserve 대상 스트림의 모든 live 항목에 대해
         archive 정착을 보장 (이미 정착했으면 no-op — 멱등)
  (기존) prune 단계: 전 노드 동일한 retention 규칙 그대로 실행
```

- 30일 경계에서 첫 쓰기를 시도하지 않는다 — 도착 직후부터 매 reconcile이
  정착을 보장하므로 실패를 수일간 재시도할 수 있다.
- retention 코드는 preserver/비preserver에서 동일 — 코드 갈래 없음.
- prune은 "archive 정착 확인 후 unlink" — 정착 안 된 만료 항목은 지우지
  않고 소리 낸다(fail-closed, §2.3).

### 2.2 물리 — 같은 FS hardlink (v0 제한)

```
archive/streams/<stream>/<node>/<YYYY>/<MM>/<id>    # 연월은 id epoch의 UTC
archive/.pending/                                    # (cross-FS 지원 시에만)
```

- **경로 계약 (eddy S0 + Pro S0-6 통합)**: `archive/`는 `$KHALA_ROOT` 직하,
  `streams/`의 **형제**다. 자식 금지 — serve 스캔이 이름 문법만으로 샤드를
  등록하므로 트리 안 archive는 함대 재살포 사고가 된다(watch.go 대질 완료).
  링크·rsync의 송수신 어느 view에도 나타나지 않음을 수용 속성으로 증명(P4).
- capture = live 파일 검증 → archive 목적지 `ln(2)` no-clobber → 존재 시
  digest 비교(상이 = quarantine + 큰 오류) → dir fsync. 스트림 객체는
  불변이라 hardlink가 의미론 안전. crash 상태는 live만/live+archive/
  archive만 — "둘 다 없음"이 불가능(P1).
- v0는 **same-filesystem 제한** — cross-FS는 STORED급 복사 계약이 필요해
  수요 실재 시 후행. (허브 ~/.khala는 로컬 NVMe — eddy 실측.)
- 조회: `stream cat`이 live+archive를 `(stream, publisher, id)` 키로 dedup
  병합, `(epoch,id)` 정렬, **커서 불변**. 원격 recall은 후행(ssh+grep으로
  이미 가능) — 추가 시에도 조회 경로이지 복제 경로가 아니다.

### 2.3 fail-closed 정책 (Pro)

금지: archive 실패 후 조용한 prune / digest 충돌의 임의 선택 / 디스크 부족
시 오래된 archive 자동 삭제(eviction 없음) / 실패 상태의 침묵.
`preserver degraded`는 소리 나는 상태다 — status 표시(선택 스트림, root,
same-FS 여부, last success, pending/conflict, bytes)는 S1.

### 2.4 보장 수준의 정직성 (Pro S0-5 — 약한 보장을 정확히)

preserver v1은 **observed stream archive**다: "자기 투영에서 관측·정착한
객체만 로컬 보존." completeness(전 발화 무결 보존)·단일 디스크 생존을
주장하지 않는다 — 강한 보장은 stream의 "ack 없음, 나이 독립 삭제" 의미론을
바꾸므로 범위 밖. 수탁의 신뢰성은 사본 수에서 (eddy):

- **백업 한 줄 (1일차)**: archive 트리를 더 오래 사는 기질로 주기 rsync —
  역할 정의에 "archive는 백업 대상" 명문.
- **다중 preserver (수요 시)**: 독립 archive, 조정 없음 — "0개여도 성립"에서
  "N개여도 성립"이 공짜. 후보 2호 = mini.
- enable 시 backfill은 현재 live 투영부터 — 과거 전역 completeness를 보고하지
  않는다(P7). disable은 미래 capture만 중지, 기존 archive 불삭(P8).

## 3. C1 경로표 증보 (규범)

| 경로 | 생성·변이 소유자 | 링크·교환 | 삭제·수명 |
|---|---|---|---|
| `minds/<self>/<session>/<gen>` | 자기 뇌만 (brain lock) | owner→hub→전 스포크 offer (class mind, 불변 no-clobber) | 낮은 세대 로컬 GC / 최대 세대 retain / clear·retire도 세대 |
| `minds/<X>/<session>/<gen>` X≠self | 전송 계층 설치만 | 상류 반사 금지 | 동일 GC 규칙 (로컬 뇌) |
| `archive/streams/**` | preserver 뇌만 | **송수신 모두 금지** (경로 계약) | 자동 retention 없음 — 명시 purge만 |
| `archive/.pending/**` | preserver 뇌 | 복제 밖 | commit까지 재시도, 자동 삭제 금지 |
| profile/mind 필드족 | §1.2 소유권 표 | (세대 파일에 동승) | 세대 규칙 |
| mail, join, cursor | (기존 불변) | (기존) | preserver·mind 대상 아님 |

mind는 archive 대상이 아니다(상태이지 기록이 아님). mail 불보존 재확인 —
제3자 축적은 감시다.

## 4. 수용 속성 (사전 등록)

### minds (M)
M1. V2 설치 후 지연 V1이 링크·rsync 양쪽으로 도착해도 현재값 V2.
M2. clear 후 지연 구세대 도착 — mind 재출현 0.
M3. 같은 명의 세션 A→B 교체 후 A의 늦은 Stop 훅이 B의 상태를 못 바꾼다
    (훅의 mind 불가침 + profile은 세대 단조성으로).
M4. retire 후 minds 표에서 즉시 소거; 재발화만으로 과거 mind 미재현(새 mind
    선언 필요).
M5. freshness 경과 시 stale 명시 표기 — fresh처럼 출력 금지. 필드별 Declared
    나이 표기.
M6. 같은 세대·다른 바이트 = quarantine (덮어쓰기 0).
M7. mind 세대 파일은 watch 비각성·drain 비출력·커서 무관·preserver 비대상.
M8. 구버전(mind 이전 minor) 링크와 혼합 — 오류 0, mind는 sync로 수렴.
M9. 3층 조인 표가 실파일과 일치 (표시 전용).

### preserver (P)
P1. capture 각 단계 kill — 최종 상태는 live만/live+archive/archive만,
    소실 없음.
P2. 같은 Id 지연 재도착 — archive 중복 0 (멱등).
P3. live·archive digest 상이 — cat·prune이 임의 선택하지 않고 큰 오류.
P4. archive·pending의 어떤 파일도 링크 초기·주기 스캔, rsync 왕복에 불출현.
P5. archive 실패·ENOSPC — live 조용한 삭제 0, degraded 소리.
P6. cat 병합 — dedup·정렬 유지·커서 불변.
P7. 늦은 enable — 현재 live 창만 capture, completeness 미주장.
P8. disable — 기존 archive 잔존.

### 상속 게이트 (D13 경화 — 선행 레인에서 H1-H6로 이미 등록)
S1. retain 초과 오프라인 노드의 link-first 기동 — 만료 offer 0.
S2. 상시 링크 idle 노드 — 허브 prune 후 반복 재offer 0.
S3. in-flight 만료 도착 — watch·drain 불노출, 다음 reconcile 소멸.

## 5. 레인 계획

- **lane A (bash 뇌+플러그인+스킬)**: §1 CLI·세대 register·3층 조인 +
  §2 preserver 전부(순수 로컬 기관) + M1-M7,M9 + P 전부. 단독 완결(sync 저하).
- **lane B (Go 신경)**: class mind + minor +1 + M8 + P4의 링크 몫.
  A 머지 후 (뇌가 만든 온디스크를 신경이 나르는 순서 — 불변 전례).
- 버전: 뇌·플러그인 0.4.0, link 0.4.0 (protocol 1.2).
- 게이트: eddy 합의 → 발사. 공개·마켓 재핀은 수집·재감사(파일당 luna) 후.

## 6. NOT-in-r1

- transcript 기반 model 진실원 갱신 (후행 후보 — eddy ②의 소스는 기록만)
- 원격 recall / cross-FS archive / archive 인덱스·pack (수요 후행)
- remember류 선택·요약 기억 (Pro가 "더 본질적 후속" 후보로 기록 — D15+)
- 함대 간 연방 (R7 신뢰 모델 근본 변경 — 별도 라운드)
