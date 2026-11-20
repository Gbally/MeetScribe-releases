// Hesper's pages: the popover (#home), a meeting (#meeting/ID), Settings (#settings/PANE) and the
// first launch (#welcome). The app (C#) holds the recorder, the engine and the files; this asks
// it things with call(cmd, args) and redraws on its "state" / "live" events.
"use strict";

// ---------- bridge ----------
const host = window.chrome?.webview;
let nextId = 1;
const waiting = new Map();
function call(cmd, args = {}) {
  if (!host) return Promise.resolve(null);  // opened in a plain browser (design preview)
  const id = nextId++;
  return new Promise((resolve, reject) => {
    waiting.set(id, { resolve, reject });
    host.postMessage({ id, cmd, args });
  });
}
const handlers = {};
host?.addEventListener("message", e => {
  const m = e.data;
  if (m.id && waiting.has(m.id)) {
    const w = waiting.get(m.id); waiting.delete(m.id);
    m.error ? w.reject(new Error(m.error)) : w.resolve(m.result);
  } else if (m.event) handlers[m.event]?.(m.data);
});

// ---------- translations (the Mac app's: English text → translation) ----------
let words = {};
const LANGS = { en: "English", fr: "Français", es: "Español", pt: "Português", ja: "日本語", "zh-Hans": "简体中文" };
// Windows-only texts (English key → translation), in i18n-windows.json; the Mac files have the rest
let winWords = {};
function tr(key, ...args) {
  let s = words[key] ?? winWords[key] ?? key;
  for (const a of args) s = s.replace("%@", a);
  return s;
}
let lang = "en";
async function loadLanguage(settings) {
  const want = settings?.AppLanguage || navigator.language;
  lang = want.startsWith("zh") ? "zh-Hans" : Object.keys(LANGS).find(l => want.toLowerCase().startsWith(l)) ?? "en";
  words = lang === "en" ? {} : (await call("i18n", { lang })) ?? {};
  winWords = lang === "en" ? {} : (await fetch("i18n-windows.json").then(r => r.json()).catch(() => ({})))[lang] ?? {};
  document.documentElement.lang = lang;
}

// ---------- helpers ----------
const $ = sel => document.querySelector(sel);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const locale = () => (lang === "zh-Hans" ? "zh-CN" : lang);
function fmtDuration(sec) {
  sec = Math.max(0, Math.round(sec || 0));
  const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}
const fmtDate = iso => new Date(iso).toLocaleString(locale(), { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
const fmtTime = sec => { sec = Math.floor(sec); return `${String(Math.floor(sec / 60)).padStart(2, "0")}:${String(sec % 60).padStart(2, "0")}`; };
const isToday = iso => new Date(iso).toDateString() === new Date().toDateString();
const meetingTitle = m => m.title || tr("Meeting");

// Icons: the brand glyph (star over a horizon line, 18-unit box) and a few line icons
const STAR = "M9 2Q9 7 14 7Q9 7 9 12Q9 7 4 7Q9 7 9 2Z";
const glyph = (color = "currentColor", outlined = false) =>
  `<svg viewBox="0 0 18 18"><path d="${STAR}" ${outlined ? `fill="none" stroke="${color}" stroke-width="1.1"` : `fill="${color}"`}/><rect x="2" y="14.2" width="14" height="1.6" rx=".8" fill="${color}"/></svg>`;
const appIcon = size => `<svg width="${size}" height="${size}" viewBox="0 0 100 100" aria-label="Hesper">
  <defs><clipPath id="sq${size}"><rect width="100" height="100" rx="22"/></clipPath></defs>
  <rect width="100" height="100" rx="22" fill="#1B1F2E"/>
  <g clip-path="url(#sq${size})"><circle cx="50" cy="132" r="64" fill="#2E3550" stroke="rgba(242,181,68,.9)" stroke-width="2.2"/></g>
  <path d="M50 22Q50 38 64 38Q50 38 50 54Q50 38 36 38Q50 38 50 22Z" fill="#F2B544"/></svg>`;
const ICONS = {
  gear: '<path d="M6.9 1.5h2.2l.4 1.9 1.3.6 1.7-1 1.5 1.5-1 1.7.6 1.3 1.9.4v2.2l-1.9.4-.6 1.3 1 1.7-1.5 1.5-1.7-1-1.3.6-.4 1.9H6.9l-.4-1.9-1.3-.6-1.7 1-1.5-1.5 1-1.7-.6-1.3-1.9-.4V6.9l1.9-.4.6-1.3-1-1.7 1.5-1.5 1.7 1 1.3-.6z"/><circle cx="8" cy="8" r="2.2"/>',
  more: '<circle cx="3.5" cy="8" r=".9" fill="currentColor"/><circle cx="8" cy="8" r=".9" fill="currentColor"/><circle cx="12.5" cy="8" r=".9" fill="currentColor"/>',
  search: '<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14"/>',
  list: '<path d="M5.5 4h8M5.5 8h8M5.5 12h8"/><circle cx="2.5" cy="4" r=".6" fill="currentColor"/><circle cx="2.5" cy="8" r=".6" fill="currentColor"/><circle cx="2.5" cy="12" r=".6" fill="currentColor"/>',
  check: '<path d="M2 4.5l1.5 1.5L6 3.5M2 10.5l1.5 1.5L6 9.5M8.5 5h5.5M8.5 11h5.5"/>',
  doc: '<path d="M4 1.5h5.5L12.5 4.5v10h-8.5z" fill="currentColor" stroke="none"/><path d="M6 8h4.5M6 10.5h4.5" stroke="var(--bg)"/>',
  wave: '<path d="M2 8h1.5M5 5v6M8 3v10M11 5.5v5M14 8h-1"/>',
  warn: '<path d="M8 2 15 14H1z" fill="currentColor" stroke="none"/><path d="M8 6.5v3.5M8 12v.2" stroke="var(--bg)"/>',
  chevron: '<path d="M6 3.5 10.5 8 6 12.5"/>',
  mic: '<rect x="5.5" y="1.5" width="5" height="8" rx="2.5"/><path d="M3 7.5a5 5 0 0 0 10 0M8 12.5v2"/>',
  speaker: '<path d="M2 6h2.5L8 3v10L4.5 10H2z"/><path d="M10.5 5.5a3.5 3.5 0 0 1 0 5M12.5 3.5a6.5 6.5 0 0 1 0 9"/>',
  person: '<circle cx="8" cy="5.5" r="2.8"/><path d="M2.5 14.5c.8-3 3-4.5 5.5-4.5s4.7 1.5 5.5 4.5"/>',
  bell: '<path d="M4 11V7a4 4 0 0 1 8 0v4l1.5 1.5h-11zM6.5 14a1.6 1.6 0 0 0 3 0"/>',
  lock: '<rect x="3" y="7" width="10" height="7.5" rx="1.5"/><path d="M5 7V5a3 3 0 0 1 6 0v2"/>',
  cpu: '<rect x="4" y="4" width="8" height="8" rx="1"/><path d="M6 1.5v2.5M10 1.5v2.5M6 12v2.5M10 12v2.5M1.5 6h2.5M1.5 10h2.5M12 6h2.5M12 10h2.5"/>',
  voices: '<circle cx="6" cy="5.5" r="2.5"/><path d="M1.5 14c.6-2.5 2.4-4 4.5-4s3.9 1.5 4.5 4M11.5 4.5a3 3 0 0 1 0 4.5M13.5 2.5a6 6 0 0 1 0 8.5"/>',
  info: '<circle cx="8" cy="8" r="6.5"/><path d="M8 7.5v4M8 5v.2"/>',
};
const icon = (name, cls = "icon") => `<svg class="${cls}" viewBox="0 0 16 16">${ICONS[name]}</svg>`;

let state = null;
async function refresh() { state = await call("state"); }

// Menus (⋯): items = [{label, action, danger, disabled} | "-"]
function openMenu(anchor, items, x = null, y = null) {
  closeMenu();
  const m = document.createElement("div");
  m.className = "menu";
  m.innerHTML = items.map((it, i) => it === "-" ? "<hr>" :
    `<button data-i="${i}" class="${it.danger ? "danger" : ""}" ${it.disabled ? "disabled" : ""}>${esc(it.label)}</button>`).join("");
  document.body.appendChild(m);
  const r = anchor.getBoundingClientRect();
  m.style.top = Math.max(6, Math.min(y ?? r.bottom + 4, innerHeight - m.offsetHeight - 6)) + "px";
  m.style.left = Math.max(6, Math.min(x ?? r.right - m.offsetWidth, innerWidth - m.offsetWidth - 6)) + "px";
  m.onclick = e => { const b = e.target.closest("button"); if (b) { closeMenu(); items[b.dataset.i].action(); } };
  setTimeout(() => addEventListener("click", closeMenu, { once: true }), 0);
}
function closeMenu() { document.querySelectorAll(".menu").forEach(m => m.remove()); }

function dueBadge(a, done) {
  if (!a.due_date && !a.due) return "";
  let cls = "";
  if (a.due_date && !done) {
    const days = (new Date(a.due_date + "T00:00") - new Date(new Date().toDateString())) / 864e5;
    cls = days < 0 ? "late" : days <= 1 ? "soon" : "";
  }
  const text = a.due_date ? new Date(a.due_date + "T00:00").toLocaleDateString(locale(), { weekday: "short", day: "numeric", month: "short" }) : a.due;
  return `<span class="due ${cls}">${esc(text)}</span>`;
}
const mine = a => {
  const me = (state?.settings?.MyName || "").trim().toLowerCase();
  return me && a.owner.toLowerCase().split(/[\s,&+]+/).some(w => w && me.split(/\s+/)[0] === w);
};
function openTodos(m) { return (m.actions || []).map((a, i) => ({ a, i, m })).filter(t => !m.done.includes(t.i)); }

// ============================================================ asking inside the page
// A small dialog in the page (a system one would take the focus from the popover and close it).
function ask(title, body, ok, danger = false, cancel = tr("Cancel")) {
  return new Promise(resolve => {
    const d = document.createElement("div");
    d.className = "overlay";
    d.innerHTML = `<div class="dialog"><b>${esc(title)}</b>${body ? `<div class="caption">${esc(body)}</div>` : ""}
      <div class="row"><span class="grow"></span><button class="btn" data-a="0">${esc(cancel)}</button>
      <button class="btn ${danger ? "danger" : "primary"}" data-a="1">${esc(ok)}</button></div></div>`;
    document.body.appendChild(d);
    d.onclick = e => { const a = e.target.closest("[data-a]")?.dataset.a; if (a != null || e.target === d) { d.remove(); resolve(a === "1"); } };
  });
}

// ============================================================ the popover
let tab = "today", search = "", hits = null, homeView = "home", template = null, todoMine = true, todoShowDone = false;

function renderHome() {
  document.title = "Hesper";
  const upd = state?.update?.available;
  $("#app").innerHTML = `
  <div class="popover">
    <div class="pop-header">
      ${homeView !== "home" ? `<button class="icon-btn" id="back" title="${L("Back")}">‹</button>` : appIcon(30)}
      <div class="grow">
        ${homeView === "todos" ? `<div class="headline">${L("To-dos")}</div>` : homeView.startsWith("brief/") ? `<div class="headline">${L("Still open")}</div>` : `
        <div class="headline">${esc(new Date().toLocaleDateString(locale(), { weekday: "long" }).replace(/^./, c => c.toUpperCase()))}</div>
        <div class="caption">${esc(new Date().toLocaleDateString(locale(), { day: "numeric", month: "long" }))}</div>`}
      </div>
      ${upd ? `<button class="badge" id="update" title="${L("A new version of Hesper is available")}">${L("Update")}</button>` : ""}
      <button class="icon-btn" id="gear" title="${L("Settings")}">${icon("gear")}</button>
      <button class="icon-btn" id="more" title="${L("More")}">${icon("more")}</button>
    </div>
    <hr>
    <div class="pop-scroll" id="content"></div>
    ${homeView === "home" ? `<div class="pop-footer">
      <div class="search">${icon("search")}<input id="q" placeholder="${L("Search or ask")}" value="${esc(search)}" spellcheck="false"></div>
      <div class="tabs" id="tabs"></div>
    </div>` : ""}
  </div>`;
  $("#back") && ($("#back").onclick = () => { homeView = "home"; renderHome(); });
  $("#update") && ($("#update").onclick = () => call("openSettings", { pane: "about" }));
  $("#gear").onclick = () => call("openSettings", { pane: "" });
  $("#more").onclick = e => { e.stopPropagation(); openMenu($("#more"), [
    { label: tr("Transcribe an audio file…"), action: () => call("importFile", { transcript: false, title: tr("Choose a meeting recording to transcribe") }), disabled: !state.ready },
    { label: tr("Import a transcript…"), action: () => call("importFile", { transcript: true, title: tr("Import a transcript…") }), disabled: !state.ready },
    { label: tr("Open notes folder"), action: () => call("openFolder") },
    "-",
    { label: tr("Quit Hesper"), action: () => call("quit") },
  ]); };
  const q = $("#q");
  if (q) {
    q.oninput = async () => {
      search = q.value;
      hits = search.trim() ? await call("search", { q: search }) : null;
      drawContent(); drawTabs();
    };
    q.onkeydown = e => {
      if (e.key === "Enter" && search.trim()) call("ask", { q: search.trim() });
      if (e.key === "Escape") { if (search) { q.value = ""; q.oninput(); } else call("hide"); }
    };
    drawTabs();
  }
  drawContent();
}

function drawTabs() {
  if (!$("#tabs")) return;
  const t = (id, svg, label, count = 0) =>
    `<button class="tab ${tab === id && !search ? "selected" : ""}" data-tab="${id}">${svg}<span>${esc(tr(label))}${count ? " · " + count : ""}</span></button>`;
  const myOpen = (state?.meetings ?? []).flatMap(openTodos).filter(x => mine(x.a)).length;
  $("#tabs").innerHTML = t("today", glyph(), "Today") + t("meetings", icon("list"), "Meetings") + t("todos", icon("check"), "To-dos", myOpen);
  $("#tabs").onclick = e => {
    const b = e.target.closest(".tab"); if (!b) return;
    tab = b.dataset.tab; search = ""; hits = null; $("#q").value = "";
    drawContent(); drawTabs();
  };
}

function drawContent() {
  const el = $("#content");
  if (!el || !state) return;
  const parts = [];
  if (homeView === "todos") parts.push(allTodos());
  else if (homeView.startsWith("brief/")) parts.push(briefView(homeView.slice(6)));
  else {
    if (!state.ready) parts.push(setupCard());
    else parts.push(hero());
    if (state.laterPending && !state.recording) parts.push(laterCard());
    if (state.job && !["ask", "model", "check"].includes(state.job.kind)) parts.push(jobCard(state.job));
    if (state.answer) parts.push(answerCard(state.answer));
    parts.push("<hr>");
    if (search.trim()) parts.push(meetingList(state.meetings.filter(m => hits?.includes(m.id)), tr("No meeting mentions that. Press ↩ to ask.")));
    else if (tab === "meetings") parts.push(meetingList(state.meetings, tr("Your meetings will appear here.")));
    else if (tab === "todos") parts.push(todoList());
    else parts.push(today());
  }
  el.innerHTML = parts.join("");
  el.onclick = onContentClick;
  el.oncontextmenu = onContentMenu;
  drawLive();
}

function setupCard() {
  const s = state.setup;
  if (s) return `<div class="card"><div class="row"><div class="spinner"></div><div class="headline">${L("Hesper is setting up…")}</div></div>
    <div class="caption">${esc(tr(s.text))}</div>${progressBar(s.progress)}</div>`;
  return `<div class="card"><div class="headline">${L("Hesper isn't ready yet.")}</div>
    ${state.setupError ? `<div class="error-text">${esc(state.setupError)}</div>` : ""}
    <button class="btn primary" data-act="welcome">${L("Finish setting up")}</button></div>`;
}
const progressBar = p => p == null ? `<div class="progress indeterminate"><div></div></div>`
                                   : `<div class="progress"><div style="width:${Math.round(Math.min(1, p) * 100)}%"></div></div>`;
const templateName = id => tr(TEMPLATES.find(([v]) => v === id)?.[1] ?? "General");

function hero() {
  const r = state.recording;
  if (r) return `<div class="card">
      <div class="row"><div class="rec-dot"></div><div class="headline grow">${L("Recording now")}</div><div class="title2 mono" id="clock">${fmtDuration(r.elapsed)}</div></div>
      <div class="meter">${icon("mic")}<span class="label">${L("Your mic")}</span><div class="bar"><div id="lv-mic"></div></div></div>
      <div class="meter">${icon("speaker")}<span class="label">${L("Meeting")}</span><div class="bar"><div id="lv-sys"></div></div></div>
      ${r.notices.map(n => `<div class="notice">${icon("warn")}<span>${esc(notice(n))}</span></div>`).join("")}
      <button class="btn primary large" data-act="stop">■ ${L("Stop & create notes")}</button>
      <button class="plain" style="color:var(--danger);align-self:center" data-act="discard">${L("Discard this recording")}</button>
    </div>`;
  const t = template ?? state.settings.Template;
  const ev = state.calendar?.next, brief = state.calendar?.nextBrief;
  const now = ev && new Date(ev.start) <= new Date(Date.now() + 10 * 60000);
  const open = brief?.open?.length ?? 0;
  return `<div class="hero">
      <button class="record-btn" data-act="record" title="${L("Start recording")}" ${state.ready ? "" : "disabled"}>${glyph("#F2B544")}</button>
      <div class="grow" style="min-width:0"><div class="headline ellipsis">${ev && now ? esc(tr("Record %@", ev.title)) : L("Record")}</div>
        <div class="caption row" style="gap:4px">${ev && now ? `<span>${esc(tr("Now · %@ ·", fmtClock(ev.start)))}</span>` : ""}<button class="plain" style="color:var(--secondary)" data-act="template" title="${L("Meeting type: shapes the notes")}">${esc(templateName(t))} ▾</button>
          ${state.settings.Hotkey ? `<span>· ${esc(state.settings.Hotkey)}</span>` : ""}</div>
        ${brief ? `<button class="plain" data-brief="${esc(ev.id ?? ev.title)}">${esc(open === 0 ? tr("Notes from last time ›") : open === 1 ? tr("1 open to-do from last time ›") : tr("%@ open to-dos from last time ›", open))}</button>`
          : state.settings.AutoRecord ? `<div class="caption">${L("Records calls automatically")}</div>` : ""}
      </div>
    </div>`;
}

/// The recorder's notices (English, from the app) in the app's language, with the Mac's texts where they exist.
function notice(n) {
  const m = n.match(/^(.*) isn't running — recording all PC audio instead\.$/);
  return m ? pc(tr("%@ isn't running — recording all Mac audio instead.", m[1])) : tr(n);
}

function laterCard() {
  const n = state.laterPending;
  return `<div class="card"><div class="row"><span class="grow">${esc(n === 1 ? tr("1 meeting waiting for its notes") : tr("%@ meetings waiting for their notes", n))}</span>
    <button class="btn small" data-act="writeNow" ${state.job ? "disabled" : ""}>${L("Write now")}</button></div></div>`;
}

function drawLive(live) {
  const r = live ?? state?.recording;
  if (!r || !$("#clock")) return;
  $("#clock").textContent = fmtDuration(r.elapsed);
  const w = lv => lv == null ? 0 : Math.min(100, Math.sqrt(lv) * 140);
  $("#lv-mic").style.width = w(r.mic) + "%";
  $("#lv-sys").style.width = w(r.system) + "%";
}

function jobCard(job) {
  const m = state.meetings.find(x => x.id === job.id);
  const name = m ? meetingTitle(m) : tr("meeting");
  const title = job.kind === "import" ? tr("Processing %@", job.file) : job.kind === "process" ? tr("Processing “%@”", name) : tr("Updating “%@”", name);
  const left = job.remaining == null ? "" : job.remaining < 60 ? tr("less than a minute left") : tr("about %@ min left", Math.round(job.remaining / 60));
  return `<div class="card"><div class="row"><div class="grow ellipsis" style="font-weight:500">${esc(title)}</div>
    ${job.waiting ? `<span class="caption2">${esc(tr("+%@ waiting", job.waiting))}</span>` : ""}</div>
    ${job.step ? `<div class="caption">${esc(tr(job.step))}${left ? " · " + esc(left) : ""}</div>` : ""}${progressBar(job.progress)}</div>`;
}

function answerCard(a) {
  const sources = a.result?.sources ?? [];
  return `<div class="card selectable"><div class="row"><div class="grow headline ellipsis">${esc(a.question)}</div>
      <button class="icon-btn" data-act="clearAnswer" title="${L("Close")}">✕</button></div>
    ${a.busy ? `<div class="row"><div class="spinner"></div><span class="caption">${L("Searching your meetings")}…</span></div>`
      : a.error ? `<div class="error-text">${esc(a.error)}</div>`
      : `<div class="answer">${esc(a.result?.answer ?? "")}</div>
         ${sources.length ? `<div class="section-title">${L("Sources")}</div>` + sources.map(s =>
           `<a data-open="${esc(s.id ?? s.folder?.split(/[\\/]/).pop() ?? "")}" class="caption">[${s.n}] ${esc(s.title)} — ${esc(s.date)}</a>`).join("<br>") : ""}
         <div class="caption2">${P("Answers come from your notes and transcripts, by the AI on this Mac. Check the sources for anything important.")}</div>`}
  </div>`;
}

function meetingRow(m) {
  const busy = state.busy.includes(m.id) || state.recording?.id === m.id;
  const status = busy ? `<div class="spinner"></div>`
    : m.error ? `<span style="color:var(--warn)">${icon("warn")}</span>`
    : m.hasNotes ? `<span style="color:var(--accent)">${icon("doc")}</span>`
    : `<span class="secondary">${icon("wave")}</span>`;
  const open = openTodos(m).length;
  const sub = [fmtDate(m.date), m.duration ? fmtDuration(m.duration) : ""].filter(Boolean).join(" · ");
  return `<button class="meeting-row" data-open="${esc(m.id)}">
    <span class="status">${status}</span>
    <span class="grow"><div class="ellipsis" style="font-weight:500">${esc(meetingTitle(m))}</div><div class="caption">${esc(sub)}</div></span>
    ${open ? `<span class="badge">${esc(tr(open === 1 ? "%@ to-do" : "%@ to-dos", open))}</span>` : ""}
    <span class="secondary">${icon("chevron")}</span></button>`;
}
function meetingList(list, empty) {
  list = list.filter(m => m.id !== state.recording?.id);
  return list.length ? `<div class="list">${list.map(meetingRow).join("")}</div>` : `<div class="empty">${esc(empty)}</div>`;
}

function todoRows(items, withDone = false) {
  return `<div class="list">${items.map(({ a, i, m, done }) => `
    <button class="todo-row" data-done="${esc(m.id)}:${i}:${done ? 0 : 1}" title="${L(done ? "Mark as not done" : "Mark as done")}">
      <span class="box ${done ? "ticked" : ""}">${done ? "✓" : ""}</span>
      <span class="grow"><div style="${done ? "text-decoration:line-through;color:var(--secondary)" : ""}">${esc(a.task)}</div>
        <div class="row" style="gap:6px">${dueBadge(a, done)}<span class="caption2 ellipsis">${esc(todoMine ? "" : a.owner + " · ")}${esc(meetingTitle(m))}</span></div></span>
    </button>`).join("")}</div>`;
}
const dueKey = x => x.a.due_date ?? "9999";
function myTodos() {
  return state.meetings.flatMap(openTodos).filter(x => mine(x.a)).sort((x, y) => dueKey(x) < dueKey(y) ? -1 : dueKey(x) > dueKey(y) ? 1 : 0);
}
function todoList() {
  if (!state.settings.MyName) return `<div class="empty">${L("Set your name in Settings to see your to-dos.")}</div>`;
  const items = myTodos();
  return (items.length ? todoRows(items.slice(0, 8)) : `<div class="empty">${L("Nothing open. Nice.")}</div>`)
    + `<button class="plain" data-act="allTodos">${L("See all to-dos")}</button>`;
}
/// All to-dos: mine or everyone's, open or also done, by meeting (TodosView on the Mac)
function allTodos() {
  const items = state.meetings.flatMap(m => (m.actions || []).map((a, i) => ({ a, i, m, done: m.done.includes(i) })))
    .filter(x => (todoShowDone || !x.done) && (!todoMine || mine(x.a)));
  const groups = [...new Set(items.map(x => x.m.id))];
  return `<div class="row"><div class="segmented"><button class="${todoMine ? "on" : ""}" data-act="mine">${L("Mine")}</button>
      <button class="${todoMine ? "" : "on"}" data-act="everyone">${L("Everyone's")}</button></div><span class="grow"></span>
      <label class="check caption"><input type="checkbox" data-act="showDone" ${todoShowDone ? "checked" : ""}>${L("Done")}</label></div>
    ${todoMine && !state.settings.MyName ? `<div class="empty">${L("Set your name in Settings so Hesper knows which to-dos are yours.")}</div>` : ""}
    ${items.length === 0 ? `<div class="empty">${L("No open to-dos.")}</div>` : groups.map(id => {
      const m = state.meetings.find(x => x.id === id);
      return `<div><button class="section-title plain" data-open="${esc(id)}">${esc(meetingTitle(m))} · ${esc(fmtDate(m.date))}</button>${todoRows(items.filter(x => x.m.id === id))}</div>`;
    }).join("")}`;
}
const fmtClock = iso => new Date(iso).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });

/// Today's calendar meetings, matched with what was recorded, plus unplanned recordings (a timeline).
function timeline() {
  const recorded = state.meetings.filter(m => isToday(m.date) && m.id !== state.recording?.id);
  const used = new Set();
  const items = (state.calendar?.today ?? []).map(e => {
    const match = recorded.find(m => !used.has(m.id) && m.calendar && (m.calendar.id === e.id || m.calendar.title === e.title));
    if (match) used.add(match.id);
    return { time: new Date(e.start), end: new Date(e.end), title: match ? meetingTitle(match) : e.title, event: e, meeting: match };
  });
  items.push(...recorded.filter(m => !used.has(m.id)).map(m => ({ time: new Date(m.date), title: meetingTitle(m), meeting: m })));
  items.sort((a, b) => a.time - b.time);
  const now = new Date();
  return `<div class="timeline">${items.map((it, k) => {
    const phase = it.meeting ? "done" : it.end && it.time <= new Date(now.getTime() + 300000) && it.end > now ? "now" : it.time > now ? "later" : "done";
    const color = phase === "now" ? "var(--recording)" : phase === "later" ? "var(--accent)" : "var(--secondary)";
    const open = it.meeting ? openTodos(it.meeting).length : 0;
    const key = it.event ? (it.event.id ?? it.event.title) : null;
    return `<div class="tl-item"><div class="tl-rail"><span class="tl-dot" style="background:${color};opacity:${phase === "later" ? .45 : 1}"></span>${k < items.length - 1 ? `<span class="tl-line"></span>` : ""}</div>
      <button class="tl-body" ${it.meeting ? `data-open="${esc(it.meeting.id)}"` : key && state.calendar.briefs?.[key]?.brief ? `data-brief="${esc(key)}"` : ""}>
        <div class="row"><span class="caption mono">${fmtClock(it.time)}</span><span class="grow ellipsis" style="font-weight:500">${esc(it.title)}</span>
        ${open ? `<span class="badge">${esc(tr(open === 1 ? "%@ to-do" : "%@ to-dos", open))}</span>` : ""}</div></button></div>`;
  }).join("")}</div>`;
}

/// Before a meeting: what's still open from the last one like it (BriefView on the Mac).
function briefView(key) {
  const b = state.calendar?.briefs?.[key];
  if (!b) return `<div class="empty">${L("No open to-dos from last time")}</div>`;
  const e = b.event, open = b.brief?.open ?? [];
  const last = state.meetings.find(m => m.id === b.brief?.last);
  return `<div><div class="headline">${esc(e.title)}</div><div class="caption">${esc(fmtClock(e.start))}–${esc(fmtClock(e.end))}</div></div>
    ${state.recording ? "" : `<button class="btn primary large" data-act="record">● ${L("Start recording")}</button>`}
    <div><div class="section-title">${L("Still open")}</div>${open.length ? todoRows(open.map(o => ({ a: o.action, i: o.index, m: state.meetings.find(m => m.id === o.id) ?? { id: o.id, title: o.title } })))
      : `<div class="empty">${L("No open to-dos from last time")}</div>`}</div>
    ${last ? `<div><div class="section-title">${esc(tr("Last time · %@", new Date(last.date).toLocaleDateString(locale(), { day: "numeric", month: "short" })))}</div>
      <button class="plain" data-open="${esc(last.id)}">${L("Open those notes")}</button></div>` : ""}`;
}

function today() {
  if (state.calendar?.on && state.calendar.available) {
    const week = new Date(); week.setDate(week.getDate() + 7);
    const due = state.settings.MyName ? myTodos().filter(x => x.a.due_date && new Date(x.a.due_date + "T00:00") <= week) : [];
    return timeline() + (due.length ? `<div><div class="section-title">${L("Your open to-dos")}</div>${todoRows(due)}</div>` : "");
  }
  const todays = state.meetings.filter(m => isToday(m.date));
  const week = new Date(); week.setDate(week.getDate() + 7);
  const due = state.settings.MyName ? myTodos().filter(x => x.a.due_date && new Date(x.a.due_date + "T00:00") <= week) : [];
  if (!state.meetings.length) return `<div class="empty">${L("Press record when your next meeting starts. Your notes and to-dos will show up here.")}</div>`;
  return `<div><div class="section-title">${L("Today's meetings")}</div>${todays.length ? meetingList(todays, "") : meetingList(state.meetings.slice(0, 3), "")}</div>
    ${due.length ? `<div><div class="section-title">${L("Your open to-dos")}</div>${todoRows(due)}</div>` : ""}`;
}

async function onContentClick(e) {
  const act = e.target.closest("[data-act]")?.dataset.act;
  const open = e.target.closest("[data-open]")?.dataset.open;
  const done = e.target.closest("[data-done]")?.dataset.done;
  const brief = e.target.closest("[data-brief]")?.dataset.brief;
  if (brief) { homeView = "brief/" + brief; renderHome(); return; }
  if (act === "record") { call("record", { template: template ?? "" }); template = null; }
  else if (act === "stop") call("stop");
  else if (act === "discard") { if (await ask(tr("Discard this recording?"), "", tr("Discard"), true)) call("stop", { discard: true }); }
  else if (act === "clearAnswer") call("clearAnswer");
  else if (act === "welcome") call("openWelcome");
  else if (act === "writeNow") call("writeLaterNow");
  else if (act === "allTodos") { homeView = "todos"; renderHome(); }
  else if (act === "mine" || act === "everyone") { todoMine = act === "mine"; drawContent(); }
  else if (act === "showDone") { todoShowDone = e.target.checked; drawContent(); }
  else if (act === "template") {
    e.stopPropagation();
    openMenu(e.target.closest("[data-act]"), TEMPLATES.map(([v, l]) => ({ label: ((template ?? state.settings.Template) === v ? "✓ " : "") + tr(l), action: () => { template = v; drawContent(); } })));
  }
  else if (open) call("openMeeting", { id: open });
  else if (done) { const [id, i, d] = done.split(":"); await call("setDone", { id, index: +i, done: d === "1" }); }
}

function shareLabels() {
  return Object.fromEntries(["Summary", "Decisions", "Action items", "Open questions", "Meeting"].map(k => [k, tr(k)]));
}

async function onContentMenu(e) {
  const row = e.target.closest("[data-open]");
  if (!row) return;
  e.preventDefault();
  const id = row.dataset.open, m = state.meetings.find(x => x.id === id);
  if (!m) return;
  const busy = state.busy.includes(id) || state.recording?.id === id;
  openMenu(row, [
    { label: tr("Open"), action: () => call("openMeeting", { id }) },
    { label: tr("Email the notes…"), action: () => call("email", { id, subject: tr("Notes: %@", meetingTitle(m)), labels: shareLabels() }), disabled: !m.hasNotes },
    { label: tr("Show in Explorer"), action: () => call("showInExplorer", { id }) },
    "-",
    { label: tr("Delete…"), danger: true, disabled: busy, action: async () => {
      if (await ask(tr("Delete “%@”?", meetingTitle(m)), tr("The notes, transcript and audio go to the Trash."), tr("Move to Trash"), true)) call("delete", { id });
    } },
  ], e.clientX, e.clientY);
}

// ============================================================ a meeting
let meeting = null, view = "notes", speakers = null, editing = null;

async function loadMeeting(id) {
  meeting = await call("meeting", { id });
  document.title = meeting ? meetingTitle(meeting) : "Hesper";
  if (!editing) renderMeeting();
}

function renderMeeting() {
  const m = meeting;
  if (!m) { $("#app").innerHTML = `<div class="pane">${L("This meeting is no longer there.")}</div>`; return; }
  const n = m.notes;
  const busy = state?.busy?.includes(m.id);
  const sub = [fmtDate(m.date), m.duration ? fmtDuration(m.duration) : "", (n?.participants ?? []).join(", ")].filter(Boolean).join(" · ");
  $("#app").innerHTML = `
  <div class="window">
    <div class="meeting-head">
      <div class="row"><div class="title2 grow ellipsis selectable">${esc(meetingTitle(m))}</div>
        ${editing ? "" : `<div class="segmented">
          <button class="${view === "notes" ? "on" : ""}" data-view="notes">${L("Notes")}</button>
          <button class="${view === "transcript" ? "on" : ""}" data-view="transcript" ${m.transcript.length ? "" : "disabled"}>${L("Transcript")}</button>
        </div>
        <button class="btn small" id="edit" ${n && !busy ? "" : "disabled"}>${L("Edit")}</button>
        <button class="icon-btn" id="more">${icon("more")}</button>`}</div>
      <div class="caption">${esc(sub)}</div>
    </div>
    <div class="scroll grow"><div class="meeting-body selectable" id="body"></div></div>
  </div>`;
  document.querySelectorAll("[data-view]").forEach(b => b.onclick = () => { view = b.dataset.view; speakers = null; renderMeeting(); });
  $("#edit") && ($("#edit").onclick = () => { editing = JSON.parse(JSON.stringify(n)); renderMeeting(); });
  $("#more") && ($("#more").onclick = e => { e.stopPropagation(); openMenu($("#more"), [
    { label: tr("Open notes"), action: () => call("openFile", { id: m.id, name: "notes.md" }), disabled: !n },
    { label: tr("Open transcript"), action: () => call("openFile", { id: m.id, name: "transcript.md" }), disabled: !m.hasTranscript },
    { label: tr("Show in Explorer"), action: () => call("showInExplorer", { id: m.id }) },
    "-",
    { label: tr("Name the speakers…"), action: () => { view = "speakers"; renderMeeting(); }, disabled: !n || busy },
    { label: tr("Email the notes…"), action: () => call("email", { id: m.id, subject: tr("Notes: %@", meetingTitle(m)), labels: shareLabels() }), disabled: !n },
    { label: tr("Export folder (Markdown)"), action: () => call("export", { id: m.id, title: tr("Export") }), disabled: !n },
    { label: tr("Copy the notes"), action: () => call("copyNotes", { id: m.id, labels: shareLabels() }), disabled: !n },
    "-",
    { label: tr("Regenerate notes"), action: () => call("regenerate", { id: m.id }), disabled: !m.hasTranscript || busy },
    { label: tr("Regenerate as…"), disabled: !m.hasTranscript || busy, action: () => setTimeout(() => openMenu($("#more"),
        TEMPLATES.map(([v, l]) => ({ label: ((m.template ?? "general") === v ? "✓ " : "") + tr(l), action: () => call("regenerate", { id: m.id, template: v }) }))), 0) },
    { label: tr("Transcribe again"), action: () => call("process", { id: m.id }), disabled: !m.hasAudio || busy },
    "-",
    { label: tr("Move to Trash…"), danger: true, disabled: busy, action: async () => {
      if (await ask(tr("Delete “%@”?", meetingTitle(m)), tr("The notes, transcript and audio go to the Trash."), tr("Move to Trash"), true)) {
        await call("delete", { id: m.id }); call("close");
      } } },
  ]); });
  const body = $("#body");
  if (editing) drawEditor(body);
  else if (view === "transcript") body.innerHTML = m.transcript.map(l =>
    `<div class="line"><span class="t caption mono">${fmtTime(l.start)}</span><span><span class="who">${esc(l.speaker)}</span>${esc(l.text)}</span></div>`).join("");
  else if (view === "speakers") drawSpeakers(body);
  else body.innerHTML = notesHtml(m, busy);
  if (editing) return;
  body.onclick = async e => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "process") call("process", { id: m.id });
    if (act === "speakers") { view = "speakers"; renderMeeting(); }
    if (act === "namesRight") call("confirmNames", { id: m.id });
    if (act === "writeNow") call("writeLaterNow");
  };
  body.onchange = async e => {
    const box = e.target.closest("[data-todo]");
    if (!box) return;
    await call("setDone", { id: m.id, index: +box.dataset.todo, done: box.checked });
    box.closest(".todo").classList.toggle("done", box.checked);
  };
  body.oncontextmenu = e => {
    const todo = e.target.closest(".todo");
    if (!todo || busy) return;
    e.preventDefault();
    const i = +todo.querySelector("[data-todo]").dataset.todo;
    openMenu(todo, [{ label: tr("Delete this to-do"), danger: true, action: () => call("deleteTodo", { id: m.id, index: i }) }], e.clientX, e.clientY);
  };
}

function notesHtml(m, busy) {
  const n = m.notes;
  const out = [];
  if (busy) out.push(`<div class="card"><div class="row"><div class="spinner"></div><span>${esc(state.job?.id === m.id && state.job.step ? tr(state.job.step) : tr("Waiting for the meeting being processed…"))}</span></div>
    ${state.job?.id === m.id ? progressBar(state.job.progress) : ""}</div>`);
  else if (m.error) out.push(`<div class="card"><div class="row" style="color:var(--warn)">${icon("warn")}<b>${L("Processing failed")}</b></div>
    <div class="caption">${esc(m.error)}</div>${m.hasAudio ? `<button class="btn" data-act="process">${L("Try again")}</button>` : ""}</div>`);
  else if (m.later && !busy) out.push(`<div class="card"><div class="row"><span class="grow">${esc(n ? pc(tr("Better notes are written when you're not using the Mac.")) : pc(tr("The notes are written when you're not using the Mac.")))}</span>
    <button class="btn small" data-act="writeNow">${L("Write now")}</button></div></div>`);
  else if (!n) out.push(`<div class="card"><div>${L("This recording hasn't been processed yet.")}</div>
    ${m.hasAudio ? `<button class="btn primary" data-act="process">${L("Create notes now")}</button>` : ""}</div>`);
  if (!n) return out.join("");
  if (m.roomOnly) out.push(`<div class="card"><div class="row">${icon("speaker")}<b>${L("The meeting audio wasn't recorded")}</b></div>
    <div class="caption">${esc(tr("Only your microphone was captured, so other people's voices were picked up through your speakers — speaker names may be less reliable."))}</div></div>`);
  if (m.guessed?.length) out.push(`<div class="card"><div class="caption">${L("Worked out from who was addressed by name. Check that the right voice got the right name.")}</div>
    <div class="row"><button class="btn small" data-act="namesRight">${L("They're right")}</button><button class="btn small" data-act="speakers">${L("Check the voices…")}</button></div></div>`);
  else if ((n.participants ?? []).some(p => /^Speaker \d+$/.test(p))) out.push(`<div class="card"><div>${L("Who is who? Name the speakers and the notes are rewritten with their names.")}</div>
    <button class="btn" data-act="speakers">${L("Name the speakers…")}</button></div>`);
  const bullets = (title, items) => items?.length ? `<section><div class="section-title">${esc(tr(title))}</div><ul class="bullets">${items.map(i => `<li><span>${esc(i)}</span></li>`).join("")}</ul></section>` : "";
  out.push(bullets("Summary", n.summary));
  out.push(bullets("Decisions", n.decisions));
  if (n.actions?.length) out.push(`<section><div class="section-title">${L("To-do")}</div>${n.actions.map((a, i) => {
    const done = m.done.includes(i);
    return `<label class="todo ${done ? "done" : ""}"><input type="checkbox" data-todo="${i}" ${done ? "checked" : ""}>
      <span class="grow"><div class="task">${esc(a.task)}</div><div class="row" style="gap:6px"><span class="caption">${esc(a.owner)}</span>${dueBadge(a, done)}</div></span></label>`;
  }).join("")}</section>`);
  for (const s of n.sections ?? []) out.push(bullets(s.title, s.items));
  out.push(bullets("Open questions", n.questions));
  return out.join("");
}

/// Editing the notes (as the Mac's: name, summary, decisions, to-dos); notes.md is then rebuilt.
function drawEditor(body) {
  const e = editing;
  const lines = arr => esc((arr ?? []).join("\n"));
  body.innerHTML = `
    <div><div class="section-title">${L("Meeting name")}</div><input class="field" id="ed-title" value="${esc(e.title ?? "")}"></div>
    <div><div class="section-title">${L("Summary")}</div><textarea class="field" id="ed-summary" rows="6">${lines(e.summary)}</textarea></div>
    <div><div class="section-title">${L("Decisions")}</div><textarea class="field" id="ed-decisions" rows="4">${lines(e.decisions)}</textarea></div>
    <div><div class="section-title">${L("To-dos")}</div>
      ${(e.actions ?? []).map((a, i) => `<div class="row edit-todo" data-i="${i}">
        <input class="field" style="width:130px" data-f="owner" placeholder="${L("Owner")}" value="${esc(a.owner)}">
        <input class="field grow" data-f="task" placeholder="${L("Task")}" value="${esc(a.task)}">
        <input class="field" style="width:150px" data-f="due" placeholder="${L("Due (e.g. Friday, 30 Oct)")}" value="${esc(a.due ?? "")}">
        <button class="icon-btn" data-remove="${i}" title="${L("Delete this to-do")}">−</button></div>`).join("")}
      <button class="plain" id="ed-add">+ ${L("Add a to-do")}</button>
      <div class="caption">${L("Due dates are understood in plain words (“Friday”, “next week”, “30 Oct”).")}</div></div>
    <div class="row"><span class="grow"></span><button class="btn" id="ed-cancel">${L("Cancel")}</button><button class="btn primary" id="ed-save">${L("Save")}</button></div>`;
  const collect = () => {
    e.title = $("#ed-title").value.trim();
    e.summary = $("#ed-summary").value.split("\n").map(s => s.trim()).filter(Boolean);
    e.decisions = $("#ed-decisions").value.split("\n").map(s => s.trim()).filter(Boolean);
    body.querySelectorAll(".edit-todo").forEach(r => {
      const a = e.actions[+r.dataset.i];
      const due = r.querySelector('[data-f="due"]').value.trim();
      if (due !== (a.due ?? "")) delete a.due_date;  // worked out again from the words
      a.owner = r.querySelector('[data-f="owner"]').value.trim();
      a.task = r.querySelector('[data-f="task"]').value.trim();
      a.due = due;
    });
  };
  $("#ed-add").onclick = () => { collect(); e.actions = [...(e.actions ?? []), { owner: state.settings.MyName, task: "", due: "" }]; drawEditor(body); };
  body.querySelectorAll("[data-remove]").forEach(b => b.onclick = () => { collect(); e.actions.splice(+b.dataset.remove, 1); drawEditor(body); });
  $("#ed-cancel").onclick = () => { editing = null; renderMeeting(); };
  $("#ed-save").onclick = async () => {
    collect();
    e.actions = (e.actions ?? []).filter(a => a.task);
    await call("saveNotes", { id: meeting.id, notes: { title: e.title, summary: e.summary, decisions: e.decisions, actions: e.actions } });
    editing = null;
    loadMeeting(meeting.id);
  };
}

async function drawSpeakers(body) {
  const m = meeting;
  speakers ??= await call("samples", { id: m.id }) ?? {};
  const names = Object.keys(speakers);
  body.innerHTML = `<div class="caption">${L("Type each speaker's name. Hesper remembers their voice for next time, and the notes are rewritten with the names. Same person split in two? Give both the same name.")}</div>
    ${names.map(s => `<div class="card"><div class="row"><b class="grow">${esc(s)}</b>
        <input class="field" style="width:220px" data-spk="${esc(s)}" placeholder="${L("Name")}" value="${/^Speaker \d+$/.test(s) ? "" : esc(s)}">
        <button class="btn small" data-me="${esc(s)}">${L("Me")}</button></div>
        ${speakers[s].map(t => `<div class="caption">“${esc(t)}”</div>`).join("") || `<div class="caption">${L("Only said a few words.")}</div>`}</div>`).join("")}
    <div class="row"><button class="btn" id="cancel">${L("Cancel")}</button><span class="grow"></span>
      <button class="btn primary" id="save">${L("Save & regenerate notes")}</button></div>`;
  body.querySelectorAll("[data-me]").forEach(b => b.onclick = () => {
    body.querySelector(`[data-spk="${CSS.escape(b.dataset.me)}"]`).value = state.settings.MyName || "Me";
  });
  $("#cancel").onclick = () => { view = "notes"; renderMeeting(); };
  $("#save").onclick = async () => {
    const mapping = {};
    body.querySelectorAll("[data-spk]").forEach(i => { const v = i.value.trim(); if (v && v !== i.dataset.spk) mapping[i.dataset.spk] = v; });
    if (Object.keys(mapping).length) await call("rename", { id: m.id, mapping });
    view = "notes"; speakers = null; renderMeeting();
  };
}

// ============================================================ Settings
// The panes of mac/App/SettingsWindow.swift and SettingsSections.swift, with the Mac's texts
// (so its translations apply); "Mac" is said "PC" here (pc()).
const PANES = [
  ["general", "person", "General"], ["recording", "mic", "Recording"], ["notes", "doc", "Notes"],
  ["models", "cpu", "AI models"], ["notifications", "bell", "Notifications"], ["privacy", "lock", "Privacy and storage"],
  ["voices", "voices", "Voices"], ["about", "info", "About"],
];
const SPOKEN = { en: "English", fr: "French", es: "Spanish", de: "German", it: "Italian", pt: "Portuguese", nl: "Dutch", pl: "Polish",
                 sv: "Swedish", da: "Danish", fi: "Finnish", ja: "Japanese", zh: "Chinese", ko: "Korean", ru: "Russian", ar: "Arabic" };
// A language's name in the app's language ("Français", "anglais"…)
function languageName(code, capital = true) {
  try { const n = new Intl.DisplayNames([locale()], { type: "language" }).of(code); return n && capital ? n[0].toLocaleUpperCase(locale()) + n.slice(1) : n ?? code; }
  catch { return SPOKEN[code] ?? code; }
}
const pc = s => s.replace(/\bMac\b/g, "PC");  // the Mac's texts, said for a PC
const TEMPLATES = [["general", "General"], ["one_on_one", "1:1"], ["standup", "Stand-up"], ["client", "Client call"], ["interview", "Interview"], ["workshop", "Workshop / brainstorm"]];
const STYLES = { brief: ["Brief", "As short as possible — a few bullet points to skim in 15 seconds."],
                 standard: ["Standard", "The main topics and outcomes, one line each."],
                 detailed: ["Detailed", "Long notes with context, who said what, numbers — for people who missed the meeting."] };
const FILTERS = { off: ["Off", "Every to-do the AI finds is listed."],
                  standard: ["Standard", "Each to-do is checked once more: about a third of the false ones go, almost no real ones (a few seconds per to-do)."],
                  strict: ["Strict", "Removes about half of the false to-dos, but also about one real to-do in ten."] };
const RETENTION = [[0, "Right after the notes are made"], [1, "After 1 day"], [3, "After 3 days"], [7, "After 7 days"], [14, "After 14 days"], [30, "After 30 days"], [-1, "Never"]];
const REPO = "https://github.com/Gbally/Hesper";
let pane = "general", devices = null, voices = null, models = null, engineBytes = null, hotkeyRecording = false, customSpeech = false, customLink = { false: "", true: "" };

function renderSettings() {
  document.title = tr("Hesper Settings");
  $("#app").innerHTML = `<div class="settings">
    <nav class="sidebar">${PANES.map(([id, ic, label]) =>
      `<button class="side-item ${pane === id ? "on" : ""}" data-pane="${id}">${icon(ic)}${esc(tr(label))}</button>`).join("")}</nav>
    <div class="scroll grow"><div class="pane" id="pane"></div></div></div>`;
  document.querySelectorAll("[data-pane]").forEach(b => b.onclick = () => { pane = b.dataset.pane; history.replaceState(null, "", "#settings/" + pane); renderSettings(); });
  drawPane();
}

// Rows: a label (and a caption under it) on the left, a control on the right; or a full-width line
const item = (label, control, note = "") =>
  `<div class="item"><div class="label">${label}${note ? `<div class="caption2">${note}</div>` : ""}</div><div class="control">${control}</div></div>`;
const line = html => `<div class="item"><div class="label">${html}</div></div>`;
const caption = text => `<div class="item caption">${esc(text)}</div>`;
const select = (key, options, value) =>
  `<select class="field" data-key="${key}">${options.map(([v, l]) => `<option value="${esc(v)}" ${String(v) === String(value) ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
const segmented = (key, options, value) =>
  `<div class="segmented">${options.map(([v, l]) => `<button class="${v === value ? "on" : ""}" data-seg="${key}" data-value="${esc(v)}">${esc(l)}</button>`).join("")}</div>`;
const text = (key, value, placeholder = "") => `<input class="field" data-key="${key}" value="${esc(value)}" placeholder="${esc(placeholder)}" spellcheck="false">`;
const toggle = (key, on, disabled = false) => `<label class="toggle"><input type="checkbox" data-key="${key}" ${on ? "checked" : ""} ${disabled ? "disabled" : ""}><span></span></label>`;
const group = (title, items, footer = "") => `<div>${title ? `<div class="group-title">${esc(title)}</div>` : ""}<div class="group">${items.join("")}</div>${footer ? `<div class="caption" style="margin:6px 2px 0">${esc(footer)}</div>` : ""}</div>`;
const tag = (t, color) => `<span class="tag" style="--c:${color}">${esc(tr(t))}</span>`;
const L = k => esc(tr(k));
const P = k => esc(pc(tr(k)));

async function save(changes) {
  Object.assign(state.settings, changes);
  await call("saveSettings", { settings: state.settings });
}

async function drawPane() {
  const s = state.settings, el = $("#pane");
  const busy = !!(state.recording || state.job);
  if (pane === "general") el.innerHTML =
    group(tr("Language"), [item(L("App language"), select("AppLanguage", [["", tr("Same as Windows")], ...Object.entries(LANGS)], s.AppLanguage))],
          tr("Other languages show in English. Meeting notes follow the meeting's language (Settings → Notes).")) +
    group(tr("You"), [item(L("Your name"), text("MyName", s.MyName))], tr("Used for your voice in transcripts and to find the to-dos that are yours.")) +
    group(tr("Shortcut and startup"), [
      item(L("Start / stop recording"), `<button class="btn hotkey" id="hotkey">${esc(hotkeyRecording ? tr("Type the shortcut…") : s.Hotkey || tr("None"))}</button>
        ${s.Hotkey ? `<button class="icon-btn" id="hotkey-clear" title="${L("Remove")}">✕</button>` : ""}`),
      item(P("Open Hesper at login"), toggle("@login", state.launchAtLogin)),
    ]) +
    group(tr("Email"), [
      item(L("Write emails with"), select("EmailApp", [["default", tr("Default mail app")], ...(state.outlook ? [["outlook", "Microsoft Outlook"]] : []),
                                                     ["gmail", "Gmail"], ["outlookWeb", tr("Outlook on the web")]], s.EmailApp)),
      ...(s.EmailApp === "gmail" ? [item(L("Gmail address (optional, if you use several)"), text("GmailAccount", s.GmailAccount))] : []),
      ...(s.EmailApp === "gmail" || s.EmailApp === "outlookWeb" ? [caption(tr("The draft opens in your browser, so the notes are sent to that website to create it."))] : []),
    ]);
  else if (pane === "recording") {
    devices ??= await call("devices") ?? { mics: [], speakers: [] };
    const langs = s.Languages.split(",").filter(Boolean);
    el.innerHTML =
      group(tr("Audio"), [
        item(L("Record"), select("AppOnly", [["", pc(tr("All Mac audio"))], ["teams", tr("Microsoft Teams only")]], s.AppOnly),
             state.appLoopback ? "" : esc(tr("Recording one app only needs Windows 11."))),
        item(L("Microphone"), select("Microphone", [["", tr("Windows default")], ...devices.mics.map(d => [d, d])], s.Microphone)),
        item(L("PC sound from"), select("Speakers", [["", tr("Windows default")], ...devices.speakers.map(d => [d, d])], s.Speakers),
             L("Hesper records your microphone and what your PC plays (the other people in a call).")),
        item(L("Record calls automatically"), toggle("AutoRecord", s.AutoRecord),
             L("Starts when Teams, Zoom or a browser call uses the microphone, and stops when the call ends.")),
      ]) +
      group(tr("Calendar"), [
        item(L("Use my calendar for meeting names & attendees"), toggle("UseCalendar", s.UseCalendar && state.calendar?.available, !state.calendar?.available),
             L("Names meetings and their attendees, and reminds you of open to-dos before the next one.")),
        caption(state.calendar?.available ? tr("Read from Outlook on this PC (the classic app: the new Outlook can't be read by other apps).")
              : state.calendar?.installed ? tr("Outlook is installed but has no account set up on this PC.")
              : tr("Needs the classic Outlook app on this PC (the new Outlook can't be read by other apps).")),
        ...(state.calendar?.error ? [`<div class="item error-text">${esc(state.calendar.error)}</div>`] : []),
      ]) +
      group(tr("Languages"), [
        `<div class="item"><div class="label">${L("Languages spoken in your meetings")}</div></div>`,
        `<div class="langs">${Object.keys(SPOKEN).map(c => `<label class="check"><input type="checkbox" data-lang="${c}" ${langs.includes(c) ? "checked" : ""}>${esc(languageName(c))}</label>`).join("")}</div>`,
        caption(langs.length === 0 ? tr("None ticked: the language is detected automatically (one per meeting).")
              : langs.length === 1 ? tr("Everything is transcribed as %@.", languageName(langs[0], lang === "en")) : tr("The meeting may switch between these languages.")),
        item(L("Names and jargon"), text("Vocabulary", s.Vocabulary, "Acme, Kubernetes, Zora")),
      ], tr("Comma-separated. Helps spell product names, acronyms and colleagues' names."));
  }
  else if (pane === "notes") {
    if (s.NotesTiming !== "now") models ??= await call("catalog", { lang });
    const installedNotes = models ? Object.keys(models.installed).filter(r => r.includes(":")) : [];
    el.innerHTML =
      group(tr("Notes"), [
        item(L("Usual meeting type"), select("Template", TEMPLATES.map(([v, l]) => [v, tr(l)]), s.Template)),
        item(L("Detail"), segmented("SummaryStyle", Object.entries(STYLES).map(([v, [l]]) => [v, tr(l)]), s.SummaryStyle), L(STYLES[s.SummaryStyle]?.[1] ?? "")),
        item(L("Check the to-dos"), segmented("TodoFilter", Object.entries(FILTERS).map(([v, [l]]) => [v, tr(l)]), s.TodoFilter), L(FILTERS[s.TodoFilter]?.[1] ?? "")),
        item(L("Language"), select("NotesLanguage", [["auto", tr("Same as the meeting")], ...Object.entries(SPOKEN).map(([c, l]) => [l, languageName(c)])], s.NotesLanguage)),
      ], tr("Applies to new meetings. To redo one: open it → ⋯ → Regenerate notes.")) +
      group(tr("When to write the notes"), [
        `<div class="item radios">${[["now", "Right after the meeting"], ["later", "When I'm not using the Mac"], ["both", "Quick notes right away, better ones when I'm not using the Mac"]]
          .map(([v, l]) => `<label class="check"><input type="radio" name="timing" data-key="NotesTiming" value="${v}" ${s.NotesTiming === v ? "checked" : ""}>${P(l)}</label>`).join("")}</div>`,
        ...(s.NotesTiming === "now" ? [] : [
          item(esc(tr(s.NotesTiming === "both" ? "Model for the better notes" : "Model")),
               select("LaterModel", [["", models?.catalog.notes.find(m => m.repo === state.notesModel)?.name ?? state.notesModel],
                                     ...installedNotes.filter(r => r !== state.notesModel).map(r => [r, models.catalog.notes.find(m => m.repo === r)?.name ?? r])], s.LaterModel),
               P("It runs while you're away, so a bigger model is fine: speed doesn't matter then. More models: AI models.")),
          item(L("At set times"), toggle("LaterInWindows", s.LaterInWindows)),
          ...(s.LaterInWindows ? s.LaterWindows.map((w, i) => item(
            `${L("From")} <input type="time" class="field time" data-window="${i}" data-end="0" value="${hhmm(w[0])}"> ${L("to")} <input type="time" class="field time" data-window="${i}" data-end="1" value="${hhmm(w[1])}">`,
            `<button class="icon-btn" data-remove-window="${i}" title="${L("Remove this time")}">−</button>`)).concat(
            [line(`<button class="plain" id="add-window">${L("Add a time")}</button>`)]) : []),
          item(P("When the Mac hasn't been used for a while"), toggle("LaterWhenIdle", s.LaterWhenIdle)),
          ...(s.LaterWhenIdle ? [item(esc(tr("%@ minutes without keyboard or mouse", s.LaterIdleMinutes)),
                                      `<input type="number" class="field" style="width:80px" min="2" max="60" data-key="LaterIdleMinutes" value="${s.LaterIdleMinutes}">`)] : []),
          item(L("When the screen is locked"), toggle("LaterWhenLocked", s.LaterWhenLocked)),
          caption(pc(tr("Only when the Mac is on power. Transcripts are always made right away. If you come back while notes are being written, that meeting is finished and the next ones wait. To write them now: the button in Hesper's window."))),
        ]),
      ]) +
      group(tr("Export"), [
        item(L("Copy notes to a folder"), `<span class="caption ellipsis" style="max-width:150px" title="${esc(s.ExportFolder)}">${esc(s.ExportFolder || tr("None"))}</span>
          <button class="btn small" data-do="exportFolder">${L("Choose…")}</button>${s.ExportFolder ? `<button class="btn small" data-do="exportRemove">${L("Remove")}</button>` : ""}`),
        item(L("Copy every new meeting's notes there automatically"), toggle("AutoExport", s.AutoExport, !s.ExportFolder)),
      ], tr("Markdown files with the date, participants and a #meeting tag — e.g. for an Obsidian vault."));
  }
  else if (pane === "models") {
    models = await call("catalog", { lang }) ?? { catalog: { notes: [], speech: [] }, installed: {} };
    const c = models.catalog, inst = models.installed, mj = state.modelJob;
    const row = (m, speech) => {
      const inUse = (speech ? state.speechModel : state.notesModel) === m.repo;
      const rec = (speech ? c.recommendedSpeech : c.recommendedNotes) === m.repo;
      const has = inst[m.repo] != null;
      return `<div class="item"><div class="label"><div class="row" style="gap:6px">${esc(m.name)}${rec ? tag("Recommended", "var(--accent)") : ""}${inUse ? tag("In use", "var(--ok)") : ""}</div>
        <div class="caption2">${m.size.toFixed(1)} GB · ${esc(m.description)}${m.tested ? "" : " · " + L("not tested with Hesper")}${m.fits ? "" : " · " + esc(pc(tr("Too big for this Mac")))}</div></div>
        <div class="control" style="flex-direction:column;align-items:flex-end;gap:2px;width:auto">${inUse ? "" :
          `<button class="btn small" data-use="${esc(m.repo)}" data-speech="${speech}" ${mj?.status || state.setup ? "disabled" : ""}>${L(has || !state.ready ? "Use" : "Download and use")}</button>
           ${has ? `<button class="plain" style="color:var(--secondary)" data-delete-model="${esc(m.repo)}">${L("Delete")}</button>` : ""}`}</div></div>`;
    };
    const custom = speech => {
      const repo = speech ? state.speechModel : state.notesModel, list = speech ? c.speech : c.notes;
      if (!repo || list.some(m => m.repo === repo)) return [];
      const rec = list.find(m => m.repo === (speech ? c.recommendedSpeech : c.recommendedNotes));
      return [`<div class="item"><div class="label"><div class="row" style="gap:6px">${esc(repo.split("/").pop())}${tag("Custom", "var(--warn)")}${tag("In use", "var(--ok)")}</div>
        <div class="caption2">${esc(repo)} · ${L("not tested with Hesper")}</div></div>
        <div class="control" style="width:auto">${rec ? `<button class="btn small" data-use="${esc(rec.repo)}" data-speech="${speech}">${esc(tr("Back to %@", rec.name))}</button>` : ""}</div></div>`];
    };
    const listed = new Set([...c.notes, ...c.speech].map(m => m.repo).concat([state.notesModel, state.speechModel, "base"]));
    const unused = Object.entries(inst).filter(([r]) => !listed.has(r));
    const check = mj?.check, checking = mj?.status === "Checking…";
    el.innerHTML =
      group("", [item(P("This Mac"), `<span class="caption">${esc(c.hardware)}</span>`)],
            pc(tr("Models run on this Mac only. Recommendations come from a list of models tested with Hesper (updated %@).", c.updated || "—"))) +
      (mj?.status && !checking ? group(tr("Downloading"), [`<div class="item" style="flex-direction:column;align-items:stretch;gap:6px"><div class="caption">${esc(tr(mj.status))}</div>${progressBar(mj.progress)}</div>`]) : "") +
      (mj?.error && !mj.check ? `<div class="error-text selectable">${esc(mj.error)}</div>` : "") +
      (state.ready ? "" : `<div class="caption">${L("Not set up yet: the models you choose here are downloaded during the one-time setup.")}</div>`) +
      group(tr("Notes model"), [...c.notes.map(m => row(m, false)), ...custom(false)]) +
      group(tr("Speech model"), [...c.speech.map(m => row(m, true)), ...custom(true)]) +
      group(tr("Custom model"), [
        item(L("Replace the"), segmented("@custom", [["notes", tr("Notes model")], ["speech", tr("Speech model")]], customSpeech ? "speech" : "notes")),
        `<div class="item"><input class="field grow" id="custom-link" placeholder="${esc(customSpeech ? "huggingface.co/Systran/faster-whisper-…" : "huggingface.co/unsloth/…-GGUF:Q4_K_M")}" value="${esc(customLink[customSpeech])}">
          <button class="btn small" id="custom-check" ${checking ? "disabled" : ""}>${L(checking ? "Checking…" : "Check")}</button></div>`,
        ...(check && mj.speech === customSpeech ? [check.compatible
          ? `<div class="item" style="flex-direction:column;align-items:stretch;gap:6px"><div style="color:var(--ok)" class="caption">✓ ${esc(tr("Compatible: %@", tr(check.key, ...(check.args ?? []))))}</div>
              <div class="row"><span class="grow caption">${esc(mj.repo)}</span><button class="btn small" id="custom-use">${L("Download and use anyway")}</button></div></div>`
          : `<div class="item error-text">${esc(tr("Hesper can't run it: %@", tr(check.key, ...(check.args ?? []))))}</div>`] : []),
      ], tr("For experiments: any model from Hugging Face. Hesper checks it can run it; you can go back to the recommended model at any time.")) +
      (unused.length ? group(tr("Downloaded, not in use"), unused.map(([r, gb]) =>
        item(esc(r.split("/").pop()), `<button class="btn small" data-delete-model="${esc(r)}">${esc(tr("Delete (%@ GB)", gb.toFixed(1)))}</button>`))) : "") +
      group(tr("Engine"), [
        item(L("Location"), `<button class="btn small" data-do="showHome">${L("Show folder")}</button>`),
        item(L("Log"), `<button class="btn small" data-do="log">${L("Open")}</button>`),
        item(L("Reinstall"), `<button class="btn small" data-do="reinstall" ${state.setup || state.job ? "disabled" : ""}>${L("Reinstall engine…")}</button>`),
      ]);
  }
  else if (pane === "notifications") el.innerHTML = group(tr("Notify me"), [
    item(L("When notes are ready"), toggle("NotifyWhenReady", s.NotifyWhenReady)),
    item(L("When a call starts (“Record this call?”)"), toggle("CallReminders", s.CallReminders)),
    item(L("Stop by itself when the meeting is over (long quiet, call ended)"), toggle("StopWhenOver", s.StopWhenOver)),
    item(L("When the calendar meeting is over (“Stop recording?”)"), toggle("EndReminders", s.EndReminders)),
    item(L("5 min before a meeting: what's still open from last time"), toggle("Briefs", s.Briefs && state.calendar?.available && s.UseCalendar, !(state.calendar?.available && s.UseCalendar))),
    item(L("The day before my to-dos are due"), toggle("DueReminders", s.DueReminders)),
  ], tr("Windows shows them in the notification area; to change how, see Windows Settings → System → Notifications."));
  else if (pane === "privacy") {
    engineBytes ??= await call("engineSize");
    const accounts = state.oneDrive ?? [];
    const sync = s.Storage === "custom" ? await call("syncService") : null;
    const desc = s.Storage === "local" ? pc(tr("Stays on this Mac — never uploaded anywhere."))
      : s.Storage === "onedrive" ? tr("Synced to %@: backed up, and available on your other devices and on the web. Your company's OneDrive rules apply.",
                                      accounts.find(a => a.path === s.OneDrivePath)?.name ?? "OneDrive")
      : sync ? tr("This folder is synced to %@.", sync) : tr("This folder isn't synced to the cloud.");
    el.innerHTML =
      group(tr("Where notes are saved"), [
        `<div class="item radios">
          <label class="check"><input type="radio" name="storage" data-storage="local" ${s.Storage === "local" ? "checked" : ""} ${busy ? "disabled" : ""}>${P("This Mac only")}</label>
          <label class="check"><input type="radio" name="storage" data-storage="onedrive" ${s.Storage === "onedrive" ? "checked" : ""} ${busy ? "disabled" : ""}>${esc(accounts.length ? "OneDrive" : pc(tr("OneDrive (not set up on this Mac)")))}</label>
          <label class="check"><input type="radio" name="storage" data-storage="custom" ${s.Storage === "custom" ? "checked" : ""} ${busy ? "disabled" : ""}>${L("Another folder…")}</label></div>`,
        ...(s.Storage === "onedrive" && accounts.length > 1 ? [item(L("Account"), `<select class="field" id="onedrive-account">${accounts.map(a =>
            `<option value="${esc(a.path)}" ${a.path === s.OneDrivePath ? "selected" : ""}>${esc(a.name)}</option>`).join("")}</select>`)] : []),
        caption(desc),
        ...(s.Storage !== "local" && s.AudioRetentionDays !== 0 ? [caption(tr("Audio files (~230 MB per hour) are synced too — turn off “Keep audio files” to sync only the notes."))] : []),
        `<div class="item"><span class="caption ellipsis grow" title="${esc(s.NotesFolder)}">${esc(s.NotesFolder)}</span>
          <button class="btn small" data-do="openFolder">${L("Open")}</button>
          ${s.Storage === "custom" ? `<button class="btn small" data-storage-change="custom" ${busy ? "disabled" : ""}>${L("Change…")}</button>` : ""}</div>`,
        ...(busy ? [caption(tr("Can be changed when nothing is recording or processing."))] : []),
        `<div id="move-ask"></div>`,
      ]) +
      group(tr("Audio recordings"), [item(L("Delete audio recordings"), select("AudioRetentionDays", RETENTION.map(([d, l]) => [d, tr(l)]), s.AudioRetentionDays))],
            tr("Notes and transcripts are kept. The audio — including the short voice samples used to name speakers — is deleted.")) +
      group(tr("Remove Hesper"), [
        caption(engineBytes ? tr("The engine, the AI models and your settings use %@ (in %LOCALAPPDATA%\\Hesper). This removes everything, then Hesper itself.", fmtBytes(engineBytes))
                            : tr("Measuring the engine and AI models…")),
        item(L("Also move my meeting notes to the Trash"), `<label class="toggle"><input type="checkbox" id="remove-notes"><span></span></label>`),
        item(L("Uninstall"), `<button class="btn small danger" id="uninstall" ${busy || state.setup ? "disabled" : ""}>${L("Remove Hesper…")}</button>`),
        `<div id="uninstall-ask"></div>`,
      ]);
  }
  else if (pane === "voices") {
    voices = await call("voices") ?? [];
    el.innerHTML = group(tr("Known voices"), [
      caption(pc(tr("Name the speakers of a meeting (⋯ → Name the speakers) and Hesper recognises them next time. Voiceprints stay on this Mac."))),
      ...(voices.length ? voices.map(v => item(esc(v), `<button class="btn small" data-forget="${esc(v)}">${L("Forget")}</button>`))
                        : [caption(tr("No voices learned yet."))]),
    ]);
  }
  else if (pane === "about") {
    const u = state.update ?? {}, info = u.available;
    el.innerHTML = `<div class="row" style="gap:16px;padding:4px 2px">${appIcon(64)}<div><div class="wordmark" style="font-size:28px">Hesper</div>
        <div class="secondary">${L("Private meeting notes, fully offline")} · ${esc(state.version.replace(/\.0$/, ""))}</div></div></div>` +
      group("", [
        ...(info ? [item(L("Update available"), `<button class="btn small primary" data-do="installUpdate" ${state.recording || state.job || u.state === "downloading" ? "disabled" : ""}>${esc(tr("Install %@ and restart", info.version))}</button>`),
                    ...(info.notes ? [caption(info.notes)] : []),
                    ...(state.recording || state.job ? [caption(tr("Available once nothing is recording or processing."))] : [])]
                 : [item(L("Updates"), `<button class="btn small" data-do="checkUpdate">${L(u.state === "checking" ? "Checking…" : "Check now")}</button>`),
                    ...(u.checked ? [caption(tr("Up to date · checked %@", u.checked))] : [])]),
        ...(u.state === "downloading" ? [`<div class="item" style="flex-direction:column;align-items:stretch;gap:6px"><span class="caption">${L("Downloading the update…")}</span>${progressBar(u.progress)}</div>`] : []),
        ...(u.state === "failed" ? [`<div class="item error-text">${esc(u.error)}</div>`] : []),
        line(`<a data-url="${REPO}/releases">${L("Release notes")}</a>`),
        item(L("Receive test versions"), toggle("TestVersions", s.TestVersions), L("Versions with fixes still being tried, before they're released to everyone. Same signature checks as releases.")),
      ]) +
      group(tr("Open source"), [
        `<div class="item"><div style="width:22px;height:22px;color:var(--accent)">${glyph("currentColor")}</div><div class="label"><b>${L("Hesper is free and open source")}</b>
          <div class="caption2">${L("Like it? A star on GitHub helps other people find it.")}</div></div>
          <button class="btn small primary" data-url="${REPO}">${L("Star on GitHub")}</button></div>`,
        item(L("Source code"), `<a data-url="${REPO}">github.com/Gbally/Hesper</a>`),
        item(L("Bugs and ideas"), `<a data-url="${REPO}/issues/new">${L("Report a problem…")}</a>`),
        item(L("License"), `<a data-url="${REPO}/blob/main/LICENSE">MIT</a> · <a data-url="${REPO}/blob/main/PRIVACY.md">${L("Privacy")}</a> · <a data-url="${REPO}/blob/main/THIRD_PARTY_NOTICES.md">${L("Third-party licenses")}</a>`),
      ]) +
      group(tr("Credits"), [caption(tr("Speech: OpenAI Whisper (MIT), via faster-whisper. Notes: Qwen (Apache 2.0), via llama.cpp. Speaker separation: pyannote segmentation (MIT) and NVIDIA TitaNet (CC BY 4.0), via sherpa-onnx."))]) +
      `<div class="caption" style="text-align:center">${L("by Nibjorg Studio")} · <a data-do="log">${L("Open the log")}</a></div>`;
  }
  bindPane(el);
}

const hhmm = m => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
const fmtBytes = b => b > 1e9 ? `${(b / 1e9).toFixed(1)} GB` : `${Math.round(b / 1e6)} MB`;

function bindPane(el) {
  const s = state.settings;
  el.onchange = async e => {
    const t = e.target;
    if (t.dataset.lang) {
      const set = new Set(s.Languages.split(",").filter(Boolean));
      t.checked ? set.add(t.dataset.lang) : set.delete(t.dataset.lang);
      await save({ Languages: [...set].join(",") });
      return drawPane();
    }
    if (t.dataset.window) {
      const [h, m] = t.value.split(":").map(Number);
      const windows = s.LaterWindows.map(w => [...w]);
      windows[+t.dataset.window][+t.dataset.end] = h * 60 + m;
      return save({ LaterWindows: windows });
    }
    if (t.dataset.storage) return changeStorage(t.dataset.storage);
    if (t.id === "onedrive-account") return changeStorage("onedrive", t.value);
    const key = t.dataset.key;
    if (!key) return;
    if (key === "@login") return call("setLaunchAtLogin", { on: t.checked });
    const value = t.type === "checkbox" ? t.checked : t.type === "number" || key === "AudioRetentionDays" ? +t.value : t.value;
    await save({ [key]: value });
    if (key === "AppLanguage") { await loadLanguage(state.settings); renderSettings(); }
    else if (["EmailApp", "NotesTiming", "LaterInWindows", "LaterWhenIdle", "AutoExport", "TestVersions", "AudioRetentionDays"].includes(key)) drawPane();
    if (key === "TestVersions") call("checkUpdate");
  };
  el.onclick = async e => {
    const t = e.target;
    const seg = t.closest("[data-seg]");
    if (seg) {
      if (seg.dataset.seg === "@custom") { customSpeech = seg.dataset.value === "speech"; return drawPane(); }
      await save({ [seg.dataset.seg]: seg.dataset.value });
      return drawPane();
    }
    const url = t.closest("[data-url]")?.dataset.url;
    if (url) return call("openUrl", { url });
    const d = t.closest("[data-do]")?.dataset.do;
    if (d === "openFolder") call("openFolder");
    if (d === "log") call("openLog");
    if (d === "showHome") call("showHome");
    if (d === "checkUpdate") call("checkUpdate");
    if (d === "installUpdate") call("installUpdate");
    if (d === "reinstall" && confirm(tr("Reinstall the engine? Downloaded models are kept."))) call("startSetup");
    if (d === "exportFolder") { const f = await call("chooseFolder", { title: tr("Copy notes to a folder") }); if (f) { await save({ ExportFolder: f }); drawPane(); } }
    if (d === "exportRemove") { await save({ ExportFolder: "", AutoExport: false }); drawPane(); }
    if (t.closest("[data-storage-change]")) changeStorage("custom");
    const f = t.closest("[data-forget]")?.dataset.forget;
    if (f && confirm(tr("Forget %@'s voice?", f))) { await call("forgetVoice", { name: f }); drawPane(); }
    const use = t.closest("[data-use]");
    if (use) { await call("useModel", { repo: use.dataset.use, speech: use.dataset.speech === "true" }); models = null; }
    const del = t.closest("[data-delete-model]")?.dataset.deleteModel;
    if (del && confirm(tr("Delete %@?", del.split("/").pop()))) { await call("deleteModel", { repo: del }); models = null; }
    if (t.id === "custom-check") { customLink[customSpeech] = $("#custom-link").value; call("checkModel", { repo: customLink[customSpeech], speech: customSpeech }); }
    if (t.id === "custom-use" && confirm(tr("It isn't tested with Hesper. If results look wrong or processing fails, switch back to the recommended model here.")))
      call("useModel", { repo: state.modelJob.repo, speech: customSpeech });
    if (t.id === "add-window") { await save({ LaterWindows: [...s.LaterWindows, [18 * 60, 20 * 60]] }); drawPane(); }
    const rw = t.closest("[data-remove-window]")?.dataset.removeWindow;
    if (rw != null) { await save({ LaterWindows: s.LaterWindows.filter((_, i) => i !== +rw) }); drawPane(); }
    if (t.id === "hotkey") { hotkeyRecording = true; drawPane(); }
    if (t.id === "hotkey-clear") { await save({ Hotkey: "" }); drawPane(); }
    if (t.id === "uninstall") {
      const notes = $("#remove-notes").checked;
      $("#uninstall-ask").innerHTML = `<div class="item" style="flex-direction:column;align-items:stretch;gap:8px"><b>${P("Remove Hesper from this Mac?")}</b>
        <div class="caption">${P(notes ? "Deletes the engine, the AI models, your settings and learned voices, and moves the app and your notes to the Trash. Hesper then quits."
                                       : "Deletes the engine, the AI models, your settings and learned voices, and moves the app to the Trash. Your notes are kept. Hesper then quits.")}</div>
        <div class="row"><span class="grow"></span><button class="btn small" id="uninstall-no">${L("Cancel")}</button><button class="btn small danger" id="uninstall-yes">${L("Remove Hesper")}</button></div></div>`;
      $("#uninstall-no").onclick = () => $("#uninstall-ask").innerHTML = "";
      $("#uninstall-yes").onclick = () => call("uninstall", { notes });
    }
  };
  el.querySelector("#custom-link")?.addEventListener("keydown", e => { if (e.key === "Enter") $("#custom-check").click(); });
}

// The shortcut field: the next key pressed with Ctrl, Alt or Win is the shortcut
addEventListener("keydown", async e => {
  if (!hotkeyRecording) return;
  e.preventDefault();
  if (e.key === "Escape") { hotkeyRecording = false; return drawPane(); }
  if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
  if (!e.ctrlKey && !e.altKey && !e.metaKey) return;
  const key = e.code.startsWith("Key") ? e.code.slice(3) : e.code.startsWith("Digit") ? e.code.slice(5) : e.key.length === 1 ? e.key.toUpperCase() : e.code;
  const combo = [e.ctrlKey && "Ctrl", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "Win", key].filter(Boolean).join("+");
  hotkeyRecording = false;
  await save({ Hotkey: combo });
  drawPane();
}, true);

/// Where the notes go; with meetings already there, asks whether to move them (as the Mac does).
async function changeStorage(storage, path = "") {
  if (storage === "custom" && !path) path = await call("chooseFolder", { title: tr("Another folder…") }) ?? "";
  if (storage === "custom" && !path) return drawPane();
  const r = await call("changeStorage", { storage, path });
  if (typeof r === "number") {
    $("#move-ask").innerHTML = `<div class="item" style="flex-direction:column;align-items:stretch;gap:8px">
      <b>${esc(tr("Move your %@ existing meeting(s) to the new location?", r))}</b>
      <div class="caption">${L("Meetings left behind won't show in the history, but stay in their folder.")}</div>
      <div class="row"><span class="grow"></span><button class="btn small" id="move-no">${L("Leave them where they are")}</button>
        <button class="btn small primary" id="move-yes">${L("Move them")}</button></div></div>`;
    $("#move-no").onclick = async () => { await call("changeStorage", { storage, path, move: false }); await refresh(); drawPane(); };
    $("#move-yes").onclick = async () => {
      const res = await call("changeStorage", { storage, path, move: true });
      await refresh(); drawPane();
      if (String(res).startsWith("failed:")) alert(tr("%@ meeting(s) couldn't be moved — they're still in %@.", res.slice(7), ""));
    };
    return;
  }
  await refresh();
  drawPane();
}

// ============================================================ first launch
let step = 0;
function renderWelcome() {
  document.title = tr("Welcome to Hesper");
  const s = state.settings;
  const steps = 4;
  const pages = [
    () => `<div style="display:flex;flex-direction:column;align-items:center;text-align:center;gap:10px;padding-top:30px">${appIcon(96)}
      <div class="title2" style="font-size:26px">${esc(tr("Welcome to Hesper"))}</div>
      <div class="secondary" style="font-size:15px">${esc(tr("Meeting notes that never leave your PC."))}</div>
      <div class="caption" style="max-width:420px;margin-top:10px">${esc(tr("Everything stays on this PC: recordings, transcripts, notes and the AI that writes them."))}</div></div>`,
    () => group(tr("You"), [item(L("Your name"), text("MyName", s.MyName))], tr("Used for your voice in transcripts and to find the to-dos that are yours.")) +
      `<div><div class="group-title">${esc(tr("Languages spoken in your meetings"))}</div><div class="group"><div class="langs">${
        Object.entries(SPOKEN).slice(0, 9).map(([c, l]) => `<label class="check"><input type="checkbox" data-lang="${c}" ${s.Languages.split(",").includes(c) ? "checked" : ""}>${esc(languageName(c))}</label>`).join("")}</div></div></div>`,
    () => group(tr("Audio"), [
        item(L("Microphone"), select("Microphone", [["", tr("Windows default")], ...(devices?.mics ?? []).map(d => [d, d])], s.Microphone)),
        item(L("PC sound from"), select("Speakers", [["", tr("Windows default")], ...(devices?.speakers ?? []).map(d => [d, d])], s.Speakers)),
      ]) + `<div class="caption">${esc(tr("Hesper records your microphone and what your PC plays (the other people in a call)."))}</div>`,
    () => `<div style="display:flex;flex-direction:column;align-items:center;text-align:center;gap:14px;padding-top:30px">
      <div style="width:64px;height:64px;color:var(--accent)">${glyph("currentColor")}</div>
      <div class="title2">${esc(tr("You're all set"))}</div>
      <div class="secondary" style="max-width:440px">${esc(tr("Click Hesper's icon in the notification area (bottom right, maybe under ^), then the record button when a meeting starts. Your notes appear there when it ends."))}</div></div>`,
  ];
  const setup = state.setup, ready = state.ready;
  $("#app").innerHTML = `<div class="window">
    <div class="pane welcome grow"><div class="steps">${Array.from({ length: steps }, (_, i) => `<div class="${i <= step ? "on" : ""}"></div>`).join("")}</div>
      <div id="page">${pages[step]()}</div></div>
    ${step > 0 ? `<div style="padding:0 32px">${ready ? "" : setup ? `<div class="caption" style="margin-bottom:6px">${esc(tr(setup.text))}</div>${progressBar(setup.progress)}`
      : state.setupError ? `<div class="error-text">${esc(tr("Setup stopped"))}: ${esc(state.setupError)}</div>` : ""}</div>` : ""}
    <div class="welcome-foot">
      ${step > 0 ? `<button class="btn" id="back">${esc(tr("Back"))}</button>` : ""}
      <span class="grow"></span>
      ${!ready && !setup && state.setupError ? `<button class="btn" id="retry">${esc(tr("Try again"))}</button>` : ""}
      ${step === 0 ? `<button class="btn primary" id="next">${esc(tr("Get started"))}</button>`
        : step < steps - 1 ? `<button class="btn primary" id="next">${esc(tr("Continue"))}</button>`
        : `<button class="btn primary" id="done" ${ready ? "" : "disabled"}>${esc(ready ? tr("Done") : tr("Hesper is setting up…"))}</button>`}
    </div></div>`;
  $("#back") && ($("#back").onclick = () => { step--; renderWelcome(); });
  $("#retry") && ($("#retry").onclick = () => call("startSetup"));
  $("#next") && ($("#next").onclick = async () => {
    if (step === 0 && !state.ready) call("startSetup");
    if (step === 1) devices ??= await call("devices");
    step++; renderWelcome();
  });
  $("#done") && ($("#done").onclick = async () => { await call("welcomed"); call("close"); });
  $("#page").onchange = async e => {
    const t = e.target, s2 = { ...state.settings };
    if (t.dataset.lang) {
      const set = new Set(s2.Languages.split(",").filter(Boolean));
      t.checked ? set.add(t.dataset.lang) : set.delete(t.dataset.lang);
      s2.Languages = [...set].join(",");
    } else if (t.dataset.key) s2[t.dataset.key] = t.value;
    state.settings = s2;
    await call("saveSettings", { settings: s2 });
  };
}

// ============================================================ routing
function route() {
  const [page, arg] = decodeURIComponent(location.hash.slice(1)).split(/\/(.*)/s);
  return { page: page || "home", arg: arg ?? "" };
}

function render() {
  const { page, arg } = route();
  if (page === "home") { homeView = "home"; renderHome(); }
  else if (page === "meeting") loadMeeting(arg);
  else if (page === "settings") { pane = arg || pane; renderSettings(); }
  else if (page === "welcome") renderWelcome();
}

handlers.state = async data => {
  const before = JSON.stringify(state?.settings);
  if (data) state = data; else await refresh();
  if (JSON.stringify(state.settings) !== before) await loadLanguage(state.settings);
  const { page, arg } = route();
  if (page === "home") { drawContent(); drawTabs(); }
  else if (page === "meeting") { if (view !== "speakers") loadMeeting(arg); }
  else if (page === "welcome") { if (!document.activeElement?.matches("input")) renderWelcome(); }
  else if (page === "settings" && ["models", "about", "privacy", "general"].includes(pane) && !document.activeElement?.matches("input:not([type=checkbox]):not([type=radio]), select")) drawPane();
};
handlers.live = data => drawLive(data);
handlers.view = v => { if (route().page === "home") { homeView = v; renderHome(); } };
addEventListener("hashchange", render);
addEventListener("keydown", e => { if (e.key === "Escape" && route().page === "home" && !search) call("hide"); });

(async () => {
  await refresh();
  if (!state) {  // a plain browser: a sample state, to look at the design
    state = { ready: true, settings: { MyName: "Guillaume", Languages: "en,fr", NotesFolder: "C:\\Users\\you\\Documents\\MeetingNotes", TodoFilter: "standard",
              Template: "general", SummaryStyle: "standard", NotesLanguage: "auto", Vocabulary: "", Microphone: "", Speakers: "", NotifyWhenReady: true, AppLanguage: "" },
              busy: [], meetings: [
                { id: "a", title: "Android 12 Login Fix Update", date: new Date().toISOString(), duration: 1520, hasNotes: true, actions: [{ owner: "Guillaume", task: "Call the vendor about the API keys", due_date: new Date().toISOString().slice(0, 10) }, { owner: "Priya", task: "fix login crash" }], done: [] },
                { id: "b", title: "Client pilot review", date: "2026-11-18T14:00:00", duration: 2710, hasNotes: true, actions: [], done: [] }],
              version: "0.7.0.0", gpu: true };
  }
  await loadLanguage(state.settings);
  render();
})();
