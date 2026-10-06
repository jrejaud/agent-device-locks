#!/usr/bin/env node
// agent-lock — a cross-agent mutex keyed by resource name, so several AI agents never
// drive the same thing (a phone, a tablet, a headset, this Mac's screen, any named
// resource) at once. One agent holds it, finishes its whole action, releases; the others
// wait in a QUEUE until it is their turn.
//
// Storage:
//   --device <serial>  → the lock lives ON THE DEVICE (/data/local/tmp/agent-locks/<res>.d,
//                        over adb). Agents on different machines driving the same device
//                        (USB or adb-over-network) all see one lock. Use for adb devices.
//   (default)          → a local lock at $AGENT_LOCK_DIR/<res>.d
//                        (default ~/.local/state/agent-locks). One machine's agents.
//
// TTL + stale reaping: a lock past `expires` is stale, so a crashed or forgetful agent
// cannot wedge the resource forever. Long jobs call `renew` to extend.
//
// A LIVE lock can never be taken away. `steal` only adopts a stale lock (or one that is
// already mine); against a live holder it refuses. `acquire` reaps stale locks on its own.
//
// Interrupt channel: anyone (notably the user, via a Stop button) can flag the current
// holder without owning the lock. `interrupt` raises a flag the holder is expected to
// check; it does NOT release the lock — only the holder tears its own work down cleanly.
// The flag lives inside the lock dir, so every caller that already reads lock state sees
// it for free, and `release` wipes it with the lock: a stop raised against one holder
// never leaks onto the next.
//
// Queue: a waiting `acquire` registers in `<res>.q/<holder>.json` next to the lock and
// heartbeats it every poll, so "who is waiting, since when, for what" is readable by
// anyone (`queue --json`). Service order is `<res>.q/order.json` when the user set one
// (`reorder`), then arrival time; a waiter only claims a free lock when it is FIRST among
// live waiters, so the order is enforced by the lock itself, not by a UI. A waiter whose
// heartbeat is older than 3 polls (min 30 s) is dead and ignored, so a crashed waiter
// cannot block the line.
//
// Master switch: `disable` writes `<res>.off` and every `acquire` refuses until `enable`.
// Enforced here, so a direct call cannot route around it.
//
// Holder identity must be STABLE across the many short-lived processes one agent spawns:
// --holder, else $AGENT_LOCK_HOLDER, else $CLAUDE_CODE_SESSION_ID@hostname, else
// pid@hostname (single-shot: it cannot renew or release from a later call).
//
// Usage:
//   agent-lock acquire   <res> [--device S] [--ttl 300] [--wait 600] [--poll 5] [--desc "..."]
//   agent-lock release   <res> [--device S] [--fence N]
//   agent-lock renew     <res> [--device S] [--ttl 300] [--fence N]
//   agent-lock status    <res> [--device S] [--json]
//   agent-lock steal     <res> [--device S] [--desc "..."]       # adopt a STALE lock only
//   agent-lock interrupt <res> [--device S] [--message "..."]    # raise the stop flag
//   agent-lock resume    <res> [--device S]                      # clear it
//   agent-lock queue     <res> [--device S] [--json]             # holder + waiters + order + switch
//   agent-lock reorder   <res> [--device S] --order h1,h2,...    # service order for waiters
//   agent-lock disable   <res> [--device S] [--message "..."]    # acquire refuses until enable
//   agent-lock enable    <res> [--device S]
// --fence N: refuse (exit 5) if the lock's token moved on (a holder that froze past its TTL).
// Exit: 0 ok · 2 usage · 4 acquire timed out (held by another) · 5 not held by me / refused
//       6 resource disabled
import { execFileSync } from 'node:child_process';
import { hostname } from 'node:os';
import fs from 'node:fs';
import path from 'node:path';

const VERBS = ['acquire','release','renew','status','steal','interrupt','resume','queue','reorder','disable','enable'];
const args = process.argv.slice(2);
const cmd = args[0], res = args[1];
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const has = (n) => args.includes('--' + n);
if (!cmd || !res || !VERBS.includes(cmd) || !/^[A-Za-z0-9._-]+$/.test(res)) {
  console.error(`usage: agent-lock <${VERBS.join('|')}> <resource> [--device S] [--ttl N] [--wait N] [--poll N] [--desc ...] [--message ...] [--order a,b] [--json]`);
  process.exit(2);
}
const device = opt('device', process.env.AGENT_LOCK_DEVICE || null);
const ttl = parseInt(opt('ttl', '300'), 10);
const wait = parseInt(opt('wait', '600'), 10);
const poll = parseInt(opt('poll', '5'), 10);
const desc = opt('desc', '');
const jsonOut = has('json');
const fenceArg = opt('fence') ? parseInt(opt('fence'), 10) : null;
const ME = opt('holder', process.env.AGENT_LOCK_HOLDER ||
  (process.env.CLAUDE_CODE_SESSION_ID ? `${process.env.CLAUDE_CODE_SESSION_ID}@${hostname()}` : `pid${process.pid}@${hostname()}`));
const now = () => Math.floor(Date.now() / 1000);
const sleep = (s) => execFileSync('sleep', [String(s)]);

// ---- storage backends: device (adb) vs local (fs). Both expose mkdir(atomic)/read/write/rm. ----
const parent = device ? '/data/local/tmp/agent-locks'
  : (process.env.AGENT_LOCK_DIR || path.join(process.env.HOME, '.local/state/agent-locks'));
const dir = `${parent}/${res}.d`;
const metaPath = `${dir}/meta.json`;
const intrPath = `${dir}/interrupt.json`;
// The queue lives BESIDE the lock dir, not inside it: a release must not erase the line.
const qDir = `${parent}/${res}.q`;
const orderPath = `${qDir}/order.json`;
const offPath = `${parent}/${res}.off`;
const fencePath = `${parent}/${res}.fence`;
// If you gate adb itself behind this lock (a wrapper on PATH), point AGENT_LOCK_ADB at the
// real binary: the lock's own reads and writes must not need the lock.
const ADB = process.env.AGENT_LOCK_ADB || 'adb';
const adb = (a) => execFileSync(ADB, ['-s', device, 'shell', a], { encoding: 'utf8' });
function readFile(p) {
  try { return device ? adb(`cat ${p} 2>/dev/null`) : fs.readFileSync(p, 'utf8'); } catch { return ''; }
}
function readJson(p) { try { const raw = readFile(p); return raw.trim() ? JSON.parse(raw) : null; } catch { return null; } }
function writeJson(p, o, mkdir) {
  const s = JSON.stringify(o);
  if (device) { adb(`mkdir -p ${mkdir}; cat > ${p} <<'__EOF__'\n${s}\n__EOF__`); }
  else { fs.mkdirSync(mkdir, { recursive: true }); fs.writeFileSync(p, s); }
}
function rmFile(p) { if (device) { try { adb(`rm -f ${p}`); } catch {} } else { try { fs.rmSync(p, { force: true }); } catch {} } }
function rmTree(p) { if (device) { try { adb(`rm -rf ${p}`); } catch {} } else { try { fs.rmSync(p, { recursive: true, force: true }); } catch {} } }
function listDir(p) {
  try {
    if (device) return adb(`ls ${p} 2>/dev/null`).split('\n').map((s) => s.trim()).filter(Boolean);
    return fs.readdirSync(p);
  } catch { return []; }
}
function tryMkdir() { // atomic exclusive create of the lock dir → true if we won it.
  // The PARENT must exist first, then the lock dir is created NON-recursively so it is
  // the atomic compare-and-set primitive: exactly one racer wins.
  if (device) { try { return adb(`mkdir -p ${parent}; mkdir ${dir} 2>/dev/null && echo OK || echo NO`).includes('OK'); } catch { return false; } }
  try { fs.mkdirSync(parent, { recursive: true }); } catch {}
  try { fs.mkdirSync(dir, { recursive: false }); return true; } catch { return false; }
}
const readMeta = () => readJson(metaPath);
/** Create meta.json only if it does not exist yet → true iff WE created it (atomic). */
function createMetaExclusive(o) {
  const s = JSON.stringify(o);
  if (device) {
    try { return adb(`mkdir -p ${dir}; (set -C; cat > ${metaPath}) 2>/dev/null <<'__EOF__' && echo OK || echo NO\n${s}\n__EOF__`).includes('OK'); } catch { return false; }
  }
  try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(metaPath, s, { flag: 'wx' }); return true; } catch { return false; }
}
const writeMeta = (m) => writeJson(metaPath, m, dir);
const readInterrupt = () => readJson(intrPath);
// mkdir -p the lock dir first: the user can hit Stop while an agent drives WITHOUT having
// taken the lock. The flag must still land, or the button does nothing for exactly the
// sloppy agent it most needs to stop.
const writeInterrupt = (o) => writeJson(intrPath, o, dir);
const clearInterrupt = () => rmFile(intrPath);
const expired = (m) => !m || !m.expires || m.expires <= now();
const mine = (m) => !!m && m.holder === ME;
const stateOf = (m) => !m ? 'free' : expired(m) ? 'stale' : mine(m) ? 'held-by-me' : 'held';

// ---- fencing token: a counter that only goes up, bumped by every successful claim. It is
// stored OUTSIDE the lock dir (release must not reset it) and only the exclusive winner
// writes it. A holder that froze past its TTL and comes back sees its token no longer
// matches meta.fence, so `renew/release --fence N` refuse instead of acting on a lock
// someone else now holds.
function nextFence() {
  const n = (parseInt((readFile(fencePath) || '0').trim(), 10) || 0) + 1;
  if (device) { try { adb(`echo ${n} > ${fencePath}`); } catch {} } else { try { fs.writeFileSync(fencePath, String(n)); } catch {} }
  return n;
}

// ---- race-safe reclaim of a dead holder's lock. rm -rf of a stale lock dir is unsafe:
// between reading the stale meta and the rm, another waiter can reap it AND claim a fresh
// lock, and the rm then destroys the live one. Instead RENAME the dir aside (atomic:
// exactly one reaper wins), then confirm the tombstone really is the stale lock we saw;
// if it turned out to be a fresh claim, rename it straight back.
function reclaimStale(seen) {
  const tomb = `${dir}.reap-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  if (device) {
    let o = '';
    try { o = adb(`mv ${dir} ${tomb} 2>/dev/null && echo OK || echo NO`); } catch {}
    if (!o.includes('OK')) return false;
  } else {
    try { fs.renameSync(dir, tomb); } catch { return false; } // someone else reaped it first
  }
  const t = readJson(`${tomb}/meta.json`);
  if (t && seen && (t.holder !== seen.holder || t.acquired !== seen.acquired)) {
    if (device) { try { adb(`mv ${tomb} ${dir}`); } catch {} } else { try { fs.renameSync(tomb, dir); } catch {} }
    return false;
  }
  rmTree(tomb);
  return true;
}

// ---- queue ----
const safeName = (h) => h.replace(/[^A-Za-z0-9._-]/g, '_');
const myEntry = `${qDir}/${safeName(ME)}.json`;
// Never below 30 s: an adb round trip on a busy device can take seconds, and a live
// waiter dropped for slowness would let the next one jump it.
const waiterDead = (w, pollSecs) => !w || !w.seen || now() - w.seen > Math.max(30, 3 * pollSecs);
function readWaiters() {
  const out = [];
  for (const f of listDir(qDir)) {
    if (!f.endsWith('.json') || f === 'order.json') continue;
    const w = readJson(`${qDir}/${f}`);
    if (w && w.holder) out.push(w);
  }
  return out;
}
const readOrder = () => { const o = readJson(orderPath); return o && Array.isArray(o.order) ? o.order : []; };
const readOff = () => readJson(offPath);
/** Live waiters in service order: the user's order first, then arrival. */
function serviceOrder(waiters) {
  const live = waiters.filter((w) => !waiterDead(w, w.poll || poll));
  const pinned = readOrder();
  const rank = (w) => { const i = pinned.indexOf(w.holder); return i < 0 ? Number.MAX_SAFE_INTEGER : i; };
  return live.sort((a, b) => rank(a) - rank(b) || (a.since || 0) - (b.since || 0) || a.holder.localeCompare(b.holder));
}
const enqueue = (since) => writeJson(myEntry, { holder: ME, desc, since, seen: now(), poll }, qDir);
const dequeue = () => rmFile(myEntry);
function firstInLine() { const q = serviceOrder(readWaiters()); return q.length === 0 || q[0].holder === ME; }

function claim() { // true if we now hold it
  // An UNOWNED dir (no meta.json) is adoptable: `interrupt` mkdir -p's the lock dir so a
  // Stop lands even with no holder, and without this that stray dir would wedge the
  // resource forever.
  if (!tryMkdir() && readMeta()) return false;
  // The real compare-and-set is the EXCLUSIVE create of meta.json, not the mkdir: an
  // unowned dir is also what a racer sees between another agent's mkdir and its meta
  // write. Whoever creates meta.json owns the lock; everyone else backs off.
  const stamp = { holder: ME, desc, acquired: now(), expires: now() + ttl };
  if (!createMetaExclusive(stamp)) return false;
  // A stop raised against a previous (or absent) holder must not block the next agent.
  // Only a FRESH claim clears it — renew does not, so an agent told to stop cannot
  // un-stop itself by acquiring again.
  clearInterrupt();
  writeMeta({ ...stamp, fence: nextFence() });
  return mine(readMeta());
}

const label = (m) => (m ? m.holder : '?');
const fail = (code, msg) => { console.error(msg); process.exit(code); };

if (cmd === 'interrupt') {
  // Deliberately NOT gated on holding the lock: a bystander (the user, via a Stop button)
  // raises it against whoever is driving.
  const m = readMeta();
  writeInterrupt({ at: now(), by: ME, message: opt('message', ''), target: m ? m.holder : null });
  console.log(`interrupt raised on ${res}${m ? ` (holder ${m.holder})` : ' (no holder)'}`);
  process.exit(0);
}
if (cmd === 'resume') { clearInterrupt(); console.log('interrupt cleared'); process.exit(0); }

if (cmd === 'status') {
  const m = readMeta(), intr = readInterrupt();
  // `mine` is reported for a STALE lock too: an agent whose own lease lapsed mid-run can
  // renew or re-acquire it without asking anyone again.
  if (jsonOut) console.log(JSON.stringify({ resource: res, device: device || null, state: stateOf(m), ...(m || {}), mine: mine(m), interrupted: !!intr, interrupt: intr, disabled: readOff(), now: now() }));
  else {
    console.log(m ? `${stateOf(m)}: holder=${m.holder} desc=${JSON.stringify(m.desc)} expires_in=${m.expires - now()}s` : 'free');
    if (intr) console.log(`INTERRUPTED by ${intr.by}${intr.message ? `: ${intr.message}` : ''}`);
  }
  process.exit(0);
}
if (cmd === 'queue') {
  const m = readMeta(), intr = readInterrupt(), off = readOff();
  const waiters = serviceOrder(readWaiters());
  const out = { resource: res, device: device || null, state: stateOf(m), holder: m && !expired(m) ? m : null, waiters, order: readOrder(), disabled: off, interrupted: !!intr, interrupt: intr, now: now() };
  if (jsonOut) console.log(JSON.stringify(out));
  else {
    console.log(m ? `${stateOf(m)}: holder=${m.holder} desc=${JSON.stringify(m.desc)}` : 'free');
    if (off) console.log(`DISABLED by ${off.by}${off.message ? `: ${off.message}` : ''}`);
    if (intr) console.log(`INTERRUPTED by ${intr.by}${intr.message ? `: ${intr.message}` : ''}`);
    waiters.forEach((w, i) => console.log(`  ${i + 1}. ${w.holder} — ${w.desc || '(no desc)'} (waiting ${now() - w.since}s)`));
    if (!waiters.length) console.log('  (nobody waiting)');
  }
  process.exit(0);
}
if (cmd === 'reorder') {
  const order = (opt('order', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
  writeJson(orderPath, { order, by: ME, at: now() }, qDir);
  console.log(`order set: ${order.join(' → ') || '(arrival order)'}`);
  process.exit(0);
}
if (cmd === 'disable') { writeJson(offPath, { by: ME, at: now(), message: opt('message', '') }, parent); console.log(`${res} disabled — acquire refuses until enable`); process.exit(0); }
if (cmd === 'enable') { rmFile(offPath); console.log(`${res} enabled`); process.exit(0); }
if (cmd === 'release') {
  const m = readMeta();
  if (!m) { console.log('already free'); process.exit(0); }
  if (!mine(m) && !expired(m)) fail(5, `NOT yours (held by ${label(m)})`);
  if (fenceArg && m.fence !== fenceArg) fail(5, `fence mismatch: you hold token ${fenceArg}, the lock is at ${m.fence} — someone else holds it now`);
  if (mine(m)) rmTree(dir); else reclaimStale(m); // a foreign STALE lock: reap it race-safely
  console.log('released'); process.exit(0);
}
if (cmd === 'renew') {
  const m = readMeta();
  if (!mine(m)) fail(5, 'cannot renew: not held by me');
  if (fenceArg && m.fence !== fenceArg) fail(5, `cannot renew: fence mismatch (yours ${fenceArg}, lock ${m.fence})`);
  writeMeta({ ...m, expires: now() + ttl }); console.log(`renewed +${ttl}s`); process.exit(0);
}
if (cmd === 'steal') {
  // A LIVE lock is never stealable: its holder keeps it until it releases or its TTL runs
  // out. `steal` only adopts a stale (crashed) lock or one that is already mine.
  const m = readMeta();
  if (m && !expired(m) && !mine(m)) fail(5, `refusing to steal: ${res} is held by ${label(m)} with ${m.expires - now()}s left. A live lock is not stealable — wait for it to expire or be released.`);
  if (m && !mine(m)) reclaimStale(m); else if (m) rmTree(dir);
  if (claim()) { console.log('stolen+acquired'); process.exit(0); }
  fail(4, 'steal failed');
}

// acquire: refuse a disabled resource, then wait in line until free-or-stale AND first,
// then claim; reap stale locks along the way.
{ const off = readOff(); if (off) fail(6, `${res} is DISABLED by ${off.by}${off.message ? `: ${off.message}` : ''} — run agent-lock enable ${res}`); }
const deadline = now() + wait;
const since = now();
let queued = false;
const leave = () => { if (queued) { queued = false; dequeue(); } };
process.on('exit', leave);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => { leave(); process.exit(130); });
for (;;) {
  const m = readMeta();
  if (mine(m)) { writeMeta({ ...m, expires: now() + ttl }); leave(); console.log('already mine (renewed)'); process.exit(0); }
  // First in line (or nobody waiting): take it. Otherwise hold position — jumping the one
  // ahead is exactly what the queue forbids. Only the FRONT waiter reaps a stale lock.
  if ((!m || expired(m)) && firstInLine() && (!m || reclaimStale(m) || !readMeta()) && claim()) {
    leave(); console.log(`acquired ${res}${device ? ' on ' + device : ''} (ttl ${ttl}s)`); process.exit(0);
  }
  if (now() >= deadline) { leave(); const h = readMeta(); fail(4, `timed out after ${wait}s; held by ${label(h)} (${h ? h.expires - now() : '?'}s left)`); }
  if (readOff()) { leave(); fail(6, `${res} was DISABLED while waiting`); }
  enqueue(since); queued = true; // registers on the first wait, heartbeats after
  // Jitter the poll so two waiters don't wake in lock-step and race for the same stale lock.
  sleep(Math.max(1, poll + (Math.random() * poll - poll / 2)).toFixed(2));
}
