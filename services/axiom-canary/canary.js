'use strict';

// axiom-canary: watches the axiom stream server (sergejbog/axiom-data, stack axiom-data on
// ex44) from Local and sends ntfy alerts. No dependencies: Node 22's fetch and WebSocket.
//
// Every INTERVAL_MS:
//   1. GET  $AXIOM_URL/selfcheck   (Bearer AXIOM_API_KEY): the server's own checks
//   2. WS   $AXIOM_URL/stream      (the key in the Authorization header, never in the URL,
//      which Traefik logs): subscribe to the selfcheck's probe token, expect a snapshot and
//      an update within STREAM_TIMEOUT_MS
// Alerts to $NTFY_URL/$NTFY_TOPIC (Bearer NTFY_TOKEN):
//   - after FAIL_RUNS failing runs in a row, again when the set of failures changes, a
//     reminder every REMIND_MS while it lasts, and one recovery message
//   - `outdated` checks (the site moved on, nothing broken yet): low priority, once per change
// With AUTOFIX_WEBHOOK_URL and AUTOFIX_WEBHOOK_SECRET set, each alert also goes to the autofix router (n8n) as
// firing/resolved events, fingerprinted by the failing check names. Best effort: never blocks or repeats an alert.
// State (open alert, streaks) survives restarts in STATE_FILE.
//
// usage: node canary.js [--runs N]   (default: forever; --runs 1 for a single run)

const fs = require('fs');
const path = require('path');

const DEFAULTS = {
    AXIOM_URL: 'https://axiom.sniperoo.app',
    NTFY_URL: 'https://notifications.sniperoo.app',
    NTFY_TOPIC: 'axiom',
    INTERVAL_MS: 10 * 60 * 1000,
    STREAM_TIMEOUT_MS: 30 * 1000,
    HTTP_TIMEOUT_MS: 90 * 1000,
    FAIL_RUNS: 2,
    REMIND_MS: 6 * 60 * 60 * 1000,
    // The server's selfcheck runs every 10 minutes; older than this means its loop is stuck.
    MAX_REPORT_AGE_MS: 25 * 60 * 1000,
    STATE_FILE: '/home/node/state.json',
};
const MAX_MESSAGE = 3500; // ntfy turns longer messages into attachments

function config(env) {
    const c = {};
    for (const [key, value] of Object.entries(DEFAULTS)) {
        const given = env[key];
        c[key] = given === undefined || given === '' ? value : typeof value === 'number' ? Number(given) : given;
    }
    c.AXIOM_URL = c.AXIOM_URL.replace(/\/+$/, '');
    c.NTFY_URL = c.NTFY_URL.replace(/\/+$/, '');
    c.AXIOM_API_KEY = env.AXIOM_API_KEY || '';
    c.NTFY_TOKEN = env.NTFY_TOKEN || '';
    c.AUTOFIX_WEBHOOK_URL = env.AUTOFIX_WEBHOOK_URL || '';
    c.AUTOFIX_WEBHOOK_SECRET = env.AUTOFIX_WEBHOOK_SECRET || '';
    return c;
}

const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const duration = (ms) => (ms < 90 * 60 * 1000 ? plural(Math.round(ms / 60000), 'minute') : plural(Math.round(ms / 3600000), 'hour'));
const shortList = (names) => (names.length <= 3 ? names.join(', ') : `${names.slice(0, 3).join(', ')} +${names.length - 3} more`);
const sameSet = (a, b) => a.length === b.length && a.every((x) => b.includes(x));

function createCanary({ env = process.env, fetch = globalThis.fetch, WebSocket = globalThis.WebSocket, now = Date.now, log = (...parts) => console.log(new Date().toISOString(), ...parts) } = {}) {
    const c = config(env);
    if (!c.AXIOM_API_KEY) throw new Error('AXIOM_API_KEY is not set (Infisical /axiom-canary)');
    if (!c.NTFY_TOKEN) throw new Error('NTFY_TOKEN is not set (Infisical /axiom-canary)');
    // Never echo a secret, even inside an error message.
    const scrub = (text) => {
        const out = String(text).split(c.AXIOM_API_KEY).join('<key>').split(c.NTFY_TOKEN).join('<token>');
        return c.AUTOFIX_WEBHOOK_SECRET ? out.split(c.AUTOFIX_WEBHOOK_SECRET).join('<secret>') : out;
    };

    // --- state ---

    function load() {
        try {
            return JSON.parse(fs.readFileSync(c.STATE_FILE, 'utf8'));
        } catch {
            return { failStreak: 0, alerting: false, alerted: [], alertedAt: 0, failingSince: 0, outdated: [] };
        }
    }

    function save(state) {
        const tmp = `${c.STATE_FILE}.tmp`;
        fs.mkdirSync(path.dirname(c.STATE_FILE), { recursive: true });
        fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
        fs.renameSync(tmp, c.STATE_FILE);
    }

    // --- checks ---

    // { failures: { name: detail }, outdated: { name: detail } | null (unknown), probe, checkedAt }
    async function selfcheck() {
        const failures = {};
        let res;
        try {
            res = await fetch(`${c.AXIOM_URL}/selfcheck`, { headers: { authorization: `Bearer ${c.AXIOM_API_KEY}` }, signal: AbortSignal.timeout(c.HTTP_TIMEOUT_MS) });
        } catch (err) {
            failures.selfcheck = `GET /selfcheck failed: ${scrub((err && err.cause && err.cause.message) || (err && err.message) || err)}`;
            return { failures, outdated: null, probe: null, checkedAt: null };
        }
        const text = await res.text().catch(() => '');
        let report = null;
        try {
            report = JSON.parse(text);
        } catch {}
        if (![200, 503].includes(res.status) || !report || !Array.isArray(report.checks)) {
            const hint = res.status === 401 ? ' (AXIOM_API_KEY does not match the server’s API_KEY)' : '';
            failures.selfcheck = `GET /selfcheck -> HTTP ${res.status}${hint}: ${scrub(text.slice(0, 200)) || 'empty body'}`;
            return { failures, outdated: null, probe: null, checkedAt: null };
        }
        const outdated = {};
        for (const check of report.checks) {
            if (check.status === 'broken') failures[check.name] = check.detail;
            else if (check.status === 'outdated') outdated[check.name] = check.detail;
        }
        if (res.status === 503 && !Object.keys(failures).length) failures.selfcheck = 'GET /selfcheck -> HTTP 503 without a broken check';
        const age = now() - Date.parse(report.checkedAt);
        if (!(age < c.MAX_REPORT_AGE_MS)) failures['selfcheck:stale'] = `the latest selfcheck is from ${report.checkedAt}; its 10-minute runs have stopped`;
        return { failures, outdated, probe: report.probe || null, checkedAt: report.checkedAt };
    }

    // Subscribe to `token` on /stream: null when a snapshot and then an update arrive in time,
    // else what went wrong.
    function stream(token) {
        return new Promise((resolve) => {
            const url = `${c.AXIOM_URL.replace(/^http/, 'ws')}/stream`;
            const startedAt = now();
            let snapshotAt = 0;
            let ws = null;
            let done = false;
            const finish = (problem) => {
                if (done) return;
                done = true;
                clearTimeout(timer);
                try {
                    ws.close();
                } catch {}
                resolve(problem ? scrub(problem) : null);
            };
            const timer = setTimeout(() => finish(`no ${snapshotAt ? 'update' : 'snapshot'} for ${token} within ${c.STREAM_TIMEOUT_MS / 1000} s`), c.STREAM_TIMEOUT_MS);
            try {
                ws = new WebSocket(url, { headers: { authorization: `Bearer ${c.AXIOM_API_KEY}` } });
            } catch (err) {
                return finish(`cannot open ${url}: ${err.message}`);
            }
            ws.addEventListener('open', () => ws.send(JSON.stringify({ op: 'subscribe', token })));
            ws.addEventListener('message', (event) => {
                let msg;
                try {
                    msg = JSON.parse(event.data);
                } catch {
                    return;
                }
                if (msg.token !== token) return;
                if (msg.type === 'error') finish(`the server answered the subscribe with an error: ${msg.message}`);
                else if (msg.type === 'snapshot') snapshotAt = snapshotAt || now();
                else if (msg.type === 'update' && snapshotAt) finish(null);
            });
            ws.addEventListener('error', (event) => finish(`websocket error before an update: ${(event && (event.message || (event.error && event.error.message))) || 'connection failed'}`));
            ws.addEventListener('close', (event) => finish(`the stream closed (code ${event.code}) ${snapshotAt ? 'after the snapshot but before an update' : 'before a snapshot'}, ${now() - startedAt} ms in`));
        });
    }

    // --- ntfy ---

    async function notify({ title, lines, priority, tags }) {
        let message = lines.join('\n');
        if (message.length > MAX_MESSAGE) message = `${message.slice(0, MAX_MESSAGE)}\n…`;
        const res = await fetch(c.NTFY_URL, {
            method: 'POST',
            headers: { authorization: `Bearer ${c.NTFY_TOKEN}`, 'content-type': 'application/json' },
            body: JSON.stringify({ topic: c.NTFY_TOPIC, title, message, priority, tags }),
            signal: AbortSignal.timeout(c.HTTP_TIMEOUT_MS),
        });
        if (!res.ok) throw new Error(`ntfy answered HTTP ${res.status}: ${scrub((await res.text().catch(() => '')).slice(0, 200))}`);
        log(`sent "${title}"`);
    }

    // --- autofix router (optional) ---

    const fingerprint = (prefix, names) => `${prefix}:${names.join(',')}`;

    // Sends events to the autofix router, which opens or updates a GitHub issue per fingerprint. Called after a
    // successful ntfy send; a failure here is only logged, so it can't block or repeat the alert.
    async function signal(events) {
        if (!c.AUTOFIX_WEBHOOK_URL || !c.AUTOFIX_WEBHOOK_SECRET) return;
        for (const event of events) {
            try {
                const res = await fetch(c.AUTOFIX_WEBHOOK_URL, {
                    method: 'POST',
                    headers: { 'x-autofix-secret': c.AUTOFIX_WEBHOOK_SECRET, 'content-type': 'application/json' },
                    body: JSON.stringify({ source: 'axiom-canary', component: 'axiom-data', evidenceUrl: `${c.AXIOM_URL}/selfcheck`, ...event }),
                    signal: AbortSignal.timeout(c.HTTP_TIMEOUT_MS),
                });
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                log(`autofix: ${event.status} ${event.fingerprint}`);
            } catch (err) {
                log(`autofix signal failed (${event.status} ${event.fingerprint}): ${scrub((err && err.message) || err)}`);
            }
        }
    }

    // --- one run ---

    async function runOnce() {
        const state = load();
        const result = await selfcheck();
        const token = result.probe && result.probe.token;
        if (token) {
            const problem = await stream(token);
            if (problem) result.failures.stream = problem;
        } else if (!Object.keys(result.failures).length) {
            result.failures.stream = 'the selfcheck named no probe token to subscribe to';
        }
        const failing = Object.keys(result.failures).sort();
        const footer = `${result.checkedAt ? `selfcheck ${result.checkedAt}` : 'no selfcheck report'}${token ? `, probe token ${token}` : ''}`;
        const describe = (names, details) => names.map((name) => `• ${name}: ${details[name]}`);
        const t = now();

        if (failing.length) {
            state.failStreak += 1;
            state.failingSince = state.failingSince || t;
            log(`failing (${state.failStreak} in a row): ${failing.join(', ')}`);
            const lines = [...describe(failing, result.failures), '', footer];
            const firing = (title) => ({ fingerprint: fingerprint('axiom', failing), status: 'firing', summary: title, detail: lines.join('\n') });
            if (!state.alerting && state.failStreak >= c.FAIL_RUNS) {
                const title = `axiom broken: ${shortList(failing)}`;
                await notify({ title, lines: [`Failing for ${plural(state.failStreak, 'run')} in a row:`, ...lines], priority: 4, tags: ['rotating_light'] });
                await signal([firing(title)]);
                Object.assign(state, { alerting: true, alerted: failing, alertedAt: t });
            } else if (state.alerting && !sameSet(failing, state.alerted)) {
                const title = `axiom broken (changed): ${shortList(failing)}`;
                await notify({ title, lines: [`Was: ${state.alerted.join(', ')}`, ...lines], priority: 4, tags: ['rotating_light'] });
                await signal([{ fingerprint: fingerprint('axiom', state.alerted), status: 'resolved', summary: `replaced by: ${shortList(failing)}` }, firing(title)]);
                Object.assign(state, { alerted: failing, alertedAt: t });
            } else if (state.alerting && t - state.alertedAt >= c.REMIND_MS) {
                const title = `axiom still broken: ${shortList(failing)}`;
                await notify({ title, lines: [`Failing for ${duration(t - state.failingSince)}:`, ...lines], priority: 3, tags: ['rotating_light'] });
                await signal([firing(title)]);
                state.alertedAt = t;
            }
        } else {
            log('ok');
            if (state.alerting) {
                await notify({ title: 'axiom recovered', lines: [`Everything passes again after ${duration(t - state.failingSince)}.`, `Was: ${state.alerted.join(', ')}`, '', footer], priority: 3, tags: ['white_check_mark'] });
                await signal([{ fingerprint: fingerprint('axiom', state.alerted), status: 'resolved', summary: 'axiom recovered' }]);
            }
            Object.assign(state, { failStreak: 0, alerting: false, alerted: [], alertedAt: 0, failingSince: 0 });
        }

        // Outdated findings: only known when the selfcheck answered.
        if (result.outdated) {
            const outdated = Object.keys(result.outdated).sort();
            if (!sameSet(outdated, state.outdated)) {
                const events = state.outdated.length ? [{ fingerprint: fingerprint('axiom-outdated', state.outdated), status: 'resolved', summary: outdated.length ? `replaced by: ${shortList(outdated)}` : 'no longer outdated' }] : [];
                if (outdated.length) {
                    const title = `axiom outdated: ${shortList(outdated)}`;
                    const lines = ['Still working, but the site has moved on:', ...describe(outdated, result.outdated), '', footer];
                    await notify({ title, lines, priority: 2, tags: ['hourglass_flowing_sand'] });
                    events.push({ fingerprint: fingerprint('axiom-outdated', outdated), status: 'firing', summary: title, detail: lines.join('\n') });
                } else {
                    await notify({ title: 'axiom no longer outdated', lines: [`Cleared: ${state.outdated.join(', ')}`, '', footer], priority: 1, tags: ['white_check_mark'] });
                }
                await signal(events);
                state.outdated = outdated;
            }
        }
        state.lastRunAt = t;
        save(state);
        return { failing, outdated: result.outdated ? Object.keys(result.outdated).sort() : null, state };
    }

    return { runOnce, config: c };
}

async function main() {
    const i = process.argv.indexOf('--runs');
    const runs = i >= 0 ? Number(process.argv[i + 1]) : Infinity;
    const canary = createCanary();
    const { config: c } = canary;
    console.log(`axiom-canary: ${c.AXIOM_URL} every ${c.INTERVAL_MS / 1000} s -> ${c.NTFY_URL}/${c.NTFY_TOPIC}`);
    for (let n = 0; n < runs; n++) {
        if (n > 0) await new Promise((resolve) => setTimeout(resolve, c.INTERVAL_MS));
        try {
            await canary.runOnce();
        } catch (err) {
            // e.g. ntfy unreachable: the state isn't saved, so the next run sends it again
            console.error(new Date().toISOString(), 'run failed:', err && err.message);
        }
    }
}

if (require.main === module) {
    process.on('SIGTERM', () => process.exit(0));
    main().catch((err) => {
        console.error('axiom-canary:', err.message);
        process.exit(1);
    });
}

module.exports = { createCanary, config };
