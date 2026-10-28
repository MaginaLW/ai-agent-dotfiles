const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const scripts = path.join(root, 'skills-source', 'shared', 'brainstorming', 'scripts');
const bash = process.env.BRAINSTORM_TEST_BASH;
if (!bash) throw new Error('Set BRAINSTORM_TEST_BASH to the Git Bash executable');

async function waitFor(predicate, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for server');
    await new Promise(resolve => setTimeout(resolve, 50));
  }
}

test('stop request is acknowledged without signaling the PID file or deleting session data', async () => {
  const base = path.join(root, 'tmp', 'tests', 'brainstorm-helper');
  fs.mkdirSync(base, { recursive: true });
  const session = fs.mkdtempSync(path.join(base, 'session-'));
  const state = path.join(session, 'state');
  const server = spawn(process.execPath, [path.join(scripts, 'server.cjs')], {
    env: { ...process.env, BRAINSTORM_DIR: session, BRAINSTORM_PORT: '0', BRAINSTORM_HOST: '127.0.0.1', BRAINSTORM_URL_HOST: 'localhost', BRAINSTORM_OWNER_PID: '' },
    stdio: 'ignore', windowsHide: true,
  });
  let socket;
  try {
    await waitFor(() => fs.existsSync(path.join(state, 'server-info')) || server.exitCode !== null);
    assert.ok(fs.existsSync(path.join(state, 'server-info')), 'server started');
    const info = JSON.parse(fs.readFileSync(path.join(state, 'server-info'), 'utf8'));
    assert.ok(info.port > 0, 'server reports its actual ephemeral port');
    socket = net.connect(info.port, '127.0.0.1');
    await new Promise((resolve, reject) => {
      socket.once('error', reject);
      socket.once('connect', () => socket.write('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n'));
      socket.once('data', data => {
        if (!data.toString().startsWith('HTTP/1.1 101')) reject(new Error('WebSocket upgrade failed'));
        else resolve();
      });
    });
    fs.writeFileSync(path.join(state, 'server.pid'), String(process.pid));
    fs.writeFileSync(path.join(session, 'sentinel.txt'), 'preserve');
    const stop = spawnSync(bash, [path.join(scripts, 'stop-server.sh'), session], { encoding: 'utf8', timeout: 10000 });
    assert.equal(stop.status, 0, stop.stderr || stop.stdout);
    assert.equal(JSON.parse(stop.stdout).status, 'stopped');
    await waitFor(() => server.exitCode !== null);
    assert.equal(server.exitCode, 0);
    assert.equal(fs.readFileSync(path.join(session, 'sentinel.txt'), 'utf8'), 'preserve');
    assert.equal(fs.readFileSync(path.join(state, 'server.pid'), 'utf8'), String(process.pid));
    assert.equal(JSON.parse(fs.readFileSync(path.join(state, 'server-stopped'), 'utf8')).reason, 'stop requested');
  } finally {
    if (socket) socket.destroy();
    if (server.exitCode === null) {
      server.kill();
      await waitFor(() => server.exitCode !== null || server.signalCode !== null);
    }
    const resolvedBase = fs.realpathSync(base);
    const resolvedSession = fs.realpathSync(session);
    if (path.dirname(resolvedSession) !== resolvedBase) throw new Error('Refusing to clean outside test directory');
    fs.rmSync(resolvedSession, { recursive: true });
  }
});

test('stale session is unconfirmed and its files are preserved', () => {
  const base = path.join(root, 'tmp', 'tests', 'brainstorm-helper');
  fs.mkdirSync(base, { recursive: true });
  const session = fs.mkdtempSync(path.join(base, 'stale-'));
  const state = path.join(session, 'state');
  fs.mkdirSync(state);
  fs.writeFileSync(path.join(state, 'server-info'), '{}');
  fs.writeFileSync(path.join(session, 'sentinel.txt'), 'preserve');
  try {
    const stop = spawnSync(bash, [path.join(scripts, 'stop-server.sh'), session], { encoding: 'utf8', timeout: 10000 });
    assert.equal(stop.status, 1);
    assert.equal(JSON.parse(stop.stdout).status, 'unconfirmed');
    assert.equal(fs.readFileSync(path.join(session, 'sentinel.txt'), 'utf8'), 'preserve');
  } finally {
    const resolvedBase = fs.realpathSync(base);
    const resolvedSession = fs.realpathSync(session);
    if (path.dirname(resolvedSession) !== resolvedBase) throw new Error('Refusing to clean outside test directory');
    fs.rmSync(resolvedSession, { recursive: true });
  }
});
