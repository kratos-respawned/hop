let shareWebPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<title>Hop</title>
<style>
:root { --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --muted: #6e6e73; --line: #e5e5ea; --accent: #007aff; --soft: #e8f1ff; --bad: #d70015; color-scheme: light dark; }
@media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --line: #2c2c2e; --accent: #0a84ff; --soft: #0a2540; --bad: #ff6961; } }
* { box-sizing: border-box; margin: 0; }
body { font: 16px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text);
       padding: calc(env(safe-area-inset-top) + 8px) 16px calc(env(safe-area-inset-bottom) + 32px); -webkit-text-size-adjust: 100%; }
main { max-width: 760px; margin: 0 auto; }
header { display: flex; align-items: center; gap: 12px; padding: 16px 0 8px; }
.logo { width: 44px; height: 44px; border-radius: 12px; flex: none; display: grid; place-items: center; color: #fff;
        background: linear-gradient(160deg, #5ac8fa, #007aff); }
h1 { font-size: 22px; line-height: 1.2; overflow-wrap: anywhere; }
.muted { color: var(--muted); font-size: 14px; }
.card { background: var(--card); border-radius: 14px; overflow: hidden; margin-top: 12px; }
.drop { display: block; margin-top: 16px; padding: 28px 16px; text-align: center; border: 2px dashed var(--line); border-radius: 14px;
        background: var(--card); cursor: pointer; transition: border-color .15s, background .15s; }
.drop.over { border-color: var(--accent); background: var(--soft); }
.drop strong { display: block; font-size: 17px; margin-top: 8px; }
.drop svg { color: var(--accent); }
.button { display: inline-block; margin-top: 14px; padding: 12px 22px; border-radius: 12px; background: var(--accent); color: #fff; font-weight: 600; }
input[type=file] { display: none; }
h2 { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 24px 4px 0; }
.crumbs { display: flex; flex-wrap: wrap; gap: 2px 6px; margin: 20px 4px 0; font-size: 15px; }
.crumbs a { color: var(--accent); text-decoration: none; }
.crumbs span { color: var(--muted); }
.row { display: flex; align-items: center; gap: 12px; padding: 12px 14px; min-height: 60px; color: inherit; text-decoration: none; }
.row + .row { border-top: 1px solid var(--line); }
a.row:active, a.row:hover { background: var(--soft); }
.icon { width: 36px; height: 36px; flex: none; border-radius: 9px; display: grid; place-items: center; background: var(--soft); color: var(--accent); }
.grow { flex: 1; min-width: 0; }
.name { font-weight: 500; overflow-wrap: anywhere; }
.meta { color: var(--muted); font-size: 13px; }
.meta.bad { color: var(--bad); }
.chevron { color: var(--muted); flex: none; }
.bar { height: 4px; border-radius: 2px; background: var(--line); margin-top: 6px; overflow: hidden; }
.bar i { display: block; height: 100%; width: 0; background: var(--accent); transition: width .2s; }
.empty { padding: 28px 16px; text-align: center; color: var(--muted); }
.ended { margin-top: 40px; text-align: center; }
.ended h1 { margin-bottom: 8px; }
@media (min-width: 700px) { .drop { padding: 40px 24px; } }
</style>
</head>
<body>
<main>
  <header>
    <div class="logo"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M2 9a15 15 0 0 1 20 0M5.5 12.5a10 10 0 0 1 13 0M9 16a5 5 0 0 1 6 0"/><circle cx="12" cy="19.5" r="1.2" fill="currentColor"/></svg></div>
    <div class="grow"><h1 id="title"></h1><div class="muted" id="what"></div></div>
  </header>
  <label class="drop" id="drop" hidden>
    <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4M7 9l5-5 5 5M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3"/></svg>
    <strong>Send files to this Mac</strong>
    <span class="muted" id="dropHint">Pick photos, videos or any files</span><br>
    <span class="button">Choose files</span>
    <input type="file" id="picker" multiple>
  </label>
  <section id="sending" hidden><h2>Sending</h2><div class="card" id="sendList"></div></section>
  <section id="browse" hidden><nav class="crumbs" id="crumbs"></nav><div class="card" id="list"></div></section>
</main>
<script>
const hop = __HOP__;
const canList = hop.mode !== 'receive', canUpload = hop.mode !== 'share';
const folderIcon = '<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M3 6.5A2.5 2.5 0 0 1 5.5 4h4l2 2.5h7A2.5 2.5 0 0 1 21 9v8.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/></svg>';
const fileIcon = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/></svg>';
const downloadIcon = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v12M7 11l5 5 5-5M5 20h14"/></svg>';
const chevron = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg>';

const el = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text != null) node.textContent = text; return node; };
const $ = id => document.getElementById(id);
const here = () => decodeURIComponent(location.hash.slice(1));
const join = (folder, name) => folder ? folder + '/' + name : name;
const size = bytes => { const units = ['bytes', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++; } return i ? bytes.toFixed(bytes < 10 ? 1 : 0) + ' ' + units[i] : bytes + (bytes === 1 ? ' byte' : ' bytes'); };
const date = seconds => new Date(seconds * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });

$('title').textContent = hop.name;
$('what').textContent = { receive: 'Send files to this Mac', share: 'Browse and download', both: 'Browse, download and add files' }[hop.mode];
$('drop').hidden = !canUpload;
if (hop.mode === 'both') $('dropHint').textContent = 'They go into the folder you have open below';

function ended() {
  document.querySelector('main').replaceChildren();
  const box = el('div', 'ended');
  box.append(el('h1', null, 'This share has ended'), el('p', 'muted', 'Ask for a new link from the Mac.'));
  document.querySelector('main').append(box);
}

function row(icon, name, meta, end) {
  const node = el('div', 'row'), info = el('div', 'grow');
  const badge = el('div', 'icon'); badge.innerHTML = icon;
  info.append(el('div', 'name', name), el('div', 'meta', meta));
  node.append(badge, info);
  if (end) { const tail = el('div', 'chevron'); tail.innerHTML = end; node.append(tail); }
  return node;
}

async function load() {
  if (!canList) return;
  let entries;
  try {
    const response = await fetch('list?path=' + encodeURIComponent(here()));
    if (response.status === 404 && here()) { location.hash = ''; return; }
    if (!response.ok) return ended();
    entries = (await response.json()).entries;
  } catch { return ended(); }

  const crumbs = $('crumbs'); crumbs.replaceChildren();
  const parts = here().split('/').filter(Boolean);
  [hop.name, ...parts].forEach((name, index) => {
    if (index) crumbs.append(el('span', null, '/'));
    const link = el('a', null, name); link.href = '#' + encodeURIComponent(parts.slice(0, index).join('/'));
    crumbs.append(link);
  });

  entries.sort((a, b) => (b.folder - a.folder) || a.name.localeCompare(b.name, undefined, { numeric: true }));
  const list = $('list'); list.replaceChildren();
  if (!entries.length) list.append(el('div', 'empty', 'This folder is empty'));
  for (const entry of entries) {
    const path = join(here(), entry.name);
    const node = row(entry.folder ? folderIcon : fileIcon, entry.name, entry.folder ? 'Folder' : size(entry.size) + ' · ' + date(entry.modified), entry.folder ? chevron : downloadIcon);
    const link = el('a', 'row'); link.append(...node.childNodes);
    if (entry.folder) link.href = '#' + encodeURIComponent(path);
    else { link.href = 'file?path=' + encodeURIComponent(path); link.download = entry.name; }
    list.append(link);
  }
  $('browse').hidden = false;
}

function upload(file) {
  return new Promise(done => {
    const node = row(fileIcon, file.name, 'Waiting · ' + size(file.size));
    const bar = el('div', 'bar'), fill = el('i'); bar.append(fill); node.querySelector('.grow').append(bar);
    const meta = node.querySelector('.meta');
    $('sendList').prepend(node); $('sending').hidden = false;
    const request = new XMLHttpRequest();
    request.open('POST', 'upload?path=' + encodeURIComponent(here()) + '&name=' + encodeURIComponent(file.name));
    request.upload.onprogress = event => { const part = event.loaded / file.size; fill.style.width = (part * 100) + '%'; meta.textContent = Math.floor(part * 100) + '% of ' + size(file.size); };
    request.onload = () => {
      bar.remove();
      if (request.status === 200) meta.textContent = 'Sent · ' + size(file.size);
      else if (request.status === 404 && !canList) { done(); return ended(); }
      else { meta.textContent = request.responseText || 'Didn\'t send'; meta.classList.add('bad'); }
      done();
    };
    request.onerror = () => { bar.remove(); meta.textContent = 'Didn\'t send, check that the Mac is still sharing'; meta.classList.add('bad'); done(); };
    request.send(file);
  });
}

async function send(files) {
  for (const file of files) await upload(file);
  load();
}

$('picker').onchange = () => { send([...$('picker').files]); $('picker').value = ''; };
if (canUpload) {
  const drop = $('drop');
  addEventListener('dragover', event => { event.preventDefault(); drop.classList.add('over'); });
  addEventListener('dragleave', event => { if (!event.relatedTarget) drop.classList.remove('over'); });
  addEventListener('drop', event => { event.preventDefault(); drop.classList.remove('over'); send([...event.dataTransfer.files]); });
}
addEventListener('hashchange', load);
load();
</script>
</body>
</html>
"""#
