"use strict";

let dashboardToken = decodeURIComponent(window.location.hash.slice(1));
history.replaceState(null, "", window.location.pathname + window.location.search);

const byId = (id) => document.getElementById(id);
const text = (value) => String(value === null || value === undefined || value === "" ? "-" : value);
const age = (value) => typeof value === "number" && value >= 0 ? String(value) + "s" : "-";
const since = (value) => typeof value === "number" && value > 0 ? String(Math.max(0, Math.floor(Date.now() / 1000 - value))) + "s" : "-";

function element(tag, value, className) {
  const node = document.createElement(tag);
  if (value !== undefined) node.textContent = text(value);
  if (className) node.className = className;
  return node;
}

function clear(node) {
  node.replaceChildren();
}

function authHeaders() {
  return {Authorization: "Bearer " + dashboardToken};
}

async function loadFleet() {
  const response = await fetch("/api/v1/fleet", {headers: authHeaders(), cache: "no-store"});
  if (!response.ok) throw new Error("fleet " + response.status);
  render(await response.json());
}

function render(fleet) {
  const current = fleet.nodes.filter((node) => node.state === "fresh").flatMap((node) => node.identities || []);
  const listening = current.filter((identity) => identity.listening).length;
  const rings = current.reduce((sum, identity) => sum + identity.pendingRing, 0);
  const silent = fleet.watchers.filter((watcher) => watcher.state === "silent").length;
  const fresh = fleet.nodes.filter((node) => node.state === "fresh").length;
  byId("summary").textContent = "노드 " + fresh + "/" + fleet.nodes.length + " · 듣는 세션 " + listening + " · 대기 ring " + rings + " · silent 워처 " + silent + " · " + Math.max(0, Math.floor(Date.now() / 1000 - fleet.generatedAt)) + "초 전 기준";
  renderNodes(fleet);
  renderTable(byId("watchers"), ["name", "node", "owner", "cadence", "last", "state", "since"], fleet.watchers);
  renderTable(byId("streams"), ["name", "entries", "latest", "localUnread"], fleet.streams);
  const lettersSection = byId("letters-section");
  lettersSection.hidden = !Array.isArray(fleet.letters);
  if (Array.isArray(fleet.letters)) renderLetters(fleet.letters);
}

function renderNodes(fleet) {
  const host = byId("nodes");
  clear(host);
  const sessions = new Map(fleet.sessions.map((session) => [session.address, session]));
  for (const node of fleet.nodes) {
    const card = element("article");
    const heading = element("h3", node.node);
    if (node.hub) heading.append(" ", element("span", "hub", "badge"));
    card.append(heading);
    const releases = (node.components || []).map((component) => component.name + " " + component.release).join(", ");
    let status = node.state + " · link " + age(node.linkAge) + " · release " + text(releases) + " · snapshot " + age(node.snapshotAge);
    if (node.skew > 60) status += " · clock-ahead " + node.skew + "s";
    if (node.complete === false) status += " · 일부만";
    if (node.progressing) status += " · progressing";
    card.append(element("p", status));
    const list = element("ul");
    for (const identity of node.identities || []) {
      const session = sessions.get(identity.name + "@" + node.node) || {};
      const item = element("li");
      item.append(element("strong", identity.name));
      item.append(element("span", session.state || "unknown", "badge"));
      item.append(element("span", identity.listening ? "✓ " + identity.route : identity.reason));
      item.append(element("span", text(session.model) + "/" + text(session.effort)));
      item.append(element("span", text(session.role) + " · " + text(session.charge)));
      if (session.focus) item.append(element("span", session.focus));
      item.append(element("small", "ring " + identity.pendingRing + ", info " + identity.pendingInfo + ", bell " + since(identity.lastWritten) + ", drain " + since(identity.lastDrain) + ", pending " + text(session.pendingState) + ", seen " + since(session.lastSeen)));
      list.append(item);
    }
    if (!list.childNodes.length) list.append(element("li", "세션 정보 없음"));
    card.append(list);
    host.append(card);
  }
  if (!host.childNodes.length) host.append(element("p", "노드 정보 없음"));
}

function renderTable(host, columns, rows) {
  clear(host);
  if (!rows.length) {
    host.append(element("p", "항목 없음"));
    return;
  }
  const table = element("table");
  const headRow = element("tr");
  for (const column of columns) headRow.append(element("th", column));
  const head = element("thead");
  head.append(headRow);
  table.append(head);
  const body = element("tbody");
  for (const row of rows) {
    const tableRow = element("tr");
    for (const column of columns) {
      const value = typeof row[column] === "object" && row[column] !== null ? JSON.stringify(row[column]) : row[column];
      tableRow.append(element("td", value));
    }
    body.append(tableRow);
  }
  table.append(body);
  host.append(table);
}

function renderLetters(letters) {
  const host = byId("letters");
  clear(host);
  if (!letters.length) {
    host.append(element("p", "편지 없음"));
    return;
  }
  const table = element("table");
  const body = element("tbody");
  for (const letter of letters) {
    const row = element("tr");
    for (const key of ["identity", "id", "from", "date", "type", "urgency", "subject", "state", "age"]) row.append(element("td", letter[key]));
    row.addEventListener("click", () => loadLetter(letter.identity, letter.id));
    body.append(row);
  }
  table.append(body);
  host.append(table);
}

async function loadLetter(identity, id) {
  const target = "/api/v1/letter?identity=" + encodeURIComponent(identity) + "&id=" + encodeURIComponent(id);
  const response = await fetch(target, {headers: authHeaders(), cache: "no-store"});
  byId("letter-body").textContent = response.ok ? await response.text() : "편지를 읽지 못했습니다 (" + response.status + ")";
}

function showError(error) {
  byId("summary").textContent = error.message;
}

loadFleet().catch(showError);
setInterval(() => loadFleet().catch(showError), 5000);
