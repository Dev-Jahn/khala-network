# khala-network — GPT 응답 (구독 ChatGPT)

- 패킹: `pack_khala-network_20260812_102127_1014286_14fff5.md` (~37,206 tokens)
- 모델: `GPT-5.6 Sol`
- 프롬프트: # khala-network r16 "하나의 설계" — 설계 리뷰 요청

## 배경 (2분 요약)

여러 머신(리눅스 서버들, mac 2대, W...

---

# 총평

r16의 중심 판단은 타당합니다. **내구 상태와 의미론은 디스크·bash 뇌에 남기고, Go 신경은 지연만 줄인다**는 분리는 제약과 잘 맞습니다. 허브도 별도 데몬 없이 SSH 자식과 파일시스템만으로 fan-out할 수 있습니다. 다만 현재 문서의 “모든 노드가 하나의 트리의 사본”을 **대칭 파일 미러링**으로 구현하면 의미론이 깨집니다. 정확한 모델은 **하나의 논리 트리에 대한 역할별 투영(materialized projection)** 입니다.  r16은 뇌가 의미론 전부를 소유하고 신경은 파일만 운반한다고 선언하지만, 현재 스풀의 보존·삭제 규칙은 파일 타입과 노드 역할에 따라 다릅니다. 

따라서 평결은 **아키텍처 방향은 승인**, **현재 문면 그대로 구현 착수는 불가**입니다. 아래 네 가지 S0 계약을 먼저 r16.1 수준으로 명문화해야 합니다.

## 심각도순 결함 요약

| 심각도    | 결함                                            | 6노드·동시 세션 약 10개에서의 판정                      |
| ------ | --------------------------------------------- | ------------------------------------------ |
| **S0** | 복제 경로의 소유권·삭제 전파 규칙 부재                        | **첫 메시지부터 발생 가능한 결정적 문제**                  |
| **S0** | `send` 안착과 신경이 감시하는 `spool` 사이의 활성화 경로 부재     | **현재 코드에서는 모든 send에 해당**                   |
| **S0** | bash 뇌가 동시 `sync`·`inbox --drain`에 안전하지 않음    | **watch·link·수동 sync가 겹치므로 실제 발생 가능성이 높음** |
| **S0** | 동일 스풀 ID가 서로 다른 바이트를 가질 수 있음                  | **ACK 재생성이라는 정상 경로에서 발생**                  |
| **S1** | 파일 이벤트를 진실로 취급할 위험                            | 장기 실행·재접속·mac 절전 환경에서 **사실상 필수 보강**        |
| **S1** | stdio 전송의 commit·backpressure·I/O wedge 계약 미정 | B200의 파일 I/O wedge 이력 때문에 **현실적 위험**       |
| **S1** | “링크 신선”의 정의와 singleton 교체 절차 미정               | mac 2대·바이너리 배포 때 **반복적으로 만날 문제**           |
| **S2** | 단일 `watching` 파일의 재무장/종료 경쟁                   | 메시지 유실은 없지만 presence 오표시·중복 wake 가능        |
| **S3** | 허브 serve N개의 이벤트 fan-out 비용                   | **6노드에서는 비문제**. 정확성 문제가 비용보다 우선            |

---

# 1. 구조적 결함: “사본”이 아니라 “소유권이 있는 투영”이어야 한다

## 1.1 현재 스풀은 대칭 복제 가능한 트리가 아니다

현재 명세에서 같은 `spool/for/<node>/<id>` 경로는 위치에 따라 역할이 다릅니다.

* 발신 노드의 message 스풀: e2e ACK까지 보관하는 **재전송 원천**
* 허브 스풀: 수신자가 가져갈 때까지 보관하는 **transit copy**
* 수신 노드의 `spool/for/self`: 뇌가 배달 후 소비하는 **inbound staging**
* ACK·bounce·notice의 발신 스풀: 원격 push 성공 후 지우는 **fire-and-forget source**

명세도 message는 ACK까지 보관하지만 ACK·bounce·notice는 push 성공 후 삭제한다고 명시합니다. 허브에서는 pull 성공 후 source를 제거하고, 수신 노드는 ACK 생성 후 inbound message를 소비합니다. 

따라서 일반적인 양방향 미러 규칙은 둘 다 틀립니다.

* **삭제를 전파하면:** B가 배달 후 자기 staging을 지운 사실이 허브를 거쳐 A의 재전송 원천까지 전파될 수 있습니다. 그러면 e2e ACK 전에 A의 복구 원천이 사라집니다.
* **삭제를 전파하지 않으면:** 허브 transit과 fire-and-forget 객체가 영구 잔류하고 계속 재전송됩니다.

이 문제는 dedup으로 해결되지 않습니다. dedup은 **수신 사용자에게 같은 메시지를 두 번 보이지 않게 하는 장치**이지, 발신 재전송 원천의 조기 삭제나 허브 무한 적재를 교정하는 장치가 아닙니다. 발신 큐는 e2e ACK까지 보관해야 한다는 것이 원래 의미론입니다. 

## 1.2 권고하는 하나의 복제 계약

r16의 한 문장은 다음처럼 정제하는 편이 정확합니다.

> **모든 노드는 하나의 논리 트리에서 자기 소유 경로와 필요한 투영을 디스크에 가진다. 신경은 누락된 immutable object만 보충하며, 소비와 의미론적 삭제는 경로 소유자인 뇌만 결정한다.**

구체적인 경로 계약은 아래 하나면 충분합니다.

| 경로/객체                                                   | 링크 동작                           | 삭제 소유자                                               |
| ------------------------------------------------------- | ------------------------------- | ---------------------------------------------------- |
| `outbox/new/*`                                          | 전송하지 않음. 로컬 뇌를 깨우는 trigger로만 감시 | 발신 뇌가 ACK/만료 시                                       |
| spoke의 `spool/for/X/*`, `X != self`                     | 허브로 offer                       | message는 e2e ACK 시 뇌, infra는 transport commit 통지 후 뇌 |
| hub의 `spool/for/X/*`                                    | **X 담당 serve만** X로 offer        | X가 durable commit한 후 허브 serve                        |
| spoke의 `spool/for/self/*`                               | 설치만 하고 절대 upstream으로 반사하지 않음    | 수신 뇌                                                 |
| owner의 presence/watching lease                          | owner→hub→모든 spoke              | TTL 또는 owner lease 종료                                |
| `inbox/`, `log/`, `outbox/acked`, `outbox/dead`, `tmp/` | 링크 범위 밖                         | 로컬 뇌                                                 |

핵심은 다음 두 규칙입니다.

1. **스풀의 일반적인 delete/tombstone 전파를 만들지 않는다.**
2. **신경은 “원격이 이 파일을 durable하게 보유한다”는 transport 사실만 뇌에 알린다.**

예를 들어 spoke의 ACK 파일을 허브가 `STORED`했다고 응답하면 신경은 `khala transport-committed <path>` 같은 내부 호출을 합니다. 뇌는 파일의 `Type`을 읽고 ACK·bounce·notice라면 삭제하고, message라면 유지합니다. 신경이 이 호출 전에 죽으면 파일은 남아 재offer되고, 허브가 `HAVE`를 답한 뒤 다시 통지하면 됩니다. 별도 영속 transfer DB가 필요하지 않습니다.

이 방식은 신경의 “의미론 0”을 지킵니다. 신경은 RFC822 헤더를 해석하지 않고 **경로 역할과 transport commit**만 압니다.

## 1.3 허브 serve N개의 경쟁 조건

### 서로 다른 spoke를 담당하는 serve

`spool/for/B`의 파일은 **B 담당 serve만 downstream 후보**로 삼으면 됩니다. 다른 serve가 같은 이벤트를 보더라도 필터에서 끝납니다. 따라서 모든 serve가 같은 상위 트리를 감시해도 “누가 파일을 가져갈 것인가”라는 작업 큐 경쟁은 없습니다.

### 같은 spoke의 serve가 두 개 존재하는 경우

재접속 overlap, 업그레이드, singleton 실패로 B serve가 둘 생길 수 있습니다. 이 경우도 correctness는 다음처럼 유지해야 합니다.

1. 두 serve 모두 같은 파일을 `OFFER`
2. B는 첫 번째에 `NEED`, 두 번째에는 `HAVE` 또는 둘 다 수신
3. 최종 설치는 ID·digest 기반 no-clobber
4. 하나가 `STORED`를 받고 허브 source를 삭제
5. 다른 하나의 삭제가 `ENOENT`면 성공으로 취급

**공유 파일을 rename하여 독점 claim하는 방식은 권하지 않습니다.** 이벤트는 broadcast hint이지 work-queue lease가 아닙니다. claim 소유자가 죽으면 파일은 남아 있어도 다른 serve가 그것을 자기 일로 보지 못하는 별도 복구 규칙이 필요해집니다.

### 실제 함대 판정

6개 serve가 같은 상위 디렉터리 이벤트를 받는 비용은 이 규모에서는 중요하지 않습니다. 기존 long-poll 실측에서도 연결 10개는 약 160MB RSS였고 폴링 CPU는 미미했으며, 실질적인 경계는 동시 재접속 시 MaxStartups였습니다.  correctness를 위해 serve별로 `spool/for/<담당 노드>`만 scan하도록 하면 fan-out 비용은 더 작아집니다.

---

# 2. `send`와 신경 사이에 현재 결정적 공백이 있다

r16의 흐름은 “A의 send 안착 → A 링크가 즉시 허브 스풀에 push”입니다. 그러나 현재 `cmd_send`는 파일을 `outbox/new`에 rename한 뒤 ID를 출력하고 끝납니다. `spool/for/<dest>`로의 materialization은 이후 `sync_cycle`의 `copy_outbox_to_spool`에서만 일어납니다.  

그런데 r16의 신경 감시 범위는 `spool`·`presence`로 적혀 있습니다. 따라서 현재 문면대로라면:

```text
send 성공
  → outbox/new에만 존재
  → spool 이벤트 없음
  → link는 아무것도 모름
```

특히 수용 속성 4의 “링크가 죽은 동안 send한 잔여분을 링크 재기동 시 자동 수렴”도 실패합니다. 링크가 재시작해 spool만 scan하면 outbox에 남은 파일을 발견할 수 없습니다. 해당 자동 수렴은 r16의 등록된 요구입니다. 

## 필요한 접합부

다음 하나로 정리하는 것이 적절합니다.

### `khala reconcile` — 네트워크 없는 로컬 뇌 한 패스

`reconcile`은 다음만 수행합니다.

* `outbox/new` → 목적지 spool materialization
* `spool/for/self` 배달
* ACK 정산
* bounce·만료·dedup 위생
* transport-commit 정산

그리고 다음 규칙을 둡니다.

* `send`는 durable enqueue 후 **새 파일 하나의 로컬 spool materialization을 best-effort로 시도**합니다. 실패해도 send 성공 의미론은 유지합니다.
* link는 `outbox/new`를 **데이터 원천이 아니라 reconcile trigger**로 감시합니다.
* link 시작·재접속 시에도 먼저 로컬 `reconcile`을 요청합니다.
* 받은 파일마다 프로세스를 하나씩 만들지 않고 dirty bit로 호출을 합칩니다.
* 기존 `khala sync`는 대략 다음 구조가 됩니다.

```text
reconcile
→ 하나의 rsync exchange
→ reconcile
```

plain `khala sync`를 파일 도착마다 호출하는 것은 부적절합니다. 현재 `sync`는 로컬 의미론뿐 아니라 원격 rsync 교환까지 포함하므로, live link로 받은 파일 하나가 다시 별도 SSH·rsync 교환을 만들고 link와 경쟁하게 됩니다.

이 변경은 새 레이어가 아닙니다. 뇌의 기존 `sync_cycle`을 **local semantic pass와 transport pass로 분해**하는 것입니다.

---

# 3. 현재 bash 뇌는 동시 호출에 멱등하지 않다

r16은 “멱등 로컬 연산”을 전제로 link와 수동 sync의 중복을 무해하다고 봅니다. 그러나 현재 코드는 **순차 재실행에는 대체로 멱등**이지만, **동시 실행과 중간 crash에는 안전하지 않습니다**.

## 3.1 구체적인 반례

현재 배달은 다음 순서입니다.

```text
delivered_before(id)
→ inbox/new/id로 atomic_copy
→ log/delivered 갱신
→ ACK 생성
→ incoming spool 삭제
```



`atomic_copy`는 destination 존재 확인과 최종 `mv` 사이가 원자적인 create-if-absent가 아닙니다. 또한 `record_delivered`는 전체 로그를 temp로 복사한 뒤 한 줄을 추가하고 통째로 rename합니다. 두 sync가 동시에 실행되면 서로의 로그 갱신을 덮어쓸 수 있습니다.  

실제 중복 노출 반례는 다음과 같습니다.

1. sync S1과 S2가 모두 `delivered_before(id) == false`를 봄
2. S1이 `inbox/new/id`를 생성
3. 세션이 `inbox --drain`으로 이를 `cur`로 이동
4. S2가 이제 비어 있는 `new/id`를 다시 생성
5. 같은 편지가 다시 wake 대상이 됨

프로세스 crash에서도 동일합니다.

1. inbox copy 성공
2. delivered log 기록 전에 crash
3. 사용자가 그 사이 drain
4. 재시도 시 log에는 없고 `new`에도 없으므로 다시 배달

현재 watch는 각 세션별 프로세스가 반복해서 `sync_cycle`을 호출합니다. 동시 세션이 약 10개이고 향후 link도 sync를 찌르므로, 이 반례는 이론적인 경쟁이 아닙니다. 

## 3.2 최소 수정

뇌를 단일 writer로 만드십시오.

* `reconcile`의 모든 의미론적 mutation은 `$KHALA_ROOT/run/brain.lock`의 **커널 보유 advisory lock** 아래 수행
* `inbox --drain`도 같은 lock 아래에서 `new→cur`
* `prune_delivered_log`와 `record_delivered`도 같은 lock 아래 수행
* 원격 rsync 자체는 brain lock 밖에서 수행하여 20초 네트워크 timeout이 live delivery를 막지 않게 함
* rsync 교환은 별도 `exchange.lock`으로 노드당 하나만 허용
* link의 reconcile 요청은 dirty bit로 합쳐, 실행 중 새 요청이 오면 한 패스 더 수행

crash recovery 규칙도 하나 추가해야 합니다.

```text
delivered log에 id가 있거나
inbox/<session>/new/id가 있거나
inbox/<session>/cur/id가 있으면
    이미 배달된 것으로 간주
    필요하면 delivered log를 수리
    ACK만 재생성
```

따라서 r16의 “뇌 불변, D12만 수리”는 문자 그대로 유지할 수 없습니다. **의미론은 불변이어도 동시성 구현은 수정해야 합니다.**

---

# 4. `basename/Id → immutable bytes` 불변량이 현재 깨져 있다

자체 프로토콜이 무결성을 검증하려면 스풀 객체에 다음 불변량이 필요합니다.

> 같은 namespace와 같은 파일명/Id라면 바이트가 항상 같다.

현재 인프라 메시지는 그렇지 않습니다.

* ACK 등의 ID는 `type`, 원문 `ref`, `from`으로 결정적으로 생성됩니다.
* 그러나 같은 ID의 메시지를 재생성할 때 `Date`와 `Expires`는 현재 시각으로 다시 계산됩니다.
* 따라서 ACK 유실 후 원문 재전송으로 ACK가 재생성되면 **동일 파일명, 다른 바이트**가 정상적으로 생깁니다. 

이 상태에서는 다음 중 무엇을 해도 문제가 됩니다.

* 경로만 보고 `HAVE`를 답하면 실제 충돌·손상을 놓침
* digest가 다르면 corruption으로 처리하면 정상 ACK 재생성을 오류로 오인
* rename overwrite를 허용하면 전송 중 읽던 객체가 다른 내용으로 바뀔 수 있음

## 수정 조건

스풀 객체는 반드시 immutable하게 만드십시오.

* 결정적 ID를 유지한다면 `Date`, `Expires`도 ref로부터 결정적으로 유도
* 또는 재생성할 때마다 새 ID를 부여
* 최종 설치 시 같은 경로가 이미 있으면:

  * digest 동일: `HAVE`
  * digest 다름: overwrite 금지, quarantine + hard error

message ID 자체도 현재 초·PID·`$RANDOM`에 의존합니다. 이 함대의 평상시 메시지량에서는 충돌 가능성이 낮지만, 자동화된 burst가 생기면 no-clobber mismatch가 검출할 수 있도록 해야 합니다. ID 강화는 S2지만, **충돌 시 덮어쓰지 않는 것**은 S0입니다.

---

# 5. 파일 이벤트 신뢰성: 이벤트+scan은 필수다

첨부 자료에는 각 fsnotify backend의 정확한 event guarantee가 없으므로, inotify/FSEvents별 보장치를 근거처럼 단정할 수는 없습니다. 그러나 설계는 다음 모든 경우를 허용하는 fault model로 작성해야 합니다.

* 이벤트 누락
* 중복
* 순서 역전
* 디렉터리 단위 coalescing
* rename이 create/remove 형태로 보임
* watcher error 또는 queue overflow 통지
* watcher 재등록 전후의 빈 구간
* 절전·재접속 동안 발생한 변경

이 중 하나라도 허용하면 이벤트만으로 correctness를 만들 수 없습니다. 따라서 **하이브리드는 필수**입니다. 다만 이는 폴백 레이어가 아니라 **동일한 reconciler를 깨우는 두 종류의 trigger**입니다.

## 최소 reconciler

```text
1. 감시를 먼저 등록한다.
2. 즉시 전체 eligible view를 scan한다.
3. 모든 이벤트는 “이 경로가 dirty할 수 있다”는 힌트로만 처리한다.
4. 현재 파일시스템을 stat/scan하여 실제 상태를 다시 계산한다.
5. watcher error/overflow/reconnect 시 즉시 전체 scan한다.
6. 낮은 빈도의 주기 scan으로 error 통지 자체의 유실도 치유한다.
```

이 함대에서는 link 연결 상태의 정상 지연은 event가 담당하고, 예를 들어 30초 주기 scan이 correctness를 담당하면 충분합니다. 이 scan은 전체 `~/.khala`가 아니라 역할별 eligible view만 봅니다.

* spoke: `spool/for/X`, `X != self`; owner presence; outbox trigger
* hub의 B serve: `spool/for/B`; presence fan-out
* 새 destination 디렉터리가 생기면 watch 등록 후 즉시 해당 디렉터리 scan

## rename 처리

전송 temp는 final namespace 밖의 `tmp/`에 두고, 전송 완료 후 final 경로로 원자 설치합니다. 저장소 명세도 모든 쓰기가 같은 파일시스템의 `tmp/`를 거쳐 `mv`되어야 한다고 규정합니다. 

다만 watcher는 “rename event를 받았다”에 의미를 두면 안 됩니다.

* create, rename, parent dirty 중 무엇으로 오든
* final 경로가 현재 존재하는지
* regular file인지
* expected namespace와 이름인지

만 다시 확인하면 됩니다.

---

# 6. stdio 프레이밍 프로토콜

## 6.1 최소 프로토콜

첨부 자료 안에는 Syncthing protocol이나 rsync wire protocol 같은 외부 선례의 명세가 없으므로, 특정 외부 프로토콜을 근거로 권할 수는 없습니다. 이 자료에서 직접 상속할 수 있는 선례는 두 가지입니다.

1. temp에 완성 후 final rename
2. 원격 보유가 확인된 뒤에만 source lifecycle을 진행

현재 rsync 설계도 push는 source를 지우지 않고, pull은 성공한 파일만 `--remove-source-files`로 소비합니다. 

그 계약을 그대로 표현하는 최소 frame은 다음 정도입니다.

| Frame           | 의미                                                         |
| --------------- | ---------------------------------------------------------- |
| `HELLO`         | magic, protocol major/minor, node alias, role, 구현 버전       |
| `OFFER`         | transfer ID, object class, 목적 node, basename, size, digest |
| `HAVE`          | 동일 digest의 final 객체가 이미 있음                                 |
| `NEED`          | DATA 요청                                                    |
| `DATA`          | 선언된 정확한 길이의 바이트                                            |
| `STORED`        | digest 검증 및 final atomic install 완료                        |
| `PING` / `PONG` | half-open 탐지와 freshness 갱신                                 |
| `ERROR`         | recoverable/fatal 오류 코드                                    |

경로 문자열을 그대로 받지 말고 `object class + node + basename`에서 수신측이 경로를 구성해야 합니다. absolute path, `..`, symlink, 임의 디렉터리 접근을 프로토콜 차원에서 없애야 합니다.

## 6.2 구현상 필수 규칙

* `Read`와 `Write` 한 번이 요청 길이를 모두 처리한다고 가정하지 않음
* frame header는 fixed-size 또는 명확한 length-prefix
* payload는 정확히 선언 길이만 `ReadFull`
* 프로토콜 writer는 하나만 두어 frame interleave 방지
* reader는 항상 살아 있어야 하며, 상대 응답을 기다리느라 read를 멈추지 않음
* 각 방향의 in-flight object 수를 1 또는 작은 상수로 제한
* 메모리 큐에는 파일 바이트가 아니라 경로만 저장
* 큐가 차면 이벤트를 버리되 `dirty=true`로 축약; 주기 scan이 재발견
* final install 전 size와 digest 검증
* 같은 ID·다른 digest는 덮어쓰지 않음
* temp 파일은 연결/transfer generation을 이름에 포함하고 TTL 청소
* `STORED` 전에는 hub transit이나 source를 절대 지우지 않음

## 6.3 부분 전송과 재개

v0에서는 **byte-offset resume를 만들지 않는 것**이 맞습니다.

* 연결이 끊기면 incomplete temp를 폐기 또는 TTL 청소
* 재접속 후 scan
* 동일 객체를 처음부터 다시 전송
* receiver에 이미 완성본이 있으면 `HAVE`

현재 대상은 RFC822류 UTF-8 텍스트 메시지입니다. offset resume, chunk map, sparse assembly를 넣는 순간 신경이 별도 동기화 엔진으로 변합니다.

## 6.4 R10과 head-of-line blocking

B200에는 파일 하나의 I/O가 멈추는 형태의 장애 이력이 있고, R10은 그런 장애가 전체를 멈추지 않아야 한다고 요구합니다. 

한 파일을 읽기 시작한 뒤 DATA frame 중간에서 source read가 멈추면 그 방향의 protocol stream 전체가 막힙니다. 최소 대책은 다음입니다.

* DATA header를 보내기 전에 source 파일을 worker에서 끝까지 읽고 digest를 확정
* v0의 `max-object-bytes`를 명시
* 수신도 frame 전체를 bounded buffer에 받은 뒤 disk commit worker에 넘김
* 준비 중 멈춘 파일은 protocol writer를 점유하지 않음
* 한 peer의 disk commit이 막혀도 다른 spoke는 별도 serve이므로 영향받지 않음

유한한 object 크기 상한 없이 “단일 stdio stream”, “파일 I/O wedge가 다른 파일을 막지 않음”, “chunk multiplexing 없음”을 동시에 만족시키기는 어렵습니다. 셋 중 하나는 명시적으로 선택해야 합니다. 이 시스템의 메시지 용도라면 **유한 크기 상한 + whole-object retry**가 가장 단순합니다.

## 6.5 SSH 캐리어 규칙

* `ssh -T`: PTY 금지
* stdout: 프로토콜 전용
* stderr: 로그 전용
* `2>&1` 금지
* remote profile/MOTD가 stdout에 쓰면 HELLO magic mismatch로 즉시 실패
* detached 프로세스는 ssh stderr를 반드시 drain하여 bounded log로 보냄
* `BatchMode`, 연결 timeout, keepalive를 명시
* remote 실행 경로를 명시적으로 지정

마지막 항목은 실제 설치 문서와 r16 문면의 불일치입니다. 설치 문서는 `~/.local/bin`이 PATH에 없을 수 있어 모든 명령을 절대 경로로 표기하지만, r16은 `ssh <hub> khala link --serve`를 가정합니다.  따라서 설치 계약으로 non-interactive PATH를 보장하거나 다음처럼 고정해야 합니다.

```sh
ssh -T b200 'exec ~/.local/bin/khala link --serve'
```

## 6.6 만들지 말아야 할 것

v0 경계는 명확해야 합니다.

* chunk/offset resume
* delta transfer
* compression negotiation
* generic directory mirror
* distributed tombstone
* conflict-copy 파일
* persistent transfer database
* protocol-level RFC822 해석
* 여러 peer를 한 연결에 multiplex
* generic RPC/gRPC
* 전역 순서 합의

이 중 둘 이상이 필요해지면 자체 pump의 단순성 우위가 사라집니다. 그 시점에는 long-poll+rsync 재평가가 맞습니다.

---

# 7. 뇌/신경과 수동 rsync의 경쟁

## 판정

“수신 dedup이 있으므로 무조건 무해하다”는 판단은 **현재 코드에는 틀립니다**.

다음 조건이 모두 성립한 뒤에만 “추가 작업만 생기고 의미론은 무해하다”고 말할 수 있습니다.

1. ID별 바이트 immutable
2. final no-clobber + digest mismatch quarantine
3. 뇌 semantic mutation 단일 writer
4. `spool/for/self` upstream 반사 금지
5. source 삭제는 remote `STORED` 이후
6. message와 infra의 source lifecycle은 뇌가 결정
7. duplicate cleanup의 `ENOENT`는 성공
8. event 누락은 scan이 치유

## 현재 코드의 추가 반례: self-spool echo

현재 `exchange_with_endpoint`는 시작 시 로컬 `spool/for/$self`를 허브에 push한 뒤 다시 pull합니다.  하지만 DESIGN의 정식 규칙은 push 범위가 `X != self`이고, 먼저 self ACK를 pull·정산한 뒤 다른 목적지 spool만 push하는 것입니다. 

이 차이는 기존 느린 rsync에서는 중복 전송 정도로 가려질 수 있지만, live link가 같은 트리를 감시하면 다음 echo를 만듭니다.

```text
hub → spoke self-spool
→ spoke의 기존 sync가 self-spool을 다시 hub로 push
→ hub event
→ spoke로 다시 fan-out
```

dedup이 사용자 중복은 막더라도 파일 이벤트와 ACK 재생성을 증폭합니다. **r16 구현 전에 이 spec/code 불일치를 제거해야 합니다.**

---

# 8. presence와 `watching`

D12의 heartbeat/watching 분리는 옳습니다. presence가 라우팅에 관여하지 않으므로 stale 정보가 배달 실패로 번지지 않는 것도 좋은 결정입니다. 

다만 `watching/<session>@<node>` 단일 파일을 arm 시 생성하고 trap에서 삭제하면 다음 경쟁이 있습니다.

```text
W1 arm → marker 생성
W2 재-arm → 같은 marker를 새 watch가 소유
W1 종료 trap → marker 삭제
W2는 살아 있지만 watching=false
```

또한 SessionStart, wake 직후 재arm, Stop 훅이 가까이 실행되면 같은 세션에 watch가 두 개 생겨 중복 task-notification을 낼 수 있습니다.

## 권고

watching을 tokenized lease로 만드십시오.

```text
presence/watching/<session>@<node>/<random-instance-token>
```

* 각 watch는 자기 token만 삭제
* presence는 유효 TTL의 token이 하나라도 있으면 watching
* per-session watch 자체는 kernel lock으로 singleton
* kill -9 잔해는 TTL 소독

heartbeat도 가능하면 같은 append-only lease 형태로 만들면 stale connection이 오래된 epoch를 덮어쓰는 문제가 사라집니다. 이는 D12 구현 범위에서 처리할 수 있고, spool과 presence를 모두 **immutable lease/object 전파**라는 한 규칙으로 묶습니다.

---

# 9. 대안 비교

## 9.1 Syncthing / Unison / Mutagen류

첨부에는 이 제품들의 daemon 모델, SSH agent 모드, state DB, delete/conflict 정책에 관한 자료가 없습니다. 따라서 특정 제품이 제약을 충족한다고 제품별로 단정할 근거는 없습니다.

구조적으로는 다음 조건을 모두 만족하는 엔진만 후보입니다.

* 기존 SSH의 stdio child로만 실행
* 새 listener와 새 인증 없음
* 허브 상주 데몬 없음
* symmetric mirror가 아니라 역할별 one-way projection
* spool의 generic delete propagation 금지
* remote durable commit을 뇌에 노출
* canonical state나 conflict DB를 엔진이 소유하지 않음
* link가 없어도 bash·rsync 경로 그대로 동작

일반적인 “양쪽 디렉터리를 같게 만든다”는 사용 방식은 Khala에 맞지 않습니다. Khala의 같은 경로는 발신·허브·수신에서 수명 규칙이 다르기 때문입니다. 위 조건을 맞추기 위해 wrapper와 lifecycle callback을 붙이면 결국 그 엔진은 범용 sync가 아니라 **Khala용 pump**로 사용되는 셈입니다.

얻는 것은 성숙한 scan·retry·검증·backpressure 구현이고, 잃는 것은 상태 소유권의 투명성, 삭제 의미론의 통제, grep 가능한 운영 모델입니다. 첨부 근거만으로는 채택 근거가 부족합니다.

## 9.2 long-poll + rsync

long-poll+rsync가 더 나은 지점은 분명합니다.

* 기존 실증된 `sync` 의미론을 그대로 호출
* 별도 framing protocol 없음
* 파일 이벤트 유실이 correctness에 영향 없음
* source 삭제 규칙이 이미 bash 뇌에 있음
* 구현·검증 표면이 훨씬 작음
* 장애 분석이 기존 SSH/rsync 로그로 끝남

이 함대 규모에서 resource cost도 치명적이지 않았습니다. 기존 실측상 watcher 10개의 sshd RSS는 약 160MB였고 polling CPU는 미미했습니다. 

반면 지연은 불리합니다. r15는 DERP 경유 rsync push/pull과 wake를 합쳐 약 10초를 예상했고, 실기기 문서도 한 번의 sync가 수 초 걸리는 것을 정상으로 기록합니다.   또한 session별 long-poll 구조라면 노드당 한 연결이라는 r16의 운영 단순성도 잃습니다.

따라서 판정은 다음과 같습니다.

* 목표가 **5–10초**라면 long-poll+rsync가 구현 위험 대비 더 나은 선택일 가능성이 큼
* 등록된 목표가 **A→B ≤2초, 허브 중계 ≤3초**라면 Go pump가 정당화됨
* long-poll을 별도 runtime fallback으로 다시 추가할 필요는 없음
* 기존 수동 `khala sync`는 저하 모드이자 differential oracle로 유지

---

# 10. singleton link 수명 관리

## 10.1 락파일은 존재 검사가 아니라 커널 락이어야 한다

다음 구조를 권합니다.

```text
run/link.lock       # kernel-held advisory lock 대상
run/link.status     # grep 가능한 진단 정보
run/link.ready      # protocol-ready freshness
log/link.log
```

`link.status` 예:

```text
pid 12345
started 1786530000
instance 8c4...
binary 0.2.0
protocol 1
peer b200
state ready
last-ok 1786530042
```

* 프로세스 생존 동안 열린 fd가 advisory lock을 보유
* 프로세스가 죽으면 커널이 lock을 자동 해제
* 파일 잔해 자체는 ownership을 의미하지 않음
* PID는 진단용이지 락의 진실이 아님
* singleton 범위는 node alias가 아니라 `$KHALA_ROOT`별

## 10.2 `ready`는 “프로세스가 있음”이 아니다

watch가 remote pump를 생략하는 기준은 다음을 모두 충족해야 합니다.

* SSH 연결 성공
* HELLO/version negotiation 성공
* 초기 reconcile/scan 시작 또는 완료
* 최근 PONG 또는 실제 protocol progress 존재

r16은 fresh marker가 있으면 watch가 원격 sync를 생략한다고 규정합니다.  따라서 단순 heartbeat loop가 marker를 touch하면 안 됩니다. half-open SSH나 잠든 mac에서도 프로세스는 살아 있을 수 있기 때문입니다.

* graceful exit: ready 제거
* crash: TTL로 stale
* stale 동안 watch는 기존 interval sync를 다시 수행
* 이 지연 전환은 같은 설계의 저하 모드이지 별도 계층이 아님

## 10.3 좀비와 자식 프로세스

* Go link는 시작한 `ssh` child를 반드시 `Wait`
* 종료 시 ssh process group도 정리
* detach 시 stdin은 `/dev/null`, stdout/stderr는 bounded log
* 실제 zombie는 이미 종료했으므로 lock을 보유하지 않음
* 더 위험한 것은 **살아 있지만 진전 없는 hung link**이며, 이는 ready freshness로 판정

## 10.4 업그레이드

1. 새 바이너리를 임시 경로에 설치
2. checksum/실행 확인
3. 최종 경로로 atomic rename
4. `khala link restart`
5. 기존 프로세스는 기존 inode를 계속 실행하다 TERM 후 종료
6. 새 프로세스가 lock 획득 후 새 바이너리 실행

HELLO에 protocol major/minor와 구현 버전을 반드시 넣어야 합니다.

* 같은 major: 호환 동작
* 다른 major: 명시적 종료, silent downgrade 금지
* 재시작 overlap으로 hub에 old/new serve가 동시에 있어도 동일 객체 offer는 무해해야 함

업그레이드 correctness가 singleton 완전성에 의존해서는 안 됩니다. singleton은 비용과 운영 노이즈를 줄이는 장치이고, 객체 프로토콜은 duplicate connection 자체를 견뎌야 합니다.

---

# 11. 구현 전에 추가할 수용 속성

현재 r16의 9개 속성에 다음을 추가해야 합니다.

| 추가 테스트                             | 검증 대상                                |
| ---------------------------------- | ------------------------------------ |
| outbox에 안착한 직후 link kill·restart   | spool 미생성 상태도 자동 수렴                  |
| 한 이벤트를 의도적으로 drop                  | 주기 scan으로 수렴                         |
| B 담당 serve 두 개 동시 연결               | 중복 배달·조기 삭제 없음                       |
| link와 rsync가 같은 hub 파일을 동시에 전달     | receiver·hub 상태 정상                   |
| inbox copy 직후 brain kill           | 재시작 후 재배달 없이 ACK 생성                  |
| `sync` 두 개 + `inbox --drain` 동시 실행 | delivered log 유실·new 재출현 없음          |
| 같은 path·같은 digest                  | `HAVE`, 전송 생략                        |
| 같은 path·다른 digest                  | overwrite 없이 hard failure/quarantine |
| ACK 제거 후 같은 원문 재수신                 | 재생성된 ACK가 ID immutable 규칙 충족         |
| `spool/for/self` 파일 생성             | upstream echo 0                      |
| old/new protocol major 연결          | 명시적 incompatibility                  |
| 링크 process alive, PONG 없음          | marker stale 후 watch가 rsync 재개       |
| W1 종료와 W2 재arm 경쟁                  | W2의 watching lease 유지                |

---

# GO / NO-GO

**GO — 조건부.** “bash 뇌 + 의미론 없는 Go 신경 + SSH stdio + 허브 파일시스템 bus”라는 중심 아키텍처로 구현을 시작해도 됩니다. 단, lane B 코딩 전에 **① 경로별 소유권·방향·삭제 수명표와 generic delete 금지, ② `reconcile` 분리 및 뇌 single-writer/crash-recovery 계약, ③ 스풀 ID별 immutable bytes와 transport `STORED` 계약, ④ event-as-hint + 초기·오류·주기 scan**을 r16.1의 normative contract로 먼저 고정해야 합니다. 이 네 조건 없이 현재 문면을 직접 구현하는 것은 **NO-GO**입니다. 가장 큰 위험은 fsnotify가 아니라, 역할이 다른 스풀 사본들을 일반적인 “한 트리의 미러”로 오해하는 것입니다.

