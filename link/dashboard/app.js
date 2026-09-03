"use strict";

const SVG_NS = "http://www.w3.org/2000/svg";
const HIDDEN_AFTER = 7 * 24 * 60 * 60;
const DECAY_CAP = 30 * 24 * 60 * 60;

const rawToken = window.location.hash.slice(1);
let dashboardToken = rawToken;
try {
  dashboardToken = decodeURIComponent(rawToken);
} catch (_) {
  dashboardToken = rawToken;
}
history.replaceState(null, "", window.location.pathname + window.location.search);

const view = {
  fleet: null,
  receivedAt: 0,
  selected: null,
  selectedLetter: "",
  showAll: false,
  listeningOnly: false,
  pendingOnly: false,
  node: "",
  newestFirst: true,
};

const byId = (id) => document.getElementById(id);

function text(value) {
  return String(value === null || value === undefined || value === "" ? "-" : value);
}

function element(tag, className, value) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (value !== undefined) node.textContent = text(value);
  return node;
}

function svgElement(tag, className) {
  const node = document.createElementNS(SVG_NS, tag);
  if (className) node.setAttribute("class", className);
  return node;
}

function setText(node, value) {
  const next = text(value);
  if (node.textContent !== next) node.textContent = next;
}

function reconcile(host, items, keyOf, create, update) {
  const existing = new Map();
  for (const child of Array.from(host.children)) {
    existing.set(child.getAttribute("data-key"), child);
  }
  for (const item of items) {
    const key = String(keyOf(item));
    let child = existing.get(key);
    if (!child) {
      child = create(item);
      child.setAttribute("data-key", key);
    } else {
      existing.delete(key);
    }
    update(child, item);
    host.append(child);
  }
  for (const child of existing.values()) child.remove();
}

function currentEpoch() {
  if (!view.fleet) return Math.floor(Date.now() / 1000);
  return view.fleet.generatedAt + Math.max(0, Math.floor((Date.now() - view.receivedAt) / 1000));
}

function elapsedSinceFetch() {
  return view.fleet ? Math.max(0, currentEpoch() - view.fleet.generatedAt) : 0;
}

function humanDuration(value) {
  if (!Number.isFinite(value) || value < 0) return "-";
  const seconds = Math.floor(value);
  if (seconds < 60) return seconds + "초";
  if (seconds < 3600) return Math.floor(seconds / 60) + "분";
  if (seconds < 86400) return Math.floor(seconds / 3600) + "시간";
  return Math.floor(seconds / 86400) + "일";
}

function epochAge(epoch) {
  return typeof epoch === "number" && epoch > 0 ? Math.max(0, currentEpoch() - epoch) : null;
}

function stateClass(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback;
}

function authHeaders() {
  return {Authorization: "Bearer " + dashboardToken};
}

async function loadFleet() {
  const response = await fetch("/api/v1/fleet", {headers: authHeaders(), cache: "no-store"});
  if (!response.ok) throw new Error("fleet " + response.status);
  const fleet = await response.json();
  view.fleet = fleet;
  view.receivedAt = Date.now();
  render(fleet);
  hideError();
}

function render(fleet) {
  if (!view.selected && fleet.nodes.length) {
    const initial = fleet.nodes.find((node) => node.hub) || fleet.nodes[0];
    view.selected = {kind: "node", node: initial.node};
  }
  setText(byId("self-label"), fleet.self.node + " · " + fleet.self.version + " · mailbox " + ((fleet.self.mailbox || []).join(", ") || "-"));
  renderMetrics(fleet);
  renderMap(fleet);
  renderNodeFilters(fleet);
  renderSessions(fleet);
  renderWatchers(fleet);
  renderStreams(fleet);
  renderLetters(fleet);
  renderDetail(fleet);
  updateDynamicVisuals();
}

function renderMetrics(fleet) {
  const fresh = fleet.nodes.filter((node) => node.state === "fresh").length;
  const listening = fleet.sessions.filter((session) => session.listening).length;
  const rings = fleet.nodes.reduce((total, node) => total + (node.identities || []).reduce((sum, identity) => sum + (identity.pendingRing || 0), 0), 0);
  const silent = fleet.watchers.filter((watcher) => watcher.state === "silent").length;
  const metrics = [
    {key: "nodes", label: "정상 노드", value: fresh + "/" + fleet.nodes.length, context: fresh === fleet.nodes.length ? "모두 fresh" : (fleet.nodes.length - fresh) + "개 확인 필요", tone: fresh === fleet.nodes.length ? "ok" : "danger"},
    {key: "listening", label: "듣는 세션", value: listening, context: "검증된 route", tone: "ok"},
    {key: "rings", label: "대기 ring", value: rings, context: rings ? "응답 필요" : "대기 없음", tone: rings ? "warn" : "ok"},
    {key: "watchers", label: "silent 워처", value: silent, context: silent ? "주기 초과" : "경보 없음", tone: silent ? "danger" : "ok"},
    {key: "snapshot", label: "스냅샷 기준", value: "", context: "5초마다 새로 읽음", tone: "ok", liveAge: 0},
  ];
  reconcile(byId("summary"), metrics, (item) => item.key, createMetric, updateMetric);
}

function createMetric() {
  const card = element("article", "metric");
  card._label = element("span", "metric-label");
  card._value = element("strong", "metric-value");
  card._context = element("span", "metric-context");
  card.append(card._label, card._value, card._context);
  return card;
}

function updateMetric(card, metric) {
  card.className = "metric " + metric.tone;
  setText(card._label, metric.label);
  setText(card._value, metric.value);
  setText(card._context, metric.context);
  if (metric.liveAge !== undefined) {
    card._value.setAttribute("data-age-value", String(metric.liveAge));
  } else {
    card._value.removeAttribute("data-age-value");
  }
}

function fleetPositions(nodes) {
  const compact = window.matchMedia("(max-width: 560px)").matches;
  const centerX = compact ? 210 : 500;
  const centerY = compact ? 245 : 250;
  const hubRadiusX = compact ? 42 : 62;
  const hubRadiusY = compact ? 36 : 52;
  const orbitRadiusX = compact ? 148 : 365;
  const orbitRadiusY = compact ? 160 : 190;
  const positions = new Map();
  const hubs = nodes.filter((node) => node.hub).sort((a, b) => a.node.localeCompare(b.node));
  const peers = nodes.filter((node) => !node.hub).sort((a, b) => a.node.localeCompare(b.node));
  if (hubs.length === 1) {
    positions.set(hubs[0].node, {x: centerX, y: centerY});
  } else {
    hubs.forEach((node, index) => {
      const angle = -Math.PI / 2 + index * Math.PI * 2 / Math.max(1, hubs.length);
      positions.set(node.node, {x: centerX + Math.cos(angle) * hubRadiusX, y: centerY + Math.sin(angle) * hubRadiusY});
    });
  }
  const orbit = peers.length || (hubs.length ? 0 : nodes.length);
  const orbitNodes = peers.length ? peers : nodes;
  orbitNodes.forEach((node, index) => {
    const angle = -Math.PI / 2 + index * Math.PI * 2 / Math.max(1, orbit);
    positions.set(node.node, {x: centerX + Math.cos(angle) * orbitRadiusX, y: centerY + Math.sin(angle) * orbitRadiusY});
  });
  return positions;
}

function linkTier(linkAge) {
  if (typeof linkAge !== "number" || linkAge > 300) return "link-old";
  return linkAge <= 60 ? "link-fresh" : "link-aging";
}

function renderMap(fleet) {
  byId("fleet-map").setAttribute("viewBox", window.matchMedia("(max-width: 560px)").matches ? "0 0 420 500" : "0 0 1000 520");
  const positions = fleetPositions(fleet.nodes);
  const nodesByName = new Map(fleet.nodes.map((node) => [node.node, node]));
  const edges = [];
  for (const node of fleet.nodes) {
    for (const mailbox of node.mailbox || []) {
      if (positions.has(mailbox)) {
        edges.push({key: node.node + "→" + mailbox, from: node.node, to: mailbox, age: node.linkAge});
      }
    }
  }
  reconcile(byId("map-edges"), edges, (edge) => edge.key, createEdge, (group, edge) => updateEdge(group, edge, positions));
  reconcile(byId("map-nodes"), fleet.nodes, (node) => node.node, createMapNode, (group, node) => updateMapNode(group, node, positions.get(node.node)));
  const missingTargets = fleet.nodes.flatMap((node) => (node.mailbox || []).filter((mailbox) => !nodesByName.has(mailbox)));
  byId("map-description").textContent = "허브를 중심으로 " + fleet.nodes.length + "개 노드와 " + edges.length + "개 메일박스 링크, 각 노드의 위성 신원을 표시합니다." + (missingTargets.length ? " 지도에 없는 메일박스 " + missingTargets.join(", ") + "." : "");
}

function createEdge() {
  const group = svgElement("g", "edge-group");
  group._line = svgElement("line", "map-edge");
  group._label = svgElement("text", "edge-label");
  group.append(group._line, group._label);
  return group;
}

function updateEdge(group, edge, positions) {
  const from = positions.get(edge.from);
  const to = positions.get(edge.to);
  const tier = linkTier(edge.age);
  group._line.setAttribute("class", "map-edge " + tier);
  group._line.setAttribute("x1", from.x);
  group._line.setAttribute("y1", from.y);
  group._line.setAttribute("x2", to.x);
  group._line.setAttribute("y2", to.y);
  group._label.setAttribute("x", (from.x + to.x) / 2);
  group._label.setAttribute("y", (from.y + to.y) / 2 - 6);
  setText(group._label, typeof edge.age === "number" ? humanDuration(edge.age) : "?");
}

function createMapNode() {
  const group = svgElement("g", "map-node");
  group.setAttribute("role", "button");
  group.setAttribute("tabindex", "0");
  group._hub = svgElement("circle", "hub-ring");
  group._hub.setAttribute("r", "51");
  group._body = svgElement("circle", "node-body");
  group._body.setAttribute("r", "39");
  group._icon = svgElement("text", "node-icon");
  group._icon.setAttribute("y", "-3");
  group._warning = svgElement("text", "warning-glyph");
  group._warning.setAttribute("x", "36");
  group._warning.setAttribute("y", "-30");
  group._name = svgElement("text", "node-label");
  group._name.setAttribute("y", "63");
  group._state = svgElement("text", "node-state-label");
  group._state.setAttribute("y", "78");
  group._satellites = svgElement("g", "satellites");
  group.append(group._hub, group._body, group._icon, group._warning, group._name, group._state, group._satellites);
  group.addEventListener("click", () => {
    if (!group._node) return;
    view.selected = {kind: "node", node: group._node.node};
    renderMap(view.fleet);
    renderDetail(view.fleet);
  });
  group.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      group.dispatchEvent(new MouseEvent("click", {bubbles: true}));
    }
  });
  return group;
}

function updateMapNode(group, node, position) {
  group._node = node;
  const state = stateClass(node.state, ["fresh", "stale", "stopping", "invalid", "absent"], "invalid");
  const selected = view.selected && view.selected.kind === "node" && view.selected.node === node.node;
  group.setAttribute("class", "map-node state-" + state + (selected ? " selected" : "") + (node.hub ? " hub" : ""));
  group.setAttribute("transform", "translate(" + position.x + " " + position.y + ")");
  group.setAttribute("aria-label", node.node + ", " + state + (node.hub ? ", 허브" : ""));
  group._hub.setAttribute("visibility", node.hub ? "visible" : "hidden");
  setText(group._icon, {fresh: "●", stale: "◐", stopping: "■", invalid: "×", absent: "○"}[state]);
  setText(group._warning, node.complete === false || node.skew > 60 ? "▲" : "");
  setText(group._name, node.node + (node.hub ? " · HUB" : ""));
  setText(group._state, state.toUpperCase());
  const identities = node.identities || [];
  reconcile(group._satellites, identities, (identity) => identity.name, createSatellite, (satellite, identity) => updateSatellite(satellite, identity, node, identities));
}

function createSatellite() {
  const group = svgElement("g", "satellite");
  group.setAttribute("role", "button");
  group.setAttribute("tabindex", "0");
  group._title = svgElement("title");
  group._ring = svgElement("circle", "satellite-ring");
  group._ring.setAttribute("r", "12");
  group._dot = svgElement("circle", "satellite-dot");
  group._dot.setAttribute("r", "7");
  group._count = svgElement("text", "satellite-count");
  group.append(group._title, group._ring, group._dot, group._count);
  group.addEventListener("click", (event) => {
    event.stopPropagation();
    if (!group._identity || !group._node) return;
    view.selected = {kind: "identity", node: group._node.node, name: group._identity.name};
    renderMap(view.fleet);
    renderDetail(view.fleet);
  });
  group.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      event.stopPropagation();
      group.dispatchEvent(new MouseEvent("click", {bubbles: true}));
    }
  });
  return group;
}

function updateSatellite(group, identity, node, identities) {
  group._identity = identity;
  group._node = node;
  const index = identities.indexOf(identity);
  const angle = -Math.PI / 2 + index * Math.PI * 2 / Math.max(1, identities.length);
  const radius = identities.length > 10 ? 57 : 51;
  const x = Math.cos(angle) * radius;
  const y = Math.sin(angle) * radius;
  const selected = view.selected && view.selected.kind === "identity" && view.selected.node === node.node && view.selected.name === identity.name;
  group.setAttribute("transform", "translate(" + x.toFixed(2) + " " + y.toFixed(2) + ")");
  group.setAttribute("class", "satellite " + (identity.listening ? "listening" : "not-listening") + (identity.pendingRing > 0 ? " pending" : "") + (selected ? " selected" : ""));
  group.setAttribute("aria-label", identity.name + ", " + (identity.listening ? "듣는 중" : "듣지 않음") + ", ring " + identity.pendingRing);
  group._ring.setAttribute("visibility", identity.pendingRing > 0 ? "visible" : "hidden");
  setText(group._count, identity.pendingRing > 0 ? identity.pendingRing : "");
  setText(group._title, identity.name + " · " + (identity.listening ? identity.route : identity.reason) + " · ring " + identity.pendingRing);
}

function renderDetail(fleet) {
  const title = byId("detail-title");
  const summary = byId("detail-summary");
  if (!view.selected) {
    setText(title, "노드를 선택하세요");
    setText(summary, "지도에서 노드나 위성 신원을 누르면 현재 상태를 펼칩니다.");
    renderDetailRows([]);
    return;
  }
  const node = fleet.nodes.find((item) => item.node === view.selected.node);
  if (!node) {
    setText(title, view.selected.node);
    setText(summary, "현재 스냅샷에서 이 항목을 찾을 수 없습니다.");
    renderDetailRows([]);
    return;
  }
  if (view.selected.kind === "node") {
    setText(title, node.node + (node.hub ? " · HUB" : ""));
    setText(summary, node.state + " · 신원 " + (node.identities || []).length + "개" + (node.progressing ? " · generation 진행 중" : ""));
    renderDetailRows([
      {label: "상태", value: node.state},
      {label: "허브", value: node.hub ? "예" : "아니오"},
      {label: "스냅샷 나이", value: node.snapshotAge, mode: "age"},
      {label: "작성 시각", value: node.writtenAt, mode: "epoch"},
      {label: "시계 차이", value: typeof node.skew === "number" ? node.skew + "초" : "-"},
      {label: "완전한 스냅샷", value: node.complete === false ? "아니오 · 일부만" : node.complete === true ? "예" : "-"},
      {label: "링크 나이", value: node.linkAge, mode: "age"},
      {label: "메일박스", value: (node.mailbox || []).join(", ") || "-"},
      {label: "컴포넌트", value: (node.components || []).map((item) => item.name + " " + item.release + " · adapter " + item.adapter + " · ears " + item.ears).join(" / ") || "-"},
      {label: "신원", value: (node.identities || []).map((item) => item.name).join(", ") || "-"},
    ]);
    return;
  }
  const identity = (node.identities || []).find((item) => item.name === view.selected.name);
  if (!identity) {
    setText(title, view.selected.name + "@" + node.node);
    setText(summary, "현재 스냅샷에서 이 신원을 찾을 수 없습니다.");
    renderDetailRows([]);
    return;
  }
  setText(title, identity.name + "@" + node.node);
  setText(summary, (identity.listening ? "듣는 중 · " + identity.route : "듣지 않음 · " + identity.reason) + " · " + identity.phase);
  renderDetailRows([
    {label: "주체", value: identity.principal},
    {label: "듣는 중", value: identity.listening ? "예" : "아니오"},
    {label: "경로", value: identity.route},
    {label: "단계", value: identity.phase},
    {label: "Claude Code", value: identity.cc},
    {label: "이유", value: identity.reason},
    {label: "대기 ring", value: identity.pendingRing},
    {label: "대기 info", value: identity.pendingInfo},
    {label: "대기 operator", value: identity.pendingOperator},
    {label: "generation", value: identity.generation},
    {label: "처음 관측", value: identity.firstSeen, mode: "epoch"},
    {label: "가장 오래된 대기", value: identity.oldestPending, mode: "epoch"},
    {label: "쓴 ring", value: identity.writtenRings},
    {label: "마지막 초인종", value: identity.lastWritten, mode: "epoch"},
    {label: "마지막 drain", value: identity.lastDrain, mode: "epoch"},
    {label: "drain 이전", value: identity.lastDrainBefore},
    {label: "drain 이후", value: identity.lastDrainAfter},
    {label: "drain 상태", value: identity.lastDrainStatus},
  ]);
}

function renderDetailRows(rows) {
  reconcile(byId("detail-rows"), rows, (row) => row.label, () => {
    const row = element("div", "detail-row");
    row._term = element("span", "detail-term");
    row._value = element("p", "detail-value");
    row.append(row._term, row._value);
    return row;
  }, (node, row) => {
    setText(node._term, row.label);
    node._value.removeAttribute("data-age-value");
    node._value.removeAttribute("data-age-epoch");
    if (row.mode === "age" && typeof row.value === "number") {
      node._value.setAttribute("data-age-value", row.value);
    } else if (row.mode === "epoch" && typeof row.value === "number") {
      node._value.setAttribute("data-age-epoch", row.value);
    } else {
      setText(node._value, row.value);
    }
  });
}

function sessionNode(address) {
  const index = address.lastIndexOf("@");
  return index >= 0 ? address.slice(index + 1) : "-";
}

function pendingTotal(session) {
  const pending = session.pendingByClass || {};
  return (pending.ring || 0) + (pending.info || 0) + (pending.operator || 0);
}

function isStaleClutter(session) {
  const age = epochAge(session.lastSeen);
  return session.state === "unknown" || age === null || age > HIDDEN_AFTER;
}

function renderNodeFilters(fleet) {
  const nodes = fleet.nodes.map((node) => node.node);
  if (view.node && !nodes.includes(view.node)) view.node = "";
  const filters = [{node: "", label: "모든 노드"}].concat(nodes.map((node) => ({node, label: node})));
  reconcile(byId("node-filters"), filters, (filter) => filter.node || "__all", () => {
    const button = element("button", "chip");
    button.type = "button";
    button.addEventListener("click", () => {
      view.node = button._node;
      renderNodeFilters(view.fleet);
      renderSessions(view.fleet);
    });
    return button;
  }, (button, filter) => {
    button._node = filter.node;
    button.setAttribute("aria-pressed", String(view.node === filter.node));
    setText(button, filter.label);
  });
}

function renderSessions(fleet) {
  const hiddenCount = fleet.sessions.filter(isStaleClutter).length;
  setText(byId("toggle-hidden"), "전체 보기 (+" + hiddenCount + ")");
  byId("toggle-hidden").setAttribute("aria-pressed", String(view.showAll));
  byId("filter-listening").setAttribute("aria-pressed", String(view.listeningOnly));
  byId("filter-pending").setAttribute("aria-pressed", String(view.pendingOnly));
  byId("sort-sessions").setAttribute("aria-pressed", String(!view.newestFirst));
  setText(byId("sort-sessions"), view.newestFirst ? "최근 본 순" : "오래된 순");

  let sessions = fleet.sessions.filter((session) => view.showAll || !isStaleClutter(session));
  if (view.listeningOnly) sessions = sessions.filter((session) => session.listening);
  if (view.pendingOnly) sessions = sessions.filter((session) => pendingTotal(session) > 0);
  if (view.node) sessions = sessions.filter((session) => sessionNode(session.address) === view.node);
  sessions.sort((left, right) => {
    const order = (right.lastSeen || 0) - (left.lastSeen || 0) || left.address.localeCompare(right.address);
    return view.newestFirst ? order : -order;
  });

  const nodeOrder = fleet.nodes.map((node) => node.node);
  const grouped = new Map();
  for (const session of sessions) {
    const node = sessionNode(session.address);
    if (!grouped.has(node)) grouped.set(node, []);
    grouped.get(node).push(session);
  }
  const groups = Array.from(grouped, ([node, items]) => ({node, items})).sort((left, right) => {
    const li = nodeOrder.indexOf(left.node);
    const ri = nodeOrder.indexOf(right.node);
    return (li < 0 ? 9999 : li) - (ri < 0 ? 9999 : ri) || left.node.localeCompare(right.node);
  });
  reconcile(byId("session-board"), groups, (group) => group.node, createSessionGroup, updateSessionGroup);
  byId("session-empty").hidden = groups.length > 0;
  updateDynamicVisuals();
}

function createSessionGroup() {
  const group = element("section", "session-group");
  const heading = element("div", "group-heading");
  group._title = element("h3");
  group._count = element("span", "group-count");
  heading.append(group._title, group._count);
  group._grid = element("div", "session-grid");
  group.append(heading, group._grid);
  return group;
}

function updateSessionGroup(group, item) {
  setText(group._title, item.node);
  setText(group._count, item.items.length + "개 세션");
  reconcile(group._grid, item.items, (session) => session.address, createSessionTile, updateSessionTile);
}

function createSessionTile() {
  const tile = element("article", "session-tile");
  const head = element("div", "session-head");
  tile._name = element("span", "session-name");
  tile._presence = element("span", "presence-mark");
  head.append(tile._name, tile._presence);
  const seen = element("div", "seen-line");
  const seenTrack = element("span", "track");
  tile._seenFill = element("span", "fill seen-fill");
  seenTrack.append(tile._seenFill);
  tile._seenAge = element("span", "seen-age");
  seen.append(seenTrack, tile._seenAge);
  tile._route = element("div", "route-line");
  tile._pendingBars = element("div", "pending-bars");
  tile._pendingState = element("span", "pending-state");
  tile._meta = element("div", "session-meta");
  tile._model = element("span");
  tile._role = element("span");
  tile._charge = element("span");
  tile._focus = element("span");
  tile._meta.append(tile._model, tile._role, tile._charge, tile._focus);
  tile.append(head, seen, tile._route, tile._pendingBars, tile._pendingState, tile._meta);
  return tile;
}

function updateSessionTile(tile, session) {
  const state = stateClass(session.state, ["alive-here", "alive-elsewhere", "asleep", "unknown"], "unknown");
  tile.className = "session-tile state-" + state;
  setText(tile._name, session.address.slice(0, Math.max(0, session.address.lastIndexOf("@"))));
  const presence = {
    "alive-here": "⌂ 여기서 활동",
    "alive-elsewhere": "↗ 다른 노드 활동",
    asleep: "◐ 잠듦",
    unknown: "? 알 수 없음",
  };
  setText(tile._presence, presence[state]);
  tile._seenFill.setAttribute("data-seen-epoch", session.lastSeen || 0);
  tile._seenAge.setAttribute("data-age-epoch", session.lastSeen || 0);
  const routeIcon = {socket: "↔", channel: "⌁", "channel+socket": "⇄", none: "⊘", "-": "⊘"}[session.route] || "·";
  tile._route.className = "route-line" + (session.listening ? " listening" : "");
  setText(tile._route, routeIcon + " " + (session.listening ? "듣는 중 · " + session.route : "듣지 않음 · " + session.reason));
  const pending = session.pendingByClass || {ring: 0, info: 0, operator: 0};
  const classes = [
    {key: "ring", label: "R", count: pending.ring || 0},
    {key: "info", label: "I", count: pending.info || 0},
    {key: "operator", label: "O", count: pending.operator || 0},
  ];
  reconcile(tile._pendingBars, classes, (item) => item.key, createPendingBar, updatePendingBar);
  const pendingLabels = {
    empty: "비어 있음",
    "seen-but-left": "보고도 남김",
    "no-new-since-drain": "drain 뒤 새 대기 없음",
    "new-since-drain": "drain 뒤 새 대기",
  };
  setText(tile._pendingState, pendingLabels[session.pendingState] || session.pendingState);
  tile._pendingState.className = "pending-state" + (session.pendingState === "empty" ? "" : " attention");
  setText(tile._model, "모델 " + text(session.model) + " · 노력 " + text(session.effort));
  setText(tile._role, "역할 " + text(session.role));
  setText(tile._charge, "담당 " + text(session.charge));
  setText(tile._focus, "초점 " + text(session.focus));
}

function createPendingBar() {
  const item = element("div", "pending-item");
  const label = element("span", "pending-label");
  item._name = element("span");
  item._count = element("span");
  label.append(item._name, item._count);
  const track = element("div", "pending-track");
  item._fill = element("span", "pending-fill");
  track.append(item._fill);
  item.append(label, track);
  return item;
}

function updatePendingBar(item, pending) {
  item.className = "pending-item pending-" + pending.key;
  setText(item._name, pending.label);
  setText(item._count, pending.count);
  item._fill.style.width = (pending.count > 0 ? Math.min(100, 24 + Math.log2(pending.count + 1) * 23) : 0) + "%";
}

function renderWatchers(fleet) {
  const grouped = new Map();
  for (const watcher of fleet.watchers) {
    if (!grouped.has(watcher.node)) grouped.set(watcher.node, []);
    grouped.get(watcher.node).push(watcher);
  }
  const groups = Array.from(grouped, ([node, items]) => ({node, items}));
  if (!groups.length) {
    reconcile(byId("watcher-board"), [{node: "__empty", items: []}], (group) => group.node, () => element("p", "empty-state"), (node) => setText(node, "워처 없음"));
    return;
  }
  reconcile(byId("watcher-board"), groups, (group) => group.node, createWatcherGroup, updateWatcherGroup);
}

function createWatcherGroup(item) {
  if (item.node === "__empty") return element("p", "empty-state");
  const group = element("section", "watcher-group");
  group._heading = element("div", "group-heading");
  group._title = element("h3");
  group._heading.append(group._title);
  group._grid = element("div", "watcher-grid");
  group.append(group._heading, group._grid);
  return group;
}

function updateWatcherGroup(group, item) {
  if (item.node === "__empty") {
    setText(group, "워처 없음");
    return;
  }
  setText(group._title, item.node);
  reconcile(group._grid, item.items, (watcher) => watcher.name + "@" + watcher.node, createWatcherGauge, updateWatcherGauge);
}

function createWatcherGauge() {
  const gauge = element("article", "watcher-gauge");
  const head = element("div", "gauge-head");
  gauge._name = element("span", "gauge-name");
  gauge._value = element("span", "gauge-value");
  head.append(gauge._name, gauge._value);
  gauge._owner = element("p", "gauge-owner");
  const track = element("div", "gauge-track");
  gauge._fill = element("span", "gauge-fill");
  track.append(gauge._fill);
  gauge.append(head, gauge._owner, track);
  return gauge;
}

function updateWatcherGauge(gauge, watcher) {
  setText(gauge._name, watcher.name);
  setText(gauge._owner, "owner " + watcher.owner + " · " + humanDuration(watcher.cadence) + " 주기");
  gauge.setAttribute("data-watcher-last", watcher.last);
  gauge.setAttribute("data-watcher-cadence", watcher.cadence);
  gauge.setAttribute("data-watcher-state", watcher.state);
}

function renderStreams(fleet) {
  if (!fleet.streams.length) {
    reconcile(byId("stream-board"), [{name: "__empty"}], (stream) => stream.name, () => element("p", "empty-state"), (node) => setText(node, "스트림 없음"));
    return;
  }
  const maxEntries = Math.max(1, ...fleet.streams.map((stream) => stream.entries));
  reconcile(byId("stream-board"), fleet.streams, (stream) => stream.name, createStreamCard, (card, stream) => updateStreamCard(card, stream, maxEntries));
}

function createStreamCard(stream) {
  if (stream.name === "__empty") return element("p", "empty-state");
  const card = element("article", "stream-card");
  const head = element("div", "bar-head");
  card._name = element("span", "stream-name");
  card._value = element("span", "bar-value");
  head.append(card._name, card._value);
  const track = element("div", "stream-track");
  card._fill = element("span", "stream-fill");
  track.append(card._fill);
  card._latest = element("p", "stream-latest");
  card._unread = element("div", "unread-list");
  card._feedTitle = element("p", "feed-title");
  card._feed = element("div", "stream-feed");
  card.append(head, track, card._latest, card._unread, card._feedTitle, card._feed);
  return card;
}

function updateStreamCard(card, stream, maxEntries) {
  if (stream.name === "__empty") {
    setText(card, "스트림 없음");
    return;
  }
  setText(card._name, stream.name);
  setText(card._value, stream.entries + " entries");
  card._fill.style.width = Math.max(2, stream.entries / maxEntries * 100) + "%";
  setText(card._latest, "latest " + stream.latest);
  const unread = Object.entries(stream.localUnread || {}).map(([identity, count]) => ({identity, count})).sort((left, right) => right.count - left.count || left.identity.localeCompare(right.identity));
  reconcile(card._unread, unread, (item) => item.identity, createUnreadBar, (row, item) => updateUnreadBar(row, item, Math.max(1, stream.entries)));
  const recent = Array.isArray(stream.recent) ? stream.recent : [];
  card._feedTitle.hidden = recent.length === 0;
  setText(card._feedTitle, recent.length ? "최근 항목" : "");
  reconcile(card._feed, recent, (entry) => entry.id, createFeedEntry, updateFeedEntry);
}

function createUnreadBar() {
  const row = element("div", "unread-row");
  row._name = element("span", "unread-name");
  const track = element("div", "unread-track");
  row._fill = element("span", "unread-fill");
  track.append(row._fill);
  row._count = element("span", "unread-count");
  row.append(row._name, track, row._count);
  return row;
}

function updateUnreadBar(row, item, total) {
  setText(row._name, item.identity);
  setText(row._count, item.count);
  row._fill.style.width = (item.count ? Math.max(3, item.count / total * 100) : 0) + "%";
}

function createFeedEntry() {
  const entry = element("article", "feed-entry");
  const head = element("div", "feed-entry-head");
  entry._subject = element("span", "feed-entry-subject");
  entry._date = element("span", "feed-entry-date");
  head.append(entry._subject, entry._date);
  entry._meta = element("p", "feed-entry-meta");
  entry._body = element("pre", "feed-entry-body");
  entry.append(head, entry._meta, entry._body);
  return entry;
}

function updateFeedEntry(node, entry) {
  setText(node._subject, entry.subject);
  setText(node._date, entry.date);
  setText(node._meta, entry.from + " · " + entry.id);
  setText(node._body, entry.body);
}

function renderLetters(fleet) {
  const section = byId("letters-section");
  section.hidden = !Array.isArray(fleet.letters);
  if (!Array.isArray(fleet.letters)) return;
  if (!fleet.letters.length) {
    reconcile(byId("letter-feed"), [{key: "__empty"}], (item) => item.key, () => element("p", "empty-state"), (node) => setText(node, "편지 없음"));
    return;
  }
  reconcile(byId("letter-feed"), fleet.letters, (letter) => letter.identity + "/" + letter.id, createLetterItem, updateLetterItem);
}

function createLetterItem(letter) {
  if (letter.key === "__empty") return element("p", "empty-state");
  const button = element("button", "letter-item");
  button.type = "button";
  button._subject = element("span", "letter-subject");
  button._meta = element("span", "letter-meta");
  button._route = element("span");
  button._age = element("span");
  button._meta.append(button._route, button._age);
  button.append(button._subject, button._meta);
  button.addEventListener("click", () => {
    if (!button._letter) return;
    loadLetter(button._letter);
  });
  return button;
}

function updateLetterItem(button, letter) {
  if (letter.key === "__empty") {
    setText(button, "편지 없음");
    return;
  }
  button._letter = letter;
  const key = letter.identity + "/" + letter.id;
  button.className = "letter-item" + (view.selectedLetter === key ? " selected" : "");
  setText(button._subject, (letter.urgency ? "[" + letter.urgency + "] " : "") + letter.subject);
  setText(button._route, letter.from + " → " + letter.identity + " · " + letter.state + " · ");
  button._age.setAttribute("data-age-value", letter.age);
}

async function loadLetter(letter) {
  const key = letter.identity + "/" + letter.id;
  view.selectedLetter = key;
  renderLetters(view.fleet);
  setText(byId("letter-reader-title"), letter.subject + " · " + letter.from);
  setText(byId("letter-body"), "읽는 중…");
  const target = "/api/v1/letter?identity=" + encodeURIComponent(letter.identity) + "&id=" + encodeURIComponent(letter.id);
  try {
    const response = await fetch(target, {headers: authHeaders(), cache: "no-store"});
    setText(byId("letter-body"), response.ok ? await response.text() : "편지를 읽지 못했습니다 (" + response.status + ")");
  } catch (_) {
    setText(byId("letter-body"), "편지를 읽지 못했습니다 (네트워크 연결 없음)");
  }
}

function updateDynamicVisuals() {
  const elapsed = elapsedSinceFetch();
  for (const node of document.querySelectorAll("[data-age-value]")) {
    const base = Number(node.getAttribute("data-age-value"));
    setText(node, humanDuration(base + elapsed) + " 전");
  }
  for (const node of document.querySelectorAll("[data-age-epoch]")) {
    const epoch = Number(node.getAttribute("data-age-epoch"));
    const age = epochAge(epoch);
    setText(node, age === null ? "본 적 없음" : humanDuration(age) + " 전");
  }
  for (const fill of document.querySelectorAll("[data-seen-epoch]")) {
    const age = epochAge(Number(fill.getAttribute("data-seen-epoch")));
    const freshness = age === null ? 0 : Math.max(0, 100 * (1 - Math.log(age + 1) / Math.log(DECAY_CAP + 1)));
    fill.style.width = freshness.toFixed(1) + "%";
  }
  for (const gauge of document.querySelectorAll("[data-watcher-last]")) {
    const age = Math.max(0, currentEpoch() - Number(gauge.getAttribute("data-watcher-last")));
    const cadence = Number(gauge.getAttribute("data-watcher-cadence"));
    const ratio = cadence > 0 ? age / cadence : 1;
    gauge._fill.style.width = Math.min(100, ratio * 100).toFixed(1) + "%";
    setText(gauge._value, Math.round(ratio * 100) + "% · " + humanDuration(age) + " 전");
    gauge.classList.toggle("alarm", ratio > 1 || gauge.getAttribute("data-watcher-state") === "silent");
  }
  if (view.fleet) setText(byId("fleet-clock"), humanDuration(elapsed) + " 전 생성 · " + new Date(view.fleet.generatedAt * 1000).toLocaleTimeString("ko-KR"));
}

function showError(error) {
  const banner = byId("error-banner");
  const message = error.message === "fleet 401"
    ? "인증이 만료되었습니다. 새 dashboard URL로 다시 여세요."
    : "함대 데이터를 새로 읽지 못했습니다. 마지막 정상 화면을 유지합니다. (" + error.message + ")";
  setText(banner, message);
  banner.hidden = false;
}

function hideError() {
  byId("error-banner").hidden = true;
}

byId("filter-listening").addEventListener("click", () => {
  view.listeningOnly = !view.listeningOnly;
  if (view.fleet) renderSessions(view.fleet);
});
byId("filter-pending").addEventListener("click", () => {
  view.pendingOnly = !view.pendingOnly;
  if (view.fleet) renderSessions(view.fleet);
});
byId("toggle-hidden").addEventListener("click", () => {
  view.showAll = !view.showAll;
  if (view.fleet) renderSessions(view.fleet);
});
byId("sort-sessions").addEventListener("click", () => {
  view.newestFirst = !view.newestFirst;
  if (view.fleet) renderSessions(view.fleet);
});

loadFleet().catch(showError);
setInterval(() => loadFleet().catch(showError), 5000);
setInterval(updateDynamicVisuals, 1000);
window.addEventListener("resize", () => {
  if (view.fleet) renderMap(view.fleet);
});
