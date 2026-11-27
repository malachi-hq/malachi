'use strict';

/**
 * TLS for the Node client, as the Elixir load generator has it (Malachi.Loadtest.Conn, `mix malachi.loadtest`):
 * the server is always verified against a CA (the given `--cacert`, else Node's bundled roots) and by host name,
 * a client certificate is presented when given (and then authenticates the connection, as mtls_auth), and
 * verification is skipped only by an explicit `--insecure`. Plaintext stays the default.
 *
 * Settings come from flags, which win, then from the environment, an empty variable counting as unset:
 *
 *   --tls / --no-tls     MALACHI_CLIENT_TLS            true | false
 *   --cacert <pem>       MALACHI_CLIENT_TLS_CACERT
 *   --cert <pem>         MALACHI_CLIENT_TLS_CERT
 *   --key <pem>          MALACHI_CLIENT_TLS_KEY
 *   --insecure           MALACHI_CLIENT_TLS_INSECURE   true | false
 *
 * The names carry CLIENT so they never read as the server's own MALACHI_TLS_* settings in a shared shell. Every
 * setting that cannot be honoured stops the client before it connects (`TlsConfigError`): an unknown switch value, a
 * CA, certificate, key or --insecure without TLS, --insecure with a CA, a certificate without its key or a key
 * without its certificate, and a file that cannot be read. Files are read once, here, not once per connection.
 */

const fs = require('fs');
const net = require('net');

const ENV = {
  tls: 'MALACHI_CLIENT_TLS',
  cacert: 'MALACHI_CLIENT_TLS_CACERT',
  cert: 'MALACHI_CLIENT_TLS_CERT',
  key: 'MALACHI_CLIENT_TLS_KEY',
  insecure: 'MALACHI_CLIENT_TLS_INSECURE',
};

// The value flags of the CLIs that take TLS settings on their command line (loadtest.js).
const VALUE_FLAGS = ['cacert', 'cert', 'key'];

class TlsConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TlsConfigError';
  }
}

const unset = (v) => v === undefined || v === '';

function envSwitch(env, name) {
  const raw = env[name];
  if (unset(raw)) return undefined;
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  throw new TlsConfigError(`${name} must be true or false`);
}

// One path setting: the flag's when given (a value flag given with no value is an error), else the variable's.
function pathSetting(flags, env, name) {
  if (Object.prototype.hasOwnProperty.call(flags, name)) {
    const v = flags[name];
    if (typeof v !== 'string' || v === '') throw new TlsConfigError(`--${name} needs a file path`);
    return { path: v, from: 'flag' };
  }
  const v = env[ENV[name]];
  return unset(v) ? null : { path: v, from: 'env' };
}

function read(what, path) {
  try {
    return fs.readFileSync(path);
  } catch (err) {
    throw new TlsConfigError(`cannot read the ${what} ${path} (${err.code || err.message})`);
  }
}

/**
 * The TLS settings `flags` (from ./cli.js parseArgs) and `env` ask for: null for plaintext, or
 * `{ ca, cert, key, insecure, recorded }`, where `ca`, `cert` and `key` hold the files' contents (or are
 * undefined) and `recorded` lists, as command-line flags, the settings that came from the environment, for a
 * reproduce command that holds them all (paths only, never a file's contents). Throws a `TlsConfigError`.
 */
function resolveTls(flags = {}, env = process.env) {
  let enabled = envSwitch(env, ENV.tls);
  let enabledFrom = enabled === undefined ? null : 'env';
  if (flags['no-tls'] === true && flags.tls === true) throw new TlsConfigError('--tls and --no-tls together: pick one');
  if (flags.tls === true) [enabled, enabledFrom] = [true, 'flag'];
  if (flags['no-tls'] === true) [enabled, enabledFrom] = [false, 'flag'];

  let insecure = envSwitch(env, ENV.insecure);
  let insecureFrom = insecure === undefined ? null : 'env';
  if (flags.insecure === true) [insecure, insecureFrom] = [true, 'flag'];

  const paths = { cacert: pathSetting(flags, env, 'cacert'), cert: pathSetting(flags, env, 'cert'), key: pathSetting(flags, env, 'key') };

  if (enabled !== true) {
    const stray = Object.entries(paths).filter(([, p]) => p).map(([name, p]) => (p.from === 'flag' ? `--${name}` : ENV[name]));
    if (insecure === true) stray.push(insecureFrom === 'flag' ? '--insecure' : ENV.insecure);
    if (stray.length > 0) {
      throw new TlsConfigError(`${stray.join(', ')} given without TLS: add --tls (or ${ENV.tls}=true), or remove them`);
    }
    return null;
  }

  if (insecure === true && paths.cacert) {
    throw new TlsConfigError('--insecure skips the verification a CA is given for: pick one of --insecure and --cacert');
  }
  if (Boolean(paths.cert) !== Boolean(paths.key)) {
    throw new TlsConfigError('a client certificate needs its key: give both --cert and --key, or neither');
  }

  const recorded = [];
  if (enabledFrom === 'env') recorded.push('--tls');
  for (const name of ['cacert', 'cert', 'key']) if (paths[name] && paths[name].from === 'env') recorded.push(`--${name}`, paths[name].path);
  if (insecure === true && insecureFrom === 'env') recorded.push('--insecure');

  return {
    ca: paths.cacert ? read('CA certificate', paths.cacert.path) : undefined,
    cert: paths.cert ? read('client certificate', paths.cert.path) : undefined,
    key: paths.key ? read('client key', paths.key.path) : undefined,
    insecure: insecure === true,
    recorded,
  };
}

/**
 * The options of `tls.connect` for `host`:`port` under `settings` (from `resolveTls`). The server name (SNI) is
 * the host, and so is the name its certificate must carry, unless the host is an IP address, which RFC 6066 keeps
 * out of SNI (Node then checks the certificate's IP addresses).
 */
function connectOptions(settings, host, port) {
  const opts = { host, port, rejectUnauthorized: !settings.insecure };
  if (!net.isIP(host)) opts.servername = host;
  if (settings.ca) opts.ca = settings.ca;
  if (settings.cert) {
    opts.cert = settings.cert;
    opts.key = settings.key;
  }
  return opts;
}

// Node's codes for a server certificate it did not accept, and the hint each one warrants.
const UNTRUSTED = new Set([
  'DEPTH_ZERO_SELF_SIGNED_CERT',
  'SELF_SIGNED_CERT_IN_CHAIN',
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
  'UNABLE_TO_GET_ISSUER_CERT',
  'UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
  'CERT_UNTRUSTED',
  'CERT_REJECTED',
  'CERT_SIGNATURE_FAILURE',
]);
const DATED = new Set(['CERT_HAS_EXPIRED', 'CERT_NOT_YET_VALID']);

/**
 * `err`, a connect-phase error on a TLS connection to `host`, explained when it is a verification failure, as
 * Malachi.Loadtest.Conn explains one: a new Error flagged `tlsVerification` (so a caller neither retries it as a
 * dropped connection nor hints that the server is down), with Node's code kept. Any other error is returned as it is.
 */
function explainTlsError(err, host) {
  const code = err && err.code;
  let hint = null;
  if (UNTRUSTED.has(code)) {
    hint = 'the server certificate is not signed by a CA this client trusts; pass the CA that signed it with --cacert (or MALACHI_CLIENT_TLS_CACERT), or --insecure for a test server only';
  } else if (code === 'ERR_TLS_CERT_ALTNAME_INVALID') {
    hint = `the server certificate does not name ${host}; connect by a name or address the certificate carries`;
  } else if (DATED.has(code)) {
    hint = 'the server certificate is outside its validity period';
  } else if (typeof code === 'string' && /^ERR_SSL_.*(ALERT|HANDSHAKE)/.test(code)) {
    hint = 'the server refused the TLS handshake; it may require a client certificate (--cert and --key) or another TLS version';
  }
  if (!hint) return err;
  const explained = new Error(`TLS verification failed (${code}): ${hint}`);
  explained.code = code;
  explained.tlsVerification = true;
  return explained;
}

module.exports = { ENV, VALUE_FLAGS, TlsConfigError, resolveTls, connectOptions, explainTlsError };
