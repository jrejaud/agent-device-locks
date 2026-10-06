#!/usr/bin/env node
// watch.mjs — runs the overlay for one screen claim and turns its button presses into
// state the driving agent cannot miss. Started (detached) by `screen-claim start`.
//
//   watch.mjs --state <dir> --label "<who>" --desc "<goal>" [--consent 15]
//
// What each button does:
//   Pause   → interrupt.json {kind:"pause"} + kill any in-flight peekaboo/cliclick.
//             The PreToolUse hook now DENIES every screen-driving call, and the deny
//             reason tells the agent it was paused. Resume clears it.
//   Cancel  → interrupt.json {kind:"cancel"}: same halt, but the agent is told to drop the task.
//   Talk    → pauses, then appends the message to inbox.jsonl; the hook's deny reason
//             carries it to the agent on its next screen action.
//   I'm busy (during the countdown) → decision "deny"; `screen-claim start` exits 3.
//
// Optional hooks out (env):
//   SCREEN_CLAIM_NOTIFY_CMD  run with one argument (the message) on every press — e.g. a
//                            script that types into the agent's terminal, or a phone push.
//   SCREEN_CLAIM_FOCUS_CMD   shell command for the "Go to session" button (shown only if set).
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const STATE = opt('state');
const label = opt('label', 'an agent');
const desc = opt('desc', 'driving this Mac');
const consent = opt('consent', '15');
const BIN = process.env.SCREEN_CLAIM_OVERLAY || path.join(here, '..', 'overlay', 'agent-overlay-mac');
const NOTIFY = process.env.SCREEN_CLAIM_NOTIFY_CMD || '';
const FOCUS = process.env.SCREEN_CLAIM_FOCUS_CMD || '';

const f = (n) => path.join(STATE, n);
const LOCK = f('lock.json'), INTR = f('interrupt.json'), INBOX = f('inbox.jsonl'),
      DECISION = f('decision'), DOING = f('doing');

const log = (m) => console.log(`[screen-claim] ${new Date().toISOString()} ${m}`);
const run = (cmd, a, timeout = 15000) => {
  try { return execFileSync(cmd, a, { encoding: 'utf8', timeout }); } catch { return null; }
};

function notify(text) {
  if (!NOTIFY) return;
  try { spawn('/bin/sh', ['-c', `${NOTIFY} "$1"`, 'sh', text], { stdio: 'ignore', detached: true }).unref(); }
  catch (e) { log(`notify failed: ${e.message}`); }
}

// A Pause that only raised a flag would let an in-flight `peekaboo type` finish typing.
function killDrivers() {
  for (const name of ['peekaboo', 'cliclick']) run('pkill', ['-x', name]);
  run('pkill', ['-f', '(^|/)(peekaboo|cliclick)( |$)']);
  log('killed running screen drivers (peekaboo/cliclick)');
}

function halt(kind, message) {
  fs.writeFileSync(INTR, JSON.stringify({ kind, message, at: new Date().toISOString() }) + '\n');
  killDrivers();
  log(`${kind.toUpperCase()}: ${message}`);
  notify(message);
}

const decide = (d) => fs.writeFileSync(DECISION, d + '\n');

const child = spawn(BIN, ['--who', label, '--desc', desc, '--consent', consent, '--go', FOCUS ? '1' : '0'],
  { stdio: ['pipe', 'pipe', 'pipe'] });
const send = (line) => { try { child.stdin.write(line + '\n'); } catch {} };

let buf = '';
child.stdout.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    const m = line.match(/^(GRANT|DENY|STOP|RESUME|CANCEL|MSG|FOCUS)\s*([\s\S]*)$/);
    if (!m) continue;
    const [, verb, payload] = m;
    if (verb === 'GRANT') { log('consent granted (countdown ran out)'); decide('grant'); }
    else if (verb === 'DENY') { decide('deny'); halt('deny', 'The user clicked "I\'m busy" — do not take control of the screen.'); }
    else if (verb === 'STOP') halt('pause', 'The user pressed PAUSE on the screen overlay. Stop touching the screen; keep your place and do not undo anything. Tell them what state the screen is in, then wait for Resume.');
    else if (verb === 'CANCEL') halt('cancel', 'The user pressed CANCEL on the screen overlay. The task is called OFF: stop driving, run `screen-claim stop`, abandon the task, and report exactly what state you left the screen in.');
    else if (verb === 'RESUME') { try { fs.rmSync(INTR); } catch {} log('RESUME — driving allowed again'); notify('The user pressed RESUME on the screen overlay — you may continue. Say what you are resuming before touching anything.'); }
    else if (verb === 'MSG' && payload) {
      fs.appendFileSync(INBOX, JSON.stringify({ at: new Date().toISOString(), text: payload }) + '\n');
      log(`MESSAGE: ${payload}`);
      notify(`Message from the user via the screen overlay: "${payload}"`);
    }
    else if (verb === 'FOCUS' && FOCUS) spawn('/bin/sh', ['-c', FOCUS], { stdio: 'ignore', detached: true }).unref();
  }
});
child.stderr.on('data', (d) => log(`overlay: ${d.toString().trim()}`));
child.on('exit', (c) => { log(`overlay exited (${c})`); if (!fs.existsSync(DECISION)) decide('deny'); cleanup(0); });

// `screen-claim doing "<text>"` writes the status line; forward it to the overlay.
let last = '';
fs.watchFile(DOING, { interval: 700 }, () => {
  try { const t = fs.readFileSync(DOING, 'utf8').trim(); if (t && t !== last) { last = t; send('DOING ' + t); } } catch {}
});

// A locked or sleeping display means every click lands on the lock screen: stay awake for
// the overlay's lifetime, and declare user activity every 30 s so the screensaver never starts.
const awake = spawn('caffeinate', ['-d', '-i', '-w', String(process.pid)], { stdio: 'ignore' });
const nudge = setInterval(() => run('caffeinate', ['-u', '-t', '2'], 5000), 30000);

// Never outlive the claim: when lock.json disappears (screen-claim stop), close.
const poll = setInterval(() => {
  if (!fs.existsSync(LOCK)) { log('claim released — closing the overlay'); send('HIDE'); setTimeout(() => cleanup(0), 400); }
}, 2000);

let done = false;
function cleanup(code) {
  if (done) return; done = true;
  clearInterval(poll); clearInterval(nudge);
  try { awake.kill('SIGTERM'); } catch {}
  fs.unwatchFile(DOING);
  try { child.kill('SIGTERM'); } catch {}
  process.exit(code);
}
process.on('SIGTERM', () => { send('HIDE'); setTimeout(() => cleanup(0), 300); });
process.on('SIGINT', () => cleanup(0));
log(`overlay up for ${label}: ${desc}`);
