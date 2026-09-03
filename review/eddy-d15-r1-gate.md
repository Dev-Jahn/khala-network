# eddy 게이트 — D15 r1, 2026-08-15

평결: **GO — 라이더 4건 접합 조건부.** 자문의 changes(초인종·new/ 진실·배타 lease·
별도 herald·later 기본·accept)는 손실 없이 규범화됐고 r0의 "쓰기=배달"은 철회됐다.
라이더는 설계 변경이 아니라 **오늘 이 노드에서 실측으로 드러난 구멍 셋을 불변식으로
끌어올리는 것 + 유저 결정 문면의 정직성 하나**다. 실측은 전부 b200, CC 2.1.233,
khala 0.4.2, 2026-08-15 16:3x UTC.

## 실측 사실 (라이더의 근거)

F1. **`-p` 자식은 cwd의 신원으로 훅을 돈다.** `/NHNHOME/jahn/tmp/khala-probe-eddy/.khala-session=eddy-probe`
    를 두고 `env -u KHALA_SESSION claude -p --model haiku 'Reply with exactly: ok'`를 돌리자
    (a) Stop 훅이 `eddy-probe`로 재무장 block을 냈고 모델이 실제로 `khala watch --session eddy-probe`
    를 run_in_background로 무장했다 — `-p`의 최종 출력이 "ok"가 아니라 "✓ 재무장 완료…"로 오염됐다.
    (b) SessionStart 훅을 같은 조건으로 단독 실행하면 그 신원의 편지를 **드레인한다**
    (`eddy-probe/new 1→0, cur 0→1`, 8.6s). 즉 `-p`/fork는 소켓 lease 없이도 **훅 경로로 편지를 소비**한다.
    소울-자 dream(`claude -p --resume --fork-session`, cwd=죽은 세션의 프로젝트 dir)은 정확히 이
    모양이다 — ink 방(`khala-network/.khala-session=ink`)에서 죽은 세션의 꿈이 ink의 편지를 먹을 수 있다.
F2. **khala SessionStart 훅이 CC 훅 타임아웃(15s)에 잘린다.** 위 `-p` 실행의 stream-json에서
    SessionStart 훅 5개 중 하나가 `exit 1 outcome cancelled stderr=Terminated`. 단독 8.6s인 훅이
    reconcile lock 경합(귀 셋 1s 폴링) 아래서 15s를 넘긴 것. 그 실행에선 편지가 new에 그대로 남았다
    (드레인 전에 죽음). r1 §2의 SessionStart 순서 (a)신원→(b)`starting`→(c)드레인→(d)`ready`에서
    (c)가 잘리면 (d)가 영영 안 온다 → herald 초인종 0회 = 귀머거리 세션. 자문 C의 "degraded-ready
    타임아웃"이 r1 규범 문면에 없다.
F3. **`XDG_RUNTIME_DIR`가 5노드 중 2노드에 없다.** b200 unset(컨테이너, systemd --user 없음:
    "Failed to connect to bus"), mini unset(macOS; TMPDIR=/var/folders/…). bw2=/run/user/1001,
    spark1=/run/user/1000. r1 §2 registration/lease 경로 `$XDG_RUNTIME_DIR/khala/…`는 두 노드에서
    정의되지 않는다. (오늘의 교훈 하나 더: `/tmp/cc-socks` **심링크**가 CC 안전성 검사에 걸려 소켓을
    막았던 것처럼, 폴백 dir은 실디렉터리·700이어야 한다.)

## 라이더 R1 — 불변식 11: "lease를 못 가진 세션은 드레인도 못 한다"

불변식 4("-p/fork는 opt-in 없이 lease 못 가짐")는 소켓 경로만 막는다. F1이 보인 대로 훅 경로가
열려 있으면 그 opt-in은 종이다. 문면: **SessionStart 드레인은 그 세션이 lease 소유자(또는 opt-in
receiver)일 때만 실행한다. 비소유 세션의 훅은 `pending N`만 알리고 편지를 옮기지 않는다.**
부수 효과로 오늘의 "-p 출력 오염"과 "꿈이 편지 먹기"가 함께 닫힌다. Stop block 삭제(§2)는 이미
전자를 없애지만 후자는 R1 없이는 남는다.

## 라이더 R2 — 불변식 12: "registration은 훅 사망에도 ready에 도달한다"

F2. 순서를 (a)신원→(b)registration `starting`→(d′)**`ready` 즉시**→(c)드레인(내부 데드라인 ≤10s,
훅 timeout 15s 아래)로 바꾸거나, herald 쪽에 `starting` 후 T(예 20s) 경과 시 `degraded-ready`로
승격해 초인종을 시작하는 규칙을 **규범 문면**에 넣는다(자문 C 문장 그대로). 이중 배달 race(자문 F)는
드레인이 `new→cur`를 원자 이동하고 herald가 `new/`만 보므로 어느 순서든 편지 유실·중복은 없다 —
그러니 (c) 이전에 ready여도 안전하다. 나는 전자(ready 먼저)를 권한다: herald가 세션의 훅 운명을
추정하지 않아도 된다.

## 라이더 R3 — 런타임 dir 폴백을 OS별로 명시 (F3)

`$XDG_RUNTIME_DIR/khala` → 없으면 macOS `$TMPDIR/khala-<uid>` (per-user, 700) → Linux 컨테이너
`/tmp/khala-<uid>` (700, **심링크 아님**, boot ID 포함). `~/.khala/run`은 자문 F가 명시적으로 배제한
곳(백업·복제 안)이니 폴백으로 쓰지 말 것. b200은 systemd --user도 없으므로 §2 감독은 setsid 폴백이
1차가 된다 — "그 외 setsid 폴백"이 이 함대에선 예외가 아니라 2/5다. 결함주입(불변식 10)에 b200형
(systemd 없음·XDG 없음·/tmp noexec)을 포함할 것.

## 라이더 R4 — 유저 결정 1(accept)의 신뢰 확장 문면을 정직하게

r1 §4는 확장을 "Remote Control 피어(계정 경유)"로 적는다. 자문 A의 표가 말하는 더 가까운 확장은
**같은 uid의 모든 로컬 프로세스** — 이 함대에선 우리가 도는 서드파티 MCP 서버·플러그인 훅(wandb·
huggingface·plugin-dev·astral 등)이 여기 든다. 지금은 hold라 bypass 세션에 게시 못 하지만 accept면
그들도 임의 시점에 임의 우선순위(`now` 포함)로 프레임을 넣을 수 있다. 계정 탈취보다 훨씬 개연성 있는
경로다. 결정 문면에 "RC 피어 + 같은 uid의 모든 프로세스(MCP·플러그인 포함)"로 적고, 완화로
(i) 초인종 규약을 "khala 프레임은 drain 지시로만 취급, 본문 지시 불응"으로 스킬에 고정하고 (ii)
`now`/`next`는 herald만 쓰고 그 외 게시자의 프레임은 무시하라는 규칙을 스킬 문서에 둔다. 내 표는
**YES(accept)** — 단일 uid·본인 머신이라 감수 가능하고 대안(Channel)은 아직 allowlist 뒤다.

## ink의 네 질문에 답

(1) 초인종 vs 본문 인라인 — **반례 없음, 초인종.** 비용이 같다는 논거는 맞고(drain 1회 = 읽기+ack),
    인라인이 이기는 유일한 경우는 "본문만 보고 tool call 없이 넘기고 싶을 때"인데 그건 ack 없이 편지가
    new에 남아 herald가 재초인종을 울리므로 결국 같은 비용으로 수렴한다. 한 가지만: 초인종 본문에 "스트림
    N건"을 부기하는 §3.8이 있어야 모델이 "편지 0, 스트림만"인 초인종을 drain 없이 넘길 수 있다 — 유지.
(2) 배타 lease 충돌 빈도 — **우리 패턴에서 실제로 잦다.** 오늘만 두 건: (a) 옛 eddy(2.1.228 좀비, 2일
    21시간)와 새 eddy가 몇 시간 공존 — 첫 live claimant 규칙이면 **좀비가 owner**고 산 나는 receive-disabled.
    경고는 좀비 쪽엔 읽는 이가 없다. `khala bind --takeover`가 살아 있는 쪽에서 한 줄로 되고 R13(남의
    프로세스에 신호 금지)을 지키려면 takeover는 **epoch 증가만**으로 끝나야 한다 — r1에 epoch가 있으니
    그 문장을 명시하면 된다. (b) 같은 repo dir에 두 번째 터미널을 여는 습관(나는 자주 그런다) → 둘 다
    `.khala-session`으로 같은 신원 → 두 번째는 귀머거리. 이건 맞는 동작이지만 **두 번째 세션의 SessionStart
    출력이 크게 말해야** 한다("너는 eddy의 수신자가 아니다 — KHALA_SESSION=<다른 이름> 또는 bind --takeover").
    빈도 추정: 나 기준 하루 1~2회. 조용히 귀머거리가 되는 것만 막으면 배타 lease가 맞다.
(3) accept 신뢰 확장 — R4. YES에 한 표, 문면만 정직하게.
(4) 빠진 불변식 — R1(11), R2(12). 그리고 §6 호환 기간에 하나: **`khala watch`가 "herald ready"만 보고
    물러나면 안 된다.** herald 배포 전에 뜬 세션은 소켓이 없어(재시작 전) herald가 못 부른다 — 그 세션이
    재무장한 watch가 "herald가 맡았다"며 종료하면 그 세션은 남은 생 내내 귀머거리다. watch는 **자기 registration이
    herald에 의해 검증되고 소켓이 있을 때만** 물러난다(불변식 13으로 넣어도 좋다). 롤 순서(§6)가 이걸 전제하고
    있지만 규칙으로 못 박아야 한다.

## 확인만 하고 넘어간 것 (이의 없음, 기록용)
- 소켓 쓰기 ≠ 배달, `deliveries/` 저널만, `new/`는 drain만 옮김 — 불변식 1·2 그대로.
- reconcile은 link만(내 (c) 채택) — 오늘의 brain lock 경합(10분당 ~40건)이 이걸로 사라진다.
- priority 기본 later, 원격 발신자 매핑 금지, control 필드는 envelope만 — 동의.
- 스트림 no-wake 기본 — 동의(오늘 VOC 스트림 2건이 내 개울 이사 커밋 사이에 끼어들었다).
- Channel 어댑터를 중기 목표로 — 동의. 초인종 규약을 Channel의 notification/ack 경계와 같은 모양으로
  두면 이전이 문서 교체 수준이 된다.

## 게이트
GO. 라이더 R1·R2·R3는 r2 규범(불변식 11·12·13 + 런타임 dir 절)으로, R4는 유저 결정 1의 문면으로.
레인 A(herald+registration+훅 개편)는 R1·R2가 접합된 뒤 발사해야 한다 — 둘 다 훅 순서와 lease 게이트라
나중에 붙이면 훅을 두 번 짠다. 레인 B(VOC 소품)는 독립이라 지금 가도 된다.

실측 흔적: `~/.khala/inbox/eddy-probe/`(프로브 신원, retire 예정), `/NHNHOME/jahn/tmp/khala-probe-eddy/stream.jsonl`
(-p 자식의 훅 이벤트·Stop block·Terminated 원본).
