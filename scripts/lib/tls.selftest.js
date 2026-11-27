'use strict';

/**
 * The Node client over TLS (./tls.js, ./client.js, ./links.js) against brokers in this process
 * (./testing/fake_broker.js) that serve TLS: the server verified against the given CA and by host name, nothing
 * sent before the handshake completes, verification skipped only when asked, a client certificate
 * authenticating the connection, every routed connection as verified as the first, and the settings resolved
 * from flags and the environment, failing closed. ExUnit runs it (test/scripts/tls_js_test.exs), which writes
 * the certificates it reads into the folder named by MALACHI_TLS_SELFTEST_DIR:
 *
 *   ca.pem                         a private CA
 *   server.pem, server-key.pem     signed by it, for DNS:localhost and IP:127.0.0.1
 *   other.pem, other-key.pem       signed by it, for DNS:other.test only
 *   client.pem, client-key.pem     signed by it, CN selftest-client
 *   ca2.pem                        another CA, which signed none of them
 *
 *   MALACHI_TLS_SELFTEST_DIR=<dir> node scripts/lib/tls.selftest.js
 */

const assert = require('assert');
const fs = require('fs');
const net = require('net');
const path = require('path');
const { MalachiClient } = require('./client');
const { Links } = require('./links');
const { Router } = require('./router');
const { FakeBroker } = require('./testing/fake_broker');
const { resolveTls, connectOptions, TlsConfigError, ENV } = require('./tls');

const DIR = process.env.MALACHI_TLS_SELFTEST_DIR;
const file = (name) => path.join(DIR, name);
const pem = (name) => fs.readFileSync(file(name));

const serverTls = (cert = 'server', extra = {}) => ({ tls: { key: pem(`${cert}-key.pem`), cert: pem(`${cert}.pem`), ...extra } });
const settings = (flags, env = {}) => resolveTls({ tls: true, ...flags }, env);

const brokers = [];
async function broker(opts) {
  const b = await new FakeBroker().start(0, opts);
  brokers.push(b);
  return b;
}

async function rejects(promise) {
  try {
    await promise;
  } catch (err) {
    return err;
  }
  throw new Error('expected a rejection');
}

function configError(fn) {
  try {
    fn();
  } catch (err) {
    assert.ok(err instanceof TlsConfigError, `expected a TlsConfigError, got ${err && err.stack}`);
    return err.message;
  }
  throw new Error('expected a TlsConfigError');
}

const cases = {
  async 'a server certificate from a CA the client does not trust is refused, explained, before any frame'() {
    const b = await broker(serverTls());
    const client = new MalachiClient({ host: 'localhost', port: b.port, tls: settings({}) });
    const err = await rejects(client.connect('u', 'p'));
    assert.strictEqual(err.tlsVerification, true);
    assert.match(err.message, /TLS verification failed \(UNABLE_TO_VERIFY_LEAF_SIGNATURE\).*--cacert/);
    assert.deepStrictEqual(b.auths, []);
    client.destroy();
  },

  async 'the same certificate is accepted with its CA, and the password authenticates'() {
    const b = await broker(serverTls());
    const client = await new MalachiClient({ host: 'localhost', port: b.port, tls: settings({ cacert: file('ca.pem') }) }).connect('u', 'p');
    assert.strictEqual(client.token, 'token');
    assert.deepStrictEqual(b.auths, [{ kind: 'password', user: 'u' }]);
    client.close();
  },

  async 'a CA that did not sign the server certificate is refused'() {
    const b = await broker(serverTls());
    const err = await rejects(new MalachiClient({ host: 'localhost', port: b.port, tls: settings({ cacert: file('ca2.pem') }) }).connect('u', 'p'));
    assert.strictEqual(err.tlsVerification, true);
    assert.deepStrictEqual(b.auths, []);
  },

  async 'a certificate for another host name is refused, naming the host'() {
    const b = await broker(serverTls('other'));
    const err = await rejects(new MalachiClient({ host: 'localhost', port: b.port, tls: settings({ cacert: file('ca.pem') }) }).connect('u', 'p'));
    assert.strictEqual(err.code, 'ERR_TLS_CERT_ALTNAME_INVALID');
    assert.match(err.message, /does not name localhost/);
    assert.deepStrictEqual(b.auths, []);
  },

  async 'an IP address is checked against the certificate addresses, and sent as no server name'() {
    const b = await broker(serverTls());
    const s = settings({ cacert: file('ca.pem') });
    assert.strictEqual(connectOptions(s, '127.0.0.1', 1).servername, undefined);
    assert.strictEqual(connectOptions(s, 'localhost', 1).servername, 'localhost');
    const client = await new MalachiClient({ host: '127.0.0.1', port: b.port, tls: s }).connect('u', 'p');
    client.close();
    const other = await broker(serverTls('other'));
    const err = await rejects(new MalachiClient({ host: '127.0.0.1', port: other.port, tls: s }).connect('u', 'p'));
    assert.strictEqual(err.code, 'ERR_TLS_CERT_ALTNAME_INVALID');
  },

  async '--insecure skips verification, and only it does'() {
    const b = await broker(serverTls('other'));
    const s = settings({ insecure: true });
    assert.strictEqual(connectOptions(s, 'localhost', 1).rejectUnauthorized, false);
    assert.strictEqual(connectOptions(settings({}), 'localhost', 1).rejectUnauthorized, true);
    const client = await new MalachiClient({ host: 'localhost', port: b.port, tls: s }).connect('u', 'p');
    client.close();
  },

  async 'nothing but the TLS handshake is written before the server is verified'() {
    let first = null;
    const server = net.createServer((socket) => socket.once('data', (chunk) => ((first = chunk), socket.destroy())));
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const client = new MalachiClient({ host: 'localhost', port: server.address().port, tls: settings({ cacert: file('ca.pem') }) });
    await rejects(client.connect('u', 'p'));
    server.close();
    assert.ok(first, 'the server saw no bytes');
    // 0x16 opens a TLS handshake record; a Malachi frame would open with its length, and the auth request with
    // the credentials would follow it
    assert.strictEqual(first[0], 0x16, 'the first byte is not a TLS handshake record');
  },

  async 'a client certificate authenticates the connection by mtls_auth, not the password'() {
    const b = await broker(serverTls('server', { ca: pem('ca.pem'), requestCert: true }));
    const s = settings({ cacert: file('ca.pem'), cert: file('client.pem'), key: file('client-key.pem') });
    const client = await new MalachiClient({ host: 'localhost', port: b.port, tls: s }).connect('u', 'p');
    assert.deepStrictEqual(b.auths, [{ kind: 'mtls', peer: 'selftest-client' }]);
    client.close();
  },

  async 'a routing client connects to every broker the routes name over TLS, and surfaces a refusal'() {
    const seed = await broker(serverTls());
    const primary = await broker(serverTls());
    seed.extraBrokers = [{ id: primary.id, host: 'localhost', port: primary.port, status: 'alive' }];
    seed.setRoutes('t', [[0, 0, 16, primary.id]]);
    primary.setRoutes('t', [[0, 0, 16, 'self']]);

    const links = new Links(new Router({ host: 'localhost', port: seed.port }), { user: 'u', pass: 'p', timeout: 2000, tls: settings({ cacert: file('ca.pem') }) });
    assert.deepStrictEqual(await links.connectRanges('t'), { ok: true });
    assert.deepStrictEqual(primary.auths, [{ kind: 'password', user: 'u' }]);
    await links.closeAll();

    const untrusting = new Links(new Router({ host: 'localhost', port: seed.port }), { user: 'u', pass: 'p', timeout: 2000, tls: settings({}) });
    const err = await rejects(untrusting.connection({ host: 'localhost', port: primary.port }));
    assert.strictEqual(err.tlsVerification, true);
    assert.strictEqual(untrusting.conns.size, 0, 'the failed connect is kept and would be rethrown');
    assert.strictEqual(untrusting.stats.connect_failures, 0, 'a verification failure is not a broker that is down');
    await untrusting.closeAll();
  },

  async 'plaintext stays the default path'() {
    assert.strictEqual(resolveTls({}, {}), null);
    let plain = 0;
    const fake = () => {
      plain += 1;
      const s = new net.Socket();
      setImmediate(() => s.emit('error', Object.assign(new Error('refused'), { code: 'ECONNREFUSED' })));
      return s;
    };
    const client = new MalachiClient({ host: 'x', port: 1, createConnection: fake, createTlsConnection: () => assert.fail('TLS was used') });
    const err = await rejects(client.connect('u', 'p'));
    assert.strictEqual(err.code, 'ECONNREFUSED');
    assert.strictEqual(plain, 1);
  },

  async 'settings: flags win over the environment, and the environment is recorded as flags'() {
    const env = { [ENV.tls]: 'true', [ENV.cacert]: file('ca2.pem') };
    assert.strictEqual(resolveTls({ 'no-tls': true }, { [ENV.tls]: 'true' }), null);
    assert.deepStrictEqual(resolveTls({ cacert: file('ca.pem') }, env).ca, pem('ca.pem'));
    assert.deepStrictEqual(resolveTls({}, env).recorded, ['--tls', '--cacert', file('ca2.pem')]);
    assert.deepStrictEqual(resolveTls({ tls: true, cacert: file('ca.pem') }, {}).recorded, []);
    assert.deepStrictEqual(resolveTls({}, { [ENV.tls]: 'true', [ENV.insecure]: 'true' }).recorded, ['--tls', '--insecure']);
    assert.strictEqual(resolveTls({}, { [ENV.tls]: '', [ENV.cacert]: '' }), null, 'an empty variable counts as unset');
    assert.ok(!JSON.stringify(resolveTls({}, env).recorded).includes('BEGIN'), 'a file content was recorded');
  },

  async 'settings that cannot be honoured stop the client before it connects'() {
    assert.match(configError(() => resolveTls({}, { [ENV.tls]: 'yes' })), /MALACHI_CLIENT_TLS must be true or false/);
    assert.match(configError(() => resolveTls({}, { [ENV.insecure]: '1', [ENV.tls]: 'true' })), /MALACHI_CLIENT_TLS_INSECURE/);
    assert.match(configError(() => resolveTls({ cacert: file('ca.pem') }, {})), /--cacert given without TLS/);
    assert.match(configError(() => resolveTls({ insecure: true }, {})), /--insecure given without TLS/);
    assert.match(configError(() => resolveTls({}, { [ENV.cert]: file('client.pem') })), /MALACHI_CLIENT_TLS_CERT given without TLS/);
    assert.match(configError(() => settings({ insecure: true, cacert: file('ca.pem') })), /pick one of --insecure and --cacert/);
    assert.match(configError(() => settings({ cert: file('client.pem') })), /needs its key/);
    assert.match(configError(() => settings({ key: file('client-key.pem') })), /needs its key/);
    assert.match(configError(() => settings({ cacert: file('missing.pem') })), /cannot read the CA certificate .*missing\.pem \(ENOENT\)/);
    assert.match(configError(() => settings({ cacert: undefined })), /--cacert needs a file path/);
    assert.match(configError(() => resolveTls({ tls: true, 'no-tls': true }, {})), /pick one/);
  },
};

async function main() {
  assert.ok(DIR && fs.existsSync(file('ca.pem')), 'MALACHI_TLS_SELFTEST_DIR must name the folder of certificates');
  let passed = 0;
  for (const [name, run] of Object.entries(cases)) {
    try {
      await run();
      passed += 1;
    } catch (err) {
      console.error(`FAIL ${name}\n${err.stack}`);
      process.exitCode = 1;
    } finally {
      for (const b of brokers.splice(0)) b.stop();
    }
  }
  console.log(`passed ${passed} tls cases`);
}

main();
