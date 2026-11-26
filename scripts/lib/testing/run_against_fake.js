'use strict';

/**
 * Runs scripts/loadtest.js against a broker in this process (./fake_broker.js) answering by a policy, for
 * the tests of what the generator does when the server stalls or refuses (test/scripts/loadtest_js_test.exs).
 *
 *   node scripts/lib/testing/run_against_fake.js POLICY -- LOADTEST ARGS...
 *
 * POLICY is JSON: { "open": "ok" | "silent" | { "refuse": reason }, "append": "ack" | "silent",
 * "consume": "ok" | { "refuse": reason } | { "dropAfterMs": ms }, "fetch": "ok" | "silent" | "drop",
 * "tls": { "cert": path, "key": path } (the broker serves TLS only, reached as localhost), "env": { NAME: value }
 * (more environment for the generator) }. Prints
 * { code, elapsedMs, stdout, stderr, consumes } as JSON once the generator exits, `consumes` being where
 * each consume stream the broker took was opened from.
 */

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const { FakeBroker } = require('./fake_broker');

(async () => {
  const policy = JSON.parse(process.argv[2]);
  const args = process.argv.slice(process.argv.indexOf('--') + 1);
  const tls = policy.tls ? { tls: { cert: fs.readFileSync(policy.tls.cert), key: fs.readFileSync(policy.tls.key) } } : {};
  const broker = await new FakeBroker().start(0, tls);
  broker.openPolicy = () => policy.open || 'ok';
  broker.appendPolicy = () => policy.append || 'ack';
  broker.consumePolicy = () => policy.consume || 'ok';
  broker.fetchPolicy = () => policy.fetch || 'ok';
  const started = Date.now();
  const child = spawn(process.execPath, [path.join(__dirname, '../../loadtest.js'), ...args], {
    env: {
      ...process.env,
      MALACHI_HOST: policy.tls ? 'localhost' : '127.0.0.1',
      MALACHI_PORT: String(broker.port),
      MALACHI_USER: 'u',
      MALACHI_PASS: 'p',
      ...(policy.env || {}),
    },
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => (stdout += d));
  child.stderr.on('data', (d) => (stderr += d));
  child.on('exit', (code) => {
    broker.stop();
    // and what the broker saw: where each consume stream was opened from
    const consumes = broker.consumes.map((c) => c.start);
    console.log(JSON.stringify({ code, elapsedMs: Date.now() - started, stdout, stderr, consumes }));
  });
})();
