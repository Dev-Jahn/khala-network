# Khala Network — DESIGN v0.1

> status: **r3** — 결정 D1–D8 전부 닫힘 (D4·D5는 유저 위임 하 양 세션 합의) + v0.1 구현 스케치
> ink: 설계 펜(구명 pen) · eddy: 리뷰·함대 사실(구명 soul-jar) · 결정: user
> — 2026-08-12 유저 초대로 두 세션이 스스로 개명; 본문·사료 속 옛 이름은 그대로 둔다
> date: 2026-08-11

## 1. 무엇을 만드나

유저의 founding words:

> "이 모든 환경들의 claude code 세션들을 하나로 묶는" 네트워크.
> soul-jar와 독립 동작. 플러그인 또는 외부 설치형 프로그램 형태.
> 계정과 무관하게 통신.

한 문장 정의: **함대의 모든 머신에서 도는 Claude Code 세션들을, Claude 계정과 무관하게,
하나의 통신망으로 묶는 독립 프로그램.** 이름 "칼라(Khala)"는 프로토스의 정신 교감망에서.

## 2. 함대 지도 (2026-08-11 — 유저 답변 D1–D3 반영)

| 노드 | 역할/위치 | tailnet | 가동 패턴 |
|---|---|---|---|
| B200 | 클라우드 컨테이너 (soul-jar·이 세션이 사는 곳) | 연구실 net + 개인 net에 공유 (D8, 2026-08-11) | 컨테이너 수명 — **우체통 1순위** |
| bw2 | 연구실 서버 | 연구실 net + 개인 net에 공유 (기존) | ❓ — 우체통 예비 |
| mac mini | 연구실 상시 가동 | 개인 net | 24/7 — 릴레이 자원 가능 (전제 금지, R11) |
| dgx spark | 연구실 VLA 개발기 | 개인 net | ❓ |
| macbook | 개인 노트북 | 개인 net | 이동 잦음, 자주 잠듦 |
| 집 WSL | 집 데스크탑 | 개인 net | 간헐 |
| proxmox | 홈서버(Proxmox; ccbroker가 2026-08-17 편입, uid jahn, systemd --user; 관리 세션 주소 `homelab-admin@proxmox` — 초기 `prox`는 같은 날 retire) | 개인 net (100.73.204.94) | 상시 — 우체통 예비 후보 |

스토리지 사실 (D1 확정): **함대에 공유 홈은 없다.** "모든 머신은 별개의 home을 가진다고
생각해야 해."(유저) /NHNHOME은 이 클라우드 컨테이너 전용 경로이고, Lustre는 GPU 클라우드
클러스터 내부(jsl류 서버 간)에만 공유되며 함대 밖으로 나가지 않는다.

네트워크 사실 (D2 확정, D8로 분단 해소): **tailnet이 둘이다.** 연구실 net = {B200, bw2}
(유저가 관리자), 개인 net = {mac mini, dgx spark, macbook, 집 WSL}. 두 net 사이 직통
경로가 없었으나 [D8](#d8) 실행(2026-08-11)으로 B200이 개인 net에 공유됐고, bw2는 이미
공유돼 있었음이 확인됨 — **양쪽 세계에서 닿는 노드가 둘**(b200, bw2). 개인 쪽에서의
도달성 실측 1건만 대기.

Claude 계정: 개인 4개 (ajh508 / ajh5082 / ajhskku / proton; seek2252는 제외).
**머신↔계정 매핑은 고정이 아니다** — 같은 머신에서 세션마다 계정이 다를 수 있음.
"계정 독립"이 1급 요구인 실제 이유.

### B200 컨테이너 실측 (이 세션이 직접 잰 것)

- `findmnt /NHNHOME` → `/dev/nvme2n1p1[/DCTN-0421001408]`, **fstype `xfs`** — 로컬 NVMe
  xfs의 컨테이너별 서브트리(DCTN-0421001408 = 이 컨테이너 ID). 유저 답변(D1)·soul-jar
  교차 실측과 일치: B200 홈은 노드 로컬이고, WORKSPACE 쪽 Lustre도 함대 밖으로는 안
  나간다. 공유 FS 다리 가설은 여기서 최종 기각.
- `/tmp`는 tmpfs `noexec` + 주기 청소. 휘발 경로에 주소/저장소를 두면 안 되는 이유가
  스톱갭 결함(③ TMPDIR 불일치)과 별개로 하나 더 확인됨.
- 파일 단위 I/O wedge 이력 (soul-jar가 오늘 실측): 파일 하나에 대한 I/O가 통째로 멈춘
  얼굴을 할 수 있는 스토리지 — mailbox 구현에서 타임아웃/부분 실패를 1급으로 다룰 것.

## 3. 스톱갭이 가르쳐준 것 (문제 정의)

현행 스톱갭 = session-messaging 스킬 (같은 머신 UDS, `/tmp/cc-socks/<pid>.sock`).
soul-jar가 며칠간 모은 실측 한계:

| # | 한계 | 본질 |
|---|---|---|
| ① | 같은 머신 UDS라 B200 밖으로 못 나감 | **전송(transport)** |
| ② | 유휴/소켓 없는 세션엔 닿을 수 없음 | **생존성(liveness)** |
| ③ | TMPDIR이 다르면 같은 머신에서도 발견 실패 | **발견(discovery)** |
| ④ | 기능이 세션 수명 중에 죽을 수 있다 — 프로세스·소켓은 살아 있는데 통로만 사라진다 (2026-08-11 실측: 발신측 SendMessage "not available" + 동시각 양쪽 세션의 MCP 단절 — OS는 무죄, 하니스 상태만 유죄. **재발 2026-08-12 07:5x, 이번엔 soul-jar 측 발견/발신 사망 — 24시간 내 2건, 비대칭 재현성 확보**) | **상태 소재(state locus)** |
| ⑤ | 통로가 죽으면 대체 경로가 유저 입력 레인을 오염시킬 유혹이 생긴다 — 실제로 tmux 타이핑 신호가 CC 자동완성이 놓아둔 제안 문장과 합쳐져 **사람이 한 글자도 치지 않은 유저 명의 위조 턴**으로 제출됨 (2026-08-11, `review/incident-user-lane-injection.md`) | **신원(identity)** |

④의 교훈이 칼라 설계의 검증이기도 하다: 칼라의 상태는 전부 프로세스 밖 디스크에
있으므로(§5.2), 이 병에 구조적으로 면역이다 — 실제로 ④ 발생 당일 첫 khala 실전 편지가
죽은 스톱갭을 대신해 배달됐다.

구조적 진단: 셋이 전부 **pid 소켓 경로 하나에 묶여 있다**. 주소가 프로세스 수명에 결박된
단일 장애점. soul-jar의 첫 인사가 세 번째 시도에야 닿은 것이 산 증거.

대조군: Remote Control 세션(dctn-…)은 원격 도달이 되지만 **Anthropic 서버 경유 + 계정
결합** 통로(공식 문서 확인, soul-jar). 칼라의 대체재가 아니라 계정 독립 요구의 반례.

## 4. 요구사항

| ID | 요구 | 등급 | 출처 |
|---|---|---|---|
| R1 | Claude 계정과 무관하게 통신 | 1급 | founding words |
| R2 | 머신 경계를 넘는다 (함대 6대) | 1급 | founding words |
| R3 | soul-jar와 독립 동작 (상호 의존 없음) | 1급 | founding words |
| R4 | 잠든/부재 상대에게 보낸 메시지는 죽지 않는다 — 깨어날 때 배달 | 1급 | 함대 평상시 상태가 "대부분 잠듦" |
| R5 | 주소는 프로세스보다 오래 사는 안정 이름 | 1급 | 스톱갭 결함 ①②③의 공통 뿌리 |
| R6 | presence 지도: alive-here / alive-elsewhere / asleep / unknown 구분 | 1급 | "목록에 없음 ≠ 죽음" |
| R7 | 제3자는 암호화된 바이트만 나르고(내용 열람 불가) 상태를 갖지 않으며, 없어도 칼라는 성립한다 — 유저 소유 아닌 곳에 저장소·평문·필수 의존 금지 (r16 정제; 원문면 "제3자 서버 없음"은 DERP 중계 실사용과 충돌해 다듬음. **유저 추인 완료 2026-08-13** — "ok. 그대로 하자", eddy 경유; cloudflare tunnel은 안 뚫는 것으로 함께 확정 → V4 소멸, D11 잔여 0) | 1급 | 신뢰 모델 |
| R8 | 형태: 플러그인 또는 외부 설치형 프로그램 — **r18 강등 (유저, 2026-08-13)**: "CC 없는 머신도 CLI만으로 참여"는 유저 요구가 아니었다("어쩌다 설계가 정한 것"). 배포 기본형 = **CC 플러그인**(CLI 동봉, SessionStart 훅이 ~/.local/bin/khala 자가 설치 — 심링크·수동 설치본은 불가침). CLI 단독 사용은 여전히 가능하나 부산물이지 요구가 아님 | 2급 | founding words → r18 재해석 |
| R9 | live 상대에겐 낮은 지연 (실시간 대화 가능) | 2급 | 스톱갭 UX 유지 |
| R10 | 스토리지 장애(I/O wedge)에서 전체가 멈추지 않는다 | 2급 | B200 실측 |
| R11 | 우체국(릴레이)은 역할이지 컴포넌트가 아니다 — 릴레이 0개여도 칼라는 성립 | 1급 | D3 유저 조건: "24/7 머신이 없는 사람도 고려" |
| R12 | 함대 구성은 선언적 설정 — 다른 사용자의 함대에 코드 수정 없이 이식 | 1급 | 〃 (soul-jar "machine-generic" 헌법과 같은 계보) |
| R13 | 칼라는 어떤 다리에서도 **유저 입력 레인(세션 입력창)을 사용하지 않는다** — 입력창은 유저의 신원이다. 비어 보여도 하니스가 제안 텍스트를 놓아둘 수 있어, 피어가 누르는 Enter는 "무엇이 제출될지 보낸 쪽이 알 수 없는 버튼"이다. 배달은 mailbox, 긴급 신호는 유저에게 보이는 곳(자기 화면·디스크)까지만. 상대 세션 깨우기는 별도 메커니즘("wake without impersonation", v0.2 후보) | 1급 | 한계 ⑤ 사건 (2026-08-11) |

## 5. 아키텍처 (계층 분해)

원칙: 전송·생존성·발견을 **분리해서** 푼다. 스톱갭은 셋을 한 경로에 묶어 셋 다 잃었다.

### 5.1 Identity — 안정 이름이 1급 원시자료

- 주소는 `session@node` 꼴. 프로세스·소켓·pid보다 오래 산다.
- presence 지도가 이름 → {현재 엔드포인트 | asleep | unknown}을 매핑.
- 노드 이름 규약은 미결 → [D5](#d5).

### 5.2 Delivery semantics — mailbox-first

- **send의 의미론 = "identity를 향한 내구 큐잉(durable enqueue)"**. live 배달은 지연
  최적화이지 의미론이 아니다. 이 함대의 평상시 상태는 "대부분 잠듦"이므로 이게 기본값.
- **내구성은 발신 노드 디스크에서 시작한다.** 공유 FS가 없는 세계(D1)에서 존재가 항상
  보장되는 저장소는 발신자 쪽뿐 — R4의 물리적 실체. send는 로컬 큐에 안착한 시점에
  성공이다.
- 계정 독립(R1)은 이 구도에서 공짜로 따라온다 — 큐는 파일이고 파일은 계정을 모른다.
- 보장: at-least-once + 수신측 멱등(msg_id 중복 제거). exactly-once는 좇지 않는다.
- **발신 큐 보관은 수신측 확인(end-to-end ack)까지.** 중계 버퍼(우체통)에 넘긴 시점이
  아니다 — 우체통은 유실 가능해도 의미론이 깨지지 않는 존재여야 한다(D8 전제).
- **ack 자체는 위 보관 규칙의 예외다** (재귀 차단): ack는 best-effort로 보내고 보관하지
  않는다. ack가 유실되면 발신자가 원문을 재전송하고, 수신자는 msg_id 중복 제거 후 ack를
  재생성한다 — 신뢰성은 원문 재시도가 지고, ack는 언제나 다시 만들 수 있는 파생물.
  "ack의 ack"는 없다. (bounce 1회성과 같은 계보.)
- 실패는 침묵하지 않는다: 배달 불가/기한 초과는 발신자 수신함으로 반송(bounce).
  bounce는 1회성 — 반송문 자체가 배달 불가면 발신 노드의 사망 편지함(dead-letter)에
  안치하고 끝낸다. 무한 왕복 없음.

### 5.3 Transport — 단일 백본 없음, 복수 다리

| 다리 | 커버리지 | 상태 |
|---|---|---|
| (a) 같은 머신 UDS | 같은 머신 live 세션 | **v0.1 제외** — 스톱갭에 하중 금지 (D7 결정) |
| (b) 공유/동기화 FS mailbox | 함대 간 다리로는 **사망** (D1: 공유 홈 없음) | 기록만 남김 — 같은 클러스터 내부 한정 케이스가 생기면 재론 |
| (c) tailnet 전송 | 함대 전부 — 두 net 분단은 [D8](#d8) 실행으로 해소 (도달성 실측 대기) | **v0.1의 유일 다리** |

릴레이(R11): 우체국은 역할이지 컴포넌트가 아니다 — 아무 노드나 자원할 수 있고, 0개여도
칼라는 성립한다. 릴레이가 없으면 발신 노드 큐 + **기회주의적 동기화**(양쪽이 동시에
깨어 있는 순간 배달)로 동작한다. 이 함대에서 mac mini는 지연 최적화일 뿐 전제가 아니다.

라우팅: presence 지도가 다리를 고른다. 어떤 다리도 필수 아님 — 닿는 다리가 없으면
mailbox에 남고, 그것이 정상 동작이다(R4).

### 5.4 Presence — 4상태 지도

- `alive-here` (같은 머신, live) / `alive-elsewhere` (다른 노드, live) / `asleep`
  (등록됐으나 무응답) / `unknown` (미등록·정보 없음).
- **presence는 전역 진실이 아니라 관찰자별 뷰다.** 두 net + 부분 도달의 세계(D2)에선
  노드마다 보이는 지도가 다르다. per-노드 last-seen + 전파(gossip)로 유지하고,
  unknown을 부끄러워하지 않는 표기를 유지한다.
- **presence는 칼라 활동의 지표이지 세션 생존의 지표가 아니다.** heartbeat는 khala
  명령 실행 시에만 갱신되므로, 칼라를 부르지 않는 살아 있는 세션은 asleep으로 보인다 —
  v0.1의 정직한 절충. (스톱갭의 "목록에 없음 = 죽음" 오독을 반복하지 않기 위한 명문.)
- 구현 스케치: 노드별 heartbeat + TTL. 신선하면 alive, 만료면 asleep, 없으면 unknown.
- 계보: "신호가 닿지 않는 것과 죽은 것은 다르다 — 지도를 그리며 기다려라." (soul-jar
  열다섯째의 유언; 이 지도가 그 문장의 상속이다.)

### 5.5 Last mile — 세션 안으로

- MCP 서버(send/inbox/presence 도구) + **SessionStart 훅에서 수신함 드레인**.
- soul-jar whisper와 같은 패턴 — 이 함대에서 이미 검증된 모양.
- **드레인에는 요약·상한(건수/바이트)이 처음부터 있다.** SessionStart 훅 출력은 세션
  컨텍스트에 꽂히므로, 수신함이 밀린 채 깨어난 세션이 통째로 잠기지 않게 상한 초과분은
  개수·발신자 요약만 꽂고 본문은 inbox 도구로 끌어오게 한다.
- 살아 있는 세션에의 실시간 알림은 v0.2 과제(폴링/훅 주기로 시작).

### 5.6 Trust model — 단순하게

- 경계 = tailnet. 두 net 중 연구실 net은 유저가 관리자, 개인 net은 유저 소유 — 어느
  조합(D8)이든 경계 관리 권한은 유저에게 있다. 저장소 = 유저 소유 0700 디렉터리.
  제3자 서버 없음(R7).
- 위협 모델: "전부 유저 본인 머신" — 암호화·인증은 tailnet과 파일 권한에 위임하고
  칼라 자체 암호 계층은 만들지 않는다.

## 6. v0.1 자르기

핵심 불변량 하나만: **"잠든 상대에게 보낸 메시지는 죽지 않고, 그가 깨어날 때 배달된다."**

| 포함 | 제외 (v0.2+) |
|---|---|
| identity (`session@node`) + 레지스트리 | cross-machine live 직결 |
| mailbox store-and-forward — 다리는 (c) tailnet 하나 | 실시간 push 알림 |
| 4상태 presence 지도 (관찰자별 뷰) | 다중 다리 자동 라우팅 |
| last mile: MCP + SessionStart 드레인 (상한 포함) | soul-jar rendezvous 연계 (옵트인, 그쪽 리포 소관) |
| 선언적 함대 설정 (R12) + 릴레이 0개 동작 (R11) | 스톱갭 UDS 다리 (D7 결정) |

같은 머신 live 대화는 스톱갭이 이미 하므로, v0.1의 신규 능력은 **cross-machine
store-and-forward**에 집중한다.

### 6.1 로드맵 재조정 (r14 → r16, 2026-08-12)

r14 유저 원문 요지: **"지금 상태로는 khala에 제약이 너무 많다. 사실 좀 더 realtime에
가깝게 통신하는 걸 원했다."** → realtime을 1급 로드맵 목표로 승격.

r15는 이를 3층 폴백(live 직결 → watch wake → mailbox 폴링)으로 접근했으나, **r16에서
유저 방향 지시로 프레임 교체**: ① 진짜 과녁은 idle wake(~10s로 충분)가 아니라
**active 세션 개입** ② "다단계 fallback 타워"가 아니라 **단순하고 아름다운 하나의
뿌리 설계** ③ 설계의 단순함이지 구현의 원시성이 아니다(필요하면 현대적 구현 허용).

r16의 답 — **하나의 설계**:

> 모든 노드의 우편함은 하나의 트리의 사본이다. 신경(노드당 상시 링크 하나)이 살아
> 있는 동안 사본들은 초 단위로 수렴하고, 신경이 죽어도 트리는 디스크 위의 진실로
> 남는다.

층은 없다 — 복제 설계 하나가 지연 스펙트럼을 내재한다(링크 있음 = 즉시, 없음 = 다음
펌프). 폴백은 별도 층이 아니라 같은 설계의 저하 모드. 상세: [D11](#d11) +
`review/d11-r16-one-design.md`.

## 7. 결정 — 확정된 것과 남은 것

### 확정 (r1 라운드)

- <a id="d1"></a>**D1. 공유 홈 없음** (유저): "모든 머신은 별개의 home." Lustre는
  클라우드 클러스터 내부 전용, 함대 밖으로 안 나감. → 다리 (b) 함대 간 다리로는 기각.
- <a id="d2"></a>**D2. tailnet 이중 분단** (유저): 연구실 net {B200, bw2} + 개인 net
  {mac mini, dgx spark, macbook, WSL}, 직통 없음. → [D8](#d8) 파생.
- <a id="d3"></a>**D3. mac mini 릴레이 OK, 단 전제 금지** (유저): "다른 사람들도 쓰게
  되면 24/7 머신이 없는 사람도 있을 테니 그것도 고려" → R11·R12로 승격.
- <a id="d6"></a>**D6. mailbox는 독자 포맷** (soul-jar 권고 채택): maildir류
  (tmp+rename, msg_id 파일명). soul-jar rendezvous 포맷과의 호환은 R3에 역행하는
  커플링이라 하지 않음 — 훗날 soul-jar가 칼라를 타면 그쪽 어댑터의 일.
- <a id="d7"></a>**D7. 스톱갭 UDS 다리 v0.1 제외** (soul-jar 권고 채택): 하중 금지 유지.

### 확정 (r2–r3 라운드)

- <a id="d8"></a>**D8. 두 tailnet 잇기 — 완료 (2026-08-11, Tailscale API로 실행).**
  유저가 두 tailnet의 API 토큰을 soul-jar 세션에 건네 실행을 위임 → 연구실 토큰으로
  b200-2 device-invite 생성, 개인 토큰으로 accept. **검증**: 개인 net에
  b200-2(100.87.32.89)가 external 기기로 등장, 연구실 net은 10대 그대로(신규 노출 0).
  부수 발견: **bw2(100.118.105.83)는 이미 개인 net에 공유돼 있었음**(iisdata-ts·
  iisnas2도 공유 상태) → 양쪽 세계에서 닿는 우체통 후보는 처음부터 둘 — **b200 1순위,
  bw2 예비**. (soul-jar 0.9.0 rendezvous 호스트 결정과 공용 — 같은 답이 그쪽 다방
  등록도 푼다.) **잔여: 개인 쪽 노드 → 100.87.32.89 도달성 실측 대기 (유저 ping 1회).**

  채택안은 선택지 (iii) "두 zone + 양쪽에서 닿는 우체통"을 공유 한 번으로 구현한 것.
  경위 기록 — **유저 제약 (r2)**: 연구실 tailnet은 유저가 관리자이긴 하나 여러 사람이 함께 쓰는 망 —
  개인 서버들을 그쪽에 공유하는 건 꺼려짐. (선례로 든 cc-cred는 급해서 넣은 임시방편.)
  ACL 세공은 가능하나 원치 않음 — "간편한 방법" 선호.

  **제안 (soul-jar): 공유 방향 뒤집기.** 개인 노드를 연구실 망에 들이는 게 아니라,
  연구실 쪽 유저 소유 노드 **B200을 유저 개인 identity(Dev-Jahn@)에게 공유**한다.
  Tailscale 공유는 기기 1대→사용자 1명 단위이므로: (a) 다인 공용망에 새 노드가 등장하지
  않고 (b) 개인 머신들은 연구실 망에 계속 안 보이고 (c) 노출 대상이 유저 본인의 개인
  기기들뿐이라 ACL 세공 불요(기본 ACL 가정) (d) 관리 콘솔에서 공유 두어 번 클릭이면 끝.
  cc-cred가 이미 증명한 메커니즘의 방향만 반대.

  **칼라에의 함의**: 공유는 단방향(개인 기기→공유된 노드로만 개시 가능)이지만
  mailbox-first엔 충분 — **B200이 양쪽 세계 모두에서 닿는 우체통**(R11의 relay 역할
  자원)이 되고, 모두가 B200을 향해 push/pull한다. 즉 선택지 (iii)을 공유 한 번으로
  구현하는 셈. 우체통 1순위 B200(유저 단독 소유 — 정치 비용 0), bw2는 필요시 예비.
  우체통이 죽어도 R11대로 발신 큐에 남으니 SPOF 아님.

  **pen의 주의 하나**: B200은 컨테이너 수명 + I/O wedge 이력의 노드다(§2). 이 선택의
  전제는 "우체통 mailbox는 중계 버퍼일 뿐, 진실의 원본은 발신 노드 큐"(§5.2) — 컨테이너
  재생성으로 우체통의 미수거분이 사라져도 발신측 재전송(at-least-once)으로 복구된다.
  §5.2에 보관 규칙 한 줄로 명문화함.

  **fallback**: 유저가 집에서 B200에 이미 접속 중(경로 불명) — 기존 SSH 경로가 있다면
  tailscale 무변경으로도 rsync 다리는 성립.
- <a id="d4"></a>**D4. 형태 = 하이브리드 — 확정** (유저 위임 "적당히 최적의 선택지로"
  하에 양 세션 합의, 2026-08-11): 코어는 CC 밖 **단일 CLI `khala`**, CC 플러그인은 얇은
  클라이언트(MCP·훅이 그때그때 CLI 호출). **상주 데몬은 기본 없음** — 릴레이를 자원한
  노드만 `khala relay` 상주 모드(R11). CC 없는 머신도 CLI만으로 함대 참여 가능(R8).
  soul-jar의 bin+플러그인 구조와 같은, 이 함대에서 검증된 모양.
- <a id="d5"></a>**D5. 이름 규약 — 확정** (동일 위임 하 합의, 2026-08-11):
  - **노드 별칭** = 함대 설정(R12)의 선언 값이자 유일 키. 이 함대:
    `b200 bw2 mini spark mbp wsl`. 별칭→엔드포인트 매핑은 **관찰자별 후보 목록**이다
    (r5 실측: 개인망에서 b200은 짧은 이름이 안 잡히고 `b200-2.tail6c736b.ts.net`
    FQDN으로만 닿는다 — 유저 실측). 예: `peer b200 100.87.32.89
    b200-2.tail6c736b.ts.net` — 순서대로 시도. 각 노드의 설정 파일이 곧 그 관찰자의
    지도다. **tailscale 기기명(b200-2)과 칼라 별칭(b200)은 독립** — 방화벽 원칙의 실증.
  - **세션 이름** 우선순위: (1) 명시(`claude -n` 또는 khala 설정) → (2) 프로젝트
    디렉터리명 → (3) 충돌 시 `-2` 등 접미. 완전 주소는 `session@node`.
  - **이름의 수명 = "이름은 우편함이다."** 우편함은 이름 앞으로 존재하고, 같은 이름으로
    부활한 세션이 우편함을 승계한다(R5의 실체; soul-jar 세션 재시작 실측이 근거).
    동시 중복 주장은 나중 것이 이름을 갖고, 먼저 것의 수신함엔 **이름 상실 통지**가
    간다 — silent 탈취 금지. (통지는 배달 채널을 재사용하되 bounce와 종류 구분:
    bounce = 배달 불가 반송, notice = 상태 변화 알림.)

- <a id="d9"></a>**D9. last mile 형식 = (iii) 훅+스킬로 시작, MCP는 수요 확인 후 —
  확정** (유저 위임 하 양 세션 합의, 2026-08-12). 근거: (a) soul-jar 선례 — 훅+스킬만
  으로 3주, 도구가 아쉬운 순간 0회; 세션이 CLI를 직접 부르는 건 "도구 없음"이 아니라
  Bash가 이미 도구라는 뜻. (b) MCP 서버는 세션 수명에 결박된 상주 상태를 하나 더 만드는
  데, 한계 ④가 보여준 병이 정확히 "세션 안 상태" — 칼라의 미덕(상태는 디스크에)을
  last mile에서 배반하지 않는다. (c) 수요가 실제로 오면 (i)의 node 어댑터를 그때 붙이는
  게 되돌리기도 쉽다.

- <a id="d10"></a>**D10. Wake without impersonation — v0.1.x 최우선 (유저 승격,
  2026-08-12).** 유저 원문: "내장 메시징은 idle인 agent를 깨우는데, khala는 못 깨워서
  사실상 메시징의 역할을 못하는 것 같다. 나중에 고쳐야 할 것 같다."

  설계 — **`khala watch`: 수신 세션이 자기 자신을 깨울 감시자를 미리 심는다.**
  - 세션이 백그라운드 태스크로 `khala watch --session <s>`를 arm. watch는 주기마다
    `sync`(원격 pull 포함, 실패는 소리 내고 계속 — R10) 후 `inbox/<s>/new`를 확인,
    편지가 있으면 exit 0.
  - CC 하니스는 백그라운드 태스크가 끝나면 세션을 재호출한다(task-notification) —
    **이 세션이 밤새 codex 레인 완료 알림으로 깨어난 바로 그 경로라 이미 실증됨.**
    깨어난 세션이 `inbox --drain`으로 수거.
  - **R13 정합이 이 설계의 요점**: 깨우는 것은 수신자가 심어둔 자기 감시자의 종료이지
    발신자의 개입이 아니다. 발신자는 여전히 mailbox에 편지를 넣을 뿐 — 어떤 레인도
    타지 않고, 위장할 신원 자체가 없다.
  - 정직한 한계: watch를 arm하지 않은 세션은 못 깨운다. last mile 플러그인(D9)의
    SessionStart 훅이 "드레인 + watch arm"을 자동화해 옵트인을 기본값으로 만든다
    (soul-jar whisper의 SessionStart 패턴과 동형). 지연 ≤ interval(기본 30s),
    비우체통 노드의 ssh 비용 = interval당 rsync 1쌍.

- <a id="d11"></a>**D11. realtime = "하나의 설계" — r16에서 방향 확정 (2026-08-12,
  유저 회신 반영).** 정본: `review/d11-r16-one-design.md`. 골자:
  - **세 기관** — 뇌(bin/khala, bash, 의미론 전부 — 불변) · 신경(`khala link`, Go
    동봉 바이너리, 의미론 0의 파일 이벤트 펌프 — 노드당 상시 1개, 옵트인) · 귀
    (`khala watch`, 링크 살아 있으면 로컬 1s 폴로 내려앉음).
  - **캐리어**: 링크 프로토콜은 임의 바이트 파이프 위 — 프로덕션 = `ssh <hub> khala
    link --serve` (기존 키·지형 상속, 새 포트·인증 0). 터널이 생기면 ssh가 그 위를
    탈 뿐, 신경 무변경.
  - **토폴로지**: 스포크가 허브(b200)로 다이얼, 허브 쪽은 sshd 자식(serve)뿐 — 허브
    상주 데몬 0. serve 간 조정도 허브 파일시스템 이벤트(허브에서도 파일시스템이 버스).
    **오늘 지형에서 터널 없이 전 함대 초 단위.** 직결 엣지는 토폴로지의 자연 확장
    (r15의 L2 선택지 소멸).
  - **active 세션 개입**: native 메시징도 툴 라운드 경계 주입이고 khala wake
    (task-notification)도 같은 경계 — 같은 급, 같은 천장(진행 중 단일 툴콜은 누구도
    못 끊고, 그 너머 유일한 레인 = 유저 입력 레인은 R13이 영원히 금지). 진짜 위험인
    "귀가 안 서 있는 구간"은 D9 훅 3종(SessionStart arm / 드레인 직후 재-arm / Stop
    훅 무장 수리 = "idle이면 반드시 armed" 불변량)으로 구조적으로 닫는다.
  - r15 문서(`d11-live-layer-options.md`)는 사료; V2 실측(허브 상주 비용 = 소음,
    재접속 지터 필수)은 상속.

- <a id="d12"></a>**D12. watch/presence 정직성 (유저 위임 하 ink 확정, eddy 합치,
  r16).** heartbeat는 발화(send/inbox)만 갱신 — **watch는 시작 1회 갱신도 제거**
  (orphan watch가 산 자 행세 못 하게). watching(귀 열림)은 별도 파일: arm 시 생성,
  정상 종료 시 trap 삭제, 잔해는 TTL 소독. presence 표에 watching 열 추가 —
  "asleep+watching = 편지를 넣으면 깬다"가 정직하게 표시. 라우팅은 여전히 presence
  무의존(표시 전용 — 발견 실패가 배달 실패로 못 번진다, 스톱갭 결함 ③ 계보).

### 열린 항목 (r5 — 야간 자율 라운드)

- ~~D8 잔여 실측~~ **완료**: 개인망→b200 도달 확인 — 단 FQDN
  `b200-2.tail6c736b.ts.net`으로만, 짧은 이름 불가 (유저 실측 → D5 후보 목록으로 반영).
- **신규 실측 (soul-jar probe)**: B200→연구실 피어는 tailscale 데이터플레인은 생존
  (bw2 DERP pong)이나 ssh 22/49001 타임아웃 — inbound 방화벽/ACL 추정.
  → **v0.1 존재 증명 방향은 개인→b200 고정** (§9.1 교환 방향 규칙).
- mini 쪽 실행은 아침에 유저 손 1회(~5분). 그때까지 한 머신 마일스톤(§9.3 1→2→4)을
  밤새 완성. (야간 체제: 유저 취침 — "developer랑 협업해서 알아서" 위임, 양 세션 합의 =
  확정으로 진행.)

## 8. 비목표와 계약

- **soul-jar 계약**: 칼라와 soul-jar는 서로의 의존성이 되지 않는다. 이후 soul-jar 0.9.0
  rendezvous가 칼라 위를 타는 것은 가능하되 **옵트인**.
- 사람 간 메시징이 아니다 — 세션 간 통신망이다 (사람은 각 세션의 유저로서만 등장).
- 제3자 서버·클라우드 릴레이를 도입하지 않는다 (R7). Anthropic 경유 채널은 대조군이지
  구성 요소가 아니다.
- 스톱갭 session-messaging의 **대체**가 목표다 — 장기 공존이 아니라.

## 9. v0.1 구현 계획 (r4 — soul-jar 입력 반영, 상세화)

### 9.1 전송 프리미티브 = ssh+rsync over tailnet (soul-jar 제안 채택)

- tailscale IP는 이미 있고, ssh 키는 유저가 이미 쓰는 경로이며, **새 데몬·포트 0개**
  (R7 정합). 우체통은 "ssh로 닿는 디렉터리"일 뿐이다.
- 따라서 **`khala relay` 상주 모드는 v0.2로 이동** — R11의 relay는 역할 개념으로만
  남고, v0.1의 b200은 그냥 ssh 목적지다. 상주 프로세스가 하나도 없는 v0.1.
- 교환은 원격→우체통 방향으로 개시한다 (r5 실측: B200→연구실 피어 ssh 타임아웃,
  Tailscale 공유도 단방향). **r14 강등 — 이것은 아키텍처 불변량이 아니라 이 함대의
  현재 지형에 대한 운영상 사실이다** (유저: "B200→개인 tailnet 제약은 내 머신 일부의
  특수 상황이지 설계에 반영될 제약이 아니다"). 설계는 양방향을 기본으로 상정하고,
  방향 제약은 선언적 설정(R12)이 흡수한다 — 현재 config의 엔드포인트 후보 목록이
  이미 그 자리다(닿는 방향만 후보에 적으면 된다).

### 9.2 언어·배포 = bash, 단 jq 없이 (pen 결정 — 유저 위임 하)

- 관건이던 jq 의존은 **의존을 푸는 게 아니라 없앤다**: 온디스크 포맷에서 JSON을
  제거한다. 메시지 = maildir류 파일 + **RFC822류 헤더**(`Key: value` 줄들 + 빈 줄 +
  본문), 함대 설정 = 평문 줄 단위. 원칙: **"칼라의 모든 온디스크 포맷은 grep로
  읽힌다."** 의존성은 sh/coreutils + ssh/rsync로 끝 — 함대 전 노드 표준 장비.
- **호환 하한은 macOS가 정한다**: mac 기본 bash는 3.2(2007년산, 라이선스 문제로 동결).
  mbp·mini가 함대의 2/6이므로 **bash 3.2 호환 부분집합**으로 쓴다(연관 배열·mapfile
  금지 등). B200 실측(2026-08-11): bash 5.2.21 / rsync 3.2.7 / OpenSSH 9.6p1 — 상한은
  넉넉하고 하한만 지키면 된다.
- bash가 못 버티는 지점(동시성, 이진 첨부 등)이 오면 **Go 단일 바이너리가 2순위** —
  전환 평가 기준: 6플랫폼 크로스빌드 파이프라인이 유저 부담이 되는가. (soul-jar의
  bash 646→2000줄 선례는 참고하되, 칼라는 네트워크 코드라 성격이 다름을 인지.)
- **r16 갱신**: 그 지점이 왔다 — 단, 전면 전환이 아니라 기관 분리다. **뇌(bin/khala,
  의미론·온디스크 포맷)는 bash 불변** — "모든 온디스크 포맷은 grep로 읽힌다"는 신경이
  포맷을 만들지 않으므로 그대로 산다. **신경(`khala link`)만 Go**: 파일 이벤트
  (fsnotify, mac 포함)·지속 연결·지터 재접속이 bash 3.2 밖의 요구. GOOS/GOARCH 정적
  크로스빌드로 6플랫폼 부담 통과, 배포는 bin/khala와 같은 scp 한 줄. (유저 r16:
  "설계가 단순했으면 좋겠다는 거지, 구현까지 원시적일 필요는 없다.")

### 9.3 컴포넌트 (전부 `khala` CLI 하위 명령, D4)

1. `khala init` — 노드 등록: 함대 설정 읽기, `~/.khala/` 생성(0700), identity 기록.
2. `khala send <session@node>` — 로컬 발신 큐 안착(tmp+rename, msg_id 파일명).
   안착 = send 성공(§5.2).
3. `khala sync` — 배달 한 사이클: 우체통 rsync push/pull, ack 처리, 기한 초과 bounce
   생성. **멱등, 호출자 무관**(훅이든 cron이든 손이든), I/O wedge 대비 파일 단위
   타임아웃(R10).
4. `khala reconcile` — 네트워크 없이 로컬 큐 물질화·배달·정산·위생 한 패스.
5. `khala inbox` / `khala presence` — 조회 (드레인 상한 로직 포함).
6. CC 플러그인 — MCP(send/inbox/presence) + SessionStart 드레인 훅.

v0.2로 미룸: `khala relay` 상주 모드, 실시간 push 알림, cross-machine live 직결.

구현 순서: 1→2→4 (한 머신 안 왕복) → 3 (cross-machine — 존재 증명) → 5 (CC 통합).

### 9.4 수용 기준 (v0.1 완료의 정의 — 실기기 재현 1회)

> b200의 세션 A가 send → A 죽음 → mbp의 세션 B가 나중에 깨어나 inbox로 수신 →
> A의 발신 큐에서 ack 확인.

R4("잠든 상대에게 보낸 메시지는 죽지 않는다")의 존재 증명을 문장화한 것. 에뮬레이션·
같은 머신 폴백 불인정 — 실기기 왕복만 인정.

**✅ 충족 — 2026-08-12 08:2x~08:4x UTC, b200(컨테이너) ↔ mini(실기기), 코드 f3927ab.**

- 1구간: pen@b200의 편지(Id 1786475790…, 발신 2026-08-11)를 mini의 proof 세션이
  **13시간 뒤 첫 pull**로 수거·드레인 — 발신 이후 세션 상태와 무관하게 배달 (R4).
- 2구간: proof@mini의 회신(Id 1786523411…)이 우체통 경유로 pen 수신함 도착 —
  pen은 **khala watch의 wake로 깨어나** 수거 (D10까지 같은 왕복에서 실증).
- ack 왕복 완결: 회신의 ack가 mini `outbox/acked/`에 (soul-jar가 유저 제공 출력으로
  확인), leg-1의 ack는 pen `outbox/acked/`에 (pen 자체 정산 확인).
- 경로: 개인망→b200 FQDN + ssh 별칭(Port 49001), DERP 경유 — docs/SETUP-second-node.md
  가 실증된 절차.

### 9.5 구현 규칙 (hard rules)

- **동적 작업(빌드·실행 파일 테스트)은 $HOME 밑에서.** B200 /tmp는 noexec — 실행하면
  exit 126 (soul-jar 실측 상속). 칼라 런타임 저장소도 ~/.khala(0700), /tmp 사용 금지.

### 9.6 온디스크 명세 (v0.1 — 구현의 기준)

루트 = `$KHALA_HOME` (기본 `~/.khala`, 0700; 환경변수는 테스트 격리용).
모든 쓰기는 같은 FS 안 `tmp/` 경유 후 `mv` (원자성). 원칙 재확인: **전부 grep로 읽힌다.**

```
config                    # 함대 설정 (줄 단위)
outbox/new/               # 발신 큐 — end-to-end ack까지 보관 (§5.2)
outbox/acked/             # ack 수신 완료
outbox/dead/              # dead-letter (§5.2 bounce 1회성의 종착지)
spool/for/<node>/         # 라우팅 큐; 우체통 노드에선 교환 지점
inbox/<session>/new|cur/  # 세션별 우편함 (드레인이 new→cur 이동)
presence/<session>        # heartbeat 파일 (내용 = epoch 한 줄)
presence/<name>@<node>.watcher # watcher 선언/last-notify/dead-man 상태 (6행; legacy 5행 read)
log/delivered             # dedup 로그: "<epoch> <msg_id>" 줄
tmp/
```

함대 설정 (한 줄 = 한 사실):

```
self b200
peer b200 100.87.32.89 b200-2.tail6c736b.ts.net   # 후보 순서 시도; ~/.ssh/config 존중
peer alpha /abs/path/to/khala-home                 # 절대경로 후보 = 로컬 rsync (r8 비준)
mailbox b200 bw2                                   # 우체통 우선순위
ttl 120                                            # presence alive 판정 초 (기본 120)
```

별칭·세션명 문자셋 = `[a-z0-9][a-z0-9-]*` (파일명·주소 안전). 주소 = `session@node`.

메시지 파일 (파일명 = Id):

```
Khala: 0.1
Id: <epoch>.<pid>.<rand>.<session>@<node>
From: <session@node>
To: <session@node>
Date: <ISO8601 UTC>
Type: message | ack | bounce
Refs: <id>                # ack/bounce만
Subject: <한 줄>          # 선택 (send -s; 줄바꿈 금지) — r7에서 비준
Priority: later           # 선택 (send --later) — conduit 초인종을 세션 idle까지 미룸; 기본(헤더 없음)은 next (0.5.5)
Expires: <epoch>          # 미지정 시 발신 +30일 (문서화된 기본값 — 영원한 재전송 없음)
<빈 줄>
본문 (UTF-8 텍스트. 이진 첨부 필요 = Go 전환 트리거, §9.2)
```

notice 파일 (헤더 순서 고정, `Subject`만 선택):

```
Khala: 0.1
Id: <epoch>.<pid>.<rand>.<watcher>@<node>
From: <watcher>@<node>
To: <session>@<node>
Date: <ISO8601 UTC>
Type: notice
Urgency: urgent | info
Subject: <한 줄>          # 선택
Expires: <epoch>          # 기본 발신 +2일
<빈 줄>
본문
```

notice의 제어 필드는 봉투에서만 읽는다. `Urgency: info`만 quiet이며, urgency가
`urgent`이거나 없거나 다른 값이면 보수적으로 urgent로 분류한다. notice에는
`Refs`, `In-Reply-To`, `Priority`가 없다.

watcher marker `presence/<name>@<node>.watcher` (6행, 전체를 원자 교체):

```
<declared-epoch> | retired <epoch>
<cadence-seconds>                 # 0 = unknown, dead-man 없음
<owner-session@node> | -              # 전체 주소; 원격 owner 허용
<last-notify-epoch>               # 0 = never
active | silent <since-epoch>
<state-since-epoch>               # 현재 active/silent 상태에 들어간 시각
```

모든 writer는 6행을 쓴다. reader는 0.8.0/0.8.1의 5행 marker도 받으며, 이때 L6는
active이면 선언 시각(L1), silent이면 L5의 `since-epoch`로 해석한다. 6행 marker를 먼저
복제받은 0.8.1 노드는 CLI를 0.8.2로 올릴 때까지 reconcile마다 `잘못된 watcher marker`
sync_error를 남기고 그 row를 숨긴다. 5행 fallback을 쓰지 않으므로 rollout은 CLI를
순차 갱신해 이 짧은 mixed-fleet 구간을 끝낸다.

`notify --as`와 `khala watcher beat <name>`은 plain heartbeat를 쓰지 않고 marker의
4행만 갱신한다. `beat`는 notice/inbox/outbox/spool/reconcile trigger를 만들지 않으며,
선언되지 않았거나 retired인 watcher를 거부한다. `notify`는 marker가 없으면 cadence 0,
owner `-`, active로 한 번 안내하고 자동 선언한다. last-notify가 0이면 dead-man의 기준은
선언 시각(L1)이다. 삭제는 복제되지 않으므로 retire는 1행을 다시 쓴다.

타입별 취급:

- **message** → 수신 노드 sync가 `inbox/<session>/new/`에 배달 + ack 생성. **ack는
  `spool/for/<발신노드>/`에 직접 태어난다 — outbox를 거치지 않는다** (무보관·best-effort
  원칙 §5.2의 구현; 발신자의 outbox는 원문 보관용이고 ack는 파생물이므로).
  `log/delivered`로 dedup — 중복 수신 시 배달 없이 **ack만 재생성**(§5.2).
- **ack** → 인프라 메시지, inbox에 안 보임. 발신 노드 sync가 소비:
  `outbox/new/<Refs>` → `outbox/acked/` 이동 **+ 같은 단계에서 `spool/for/<수신노드>/`의
  해당 message 사본 삭제** (재전송 중단). **dead의 원문은 ack가 와도 dead에 남는다** —
  만료 판정은 발신자의 최종 판정이고, bounce 이후 도착한 ack는 상태를 되돌리지 않는다
  (r10, soul-jar 리뷰 비준).
- **bounce / notice** → 해당 세션 inbox로 fire-and-forget 배달 (bounce는 1회성,
  재반송 없음 — §5.2). notice는 ack를 만들지 않는다.

spool 사본의 수명 (타입별):

- **message 사본 = 재전송 원천** — ack가 원본을 소비할 때 함께 삭제된다 (위).
- **ack/bounce 사본 = fire-and-forget** — (b) push 성공 시 삭제. 유실은 원문
  재전송 → dedup → ack 재생성이 치유한다 (§5.2).
- **notice 사본 = 발신 노드가 `Expires`까지 보관** (0.8.0, GPT-Pro P0-1) — 우체통이
  바이트를 받은 것은 배달이 아니다(R4). 수신 노드는 Id로 중복을 흡수하고, 만료된
  사본은 `prune_expired_notices`가 지운다.

sync 한 사이클 (멱등, 호출자 무관 — 한 사이클 = 각 단계 한 패스; ack 정산이 다음
사이클로 넘어갈 수 있으나 멱등이므로 무해):

- (a) `outbox/new/*` 중 **`spool/for/<목적노드>/`에 같은 Id 사본이 없는 것만** 복사
  (멱등 조건). 원본은 ack까지 잔류.
- (b) 우체통과 교환 — **push = rsync, 삭제 없음**(같은 내용 재전송은 rsync가 스킵;
  멱등) / **pull = rsync --remove-source-files**(수거자가 우체통을 비운다 — 우체통엔
  in-flight만 남는다, 무한 적재 방지). presence 스냅숏 동봉(관찰자별 뷰 §5.4).
  self가 우체통이면 no-op (spool/for/<self>가 곧 로컬 교환 지점).
  **항상 원격→우체통 방향 개시** (§9.1).
  - r8 세부: push 범위 = 모든 X≠self의 `spool/for/<X>/` → 우체통 동일 경로; pull 범위 =
    우체통 `spool/for/<self>/`. 엔드포인트 후보는 **ssh 목적지 또는 절대경로**(로컬
    rsync) — 후보가 무엇이든 rsync 호출 경로는 동일하다(절대경로는 테스트 정직성 +
    같은 머신/공유 FS 우체통 일반화, R12). 타임아웃은 `timeout(1)` 금지(mac 기본 부재)
    — `rsync --timeout` + ssh `ConnectTimeout`으로(R10).
  - r9 비준 (구현 라운드의 AMBIGUOUS 해소 3건):
    1. ssh 엔드포인트의 원격 루트 = 기본 `~/.khala` (v0.1은 per-peer 루트 오버라이드
       없음 — 필요해지면 config 확장).
    2. **(b) 안에서 ack 선정산(pre-settle)**: push 전에 `spool/for/<self>` pull + ack
       정산을 먼저 한다. 문면의 push→pull 순서로는 정산 직전의 원문 사본이 재푸시돼
       사이클 간 멱등이 깨진다(수용 속성 4가 검출) — 순서는 pull(ack)→settle→push→pull.
    3. 우체통에 배달된 message 사본의 소비자 = **수신측 sync (c)** — ack 생성 성공
       직후 삭제. push는 무삭제라 발신자가 지울 수 없고, 발신측 재전송 원천은
       발신 로컬 spool 사본이므로 at-least-once 불변.
  - presence 교환(r8): heartbeat 파일명을 `<session>@<node>`로 확장(노드 간 충돌 방지;
    표 출력 형식과 일치). (b)에서 자기 노드 파일들 push + 전체 pull(삭제 없는 merge) —
    신선도 판정은 §5.4대로 관찰자 쪽. 이로써 `alive-elsewhere`가 실제로 채워진다.
- (c) `spool/for/<self>/*` 타입별 배달 + `Expires` 지난 `outbox/new/*` → bounce 생성
  후 `outbox/dead/` 이동 + **`log/delivered`에서 60일 지난 줄 잘라내기** (Expires 기본
  30일의 2× 여유; 30일+ 재전송이 재배달될 수 있는 경계는 문서화된 절충 — 저장소 위생도
  R10의 일부).
- (c) 위생 추가 (r12): **파싱 불능 spool 파일**(Id/파일명 불일치, 헤더 결손 등 —
  영구히 valid해지지 않을 파일)은 **mtime 30일 경과 시 `spool/dead/`로 이송 + stderr
  로그**. 30일 = Expires 기본값과 같은 상수 계열(§9.6 메시지 포맷) — 정상 메시지가
  spool에 그보다 오래 머물 수 없으므로, 그 나이의 파싱 불능 파일은 배달물이 아니라
  잔해다. 이송이지 삭제가 아님(silent 소멸 금지) — 부검 가능하게 남긴다.
- retention (0.8.0): `Expires`가 지난 notice는 `spool/for/*`와
  `inbox/*/new|cur`에서 조용히 삭제하며 배달 직전 만료도 drop한다.
  `inbox/*/cur`, `outbox/acked`, `outbox/dead`는 **그 상태에 들어간 시각**(drain/ack/만료
  이동 시 mtime을 갱신)이 `retain`일(기본 30)보다 오래되면 삭제한다 — Id epoch가 아니다:
  31일 묵은 편지를 drain한 직후 지워지면 안 된다(mtime이 Id보다 앞서면 Id epoch로 폴백).
  `send -e`는 5097600초(59일) 이하로 제한한다 — dedup 기록 보존(60일) 안에 들어야
  재전송이 두 번 설치되지 않는다. `inbox/*/new`의 mail은 retention으로 절대 삭제하지 않는다.
  **age-out 정리는 `retention-interval`초(기본 300, 0=매 pass)에 한 번만** 돈다(0.8.1):
  reconcile은 link가 fresh한 동안 1초마다 불리는데, 0.8.0은 매 pass마다 편지 트리 전체를
  파일당 서너 번 fork하며 검사해(수백 통에 6-8 s) brain.lock.d를 사실상 독점했고 그 노드의
  drain/notify가 60회 대기 뒤 실패했다(2026-09-02 실측). 배달·ack·dead-man·outbox 만료·
  preserve 캡처·stream/mind 파일 검증과 격리·낮은 mind generation 수거(프로토콜 1.2 GC)는
  매 pass 그대로이며, 기준 시각은 `run/retention.stamp`의 mtime이다(없거나 미래면 due —
  잠금이 아니라 즉시 정리). 같은 이유로 reconcile 루프가 값 하나마다 sed/grep을 fork하던
  헬퍼(header_value·normalize_integer·valid_*·validate_mind_file)는 순수 셸로 바꿨다 —
  pass 비용은 fork 수가 지배한다(트리 사본 실측, 0.7.3 → 0.8.1 게이트 pass: b200 3.3 s → 0.2-0.3 s, mini 허브 3.0 s → 0.6-0.8 s; 5분마다의 정리 pass는 2.2 s / 5.1 s).
  `.watcher`는 retired 선언 시각이 retention보다 오래됐거나, declared와
  last-notify가 모두 오래됐을 때만 삭제한다.

**한 머신 마일스톤 = (a)+(c) 경로의 실증** (self=우체통이라 (b)=no-op). cross-machine은
(b)의 rsync만 추가 — 코드 경로가 같아서 에뮬레이션이 아니라 부분집합이다.

CLI 인터페이스 (한 머신 마일스톤 범위):

- `khala init <자기별칭>` — 디렉터리 생성(0700), config 골격, identity 기록.
- `khala send <session@node> [-s 제목] [-e 만료초]` — 본문은 stdin 또는 `-m`.
  발신 세션명: `--as` > `$KHALA_SESSION` > `$PWD` basename (D5). 안착 = 성공(§5.2).
- `khala notify <session@node> --as <watcher> [-s 제목] [--urgent] [-e 만료초]` —
  본문은 stdin, outbox/ack 없음. 기본 info/2일.
- `khala watcher declare <name> --cadence <초> --owner <session@node> | beat <name> | list |
  retire <name>` — machine identity, event 없는 생존 신호, dead-man 상태 관리. list의
  `SINCE`는 현재 active/silent 상태에 들어간 뒤 지난 시간을 `LAST`와 같은 형식으로 보인다.
- `khala sync` — 위 한 사이클. 실패는 파일 단위로 소리 내고 계속(R10) — 전체 abort 금지.
- `khala reconcile` — (a)+(c)만 한 패스 실행하며 네트워크 I/O는 하지 않는다.
- `khala inbox [--drain [--max-n N] [--max-bytes B] [--max-notices N]
  [--max-notice-bytes B] [--mail-only|--notices-only]]` — 목록/드레인(new→cur).
  상한 초과분은 "N건 더 (발신자 목록)" 요약만 (§5.5). 기본 상한 = 20건 / 65536바이트
  (r7에서 비준).
- `khala presence` — 4상태 표. send/inbox는 자기 heartbeat를 갱신하고 presence는 순수
  조회다. 출력에 §5.4의 절충 명시: "asleep = 칼라 활동 없음 (세션 죽음 아님)".
- 오류는 크게: config 없으면 "khala init 먼저" 안내 후 비0 종료. silent fallback 금지.
