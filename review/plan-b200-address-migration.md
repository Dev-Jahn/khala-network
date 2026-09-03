# b200 회수 시 eddy·ink·steno 주소 이전 계획 (유저 결정 문서)

> status: **draft r1** (ink, 2026-08-17). 결정이 필요한 항목은 §5. 결정 전에는 아무것도 실행하지 않는다.

## 0. 한 문장 요약
b200은 **컨테이너**라 회수되면 `~/.khala` 전체(우편함 원본·마음·스트림 커서·presence)와
`/NHNHOME/WORKSPACE/...`의 세 작업 트리(soul-jar=eddy, khala-network=ink, steno)가 함께 사라진다.
칼라 주소는 `이름@노드`이고 **이름은 우편함이다**(DESIGN D5) — 그러므로 "이전"은 세 이름의
우편함이 **어느 노드에 다시 열릴지**를 정하고, 함대의 나머지가 그 노드로 편지를 보내게 만드는
일이다. 코드 변경은 필요 없다. 필요한 건 (a) 새 노드 결정, (b) 회수 **전** 백업 한 번,
(c) 회수 **후** 세 노드 설정 3~4줄, (d) 옛 주소 은퇴 선언.

## 1. 지금 b200에 묶여 있는 것 (2026-08-17 실측)

| 것 | 위치 | 회수되면 | 옮길 가치 |
|---|---|---|---|
| 세션 신원 `eddy` `ink` `steno` | 각 작업 트리의 `.khala-session` (soul-jar/, khala-network/, steno/) | 트리와 함께 소멸 | 신원 자체는 파일 5바이트 — 새 노드의 트리에 다시 쓰면 끝 |
| 우편함 원본 `inbox/{eddy,ink,steno}/cur` | `~/.khala/inbox` — eddy 65통, ink 57통, steno 16통(+pen 17, soul-jar 16, 프로브들) | 소멸 | **읽음(cur)** 편지 = 과거 대화 기록. 이력 가치만 있음. 원하면 tar 1개 |
| 미읽음 `inbox/*/new` | 현재 0통 | — | 회수 직전 `khala inbox --drain` 3회로 0을 확인하면 손실 없음 |
| minds (`khala mind`) | `~/.khala/minds/b200/{eddy,ink,steno,…}` | 소멸 | 다른 노드가 이미 복제본을 갖고 있음(minds는 노드 간 복제됨). 새 노드에서 새 마음을 다시 선언하는 것이 자연스러움 |
| 스트림 커서 (`khala say/join`의 읽은 위치) | `~/.khala/cursor` `~/.khala/join` | 소멸 | 새 노드에서 join하면 커서는 처음부터 — retention(30일) 안의 commons만 다시 보임. 손실 아님 |
| presence 심장박동 `eddy@b200` 등 | 함대 전 노드의 `presence/` | b200 것은 정지, 다른 노드에는 **stale 항목으로 남음** | `khala retire`로 은퇴 선언해야 지도가 깨끗해짐 |
| conduit·link 상주 프로세스, `/tmp/khala-2985` 런타임 | b200 컨테이너 | 소멸 | 상태 없음. 새 노드는 훅이 `node ensure`로 알아서 띄움 |
| 이 저장소(khala-network 정본 + 리뷰 문서 + hippo) | `/NHNHOME/WORKSPACE/.../khala-network` | 소멸 | **가장 중요.** public clone(main=배포본, dev=테스트 포함)과 rescue(`/NHNHOME/jahn/khala-rescue`)가 있으나 rescue도 b200 안. **`.hippo/`·`review/`·정본 브랜치는 b200 밖으로 push 필요** |
| soul-jar 저장소·`~/.soul-jar` | b200 | 소멸 | 칼라 범위 밖이지만 eddy의 정체성. 별도 백업 대상으로 표기 |
| steno 저장소·`~/.venvs/steno`·GPU 결과물 | b200 | 소멸 | 칼라 범위 밖 |

함대의 다른 노드에는 b200행 **미배달 편지가 0통**(spool/outbox 확인). 즉 "회수 순간에 날아가는
편지"는 지금은 없다. 회수 시점에는 다시 확인한다(§4 체크리스트).

## 2. 원칙 (DESIGN에서 이미 정해진 것 — 다시 결정할 필요 없음)
- **주소는 프로세스보다 오래 산다, 그러나 노드보다 오래 살지는 않는다.** `이름@노드`에서 노드는
  우편함이 있는 물리 위치다. 노드가 사라지면 그 주소는 은퇴하고 새 주소가 태어난다.
  "`eddy@b200`을 다른 머신이 계속 자칭한다"(별칭 재사용)는 방식은 **권하지 않는다** — 함대의
  모든 노드 config에서 `peer b200 <엔드포인트>`를 새 머신으로 고쳐야 하고, presence·minds에 남은
  옛 b200 흔적과 섞이며, "b200 = 그 컨테이너"라는 함대 지도(DESIGN §2)가 거짓말이 된다.
- **이름은 우편함이다(D5).** 그래서 `eddy@spark1`은 `eddy@b200`의 후계자이지 같은 우편함이 아니다.
  이력을 잇고 싶으면 옛 `cur/`를 새 노드의 `inbox/eddy/cur/`에 **복사해 넣어도 된다** — 파일명이
  Id라 충돌 없고, drain은 `new/`만 보므로 재배달도 없다.
- 노드 이름을 새로 짓지 않는다. 함대 별칭 집합은 `b200 bw2 mini spark1 mbp wsl`(D5) — 새 노드는
  이 중 하나거나, 유저가 새 머신을 들일 때 그 머신 이름이다.

## 3. 선택지 — 세 이름은 각각 어디로 가나

세 세션의 성격이 다르므로 한 노드로 몰 필요가 없다.

| 이름 | 하는 일 | 후보 노드 | 비고 |
|---|---|---|---|
| **ink** (설계 펜) | khala-network 저장소 작업. GPU 불필요, 상시성 불필요 | **bw2** (연구실 리눅스, 24/7, 양쪽 tailnet에 닿음, systemd --user 있음 → conduit 상주가 가장 깔끔) / mini | 저장소 정본이 bw2로 가면 rescue 미러도 함께 |
| **eddy** (soul-jar) | 리뷰·함대 실측·soul-jar 플러그인 | soul-jar 저장소가 가는 곳 = **bw2** 또는 유저 랩탑(mbp) | 유저가 soul-jar를 어디서 돌릴지에 종속 |
| **steno** | GPU 실험(torch.compile, triton) | **GPU가 있는 곳** — spark1(DGX Spark) 또는 다음 클라우드 컨테이너 | 다음 컨테이너가 또 임시라면 그때도 이 문서를 재사용 |

**추천**: ink·eddy → `bw2`, steno → 다음 GPU 머신(그 머신 이름). 이유: bw2는 유저 관리 tailnet
양쪽에 이미 있고(DESIGN D8), 상시 가동이며, systemd --user가 있어 conduit·link가 서비스로 산다
(b200처럼 setsid 폴백이 아님). mini는 우체통(mailbox) 역할이라 개발 세션까지 얹지 않는 편이 낫다.

## 4. 실행 순서 (결정 후; 전부 기존 명령만 사용)

**회수 전 (b200에서, 10분)**
1. `khala inbox --drain` — eddy·ink·steno 각각(또는 `khala status`로 PENDING 0 확인). new/가 0통인지.
2. 백업 tar 1개: `tar czf khala-b200-$(date +%F).tgz -C ~ .khala/inbox .khala/minds .khala/streams .khala/archive .khala/config`
   → 새 노드로 scp. (편지 이력을 잇지 않기로 하면 이 단계는 생략 가능하나, 3분짜리라 그냥 한다.)
3. **저장소 밖으로**: khala-network 정본(main + 작업 브랜치 + `.hippo/` + `review/`)을 public
   저장소 또는 bw2로 push. soul-jar 저장소도 동일. (steno는 유저 소관.)
4. 옛 주소 은퇴 선언 — 새 노드가 준비된 **다음에**(§5 Q3 참조): b200에서 `khala retire eddy`,
   `khala retire ink`, `khala retire steno` → presence에 은퇴 표시가 함대로 퍼진다.
   (b200이 예고 없이 사라지면 이 단계는 못 한다. 그 경우 다른 노드에서는 `eddy@b200`이 stale로
   남고, `khala presence`에서 마지막 심장박동 시각으로 구별된다 — 지도만 지저분해질 뿐 오동작은 없음.)

**회수 후 (새 노드에서, 5분/노드)**
5. `khala init <노드별칭>`이 이미 되어 있는 노드(bw2·spark1·mini·mbp 전부 됨)면 생략.
6. 작업 트리에 `.khala-session` 쓰기 — 예: bw2의 `khala-network/.khala-session` ← `ink`,
   `soul-jar/.khala-session` ← `eddy`. 세션을 열면 훅이 `ink@bw2`로 등록·lease·conduit ensure까지 자동.
7. (이력 잇기 선택 시) 백업의 `inbox/<이름>/cur/*`를 새 노드 `~/.khala/inbox/<이름>/cur/`로 복사.
8. 마음 재선언: `khala mind` (새 노드 관점의 문장 하나).
9. 함대에 알림 한 줄: `khala say khala -s "[이사] eddy·ink → bw2, steno → <노드>"`.
   보내는 쪽은 그때부터 `khala send ink@bw2`. 옛 주소로 보낸 편지는 배달될 곳이 없으므로 발신 노드의 outbox에
   머물다 Expires가 지나면 **bounce**로 발신자 수신함에 되돌아온다(dead-letter 보관) — 조용히 사라지지 않는다.

## 5. 유저 결정이 필요한 것

| # | 질문 | 추천 |
|---|---|---|
| Q1 | ink·eddy의 새 집은 bw2인가? (아니면 mini/mbp/다음 컨테이너) | **bw2** |
| Q2 | steno의 새 집은? (spark1 / 다음 GPU 컨테이너 / 당분간 없음) | 다음 GPU 머신 — 이름은 그때 |
| Q3 | b200 회수 **예고**가 있나? 있으면 §4 1–4를 회수 전에 하고, 없으면 지금 백업·push만 미리 해두고 retire는 생략 | 예고 여부와 무관하게 **§4 2–3(백업·push)은 지금 해두자** |
| Q4 | 편지 이력(cur/ 155통)을 새 노드로 잇나? | 잇는다(3분, 부작용 없음) |
| Q5 | 옛 주소를 새 머신이 물려받는 방식(`self b200`을 bw2가 자칭)은 하지 않는다 — 동의? | 동의 (원칙 §2) |

## 6. 이 계획이 필요 없게 만드는 장기 항목 (기록만)
- 노드가 사라져도 우편함이 살아남게 하려면 우편함이 **우체통(mailbox 노드)에 원본**을 두고
  세션 노드는 사본만 갖는 모델이 필요하다 — DESIGN §5.2 "mailbox-first"의 반대 방향이라 v1
  범위 밖. 지금 함대는 mini가 우체통이므로 사실상 "mini에 다 남아 있다"에 가깝지만, 배달 완료된
  편지는 mini에서 정리되므로 보장은 아니다. 필요해지면 그때 설계.
