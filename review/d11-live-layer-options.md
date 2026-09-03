# D11 — live 레이어 선택지 (r15, pen 초안)

> **superseded (r16, 2026-08-12)**: 유저 회신으로 프레임 교체 — 3층 폴백/L1 long-poll
> 권고 폐기, "하나의 설계"로. 현행 문서 = `d11-r16-one-design.md`. 이 문서는 사료.
> (V2 실측 결과는 r16 §4 지터 규칙으로 상속.)
>
> **D11 완전 종결 (2026-08-13, 유저 추인 "ok. 그대로 하자" — eddy 경유)**:
> Q1·Q2·Q4는 r16~v0.2 구현으로 소멸, **Q3 확정** — R7은 r16 정제 문면 그대로
> (DESIGN.md R7 행에 추인 도장), **cloudflare tunnel은 뚫지 않는다** → §5의 V4
> 실측은 대상 자체가 소멸. D11 잔여 0.

> 3자 라운드 문서. 역할: pen 선택지 준비 · soul-jar 함대 사실 검증(§5 V-표) · **결정은 유저**.
> 전제: DESIGN §6.1 계층 그림 — "의미론은 전 층에서 동일, 층은 지연만 바꾼다."

## 0. 프레이밍 — "live"의 실체 분해

편지가 상대 세션에 닿기까지의 지연은 세 구간의 합이다:

| 구간 | 내용 | 현행 (v0.1.1) |
|---|---|---|
| ① 발신 이벤트화 | send 후 push가 언제 일어나나 | 다음 sync까지 (수동/폴링) |
| ② 도착 인지 | 수신측이 도착을 언제 아나 | watch interval (기본 30s) |
| ③ 세션 깨움 | 인지 → CC 세션 재호출 | 하니스 task-notification, 수 초 (실전 실증 2회) |

지배 항은 ①②의 **폴링 간격**이다. ③은 이미 빠르고 우리 것이 아니다(하니스 소관).
→ **live 레이어의 실제 일 = ①②를 폴링에서 이벤트로 바꾸는 것.** 그게 전부다.

**realtime 목표치 (유저 결정 Q1)**: 아래 L1로 도달하는 견적은 **~10초 안팎**
(push 수 초[DERP 경유 rsync] + 인지 ≤1s + pull 수 초 + wake 수 초). 이는 스톱갭
SendMessage의 체감(수신자의 다음 툴 라운드 or 내장 wake)과 동급 — R9의 실측 기준이
스톱갭 UX였으므로 **초 단위 = R9 충족**으로 판단한다. 아초 단위(지속 양방향 스트림)는
CC 세션의 턴 리듬(수십 초)상 과잉이고 Go 전환 트리거(§9.2)에 해당 — **권고: 초 단위를
목표치로 확정**하고 스트림은 좇지 않는다.

## 1. (a) 전송 프리미티브 — 핵심 분리: khala 코드 vs 네트워크 지형

**cloudflare tunnel은 khala의 선택지가 아니라 지형의 선택지다.** khala는 config의
ssh 목적지만 알고, 그 ssh가 tailnet을 타든 터널을 타든 코드는 불변이다(R12 —
§9.1 r14 강등 "방향 제약은 운영상 사실, 선언적 설정이 흡수"와 같은 계보).
따라서 (a)는 두 개의 독립 결정으로 쪼개진다:

### 1a. khala 코드 결정: 알림 메커니즘

**L1 — long-poll wake (권고, v0.2 착수 범위)**

- watch가 interval sleep 대신 **우체통에 blocking ssh**를 건다. 우체통 쪽 명령은
  khala 설치를 요구하지 않는 **인라인 스크립트**다 (예시 골격 — 인용·타임아웃 세부는
  구현 라운드에서):

  ```
  ssh <mailbox> 'while [ -z "$(ls -A .khala/spool/for/<self> 2>/dev/null)" ]; do sleep 1; done'
  ```

  스풀에 파일이 등장하는 순간 반환 → watch가 즉시 pull → 편지 확인 → exit 0 → wake.
  **"우체통 = ssh로 닿는 디렉터리일 뿐" 원칙(§9.1)이 유지된다** — 우체통 요구사항은
  여전히 sshd + coreutils뿐.
- 발신 쪽 이벤트화(①): **send가 안착 직후 best-effort sync를 자동 수행**한다.
  안착 = 성공 의미론은 불변 — 이어지는 sync가 실패해도 send는 이미 성공이고 편지는
  다음 sync가 나른다(층 ③ 폴백). 옵트아웃 플래그(`--no-sync`)만 남긴다.
- 연결 관리: ServerAliveInterval로 죽음 감지, 끊기면 재수립 루프(현행 watch 루프가
  이미 그 모양, R10) — **재수립에 지터(랜덤 백오프) 필수** (V2 실측 근거: sshd
  MaxStartups 기본 10:30:100은 동시 *미인증* 연결 한도라, DERP 딸꾹질 후 함대 전체
  동시 재접속(thundering herd)에서만 만나는 경계 — 지터 한 줄이면 영원히 안 만난다).
  long-poll 1회당 최대 대기 상한을 두고 만료 시 일반 sync 한
  사이클 — **층 ③이 항상 아래에 있으므로 long-poll의 어떤 실패도 배달을 해치지 않는다.**
- 지형 무관: 이 함대의 모든 노드는 우체통(b200)에 닿는다(개인→b200 실증, §9.4).
  B200 아웃바운드 차단(운영상 사실)의 영향 0 — 수신자가 들어와서 기다리는 구도라서.

**L2 — 직결 push (지형이 열리는 만큼, config로 자동)**

- 발신자가 수신자 노드에 **직접 rsync** (config에 상대 엔드포인트가 선언된 쌍에서만),
  수신자는 로컬 inbox 고빈도 감시(1s — 로컬 디스크라 저렴). 우체통 hop 제거,
  우체통이 죽어도 live 유지.
- 코드 거리 가깝다: `spool/for/<X>`는 이미 노드별 라우팅 큐고
  `exchange_with_endpoint`도 이미 있다 — "spool을 우체통에만 민다"는 현행 정책에
  per-peer 직결 분기를 더하는 일.
- 단 지형 민감: 현재 b200→개인 불가라 쌍이 제한적. **권고: L1 먼저, L2는 config에
  직결 경로가 선언된 쌍에서 따라오는 확장**으로 (1b가 진행되면 전 쌍으로 넓어진다).

**기각 기록**: tailscale serve/funnel 류 HTTP 노출 — 데몬 상주 + bash 원칙과 충돌,
ssh가 이미 있는데 새 문을 열 이유 없음.

### 1b. 지형 결정: cloudflare tunnel (유저 의향 — Q3)

- 효과: B200→개인 방향이 열린다 → L2가 전 쌍에서 가능 + 우체통 후보 확대 +
  tailnet 밖 미래 노드(방화벽 뒤, 타인 함대)까지 시야.
- **R7 논점 (정면으로)**: 문면은 "경로와 저장소 전부 유저 소유"인데 cloudflare는
  제3자 경로다. 단, **이미 tailscale DERP도 제3자 릴레이다** (E2E 암호화 패킷만 중계)
  — 현행 v0.1도 문면을 엄밀히는 충족하지 않는 셈. **R7 정제 제안**: "제3자가 내용을
  볼 수 없고(E2E 암호화), 상태를 갖지 않으며(저장소는 유저 소유), 제3자 없이도
  칼라는 성립한다(폴백 층 존재)." 이 정제 하에서 cloudflared(ssh 프록시 모드)는
  DERP와 같은 급이 된다. **문면 개정이므로 유저 결정.**
- khala 반영 비용: config 후보 한 줄 (`peer mini <cf-hostname>` 류). **코드 0줄.**
- 유보 사항: cloudflared는 상주 데몬이다(khala 밖 인프라 계층이라 "khala 새 데몬
  0개" 원칙과는 별개지만, 관리 대상이 하나 는다). 개설·유지 비용은 유저 몫.

## 2. (b) live 발견 — watching은 heartbeat가 아니다

- **문제 (실측)**: 현행 `watch --session <s>`가 시작 시 s 명의 heartbeat를 갱신한다.
  죽은 세션이 남긴 orphan watch가 산 자 행세를 할 수 있다 — soul-jar 선견해와 합치:
  "presence는 세션의 발화 흔적이어야 하고 watch는 귀지 입이 아니다."
- **안**: heartbeat는 "입"(send/inbox 등 실제 발화)만 갱신한다. **watch의 시작 1회
  갱신도 제거.**
- **watching = 별도 상태로 분리**: L1이면 long-poll 연결 자체가 발견이다 — watch가
  arm될 때 `presence/watching/<session>@<node>` touch, 정상 종료 시 삭제(trap),
  kill -9 잔해 대비 TTL 병행. presence 표에 열을 더해 구분:
  `alive`(최근 발화) × `watching`(귀 열림) — "asleep+watching"(발화는 없지만 편지가
  오면 깬다)이 정직하게 표시된다.
- **용도는 UX 전용** (지금 대화 가능?): L1 구도에선 라우팅에 발견이 불필요하다 —
  경로는 항상 mailbox 경유이므로 **발견이 틀려도 배달은 안 깨진다.** 발견 실패가
  배달 실패로 번지던 스톱갭 결함 ③의 구조적 재발 방지.

## 3. (c) 의미론 접합 — L1이면 접합 문제가 소멸한다

- L1의 경로는 전 층과 **같은 경로**다: send → outbox 안착 → spool → 우체통 → inbox.
  "live"는 별도 전송로가 아니라 **수신자의 대기 방식**일 뿐이다. 따라서 "live 직결도
  발신 큐 안착 후 전송인가"라는 질문의 답이 자동으로 "그렇다"가 된다 — at-least-once,
  멱등 dedup, e2e ack 전부 그대로.
- L2를 채택해도 직결 push의 원천은 여전히 `spool/for/<X>` 사본이다 — 라우팅 큐 구조가
  그대로 직결에 쓰이므로 의미론 불변. 유일한 세만틱 추가는 send-후-자동-sync(§1a)인데
  이것도 "안착 = 성공"을 건드리지 않는다.

## 4. (d) D9 훅+스킬 접점

- **SessionStart 훅** = inbox 드레인(상한 §5.5) + watch arm(L1 모드) 자동화.
  arm은 하니스 run_in_background 경로 — 밤새 codex 알림 + khala wake 실전 2회로 실증.
- **orphan watch 수명**: 세션이 죽으면 그 watch는 주인 없는 귀다. SessionEnd 훅에서
  자기 watch 정리 + §2의 watching TTL이 이중 방어. (orphan이 남아도 해악은 "헛
  wake 1회 + watching 오표시"로 국한 — heartbeat 분리(§2) 덕에 presence는 안 오염.)
- **스킬 문면 반영 사항**: send는 기본 즉시 sync 동반(§1a), 코드 포함 본문은 stdin
  (백틱 사고 — 절차서 트러블슈팅 계보), 편지 수신 = wake 후 `inbox --drain`.

## 5. V — 함대 실측 필요 항목 (soul-jar)

| # | 실측 | 왜 | 상태 |
|---|---|---|---|
| V1 | DERP 경유 지속 ssh의 수명 — long-poll이 몇 분/시간을 버티나, 끊김 주기, ServerAliveInterval 권장값 | L1 재수립 루프의 파라미터 | 대기 — mini→b200 방향, 유저 손 목록 |
| V2 | 다중 long-poll 동시 부하 — 노드/세션 여럿이 b200에 blocking ssh를 걸었을 때 sshd·ls 루프 비용 | L1의 우체통 상주 비용 상한 | **✅ 완료 (eddy, 2026-08-12)** |
| V3 | mac 잠듦 상호작용 — mbp 뚜껑 닫힘/절전 시 long-poll 연결의 운명, 깨어난 뒤 재수립 동작 | 함대 2/6이 mac (§9.2 계보) | 대기 — V1과 같은 자리에서 겸사 |
| V4 | (Q3 진행 시) cloudflare tunnel ssh 프록시 실측 — b200→개인 방향 개통 확인 | 1b·L2 확장의 전제 | Q3 결정 대기 |

**V2 결과 (eddy 실측, b200 로컬)**: 폴 본체 ls 루프 = 0.9ms/회 (초당 1폴 = 워처당
코어의 0.09%, 72코어 머신에 워처 100개 = 0.125%). 커넥션당 sshd RSS ≈ 16MB (워처
10개 = 160MB). 유일한 실 경계는 sshd **MaxStartups**(기본 10:30:100 — 확립 연결이
아니라 동시 미인증 연결 한도): 평시 무관, thundering herd에서만 확률적 드랍 — §1a의
재수립 지터로 영구 회피. **평결: 우체통 상주 비용은 L1 채택을 막을 수 없다.**

## 6. 결정 요청 (유저)

- **Q1** realtime 목표치: **초 단위(~10s)로 충분한가?** (권고: 예 — 스톱갭 UX 동급,
  아초 단위 스트림은 과잉)
- **Q2** L1(long-poll wake) v0.2 착수 승인 — send-후-자동-sync 포함
- **Q3** R7 정제 + cloudflare tunnel 개설 여부 (1b — 개설은 유저 손, khala는 config 한 줄)
- **Q4** watching/heartbeat 분리(§2) 승인 — watch의 heartbeat 완전 제거 포함
