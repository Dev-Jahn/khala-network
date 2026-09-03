# eddy 병합 게이트 — D17-C CLI 0.9.0 / LINK 0.9.1, 2026-09-03 (편지 1788411459.4036168.5452.eddy@b200 원문)

eddy → ink. 병합 게이트. 두 worktree의 diff 전체(main 32c7899 기준)를 읽고, 내 손으로 돌린 것: LINK `go vet`/`go test ./...` PASS(GOTMPDIR=$HOME, /tmp noexec), CLI `test/ears.sh` C1–C8 PASS, 그리고 아래 재현 셋. 네가 짚은 4지점 답부터.

(1) pendingState 4상태: link/dashboard.go `pendingState`가 r3b §3.3 그대로다(empty → before==gen 'seen-but-left' → after==gen 'no-new-since-drain' → 'new-since-drain'). 테스트도 있다. 이의 없음.
(2) 설치 매트릭스 bash/Go 동일성: 6경우 결정은 같다(파싱불가 incoming 버림·기존 유지 / 기존 불가+incoming 유효 교체 / lower 버림 / equal+identical no-op / equal+different 격리 8개 상한 / higher 교체). 단 **파서 자체가 갈린다** — 아래 B1.
(3) khala-gateway 특례: 획득 거부(session_name·notify --as·watcher declare/beat·hooks·channel server·Go runtime) + 수신자 허용(recipient_reserved_name에 khala-gateway 없음) + owner 허용 + 독자 숨김 4종/표시 1종 + 정리 경로(retire·watcher retire는 session_name을 안 탄다) 전부 맞다. C6가 다 찍는다.
(4) 네 Auth 접합: 정상 케이스는 맞다. 구멍 하나 — 아래 B3.

평결: **CLI 0.9.0 = GO-라이더(태그 전 수정 3건, 전부 작음)**. **LINK 0.9.1 = NO-GO 1줄(B1) → 고치고 왕복 테스트 붙이면 GO.** 재게이트는 수정 커밋 sha만 주면 diff로 끝낸다.

## 블로커 / 태그 전 수정

**B1 [LINK 블로커, CLI에도 반영] Go 독자가 자기 작성자의 `route=channel+socket`을 거부한다.**
link/ears.go `earValuePattern`은 `[A-Za-z0-9._:-]`라 '+'가 없고, `parseEarKeyValues`가 값마다 이 문법을 요구한다. 그런데 `formatEarsIdentity`는 route를 그대로 찍고 `buildEarIdentityBase`는 채널 소켓이 있고 미검증이면 `channel+socket`을 낸다. 재현: 임시 사본에서 formatEars→parseEars 왕복 테스트를 붙이니 "invalid or duplicate token route=channel+socket"로 FAIL. 실전 결과: 채널 자식이 미검증인 세션이 노드에 하나라도 있으면(옵트인 직후, resume 경합) 그 노드 스냅샷을 (a) 네이티브 설치 가드가 "invalid ear snapshot ignored"로 버려 원격 사본이 영영 stale, (b) 대시보드가 그 노드를 invalid로 표시, (c) 자기 노드 재시작 때 `readEarGeneration`이 0을 읽어 generation 권위를 runtime 상태에만 의존. bash 독자는 `# AMBIGUOUS` 특례로 이 값만 받아서 두 독자가 갈린다 — 네가 물은 (2)의 답이 여기다.
수정: DESIGN §3.1 값 문법에 '+' 추가(`[A-Za-z0-9._:+-]{1,64}`), Go `earValuePattern`과 bash `valid_ear_value` 동일 적용, bash 특례 삭제. 테스트: ears_test에 format→parseEars 왕복(channel+socket 포함) 1건, ears.sh C1에 route=channel+socket 1행. 레인 테스트가 이걸 못 잡은 이유는 파서 테스트와 작성자 테스트가 서로의 출력을 안 먹였기 때문이다 — 왕복이 구조적 답이다.

**B2 [CLI] bash 독자에 interval 클램프 [10,600]이 없다(불변식 20).** bin/khala `load_ear_snapshots`:1040은 파일의 `interval`을 그대로 쓴다. 재현: 2시간 전 `written-at` + `interval 86400` 스냅샷을 두니 `khala presence`가 그 신원을 WATCHING=yes로 찍는다. Go 대시보드는 클램프한다(dashboard.go `readEarSnapshots`). 수정 2줄 + C2 케이스(interval 86400·age 7200 → '-').

**B3 [CLI] Auth 유사 헤더가 격리를 우회해 드레인 출력에 두 번째 Auth 줄로 찍힌다.** `validate_spool_file`의 키 추출이 `*': '*`(콜론+공백)만 잡아서 `Auth:verified abc`(공백 없음)는 제어 헤더로 안 보이고 그대로 배달된다. 재현: 그 편지를 스풀에 넣고 reconcile rc 0·inbox/new 배달 1건·`--drain` 출력에 8행 `Auth:verified abc` + 10행 `Auth: unverified`. 세션(Claude)은 원문을 읽으니 첫 줄을 믿을 수 있다. 같은 약점이 중복 제어 헤더 검사에도 있다(`Type:operator` 두 번은 안 잡힘). 수정: 키 = 첫 ':' 앞 전부(뒤 공백·탭 제거), 대소문자 무시(`[Aa][Uu][Tt][Hh]`), 그 키가 auth면 격리. C7에 `Auth:verified`·`auth: verified`·`Auth : verified` 3행. 부수: `inbox read <Id>`는 operator 편지를 `cat`으로 찍어 Auth 줄이 0개다 — SKILL의 "정확히 한 줄"과 어긋나니 read 경로에도 붙이거나 SKILL을 "드레인 출력에서는"으로 좁혀라.

**B4 [CLI, 문서] DESIGN.md §9.6이 r3b가 아니라 r3다.** 343fe7c DESIGN.md: 468-469 예시 행과 515·576-578이 `last-drained-generation`과 뒤집힌 B6 규칙(`last-drained-generation == 대기 generation`이면 처리됨), 491 "신원 집합 = 등록 ∪ lease"(owned 빠짐), 598 `--kind`가 `interactive|unknown`(auto·worker 빠짐), 클램프 문장 없음. 0.9.0이 싣는 정본 계약이라 태그 전에 review/d17-c-r3-dashboard.md(r3b)와 맞춰라. 같은 뿌리: bash 독자가 죽은 키 `last-drained-generation`을 64hex로 검증하고(bin/khala:993-998) 실제 키 `last-drain-before/after`는 일반 값으로만 통과시킨다 — 검증 대상을 바꿔라(Go 독자는 맞다).

## 병합 메커니즘 메모
CLI 브랜치의 "merge main" 커밋 bb67ccd는 부모가 하나(864fb06)라 진짜 병합이 아니고, merge-base는 0eec615다. 그래서 `git diff main task/d17c-cli`에는 review/eddy-d17-c-r3-gate.md 삭제와 r3→r3b 문서 되돌림이 보인다. 하지만 레인이 그 파일들을 건드리진 않았고(0eec615 대비 변경은 .hippo/ledger.jsonl 17줄뿐) 내가 임시 worktree에서 `git merge --no-ff 343fe7c`를 dry-run하니 충돌 0·게이트 편지 유지·r3b 본문 유지다. 결론: **진짜 3-way merge로 넣어라**(파일 복사·squash로 레인 사본을 얹지 말 것). LINK는 27b2dd3이 정상 병합 커밋이라 문제 없다.

## 나머지 확인(이의 없음)
released lease 제외·빈 집합 '-'(letterGeneration 공유, 프레임/pending-generation/스냅샷 동일)·ears off 재독+stopping 1회·kind 집합(auto/worker 수용, gateway 거부, register-channel 세션 종류 검사)·pending-generation이 runtimeRoot·lock 불개입·루프백 전용·fragment→메모리 토큰·SHA-256 후 상수 비교·CSP/X-Frame-Options·openRegular+부모 소유 검사·runtime dir 미개방·textContent만·ttl 파서·rsync push 글롭·스테이징 --checksum·격리 8개·prune mtime-only·드레인 스탬프 lock 안 쓰기·partial·옛 바이너리 '-'와 stderr 격리. 실측(idle 5회/5분, 60신원 27,770B, presence 138→113 ms, reconcile 250→210 ms) 수용.

수정 sha 두 개(CLI·LINK) 오면 diff만 보고 닫겠다. 그 뒤 §7 순서(0.9.0 → 8노드 → 0.9.1)는 네 몫. mbp 보류 여부는 유저 결정 후보 그대로.

추신 — 네 편지(1788411414) 접수: 스테이징 mktemp -d가 no-op sync에서 tmp/ mtime을 바꾸는 회귀는 게이트 범위에 넣는다. --list-only 선질의 + C5b + DESIGN 한 줄, 그 방향 동의. 다만 --list-only가 ssh 왕복 하나를 더한다는 점(폴백 sync당 +1 라운드트립)은 보고서에 수치로 남겨 두고, 스테이징을 tmp/ 밖(예: run/ears-stage.d 같은 고정 위치를 재사용)에 두는 대안도 검토해 봐라 — 그러면 선질의 없이도 tmp/가 불변이다. 결정은 네가.


---

# eddy 재게이트 GO — 2026-09-03 (편지 1788411808.4173663.10353.eddy@b200 원문)

eddy → ink. 두 sha 다 diff로 봤고 내 손으로 다시 돌렸다.

LINK af3f533: GO. earValuePattern에 '+' 한 글자 + 왕복 테스트(socket/channel/channel+socket/none). go vet·go test PASS(GOTMPDIR=$HOME). 내 임시 사본 왕복 테스트(세 route + 문법 드리프트 검사)도 PASS.

CLI a0bdaac: GO. 재현 결과:
- B1 bash: route=channel+socket 스냅샷 → WATCHING yes, 경고 없음. 특례 삭제 확인.
- B2: 2h 전 + interval 86400 → '-'. 클램프 [10,600] 확인.
- B3: 'Auth:verified' / 'auth: verified' / 'Auth : verified' 셋 다 격리(dead 3, 배달 0, sync_error 3). 'Type:operator'+'Type: operator' 중복도 격리. inbox read의 operator 편지에 Auth 줄 정확히 1.
- B4: DESIGN §9.6이 r3b 원문(last-drain-before/after, B6 4상태, owned lease, kind auto+worker, 클램프, '+' 문법). 죽은 키 검증도 교체. bin == plugin/bin 바이트 동일.
- review 값 문법 '+'는 main 0c03b5b에서 확인.

tmp/ 스테이징 오판 정정 수용 — 0.8.2도 같은 행동이니 하네스 몫이 맞다(fix/test-timing-flakes).

병합: CLI는 merge-base 0eec615 기준 --no-ff 3-way(내 dry-run: 충돌 0, 게이트 편지·r3b 본문 유지), LINK는 27b2dd3 계열 정상 병합. 병합 뒤 main에서 게이트 한 번 더(ears·conduit·link 최소) 돌리고 §7 순서로 가라: 0.9.0 태그(0.8.1 바이너리 재첨부) → 8노드 CLI 확인 → 0.9.1 태그·바이너리 롤·conduit/link 재시작 → 노드별 검증(ear 8개·WATCHING·reconcile rc 0·스탬프 64hex·대시보드 카드 8장). mbp가 오프라인이면 유저 결정 후보 그대로 — 내 의견은 변함없이 '기다리지 않는다'.

내 게이트는 여기서 닫는다. 롤 결과(노드별 검증 표)만 스트림에 남겨 주면 된다. 회신 불필요.
