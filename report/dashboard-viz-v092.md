# Dashboard visualization 0.9.2

## Outcome

khala dashboard의 첫 화면을 표와 로그 목록에서 SVG 함대 지도로 교체했다. 서버, API, 보안 헤더,
토큰 수명, 라우트는 변경하지 않았다. 허브 중심 topology, 신원 위성, 상태/링크/경고 부호, 지속되는
inspector, 요약 수치, 세션 decay board, watcher cadence gauge, stream/unread chart, local letter feed를
기존 3개 embedded asset 안에서 구현했다.

실함대 sample(/tmp/.../fleet-sample.json)의 크기와 분포(8 nodes, 40 sessions, 13 watchers, 1 stream,
0 letters)를 확인해 기본 stale-clutter 접기와 노드별 grouping을 정했다. sample 자체와 사람 이름은
저장소에 복사하지 않았다.

## Property evidence

| Property | Result | Evidence |
|---|---|---|
| V1 fleet map | PASS | [desktop 1400×900](dashboard-viz-v092/desktop-1400x900.png), [mobile 390×844](dashboard-viz-v092/mobile-390x844.png), [all absent](dashboard-viz-v092/all-absent-1400x900.png). SVG는 hub를 중앙에 두고 node state를 색+기호+문자로, link age를 실선/파선/점선으로, identity를 listening fill과 ring accent/count로 표현한다. complete=false와 skew>60은 ▲. 최초 render는 hub detail을 열고 node/satellite click과 keyboard activation이 inspector를 갱신한다. DevTools에서 satellite click 후 title=mystery@mini; 5초 poll 뒤에도 동일 selection 확인. |
| V2 headline | PASS | desktop/mobile screenshot. fresh/total, listening, pending ring, silent watcher, generated snapshot age를 독립된 큰 숫자로 표시하고 이상 항목은 amber/red cue를 쓴다. |
| V3 sessions | PASS | [full boards](dashboard-viz-v092/boards-1400x2600.png). node group 안의 session tile마다 presence 색+기호, 30일 cap의 log-scale seen decay bar, route/listening, R/I/O bars, 4-state pending pill, model/effort/role/charge/focus가 있다. 기본 상태에서 unknown 또는 7일 초과 2건을 접었고 DevTools에서 전체 보기 후 9 tiles, listening filter 3, pending+listening filter 2, beta filter 1을 확인했다. filter와 sort state는 poll 뒤 유지됐다. |
| V4 watchers | PASS | full boards screenshot. node별 gauge가 (generated clock-last)/cadence를 매초 다시 계산하며 100% 초과 또는 API silent를 red alarm으로 표현한다. fixture의 overdue watcher가 alarm으로 표시된다. |
| V5 streams/letters | PASS | full boards screenshot. stream entries bar, local identity unread bar, recent feed, local letter feed가 보인다. DevTools click으로 /api/v1/letter 응답의 “두 번째 편지 본문입니다.”가 reader에 표시됨을 확인했다. |
| V6 live/no flicker | PASS | keyed reconciliation은 모든 entity에 data-key를 사용하고 page/board wholesale replacement를 사용하지 않는다. DevTools에서 mini SVG DOM object에 marker를 붙인 뒤 5초 poll 후 같은 object임을 확인했다. selection/filter/sort도 그대로였다. [API failure](dashboard-viz-v092/api-failure-1400x900.png)는 server를 page load 뒤 실제 종료하고 다음 poll을 기다려 찍었으며 banner가 나타나도 8 SVG nodes와 마지막 정상 render가 유지됐다. age/decay/gauge는 1초 tick, fetch는 5초다. |
| V7 constraints | PASS | TestDashboardR3OptionsAuthMethodsHeadersAndAssets가 createElementNS, keyed DOM, fleet/pending/unread binding과 token fragment stripping을 요구하고 storage/event-attribute/markup sink/wholesale replacement를 거부한다. 기존 Go security assertions도 전부 통과했다. 1400×900과 390×844에서 horizontal page overflow 없이 map viewBox가 각각 desktop radial/mobile compact radial layout으로 바뀐다. Chrome logs 6개에서 CSP refusal와 uncaught TypeError/ReferenceError/SyntaxError가 0건이었다. |

## Synthetic rig

최종 interaction rig는 /NHNHOME/jahn/.cache/khala-dashboard-rig-v092.DizoLn에 만들었다. 검증마다
같은 생성기로 fresh rig를 새로 만들어 clock-ahead 시간이 줄어드는 영향을 피했다. 이 경로와 생성기는
검증용 cache이며 commit하지 않았다.

| Fixture area | Contents |
|---|---|
| config | self alpha, mailbox mini, ttl 120, inert peer sentinel |
| presence/*.ear | 7 files: alpha, beta, gamma, mini fresh; delta clock-ahead stale; omega stopping; broken invalid. legacy는 heartbeat만 있어 absent. 총 8 nodes. |
| node distinctions | mini hub; beta complete no; delta written-at=now+600 so skew>60; link ages 0/8/44/92/160/420 cover all three presentation tiers |
| identities | socket, channel, channel+socket, none; listening yes/no; local@alpha ring=2; info/operator pending도 포함 |
| sessions | alive-here local@alpha, alive-elsewhere remote@beta, asleep sessions, 8일보다 오래된 old@legacy, mind-only unknown mystery@mini |
| watchers | active pulse, active relay, silent/overdue overdue |
| stream | ops, entries 2, local unread 1, recent subjects/bodies present |
| letters | local inbox new 1 + cur 1, message/notice and info/urgent |

All-absent rig는 fresh rig copy
/NHNHOME/jahn/.cache/khala-dashboard-absent-v092.NqqOGs에서 presence/*.ear만 제거했다. 각 node에
heartbeat 또는 mind가 남으므로 8 nodes 모두 absent로 렌더됐다.

## Screenshot inspection

- Desktop: map가 first viewport의 주 시각물이고 8 nodes, central hub, 5 node states, three link styles,
  satellites, pending count, two warning glyphs가 겹치지 않는다. inspector와 legend도 같은 viewport에 있다.
- Mobile: 1000-wide desktop geometry를 단순 축소했을 때 label이 너무 작았던 첫 시도를 버리고, 420×500
  compact viewBox와 별도 radial coordinates로 다시 찍었다. 최종 파일에서 node/state labels가 읽히고
  page horizontal scroll은 없다.
- Boards: 처음에는 node group마다 full row를 차지해 긴 빈 공간이 생겼다. node groups 자체를 responsive
  columns로 바꾼 뒤 최종 full screenshot에서 sessions, gauges, streams, letters가 연속된 board로 보인다.
- Failure: 1400×900 browser viewport에서 server 종료 7초 뒤 banner가 보이며 inspector/map/metrics가
  그대로 남는다.

## Deliberately omitted

- API에 history가 없으므로 sparkline, time-series, in-page ring buffer를 만들지 않았다.
- 외부 resource, dependency, build step, fourth asset, light theme, write/control action을 추가하지 않았다.
- API와 DESIGN에 link freshness enum이 없으므로 UI만 ≤60 s solid, 61–300 s dashed,
  >300 s 또는 null dotted로 표현한다. 이것은 server state를 바꾸는 판정이 아니다.
- token, selection, filters를 storage에 보존하지 않는다. “refresh” 지속성은 5초 data refresh를 뜻하며,
  browser reload 뒤에는 보안 계약대로 새 fragment token이 필요하다.

## Verification notes

- 첫 validation command는 toolchain PATH export보다 gofmt를 먼저 놓아 command not found로
  종료됐다. export 순서를 고친 동일 command가 통과했다.
- 첫 rig generator는 3개의 write_mind call에 일곱 번째 argument가 없었고, 첫 수정에서 하나만 고쳐
  한 번 더 중단됐다. 나머지 두 call을 고친 뒤 fixture가 완성됐다. 제품 코드나 test를 우회하지 않았다.
- 첫 clock-ahead fixture는 now+61이라 준비 중 60초 아래로 내려가 fresh가 됐다. 검증 window 동안
  의미가 안정적인 now+600으로 바꿨고 API에서 delta=stale, skew>60을 확인했다.
- Chrome stderr에는 headless host의 D-Bus 연결 noise가 있었으나 CSP refusal와 uncaught JavaScript
  error는 없었다.

## Stdout summary

    $ export PATH=/NHNHOME/jahn/go-toolchain/bin:$PATH
    $ export GOTMPDIR=/NHNHOME/jahn/.cache/go-tmp
    $ cd link
    $ go vet ./...
    (no stdout, exit 0)
    $ go test ./...
    ok   github.com/Dev-Jahn/khala-network/link  5.747s
    $ CGO_ENABLED=0 go build -trimpath -o /NHNHOME/jahn/.cache/khala-link-dashviz .
    (no stdout, exit 0)

    Synthetic fleet API:
    nodes=8 (fresh=4, stale=1, stopping=1, invalid=1, absent=1)
    sessions=9 (alive-here/alive-elsewhere/asleep/unknown all present)
    watchers=3 (silent=1), streams=1 (unread=1), letters=2

    DevTools interaction:
    identityTitle=mystery@mini, allSessions=9, listeningSessions=3,
    pendingAndListeningSessions=2, pendingOnBeta=0, betaSessions=1,
    letterLoaded=true, keyedNodeKept=true, selectionKept=true,
    filtersKept=true, bannerHidden=true

    Chrome application-error grep:
    CSP violations=0, uncaught JavaScript errors=0
