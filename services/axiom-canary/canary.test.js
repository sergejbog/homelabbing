'use strict';
// Offline tests for canary.js: a fake /selfcheck, a fake /stream WebSocket, a fake ntfy and
// a temporary state file. `node canary.test.js`
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const { createCanary } = require('./canary.js');

const KEY = 'fake-axiom-key-for-tests';
const NTFY = 'fake-ntfy-token-for-tests';
const TOKEN = 'CY27QvCQBCmLBuz3V7c8snEeD4z67iyoSTkwo35Ypump';

function setup() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-'));
    const w = {
        clock: Date.parse('2026-10-17T20:00:00Z'),
        report: null, // what /selfcheck answers; null = healthy
        status: null,
        selfcheckError: null,
        ntfyStatus: 200,
        sent: [],
        requests: [],
        sockets: [],
        // what the stream does after a subscribe: 'ok', 'silent', 'snapshot-only', 'error', 'refuse'
        stream: 'ok',
        dir,
    };
    const healthy = () => ({ ok: true, checkedAt: new Date(w.clock - 60000).toISOString(), probe: { token: TOKEN, pair: 'P' }, checks: [{ name: 'search', status: 'ok', detail: 'fine' }] });
    w.fetch = async (url, init = {}) => {
        w.requests.push({ url, init });
        if (url.endsWith('/selfcheck')) {
            if (w.selfcheckError) throw w.selfcheckError;
            const report = w.report || healthy();
            const status = w.status || (report.ok === false ? 503 : 200);
            return { status, ok: status === 200, text: async () => (typeof report === 'string' ? report : JSON.stringify(report)) };
        }
        if (url === 'https://ntfy.test') {
            w.sent.push({ ...JSON.parse(init.body), auth: init.headers.authorization });
            return { status: w.ntfyStatus, ok: w.ntfyStatus === 200, text: async () => (w.ntfyStatus === 200 ? '{}' : 'unauthorized') };
        }
        throw new Error(`unexpected fetch ${url}`);
    };
    w.WebSocket = class {
        constructor(url, options) {
            this.url = url;
            this.options = options;
            this.listeners = {};
            w.sockets.push(this);
            setTimeout(() => {
                if (w.stream === 'refuse') return this.emit('error', { message: 'Received network error or non-101 status code.' });
                this.emit('open', {});
            }, 2);
        }
        addEventListener(type, fn) {
            (this.listeners[type] ||= []).push(fn);
        }
        emit(type, event) {
            for (const fn of this.listeners[type] || []) fn(event);
        }
        send(text) {
            this.sentText = text;
            const { token } = JSON.parse(text);
            const msg = (m) => setTimeout(() => this.emit('message', { data: JSON.stringify(m) }), 2);
            if (w.stream === 'error') return msg({ type: 'error', token, message: 'no pair found' });
            if (w.stream === 'silent') return;
            msg({ type: 'snapshot', token, pair: 'P' });
            if (w.stream === 'ok') setTimeout(() => msg({ type: 'update', token, kind: 'viewers', data: { viewers: 3 } }), 5);
        }
        close() {
            this.closed = true;
        }
    };
    w.canary = createCanary({
        env: {
            AXIOM_URL: 'https://axiom.test/',
            NTFY_URL: 'https://ntfy.test',
            NTFY_TOPIC: 'axiom',
            AXIOM_API_KEY: KEY,
            NTFY_TOKEN: NTFY,
            STREAM_TIMEOUT_MS: '100',
            STATE_FILE: path.join(dir, 'state.json'),
        },
        fetch: w.fetch,
        WebSocket: w.WebSocket,
        now: () => w.clock,
        log: () => {},
    });
    w.broken = (checks) => ({ ok: false, checkedAt: new Date(w.clock - 60000).toISOString(), probe: { token: TOKEN, pair: 'P' }, checks });
    w.run = async () => {
        const out = await w.canary.runOnce();
        w.clock += 10 * 60 * 1000;
        return out;
    };
    return w;
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('healthy: selfcheck with the key in a header, the stream with the key in a header (not the URL), nothing sent', async () => {
    const w = setup();
    const out = await w.run();
    assert.deepStrictEqual(out.failing, []);
    assert.strictEqual(w.sent.length, 0);
    assert.strictEqual(w.requests[0].url, 'https://axiom.test/selfcheck');
    assert.strictEqual(w.requests[0].init.headers.authorization, `Bearer ${KEY}`);
    assert.strictEqual(w.sockets[0].url, 'wss://axiom.test/stream');
    assert.ok(!w.sockets[0].url.includes(KEY));
    assert.deepStrictEqual(w.sockets[0].options, { headers: { authorization: `Bearer ${KEY}` } });
    assert.deepStrictEqual(JSON.parse(w.sockets[0].sentText), { op: 'subscribe', token: TOKEN });
    assert.ok(w.sockets[0].closed);
    assert.strictEqual(JSON.parse(fs.readFileSync(path.join(w.dir, 'state.json'), 'utf8')).failStreak, 0);
});

test('alert after 2 failing runs, again when the failures change, a reminder every 6 h, then one recovery', async () => {
    const w = setup();
    w.report = w.broken([{ name: 'stream:viewers', status: 'broken', detail: 'no frames on e-P in 30 s' }]);
    await w.run();
    assert.strictEqual(w.sent.length, 0, 'one failing run is not enough');
    await w.run();
    assert.strictEqual(w.sent.length, 1);
    let m = w.sent[0];
    assert.strictEqual(m.topic, 'axiom');
    assert.strictEqual(m.title, 'axiom broken: stream:viewers');
    assert.strictEqual(m.priority, 4);
    assert.strictEqual(m.auth, `Bearer ${NTFY}`);
    assert.match(m.message, /Failing for 2 runs in a row:\n• stream:viewers: no frames on e-P in 30 s/);
    assert.match(m.message, new RegExp(`probe token ${TOKEN}`));

    await w.run();
    assert.strictEqual(w.sent.length, 1, 'same failures: no repeat');

    const both = () =>
        w.broken([
            { name: 'stream:viewers', status: 'broken', detail: 'no frames' },
            { name: 'login', status: 'broken', detail: 'logged out' },
        ]);
    w.report = both();
    await w.run();
    assert.strictEqual(w.sent.length, 2);
    assert.strictEqual(w.sent[1].title, 'axiom broken (changed): login, stream:viewers');
    assert.match(w.sent[1].message, /^Was: stream:viewers/);

    w.clock += 6 * 60 * 60 * 1000;
    w.report = both(); // checked just now
    await w.run();
    assert.strictEqual(w.sent.length, 3);
    assert.strictEqual(w.sent[2].title, 'axiom still broken: login, stream:viewers');
    assert.strictEqual(w.sent[2].priority, 3);
    w.report = both();
    await w.run();
    assert.strictEqual(w.sent.length, 3, 'the next reminder is 6 h later');

    w.report = null;
    await w.run();
    assert.strictEqual(w.sent.length, 4);
    m = w.sent[3];
    assert.strictEqual(m.title, 'axiom recovered');
    assert.strictEqual(m.priority, 3);
    assert.match(m.message, /Everything passes again after 7 hours\.\nWas: login, stream:viewers/);
    await w.run();
    assert.strictEqual(w.sent.length, 4, 'one recovery message');
});

test('a failing run between good ones never alerts', async () => {
    const w = setup();
    w.report = w.broken([{ name: 'search', status: 'broken', detail: 'HTTP 502' }]);
    await w.run();
    w.report = null;
    await w.run();
    w.report = w.broken([{ name: 'search', status: 'broken', detail: 'HTTP 502' }]);
    await w.run();
    assert.strictEqual(w.sent.length, 0);
});

test('outdated: low priority, once per change, and a note when cleared; unknown while the selfcheck is down', async () => {
    const w = setup();
    const withOutdated = (names) => ({
        ok: true,
        checkedAt: new Date(w.clock - 60000).toISOString(),
        probe: { token: TOKEN, pair: 'P' },
        checks: names.map((name) => ({ name, status: 'outdated', detail: `${name} moved on` })),
    });
    w.report = withOutdated(['site:search']);
    await w.run();
    assert.strictEqual(w.sent.length, 1);
    assert.strictEqual(w.sent[0].title, 'axiom outdated: site:search');
    assert.strictEqual(w.sent[0].priority, 2);
    assert.match(w.sent[0].message, /• site:search: site:search moved on/);
    w.report = withOutdated(['site:search']);
    await w.run();
    assert.strictEqual(w.sent.length, 1, 'once per change');
    w.selfcheckError = new TypeError('fetch failed');
    await w.run();
    w.selfcheckError = null;
    w.report = withOutdated(['site:search']);
    await w.run();
    assert.strictEqual(w.sent.length, 1, 'a run without a report leaves the outdated set alone');
    w.report = withOutdated(['site:room:viewers', 'site:search']);
    await w.run();
    assert.strictEqual(w.sent[1].title, 'axiom outdated: site:room:viewers, site:search');
    w.report = null;
    await w.run();
    assert.strictEqual(w.sent[2].title, 'axiom no longer outdated');
    assert.strictEqual(w.sent[2].priority, 1);
    assert.strictEqual(w.sent.length, 3);
});

test('the canary’s own failures: unreachable, 401, not JSON, a stale report', async () => {
    const w = setup();
    w.selfcheckError = Object.assign(new TypeError('fetch failed'), { cause: new Error(`getaddrinfo ENOTFOUND axiom.test (key ${KEY})`) });
    let out = await w.run();
    assert.deepStrictEqual(out.failing, ['selfcheck']);
    assert.strictEqual(w.sockets.length, 0, 'no stream check without a probe token');
    w.selfcheckError = null;

    w.report = { error: 'unauthorized' };
    w.status = 401;
    out = await w.run();
    assert.strictEqual(w.sent.length, 1);
    assert.match(w.sent[0].message, /HTTP 401 \(AXIOM_API_KEY does not match/);
    assert.ok(!JSON.stringify(w.sent).includes(KEY), 'the key never leaves');

    w.report = '<html>Bad gateway</html>';
    w.status = 502;
    out = await w.run();
    assert.deepStrictEqual(out.failing, ['selfcheck']);
    w.status = null;

    w.report = { ok: true, checkedAt: new Date(w.clock - 40 * 60000).toISOString(), probe: { token: TOKEN }, checks: [] };
    out = await w.run();
    assert.deepStrictEqual(out.failing, ['selfcheck:stale']);
});

test('stream problems: silent, snapshot only, an error reply, a refused upgrade', async () => {
    for (const [mode, re] of [
        ['silent', /no snapshot for .+ within 0\.1 s/],
        ['snapshot-only', /no update for .+ within 0\.1 s/],
        ['error', /answered the subscribe with an error: no pair found/],
        ['refuse', /websocket error before an update: Received network error/],
    ]) {
        const w = setup();
        w.stream = mode;
        await w.run();
        const out = await w.run();
        assert.deepStrictEqual(out.failing, ['stream'], mode);
        assert.match(w.sent[0].message, re, mode);
    }
});

test('a failed ntfy send keeps the state, so the next run sends it again', async () => {
    const w = setup();
    w.report = w.broken([{ name: 'login', status: 'broken', detail: 'logged out' }]);
    await w.run();
    w.ntfyStatus = 401;
    await assert.rejects(w.run(), /ntfy answered HTTP 401: unauthorized/);
    w.clock += 10 * 60 * 1000;
    w.ntfyStatus = 200;
    await w.run();
    assert.strictEqual(w.sent.filter((m) => m.title === 'axiom broken: login').length, 2, 'the failed one, then the retry');
});

test('missing secrets stop the canary at start', () => {
    assert.throws(() => createCanary({ env: { NTFY_TOKEN: 'x' } }), /AXIOM_API_KEY is not set/);
    assert.throws(() => createCanary({ env: { AXIOM_API_KEY: 'x' } }), /NTFY_TOKEN is not set/);
});

(async () => {
    let failed = 0;
    for (const { name, fn } of tests) {
        try {
            await fn();
            console.log(`ok - ${name}`);
        } catch (err) {
            failed++;
            console.log(`FAIL - ${name}\n${err.stack}`);
        }
    }
    console.log(failed ? `${failed} of ${tests.length} canary tests failed` : `all ${tests.length} canary tests passed`);
    process.exit(failed ? 1 : 0);
})();
