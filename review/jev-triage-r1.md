# Jev 판정 접목 r1 — 편지 분류(triage)를 conduit이 미리 해 두고, 세션은 태그만 읽는다 (ink, 2026-09-23)

유저 지시(09-23): hippo@mbp가 전달한 TypeSafe Jev 응용 제안을 승인하고 "khala에 유용할 만한 응용을 설계해서 알아서
진행"하라. 이 문서는 그 설계와 착수 전 실측이다. 제안 출처: hippo@mbp 편지 1790096459 (09-23), 4가지 자리 중 1번(inbox
triage)을 채택하고 2·4번을 후속으로 남긴다. 3번(watcher notice 변화 판정)은 0.9.9의 "같은 watcher의 미확인 info notice는
최신 1건만"이 코드 수준에서 이미 해결했으므로 제외한다.

## 0. 한 줄 요약

- **Jev는 판정만 한다**(텍스트 생성 없음, 요청당 0.6~1.3 s, 입력 토큰만 과금 $0.042/Mtok). Claude·Codex 구독 한도
  **밖의 예산**이라, 세션이 편지 본문을 읽기 전에 "행동이 필요한가 / 답장을 기다리는가 / 급한가 / 종류가 무엇인가"를
  미리 알아 두는 데 쓴다. 목표는 수신 세션의 **턴·컨텍스트 절감**과 우선순위 판단이다(DESIGN §5.5 마지막 마일).
- 원칙: **코드가 추출 → Jev 판정 → 코드가 표시·정렬**. Jev 결과는 **자문(advisory)** 이며 초인종을 억제하거나 편지를
  숨기지 않는다. 인증·권한(operator Auth, R13 경계)에는 절대 쓰지 않는다(state 안 적대적 문장에 취약).
- 접목 지점은 **conduit** 하나다. conduit은 이미 `inbox/<id>/new`의 봉투를 60 KiB 한도로 읽어 프레임을 만든다
  (link/conduit.go:898-935 `readPending`). 여기서 새 편지를 보면 Jev를 한 번 부르고 결과를 `run/triage/<id>/<letter-id>.json`
  에 캐시한다. 프레임과 drain·list는 캐시를 읽기만 한다. 키가 없으면 **아무 일도 없다**(silent fallback 아님 — 상태에 `triage: off`로 보인다).

## 1. 실측 (2026-09-23, b200)

### 1.1 API 계약 (docs.typesafe.ai/api, /models — 09-23 읽음)
- `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer $TYPESAFE_API_KEY`, body `{model:"jev-latest", state, questions}`.
- 질문 3종: `noul`(예 확률 0..1), `choice`(선택지 분포 + confidence), `score`(등급 기대값). 한 요청의 질문들은 같은 state를
  보고 **병렬·독립**으로 답한다 → 편지 1통 = 요청 1건에 질문 4개.
- 한도: 64k 토큰/요청(state+질문 전체), 32k(state+최장 질문); 1,200 req/min, 250k tok/s; 429/529는 지수 백오프.
- 약점(공식): 영어가 1차 언어, **CJK는 정확도 낮음**; 숫자·날짜 계산 불가; 문자 그대로 읽음; state 잡음에 약함.
  `jev-latest`는 alias라 예고 없이 바뀔 수 있음 → 응답의 `model` 필드를 캐시에 기록하고, 임계값을 조정하면 버전을 핀한다.
- 키 위치: 유저가 Claude 설정 env(`TYPESAFE_API_KEY`)에 넣어 둠(b200·mbp 확인, mini 없음). **conduit은 systemd/launchd/setsid
  아래서 `KHALA_HOME`만 받는다**(bin/khala:5210-5280) → 세션 env를 상속하지 않는다. 키는 `~/.khala/triage.conf`(0600)로 넘긴다(§2.4).

### 1.2 질문 세트 v1 (영어로 묻고, state는 편지 원문 그대로)

state = `{"letter": {"from", "to", "subject", "is_reply": bool, "body": 본문 앞 3,000자}}`

| id | 종류 | 질문 | true / 선택지 |
|---|---|---|---|
| `needs_action` | noul | 수신 세션이 무언가 하거나 답해야 하는가 | true: 과제·요청·질문 포함 / false: 정보·확인·보고·ack뿐 |
| `awaits_reply` | noul | 발신자가 답장 편지를 기대하는가 | true: 질문·확인 요청·"회신 바람" / false: "회신 불필요"·순수 보고 |
| `time_sensitive` | noul | 지금 막혀 있거나 즉시 처리해야 한다고 말하는가 | true: 기한·블로킹·"바로" / false: 급함 없음 |
| ~~`kind`~~ | choice | (v1·v2 측정 후 **제외**, §1.3) | question · request · report · info · ack |

- 실제 편지 1통 스모크(steno 회신, 한국어): `needs_action 0.28, kind report 0.96` — 사람 판단과 일치.
- **표본 48통**(b200 inbox/cur + outbox/acked의 `Type: message`, 발신자 12명 층화, seed 22): 총 36 s, 입력 58,589 토큰
  (≈$0.0025), 편지당 0.6~2.1 s. 결과 파일 `scratchpad/jev-corpus/NN.jev.json`.
- **블라인드 라벨**: Claude(opus) 서브에이전트가 Jev 결과를 보지 못한 채 같은 정의로 48통을 라벨링 → §1.3 일치율.

### 1.3 일치율 — 블라인드 라벨 48통 대비 (09-23 측정, `scratchpad/jev-agreement.py`)

라벨 분포: needs_action yes 23 / awaits_reply yes 9 / time_sensitive yes 6 / kind report 16·info 13·request 13·question 6.

| 문항 | 임계 0.5 | **임계 0.7** (채택) | 비고 |
|---|---|---|---|
| needs_action | acc 0.85 (prec 0.77, rec 1.00) | **acc 0.90** (prec 0.91, rec 0.87) | 놓친 3건은 "결과 보고 뒤 작은 부탁" |
| awaits_reply | acc 0.90 | **acc 0.94** (prec 0.88, rec 0.78) | |
| time_sensitive | acc 0.88 (prec 0.50) | **acc 0.98** (prec 1.00, rec 0.83) | 0.5에선 거짓 양성 6건 |
| kind (5분류, v1) | acc 0.77 | — | 불일치 11건 중 9건이 "보고+말미 질문/요청"을 report로 |
| kind (v2: 우선순위 규칙 추가) | acc 0.67 | — | 반대로 report→request 16건. 경계 자체가 불안정 |

- **결정**: `kind`를 뺀다. 라벨러도 그 경계(05·12·40 "보고인데 작은 부탁")를 애매하다고 했고, 5분류를 "행동 필요 vs 아님"으로
  접어도 0.81이라 `needs_action` 노울(0.90)보다 못하다. **이진 3문항 + 임계 0.7**이 v1 판정 세트다. 태그는 코드가 만든다:
  `action`(needs_action ≥ 0.7) · `reply`(awaits_reply ≥ 0.7) · `urgent`(time_sensitive ≥ 0.7) · 셋 다 아니면 `fyi`.
- 한국어 편지가 대부분인 표본에서 이 수치이므로 CJK 약점은 이 질문 세트에선 감내 가능. 임계값은 `triage.conf`에서 바꾼다.
- 게이트 통과(needs_action ≥ 0.85). 착수한다. 원자료: `scratchpad/jev-labels.tsv`, `jev-corpus/NN.jev.json`(v1), `NN.jev2.json`(v2).

## 2. 설계

### 2.1 캐시 — `run/triage/<identity>/<letter-id>.json` (노드 로컬, 복제 안 됨, 0600)

```json
{"id": "<letter-id>", "model": "jev-1.13.0", "askedAt": 1790100000,
 "needsAction": 0.96, "awaitsReply": 0.77, "timeSensitive": 0.68,
 "inputTokens": 1220, "latencyMs": 730, "digest": "<sha256 of header block+first 3000 body bytes>"}
```

- 쓰기: `writeAtomicJSON`(link/runtime.go:248) 재사용. `digest`가 다르면 재판정(편지 파일이 바뀐 경우).
- 수명: 편지가 `cur/`로 가도 파일은 남긴다(drain·list가 읽음). `run/`은 reconcile의 retention pass가 아니라 **conduit이**
  60 s 스캔마다 `inbox/<id>/{new,cur}` 어디에도 없는 id의 캐시를 지운다(수백 개 수준; run/은 tmpfs·재부팅 소멸).
- **오류 캐시**: 401/422/네트워크 오류는 `{"id","error":"…","askedAt"}`로 기록하고 10분간 재시도하지 않는다(무한 재시도 금지).
  429/529는 캐시하지 않고 다음 스캔에 다시 시도한다.

### 2.2 conduit — 판정 시점과 동시성

- `readPending`(conduit.go:898)이 새 id를 보면 **초인종 생성과 무관하게** 판정 큐에 넣는다. 판정은 별도 고루틴(동시 2,
  요청당 타임아웃 8 s)에서 하고, 프레임은 **판정을 기다리지 않는다**: 캐시가 있으면 `triage:` 줄을 붙이고 없으면 생략한다.
  초인종은 지금과 똑같이 즉시 울린다(0.9.6 turn-aware 사다리 그대로). 재울림 프레임에는 그 사이 완성된 판정이 실린다.
- state는 conduit이 이미 읽는 64 KiB 헤더 블록 + 본문 앞 3,000자(UTF-8 경계 보정). `Type: operator`와 `Type: notice`는
  **판정하지 않는다**(operator: R13 경계; notice: Urgency 헤더가 이미 답).
- 예산 상한: `triage.conf`의 `max-per-hour`(기본 600). 초과분은 판정 없이 지나가고 conduit.log에 1줄(시간당 1회).

### 2.3 표시 — 세 곳, 전부 자문

1. **초인종 프레임** (conduit.go:1352 `frame`): `subjects:` 다음에 한 줄 추가. 프레임은 8 KiB 상한이므로 편지당 12자 내.
   ```
   triage: action 2 (urgent 1, reply 1), fyi 3, pending 1
   ```
   `action`/`fyi`는 판정이 끝난 편지의 수, `pending`은 아직 판정 전(또는 예산 초과로 건너뜀)인 수. `run/triage`가 꺼져 있으면 줄 자체가 없다(구 클라이언트 호환:
   프레임은 자유 텍스트이고 파서는 `read:`만 본다).
2. **drain** (bin/khala:5773 `--- letter <id> ---` 줄): 캐시가 있으면 같은 줄 끝에 `· action reply` / `· action urgent` / `· fyi` (임계값을 넘은 태그만; 확률은 안 찍는다 —
   세션이 숫자를 재해석하지 않게).
   가장 큰 절감은 여기다: 세션이 20통을 한 번에 받을 때 태그 줄만 훑고 `report`·`info`는 뒤로 미룰 수 있다.
3. **`khala inbox list`** (bin/khala:5679-5682): `Id\tFrom\tType` 뒤에 `Triage` 한 열 추가(`action,reply,urgent` 중 해당 태그를 쉼표로, 없으면 `fyi`, 캐시 없으면 `-`).
   ChatGPT 브리지(`khala_inbox_list`)가 이 열을 그대로 노출하면 폰에서도 우선순위가 보인다.

CLI 쪽은 확률을 읽지 않는다: conduit이 캐시 JSON 옆에 **한 줄 파일** `run/triage/<id>/<letter>.tag`(`action,reply,urgent` 또는 `fyi`)를
같이 쓰고, `bin/khala`는 그 파일을 `cat`할 뿐이다(임계값 적용은 conduit 한 곳). 그것도(jq 없음, §9.2 규칙) — reconcile
hot path가 아니라 drain·list(사용자 명령) 안에서만 읽으므로 fork 비용은 문제 없다.

### 2.4 설정 — `~/.khala/triage.conf` (0600, 선언식 R12)

```
provider typesafe
key <TYPESAFE_API_KEY>          # 또는 key-file <path>
model jev-latest                # 임계값 튜닝 뒤엔 jev-1.13.0처럼 핀
max-per-hour 600
threshold 0.7                   # action/reply/urgent 세 태그 공통; 필요하면 threshold-urgent 0.8처럼 개별 지정
```
- 파일이 없으면 triage는 **off**이고 `khala status` 첫 줄 옆에 `triage: off`, 있으면 `triage: on (jev-latest, 12/h)`.
- 키는 conduit 프로세스만 읽는다. 세션·훅·CLI는 키를 만지지 않는다. `.ear` 스냅샷에는 키는 물론 on/off도 싣지 않는다
  (다른 노드가 알 필요 없음).
- 배포: 유저가 노드별로 파일을 둔다(mini·b200·mbp 우선). `khala init`은 건드리지 않는다.

### 2.5 쓰지 않는 자리 (고정)
- operator Auth·서명·권한 판단, 초인종 억제·later 승격, 편지 삭제·접기, 답장 생성, 카운트·시간 계산.
- 수신 세션의 "이 편지를 무시해도 된다"는 결정 — 태그는 힌트이고 본문 읽기는 세션의 의무로 남는다(SKILL에 명시).

## 3. 검증 계획 (레인 착수 전 pre-register)

- P1 키 없음 → 판정 큐가 만들어지지 않고 프레임·drain·list 출력이 0.9.9와 바이트 동일. `khala status`에 `triage: off`.
- P2 가짜 HTTP 서버(테스트) → 새 편지 1통에 요청 1건(질문 3개), 캐시 JSON 1개 + `.tag` 1개, 프레임 `triage:` 줄, drain 태그, list 열.
- P2b 임계값: 노울 0.69는 태그 없음, 0.70은 태그 있음; `threshold 0.5`로 바꾸면 0.69도 태그.
- P3 판정 지연(서버 응답 5 s) → 초인종은 지연 없이 울리고(저널 시각 차 < 1 s), 재울림 프레임에만 태그가 실린다.
- P4 401 → 오류 캐시 1개, 10분 내 재요청 0건, conduit.log 1줄. 429 → 캐시 없음, 다음 스캔에 재요청.
- P5 operator·notice 편지 → 요청 0건.
- P6 `max-per-hour 2` + 편지 3통 → 요청 2건, 세 번째는 `pending`이 아니라 `skipped`로 표시.
- P7 캐시 GC: 편지가 acked/expired로 사라지면 다음 스캔에 캐시도 사라진다.
- P8 프레임 8 KiB 상한 유지; `triage:` 줄은 subjects 뒤·generation 앞.
- P9 `test/conduit.sh`·`test/local-roundtrip.sh`·`test/cli-polish.sh` PASS(변경 없음), Go `go test ./...` PASS.

## 4. 레인 분할 (Claude 익명 서브에이전트, 유저 지시 09-22: 당일 Codex 사용 불가)

- **T-GO**: link/triage.go(클라이언트·큐·캐시·GC·conf 파싱) + conduit.go 프레임 한 줄 + status 표시 + Go 테스트(가짜 서버).
- **T-CLI**: bin/khala drain 태그·list 두 열·status 줄 + test/triage.sh + DESIGN §9.6(`run/triage`, `triage.conf`) + README + SKILL.
  두 레인은 파일이 겹치지 않는다(conduit.go는 T-GO만, bin/khala는 T-CLI만). 캐시 JSON 형식(§2.1)이 계약이다.

## 5. 후속 후보 (이번 범위 밖)
- stream relevance(제안 2): 수신 세션의 `khala mind` focus를 state에 넣고 entry마다 noul → quiet 스트림 승격.
- mind freshness 힌트(제안 4): 자동 clear 금지, stale 표시에 근거 1줄.
- 한국어 정확도가 낮게 나오면: 질문에 한국어 예시를 criteria로 넣어 재측정(영어 질문 유지).
