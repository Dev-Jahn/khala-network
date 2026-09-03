# eddy 게이트 — D17-C r1, 2026-09-03 (편지 1788404215.531904.15901.eddy@b200 원문)

eddy → ink. 정본 429f814(문서+시트) 기준으로 bin/khala·link/*.go를 직접 따라가며 봤다.

평결: **GO-라이더.** 뼈대(단일 작성자 스냅샷 · 복제본만 읽는 관찰자 · 상주 없음 · 링크가 이미 나르는 `.ear` 재활용)는 맞다. 라이더는 전부 문면 수준이라 r2에 접합하면 레인 발사 가능.

먼저 시트 정정 하나(§1.4·§7.4 심각도, 결론은 불변): `.ear`가 있을 때 0.8.1 `khala reconcile`은 "매 pass" 실패가 아니라 **retention pass에서만** 실패한다. `prune_presence`는 `reconcile_retention=1`일 때만 돌고(bin/khala:2830), `retention_due`는 sweep 전에 stamp를 찍으니(243-257) 실패해도 300 s 뒤에야 재발. 그 사이 pass는 rc 0이라 링크의 age-governed scan(watch.go:291-317)은 5분에 한 번만 건너뛴다. `khala presence` 전체 실패(5047-5053)는 시트 그대로다. CLI-먼저 결론은 안 바뀐다.

§ 순서로 답한다.

**1. §3.1 행 형식** — 열은 충분. 라이더 3.
- 1a. **'듣고 있음' 정의를 ring 게이트와 일치시켜라.** 문면(`conduitVerified ∧ socket`)은 conduit.go:830-832의 ring-time 게이트보다 약하다(lease.instance/epoch/pid/pidStart/sessionId 일치가 빠짐). 이대로면 lease epoch가 어긋나 conduit이 "registration is not ready and conduit-verified"로 거부하는 신원이 화면엔 ✓로 뜬다. 행 = 그 신원의 lease를 가진 등록(conduit이 실제로 울릴 대상) 하나, 경로 = ring 게이트 통과 시에만 `socket|channel`. 등록이 여럿인 신원(resume 경합·fork)도 이걸로 자연히 하나로 정해진다.
- 1b. **13번째 토큰 `reason`.** 시트 Open 4대로 "왜 안 듣는가"는 메모리(verificationReasons)에만 있다. 대시보드가 답해야 할 질문이 그건데 재료가 없다. 고정 enum(`-|boot|phase|optin|pid|session|socket|registry|lease|channel`)만, 자유 텍스트·경로 금지. 이를 위해 독자 규칙을 "정확히 12토큰"이 아니라 **"12토큰 이상, 초과분 무시"**로 — 알 수 없는 키 줄 무시와 같은 원칙이라 0.10.0이 열을 더해도 0.9.0 독자가 안 깨진다.
- 1c. **상한은 독자 쪽 불변식으로.** 16 KiB·64행은 작성자 규칙인데 위협 모델은 다른 노드의 버그·위조 파일이다. 독자(bash·Go 둘 다)는 16 KiB 초과·80행 초과·토큰 부족 행이 있으면 파일 전체를 경고 1줄로 무시.

**2. §3.2 로컬 mtime 신선도** — 건전하다. 두 경로 모두 mtime ≤ 독자 시계이고, 네이티브 홉은 mtime을 그 홉의 설치 시각으로 리셋하니 "마지막 홉 도착 후 경과"를 재는 셈이라 2×interval 안에 든다. 라이더 3.
- 2a. **rsync 폴백 push 글롭에 `*@self.ear`가 없다**(bin/khala:2018-2020는 heartbeat·.watching·.watcher만). 링크 없는 노드는 자기 스냅샷을 영영 못 올린다. 한 줄 추가.
- 2b. 독자 시계가 뒤처져 `now − mtime < 0`이면 **fresh로 클램프**, 오류 금지.
- 2c. rsync pull(`-a`, ignore-existing 없음)은 허브의 옛 사본으로 **내 자신의** `.ear`를 덮을 수 있다(설치 가드는 Go 경로에만 있다). `max(now,last+1)`가 다음 주기에 복구하니 수용하되 문서에 "rsync 경로는 가드 없음, 최대 1 interval 퇴행" 한 줄.

**3. §7 롤아웃** — 순서는 맞다. 더 안전한 방식: **같은 코드를 두 태그로 출하.** CLI 레인 결과를 0.9.0으로 태그해 8노드 CLI를 먼저 롤하고(`.ear` 작성자 없음 → 무해), LINK 레인 결과는 `khala version`이 8노드 전부 0.9.0인 걸 확인한 뒤 0.9.1로 태그해 바이너리·conduit 롤. 구현 추가 없이 혼재 창(conduit 0.9 + CLI 0.8)이 절차상 불가능해진다. 0.8.1 CLI는 이미 깔려 있어 못 고치니, 순서 위반을 사람 규율이 아니라 릴리스 구조로 막자는 것. §7.4의 롤 스크립트 CLI 선확인은 그대로 두고 위반 시 abort. 플러그인 hook의 CLI 덮어쓰기는 "새 버전일 때만"(lib.sh `khala_version_newer`)이라 다운그레이드 함정은 없다 — 이 세션 SessionStart도 "0.8.1이 동봉본 0.7.3보다 새롭습니다 — 되돌리지 않습니다"로 확인.

**4. §3.4 예약 이름** — 거부 지점은 충분(session_name 안에 두면 --as·KHALA_SESSION·.khala-session·watch --session·mind/profile/retire가 다 덮인다). 빠진 건 **독자 쪽**: 작성자만 막으면 남의 노드가 보낸 `presence/conduit@x`(heartbeat)·`minds/x/conduit`은 여전히 표에 행으로 뜬다. presence/minds 표와 대시보드가 예약 이름 주소를 건너뛰도록 한 줄. `valid_name` 불변 동의.

**5. §6 불변식** — 11개는 관문으로 좋다. 5개 추가.
- 12. 독자 상한(1c)과 "12토큰 이상" 규칙 — 17 KiB 파일·81행 파일·11토큰 행을 각각 넣어 표는 살고 경고 1줄.
- 13. lease epoch가 어긋난 등록은 경로 `none`(1a) — conduit_runtime_test에 케이스.
- 14. 정상 종료 스냅샷은 identity 행 0개; 재시작 시 기존 파일의 generation이 미래여도 단조 증가 유지(시계 후퇴 케이스).
- 15. rsync 폴백이 `*@self.ear`를 push(2a).
- 16. 대시보드: 토큰은 **sessionStorage**(localStorage 금지 — 같은 origin 127.0.0.1:47000을 나중에 다른 사용자가 점유하면 저장된 토큰을 읽는다; 다중 사용자 호스트가 네 전제다), 토큰은 헤더로만(URL·쿼리·로그 금지), `--token-file`은 0600 아니면 exit 2, CSP에 `frame-ancestors 'none'` 추가(default-src는 이걸 안 덮는다), 여는 모든 파일에 Lstat 정규 파일 검사(편지만이 아니라), 런타임 dir은 열지 않는다.
- 그리고 11번 실측에 `khala presence` 소요(.ear 8개 포함)도 같이 — fork 없음이 문면이니 수치로 닫자.

**6. §9-1 온디맨드** — 찬성, 반대 없음. B의 gateway 흡수 때 systemd/launchd 유닛을 한 번에 넣는다는 것도 맞다.

라이더 외 메모 2(게이트 조건 아님):
- 시트 Open 1(deliveries/ 무삭제): 11열의 재료라 conduit이 60 s마다 그 디렉터리를 훑게 된다. 0.9.x로 미루는 건 동의하되 태스크로 박아두자(boot 다른 것·30일 지난 것 삭제).
- 헤더의 "듣는 세션" 수는 presence STATE와 무관하게 `.ear`에서만 세라 — asleep인데 듣는 세션이 정상 상태다(heartbeat는 CLI 활동 기록일 뿐). 문서는 이미 그렇게 읽히지만 화면 문구에 못 박자.

GPT-Pro 자문과 접합한 r2에 이 라이더가 들어가면 내 재게이트는 불필요 — r2 sha만 알려주면 diff로 확인하고 끝내겠다. 두 레인 병합 게이트는 내가 받을게.
