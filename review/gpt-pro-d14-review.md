# GPT Pro 자문 — D14 r0 (2026-08-13, chatgpt 브리지 경유 원문)

> 처리: ink가 S0-0을 코드 대질로 검증(실재 — 아웃바운드 스캔의 reconcile 게이트 부재 + offer/설치의 과거-나이 가드 부재). 종합은 d14 r1에서.

# 결론

판정은 **방향에 대해서는 조건부 GO, 현재 r0의 레인 발사에는 NO-GO**다.

| 항목 | 판정 |
| --- | --- |
| `minds + preserver`라는 페어 | 다음 단계로 적절함 |
| `minds = presence와 같은 단일 가변 파일` | **기각**. presence 예외를 확장하면 안 됨 |
| 권고 기질 | **단일 작성자·불변 세대형 register** |
| `preserver = archive를 eligible view 밖에 둔다` | 핵심 방향은 옳음 |
| `만료 시 live→archive move` | 계약 부족. **관측 시 archive 정착 → 기존 prune 유지**가 더 낫다 |
| 원격 recall | 1일차 불필요 |
| S0 | 아래 7개. 그중 하나는 D13에서 이미 상속된 계약 공백 |

가장 큰 문제는 r17의 오류 패턴이 축소된 형태로 두 번 재등장한다는 점이다.

1. `mind`의 owner 사본과 투영 사본을 **순서 없는 동등한 가변 복제본**처럼 취급한다.
2. live stream 객체와 archive 객체 사이의 소유권 이전을 **단순한 `mv`**로 취급한다.

둘 다 논리 객체의 역할과 물리 경로의 수명을 구분하는 계약이 필요하다.

그리고 제공된 문면만 기준으로 보면, D14보다 선행하는 **D13 retention 부활 논증의 공백**도 하나 있다. D13은 `reconcile(prune) → exchange(push)` 순서를 근거로 삼지만, Go link는 독립적으로 초기·주기 full scan을 수행한다. 이 둘의 순서가 규범적으로 연결되어 있지 않다. 코드가 이미 닫고 있을 가능성은 있지만, 문서상으로는 S0다.

---

# 1. 자문 질문 1 — 이 페어가 옳은 다음 걸음인가

## 방향은 맞다

현재 남아 있는 두 축을 다음과 같이 분리한 것은 좋다.

- `minds`: 휘발성이고 최신 상태만 의미 있는 ambient state
- `preserver`: 불변 stream 사실의 장기 보존

둘을 하나의 stream 기능으로 합치지 않은 것도 맞다. 현재 상태와 역사 기록은 읽기, 수명, 삭제, wake 의미론이 다르다.

다만 D14의 문면은 두 기관이 달성하는 바를 다소 과장한다.

### `minds`는 “형성되는 생각”이 아니다

한 줄 상태를 명시적으로 작성하는 것은 여전히 **작성된 선언**이다. mail이나 stream보다 마찰이 낮고 주변 상태로 보인다는 차이는 있지만, 생각이 형성되는 과정의 자동 공유는 아니다.

이것은 결함이라기보다 R13과 절연 원칙을 지키는 올바른 절충이다. 문면을 다음 정도로 낮추는 것이 정직하다.

> mind는 명의가 마지막으로 선언한 작업·상태의 만료 가능한 공유 register다. 세션의 대화나 내부 추론을 자동 포획하지 않는다.

SessionStart/Stop/wake hook은 대화 내용을 알 수 없다. 따라서 hook이 “현재 작업 한 줄”을 생성하거나 바꾸는 설계가 되어서는 안 된다.

### `preserver`는 아직 “집단 기억”이 아니라 raw archive다

로컬 평문 archive는 기억의 **기질**로는 맞다. 하지만 다음은 아직 없다.

- 모든 발화를 빠짐없이 보존한다는 completeness
- 단일 디스크 손실을 견디는 redundancy
- 기억의 선택·요약·맥락화
- 함대 어디서든 접근 가능한 recall

따라서 현재 설계는 정확히 말하면 **observed stream archive**다. 이 사실을 인정하면 D14의 범위로 충분하다. 더 강한 preserver를 만들기 위해 stream 발행자 수명을 archive ack에 묶는 것은 현재 설계의 단순함을 크게 훼손한다.

향후 더 본질적인 기관은 raw history 전체를 영구 저장하는 것보다, stream 항목을 참조하여 명시적으로 선택·요약하는 `remember` 계열일 가능성이 높다. 다만 그것은 D14의 선행 조건은 아니다.

## 절연 원칙은 두 방향으로 정밀화해야 한다

D14의 헌장 후보와 preserver는 다음 문장을 함께 가져야 한다.

> 절연은 미래의 연결과 자동 공유를 중단시킨다. 이미 stream에 공유된 사실의 소급 삭제를 보장하지 않는다.

그리고 mind에는 실제 철회가 있어야 한다.

> 명의는 mind 선언을 철회할 수 있고, 철회된 선언은 지연된 구세대 복제본에 의해 되살아나지 않는다.

현재 단일 가변 파일 설계로는 두 번째 문장을 보장할 수 없다.

---

# 2. 자문 질문 2 — minds의 기질과 실패 모드

## 논리적으로는 lease가 맞지만, 물리적으로 presence 파일을 복제하면 안 된다

전용 stream을 기각한 논거는 맞다.

- cursor 대상이 아니다.
- drain 예산을 소비하면 안 된다.
- wake를 발생시키면 안 된다.
- 모든 갱신 이력을 보존할 필요가 없다.

그러나 대안이 곧바로 presence와 동일한 단일 가변 파일이어서는 안 된다.

| 구분 | presence | mind |
| --- | --- | --- |
| 값의 성격 | epoch 중심의 관측 신호 | 작업·상태라는 의미 있는 선언 |
| 과거 값으로의 회귀 | 잠깐이면 대체로 무해 | 잘못된 작업·감정·철회 상태 노출 |
| 자가 수리 | 다음 heartbeat 가능성이 높음 | 마지막 갱신이 Stop/retire 직전일 수 있음 |
| 사용처 | 표시 전용, 라우팅 무의존 | 사람이 직접 해석하는 상태 |
| clear 필요성 | 사실상 retire로 충분 | 명시적 철회가 필요 |
| 다중 갱신 주체 | 단순 활동 신호 | 수동 명령·hook·wake가 서로 다른 필드를 갱신 |

r17 C3(A)의 presence 예외는 좁은 예외다. 그것을 mind에 그대로 확장하면 안 된다.

## 실제 실패 시나리오

단일 `minds/<identity>` 파일을 여러 경로가 원자 교체한다고 가정하자.

1. owner가 V1을 쓴다.
2. link가 V1을 읽어 전송 큐에 넣는다.
3. owner가 V2 또는 `clear`를 쓴다.
4. rsync가 V2를 hub에 먼저 설치한다.
5. 지연된 link DATA V1이 나중에 hub를 덮어쓴다.
6. owner가 Stop되거나 오프라인이 되어 추가 갱신이 없다.

presence라면 다음 heartbeat가 고칠 수 있다. mind에서는 철회된 V1이 장시간 남을 수 있다. body의 `epoch`은 운송 계층이 그것을 비교하지 않으면 아무 보호도 하지 못한다.

또 다른 실패는 세션 인스턴스 ABA다.

1. 동일 명의로 Session A가 시작한다.
2. 동일 명의로 Session B가 재시작하거나 겹쳐 시작한다.
3. B가 새 mind를 설정한다.
4. A의 늦은 Stop hook이 `waiting` 또는 빈 상태를 쓴다.
5. B의 현재 상태가 A의 종료 이벤트에 의해 사라진다.

presence에서는 “그 명의에서 어떤 프로세스가 활동했다” 정도로 볼 수 있지만, mind에서는 명백한 거짓 상태다.

## 권고: 단일 작성자·불변 세대형 register

`mind`는 stream도 presence도 아닌 **single-writer versioned register**로 두는 것이 가장 단순하다.

예시 물리 구조:

```
minds/<node>/<session>/<generation>
```

각 generation은 불변 객체다.

- `<node>`의 뇌만 자기 shard에 새 generation을 쓴다.
- link와 rsync는 C3 no-clobber를 그대로 사용한다.
- 투영 노드는 generation을 설치할 뿐 반사하지 않는다.
- 논리 mind 값은 유효한 generation 중 최대값이다.
- 동일 generation의 다른 바이트는 quarantine이다.
- `clear`도 삭제가 아니라 더 높은 generation의 값이다.
- archive 대상이 아니다.

generation은 단순 wall clock만 쓰기보다 brain lock 아래의 persistent HLC 또는 `(max(now,last_epoch), logical_counter)`가 적합하다. 시계가 뒤로 가도 새 선언이 과거 generation보다 작아지면 안 된다.

이 구조는 Go 신경에 의미론을 추가하지 않는다. 신경은 여전히 불변 파일만 나른다. “최대 generation을 현재값으로 본다”는 해석은 bash 뇌와 조회 명령의 몫이다.

## 갱신 주체별 필드 소유권도 필요하다

현재 스케치는 수동 명령, SessionStart/Stop, wake가 같은 파일을 갱신한다고만 되어 있다. 이것으로는 자동 hook이 수동 상태를 지우는 문제가 생긴다.

최소 필드 소유권은 다음과 같아야 한다.

| 필드 | 갱신 주체 |
| --- | --- |
| 작업 한 줄 `focus` | 명시적 `khala mind`, `--mind`만 |
| 주관 상태 `stance` (`focused`, `stuck`, `celebrating` 등) | 명시적 갱신만 |
| 기계적 phase가 필요하다면 (`active`, `waiting`, `stopped`) | 현재 session-incarnation token을 가진 hook만 |
| register generation | brain lock 아래 뇌 |
| `clear` / `withdrawn` | 명시적 철회 및 `retire` |

가장 단순한 v0는 **hook이 mind 본문을 전혀 갱신하지 않는 것**이다. 기존 presence/watching이 활동 상태를 이미 제공하므로 `khala minds`가 presence와 mind를 한 표에서 조인하면 된다.

hook 기반 phase가 꼭 필요하다면 다음이 추가로 필요하다.

- SessionStart가 현재 자동 작성자 token을 발급한다.
- Stop/wake hook은 자기 token이 현재 token과 일치할 때만 쓴다.
- hook은 `focus`와 `stance`를 바꾸지 않는다.
- hook이 새 generation을 만들 때도 수동 필드의 원래 갱신 시각을 보존한다. 그렇지 않으면 오래된 작업 한 줄이 hook 갱신 때문에 새 정보처럼 보인다.

## `retain`은 lease 유효기간이 아니다

30일 retain은 저장 공간 GC다. “현재 상태”의 유효성은 별도다.

최소 세 상태가 필요하다.

- `fresh`: 선언의 의미상 유효기간 안
- `stale`: 마지막으로 알려진 상태지만 현재라고 주장하지 않음
- `absent/withdrawn`: 선언 없음 또는 철회됨

`khala minds`는 반드시 mind의 나이를 보여야 하며, stale을 단순 `focused`로 출력하면 안 된다.

정확한 freshness 상수는 구현 브리프에서 정할 수 있지만, **freshness와 storage retention이 서로 다른 계약이라는 사실 자체는 S0**다.

## 절연 동작

권고 동작은 다음과 같다.

- mind가 한 번도 설정되지 않은 명의에 대해 hook은 자동 생성하지 않는다.
- `khala mind --clear`는 `State: cleared` generation을 쓴다.
- 현재값이 `cleared`인 동안 hook은 재생성하지 않는다.
- 다음 명시적 `khala mind ...`가 opt-in 재개다.
- `retire`는 presence의 retired 갱신과 함께 mind clear generation을 만든다.
- 지연된 구 generation이 나중에 도착해도 max-register에서 선택되지 않는다.

이것이 “절연은 언제나 성사된다”를 mind 데이터 평면에서 실제로 보장하는 방법이다.

---

# 3. 자문 질문 3 — preserver의 부활 논증, 조직, recall

## archive가 복제 원천이 아니라는 핵심 논증은 맞다

다음 조건이 모두 참이면 archive 자체가 live 객체를 부활시킬 수 없다.

1. `archive/`가 link와 rsync의 송·수신 eligible view에서 모두 제외된다.
2. archive 조회가 live tree에 파일을 materialize하지 않는다.
3. archive의 객체는 원본 stream 바이트 그대로 불변이다.
4. archive에서 live로 자동 복구하는 정책이 없다.
5. broad repair나 “전체 root sync”가 archive를 포함하지 않는다.

따라서 “archive는 부활의 원천이 아니다”라는 주장은 옳다.

다만 “한번 archive되면 live에 다시 나타날 수 없다”는 더 강한 주장은 옳지 않다. 이미 큐에 들어간 전송, 아직 prune하지 않은 offline 노드, hub serve의 fan-out 큐가 같은 ID를 live tree에 다시 설치할 수 있다. 정확한 주장은 다음이어야 한다.

> archive는 live 부활의 원천이 아니다. 오래된 live 사본이나 in-flight 전송으로 인한 일시적 재설치는 허용되며, 다음 reconcile에서 다시 소멸하여 수렴한다.

그리고 watch/drain은 age-expired 객체를 무시해야 한다. 그렇지 않으면 몇 초 뒤 다시 prune되더라도 이미 세션을 깨우거나 과거 항목을 전달할 수 있다.

## D13에서 상속된 no-resurrection 공백

D13 §5의 증명은 sync 경로에는 적용되지만 live link 경로에는 문면상 충분하지 않다.

가능한 시나리오:

1. A가 stream 객체를 가진 채 30일 이상 오프라인이다.
2. hub와 다른 노드는 이미 그 객체를 prune했다.
3. A가 깨어나 `khala link`를 먼저 시작한다.
4. link의 초기 full scan이 A의 자기 shard에 남은 객체를 offer한다.
5. 이후에야 A의 brain reconcile이 실행된다.

또는 A가 온라인이지만 오랫동안 brain reconcile을 수행하지 않는 경우, link의 주기 scan이 hub가 지운 객체를 반복해서 offer할 수 있다.

r17 C4의 “이벤트는 힌트, 진실은 스캔”과 D13 retention을 함께 적용하려면 다음 계약이 필요하다.

> stream, presence, mind처럼 나이로 eligible 여부가 바뀌는 class의 초기·주기 full scan은 성공한 로컬 reconcile 뒤에만 실행한다. reconcile이 실패하면 그 class는 offer하지 않는다.

추가로:

- `watch`와 `inbox --drain`은 파일의 물리적 존재만 보지 말고 retention 유효성도 검사한다.
- offline > retain 후 link-first 기동을 수용 속성으로 등록한다.
- 이미 in-flight였던 객체에 대해서는 즉시 0이 아니라 bounded eventual convergence를 주장한다.

코드가 이미 SessionStart 또는 link startup에서 이 순서를 보장한다면 문서에 올리면 된다. 제공 문면만으로는 보장되지 않는다.

## `만료 시 move`보다 `관측 시 archive 정착 → 기존 prune`이 낫다

현재 스케치:

```
expired?
  yes -> archive로 move
  no  -> 유지
```

권고 구조:

```
preserved stream의 모든 live 객체:
  archive에 이미 정착했는지 보장

그 뒤:
  모든 노드와 동일한 기존 retention prune 실행
```

즉 preserver는 prune의 특례가 아니라, **자기 live projection에 도달한 불변 객체에 로컬 소유 경로를 하나 더 부여하는 역할**이 된다.

장점은 명확하다.

- 30일 경계에서 처음 archive 쓰기를 시도하지 않는다.
- archive 실패를 수일간 재시도할 수 있다.
- retention 코드는 preserver/non-preserver에서 동일하다.
- archive 전환과 prune의 소유권이 분리된다.
- archive가 성공했다면 live prune은 단순 unlink다.
- hub가 natural candidate인 이유도 유지된다.

v0에서 archive root를 live tree와 같은 filesystem으로 제한하면 hardlink가 가장 단순하다.

1. live 파일 검증
2. archive 목적지에 `ln(2)` no-clobber
3. 목적지가 이미 있으면 digest 비교
4. archive dir durability commit
5. retention 시 live 경로 unlink

stream 객체는 불변이므로 hardlink는 의미론적으로 안전하다. 프로세스 crash 시 가능한 상태는 `live만`, `live+archive`, `archive만`이고 `둘 다 없음`이 아니다.

다른 filesystem을 첫날부터 지원하려면 C1의 STORED와 같은 수준의 계약이 필요하다.

- archive filesystem의 tmp에 전량 복사
- file fsync
- no-clobber rename
- directory fsync
- 그 뒤 live unlink
- 실패 중간 상태는 `archive/.pending`으로 보존

이 복잡성을 피하려면 v0는 same-filesystem으로 제한하는 편이 낫다.

## archive 실패는 fail-closed여야 한다

다음 동작은 금지해야 한다.

- archive write 실패 후 live 파일을 조용히 prune
- archive digest conflict에서 한쪽을 임의 선택
- 디스크 부족 시 오래된 archive를 자동 삭제
- archive 실패로 expired live 객체를 계속 정상 offer하면서 건강 상태를 유지

최소 정책:

- 같은 ID·같은 digest: 이미 archive됨
- 같은 ID·다른 digest: quarantine + 큰 오류
- archive commit 실패: `preserver degraded`
- 만료 시 아직 archive commit되지 않은 객체: 복제 밖의 `archive/.pending`으로 이동하거나 삭제를 중단하고 큰 오류
- 자동 eviction 없음

`archive/.pending`을 둔다면 그것도 C1 표의 정식 경로가 되어야 한다.

## archive 조직

권고 경로:

```
archive/streams/<stream>/<publisher-node>/<YYYY>/<MM>/<id>
```

- `YYYY/MM`은 `Date:`가 아니라 immutable ID의 epoch에서 UTC로 결정한다.
- 원본 파일 바이트를 그대로 둔다.
- 한 디렉터리에 수년치 파일을 평평하게 두지 않는다.
- generated index가 생기더라도 source of truth는 원본 파일이다.
- `stream cat -n N`은 최근 월부터 역순으로 읽어 충분한 수를 모으면 멈출 수 있다.
- 전체 grep은 기존 도구로 재귀 검색할 수 있다.

연 단위 규모에서 바로 packfile, SQLite, vector DB를 넣을 이유는 없다. 파일 수와 inode 비용이 실제로 문제가 된 뒤, 원본 archive에서 재생성 가능한 인덱스나 pack을 추가하면 된다.

## 원격 recall은 1일차에 넣지 않는 편이 맞다

원격 recall을 link class나 복제 프로토콜에 넣으면 다음 경계를 다시 열게 된다.

- archive가 network-visible namespace가 됨
- query 권한과 자원 제한
- 결과 캐시와 live materialization
- 긴 stdout와 backpressure
- archive node 발견
- 다중 preserver 중 선택

1일차에는 로컬 `stream cat`과 기존 SSH로 충분하다.

향후 추가한다면 다음 형태가 적합하다.

> 기존 SSH carrier를 이용한 one-shot read-only query. 결과를 stdout으로만 반환하고 live tree나 cursor에 쓰지 않는다.

즉 recall은 **조회 경로**여야지 복제 경로가 되어서는 안 된다.

---

# 4. 자문 질문 4 — S0급 계약 공백

## S0 목록

| ID | 공백 | 실제 실패 | r1에서 필요한 계약 |
| --- | --- | --- | --- |
| **S0-0** | 나이 기반 객체와 live link full scan의 순서 | offline/idle owner가 만료 객체를 재offer하여 retention flap 또는 과거 wake | age-governed class의 initial/periodic scan 전 성공한 reconcile. watch/drain도 만료 객체 무시 |
| **S0-1** | mind를 단일 가변 파일로 두고 C3(A) 예외 확장 | 지연 V1이 V2/clear를 덮음. 철회·retire 상태 부활 | immutable generation 기반 single-writer register 또는 모든 경로의 monotonic CAS. 전자를 권고 |
| **S0-2** | mind 갱신 주체별 소유 필드와 writer incarnation 부재 | 오래된 Stop hook이 새 세션 상태를 덮음. hook이 수동 `stuck` 상태 삭제 | field ownership 표, current-token hook만 자동 갱신, clear/retire generation |
| **S0-3** | mind freshness와 retain 혼동 | 29일 전 `focused`가 현재 상태처럼 표시 | semantic freshness와 storage GC 분리. age/stale 표시. routing/wake 무의존 |
| **S0-4** | live→archive 소유권 이전 transaction 부재 | crash, EXDEV, ENOSPC, destination conflict에서 유실·덮어쓰기·복제 flap | capture-before-prune, no-clobber, digest conflict, durability commit, pending/fail-closed |
| **S0-5** | preserver의 completeness·durability 보장 범위 부재 | preserver가 늦게 켜지거나 30일 이상 offline이면 항목 누락. 단일 디스크 사망 시 전 기억 소실 | “자기 projection에서 관측·정착한 객체만 로컬 보존”이라는 약한 보장 명문화 또는 별도 강한 프로토콜 |
| **S0-6** | archive의 eligible view·조회·삭제 소유권과 erasure 의미 부재 | broad sync가 archive를 재복제, disable이 archive 삭제, 사용자는 30일 후 소거로 오해 | archive C1 표, local-only, explicit purge only, `retain = live horizon` 문면, mail/mind/presence 제외 |

S0-5는 코드보다 **주장 수준을 고치는 계약**이다. 현재 단순성을 유지하려면 강한 guarantee를 만들기보다 약한 guarantee를 정확히 적는 편이 옳다.

강한 preserver를 주장하려면 다음 중 하나가 필요하다.

- 발행자가 preserver STORED까지 객체를 유지
- archive 자체를 여러 preserver에 복제
- publisher shard에 연속 sequence를 부여하고 gap audit

이들은 모두 현재 stream의 “ack 없음, 나이로 독립 삭제” 의미론을 바꾼다. D14 범위에는 과하다.

---

# 5. 권고 경로별 소유권·수명표

## minds

아래는 단일 가변 파일 대신 generation register를 쓸 경우의 표다.

| 경로 | 생성·변이 소유자 | 링크·교환 | 읽기 의미론 | 삭제·수명 |
| --- | --- | --- | --- | --- |
| `minds/<self-node>/<session>/<generation>` | 해당 노드의 뇌만, brain lock 아래 | owner→hub→전 스포크 offer. immutable no-clobber | 유효 generation 중 최대값 | 더 높은 generation을 본 노드는 낮은 generation을 로컬 제거 가능. 최대 generation은 retain 후 제거 |
| `minds/<X>/<session>/<generation>`, `X≠self` | 전송 계층만 설치 | 상류 반사 금지 | 동일 | 로컬 뇌의 동일 GC 규칙 |
| local hook writer token | SessionStart가 발급, 현재 token만 갱신 | 링크 범위 밖 | 자동 hook 권한 판정 | 새 Start가 교체. stale token의 Stop/wake는 no-op |
| mind `cleared` generation | 명시적 clear 또는 retire | 일반 mind generation과 동일 | 현재값이 clear면 기본 조회에서 숨김 | 다른 최대 generation과 동일 retain |
| `archive/**`에서의 mind | 생성 금지 | 해당 없음 | 해당 없음 | mind는 preserver 대상이 아님 |

추가 규칙:

- 파일 없음 = 선언한 적 없음
- 현재 max가 `cleared` = 명시적 철회
- max가 freshness를 넘음 = stale
- `minds`는 presence와 조인하여 보여줄 수 있지만 mind를 presence로부터 추론하지 않는다.
- mind 객체는 watch를 깨우지 않고 cursor나 drain 대상이 아니다.

## preserver

| 경로 | 생성·변이 소유자 | 링크·교환 | 조회 | 삭제·수명 |
| --- | --- | --- | --- | --- |
| `streams/<s>/<self>/*` | 기존과 동일: publisher brain | 기존 stream eligible view | drain, watch, cat | 기존 retention. preserver면 prune 전에 archive commit 확인 |
| `streams/<s>/<X>/*` | 기존과 동일: 전송 계층 설치 | 상류 반사 금지 | 동일 | 기존 retention. preserver면 archive commit 후 prune |
| `archive/streams/<s>/<X>/<YYYY>/<MM>/<id>` | 로컬 preserver brain만 | **송신·수신 모두 금지** | 로컬 `stream cat`/grep만. cursor 변화 없음 | 자동 retention 없음. explicit local purge만 |
| `archive/.pending/**` | 로컬 preserver brain | 복제 범위 밖 | 기본 cat에서는 제외, doctor/status에서만 | archive commit까지 재시도. 자동 삭제 금지 |
| `archive/.tmp/**` | cross-filesystem copy를 지원할 때만 preserver brain | 복제 범위 밖 | 조회 금지 | crash recovery 규칙에 따라 pending/quarantine |
| mail, minds, presence, join, cursor | archive writer 없음 | 기존 계약 | 기존 | preserver 대상 아님 |

`stream cat`이 live와 archive를 합칠 때는 `(stream, publisher, id)`를 객체 키로 삼아야 한다.

- 양쪽 digest 동일: 한 번만 출력
- digest 상이: 큰 오류. 임의 선택 금지
- 정렬: 기존 `(epoch,id)`
- archive 조회가 cursor를 전진시키면 안 됨

---

# 6. S1급 — 레인 브리프에 명시하면 되는 사항

| 항목 | 권고 |
| --- | --- |
| archive enable | 설정 시 현재 로컬 live projection부터 backfill. 그 이전 전역 역사 completeness는 주장하지 않음 |
| `preserve all` | 설정 시점의 stream 목록이 아니라 미래에 생기는 stream도 포함하는 동적 wildcard |
| preserve disable | 미래 capture만 중지. 기존 archive는 삭제하지 않음 |
| retain 변경 | 이미 archive되거나 소멸한 객체를 자동으로 live에 복구하지 않음. 증가도 prospective |
| archive 상태 표시 | selected streams, archive root, same-filesystem 여부, healthy-since, last success, pending/conflict, bytes/inodes |
| 용량 부족 | 자동 eviction 금지. loud degraded 상태 |
| archive 무결성 | 선택적 digest scrub과 외부 backup. 인덱스는 재생성 가능 데이터 |
| mind 포맷 | 포맷 버전, UTF-8/한 줄 크기 상한, control character 정화, unknown status의 전방 관용 |
| mind 동일값 갱신 | 의미 변화가 없는 hook 갱신은 coalesce하여 파일 폭증 방지 |
| `send/say --mind` 부분 실패 | mail/stream 성공과 mind 성공 사이에 분산 transaction이 없음을 명시. 주 동작은 성공시키고 mind 실패는 경고하는 방식이 자연스러움 |
| 혼합 버전 | mind link class는 새 minor로 협상. 구 link에서는 sync-only로 느려질 뿐 오류 없음 |
| 다중 preserver | 독립 archive. leader/quorum 없음. 실제 장기 기억에는 두 노드 또는 외부 backup 권고 |
| archive 검색 | 우선 평문 원본+월별 디렉터리. 성능 문제가 실재한 후 재생성 가능한 인덱스 추가 |

---

# 7. 발사 전 수용 속성으로 등록할 항목

## inherited retention gate

1. 노드가 `retain`보다 오래 offline인 상태에서 link가 먼저 기동되어도 expired stream/presence/mind 객체를 offer하지 않는다.
2. 항상 켜진 link가 있는 idle 노드에서도 만료 객체가 hub prune 뒤 반복 재offer되지 않는다.
3. 이미 in-flight였던 만료 객체가 도착해도 watch와 drain은 그것을 노출하지 않고 다음 reconcile에서 제거한다.

## minds

1. V2 설치 후 지연된 V1이 link와 rsync 양쪽에서 도착해도 현재값은 V2다.
2. `clear` 후 지연된 구 generation이 도착해도 mind가 재출현하지 않는다.
3. Session A와 B가 같은 명의로 겹친 뒤 A의 늦은 Stop이 B의 상태를 바꾸지 않는다.
4. `retire` 후 기본 minds 표에서 즉시 사라지고, 재발화만으로 과거 mind가 다시 보이지 않는다.
5. freshness 경과 후 `focused`가 현재 상태로 표시되지 않고 명시적으로 stale 처리된다.
6. 동일 generation·상이 digest는 overwrite되지 않고 quarantine된다.
7. mind 파일은 watch wake, stream drain, preserver capture에 영향을 주지 않는다.

## preserver

1. archive commit의 각 단계에서 프로세스를 kill해도 최종 상태가 live만, live+archive, archive만 중 하나이며 둘 다 소실되지 않는다.
2. 동일 ID의 지연 재도착은 archive 중복을 만들지 않는다.
3. archive와 live의 digest가 다르면 cat이나 prune이 임의의 한쪽을 선택하지 않는다.
4. `archive/`와 `.pending/`의 파일은 어떤 link initial scan, periodic scan, rsync 왕복에서도 offer되지 않는다.
5. archive write 실패나 ENOSPC에서 live 객체가 조용히 삭제되지 않고 preserver가 degraded 상태가 된다.
6. `stream cat`의 live+archive 병합이 중복 없이 기존 `(epoch,id)` 순서를 유지하고 cursor를 변경하지 않는다.
7. preserve를 늦게 활성화한 노드는 현재 live window만 capture하며 과거 전역 completeness를 보고하지 않는다.
8. preserve를 비활성화해도 기존 archive가 남는다.

---

# 최종 판정

D14의 사상적 방향은 맞다. 다만 r1에서는 다음 세 문장이 설계의 중심이 되어야 한다.

> **mind는 presence의 가변 파일이 아니라, 명의가 소유하는 불변 세대형 register다.**

> **preserver는 만료 시 삭제를 가로채는 특례가 아니라, 관측한 stream 객체를 로컬 archive에 먼저 정착시키고 기존 retention prune을 그대로 통과시키는 역할이다.**

> **retain은 함대의 live 복제·가시성 지평이며, 이미 공유된 stream 데이터의 소거 보장은 아니다.**

그리고 D14 발사 전에 D13의 `reconcile(prune) ↔ live link full scan` 순서를 반드시 문면과 수용 속성으로 닫아야 한다. 이 계약이 닫히지 않으면 preserver의 archive 격리는 맞더라도, live 쪽 부활 불가 논증은 완결되지 않는다.
