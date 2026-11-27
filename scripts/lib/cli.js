'use strict';

/**
 * Small shared bits for the reference CLIs: ANSI colors, env-backed config, a tiny arg parser, and what the
 * consumer group CLIs (consumer.js, subscriber.js) share: the member id and the assignment line.
 */

const os = require('os');

const colors = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  cyan: (s) => `\x1b[36m${s}\x1b[0m`,
  gray: (s) => `\x1b[90m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

// Connection config shared by every CLI. A script overrides user/pass with its role default.
function config(defaults = {}) {
  return {
    host: process.env.MALACHI_HOST || 'localhost',
    port: parseInt(process.env.MALACHI_PORT, 10) || 4040,
    topic: process.env.MALACHI_TOPIC || defaults.topic || 'events',
    username: process.env.MALACHI_USER || defaults.username,
    password: process.env.MALACHI_PASS || defaults.password,
  };
}

// The longest wait a Node timer holds: setTimeout runs a longer one after 1 ms, with only a warning.
const MAX_TIMER_MS = 2 ** 31 - 1;

// A wait in milliseconds from the variable `name`, `fallback` when it is unset or empty. Anything but a
// positive whole number up to MAX_TIMER_MS is refused, never read as the fallback or cut short: a typo
// would otherwise wait the default in silence, and too long a wait would end at once.
function msFromEnv(name, fallback, env = process.env) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  if (!/^[1-9][0-9]*$/.test(raw) || Number(raw) > MAX_TIMER_MS) {
    throw new Error(`${name} must be a positive number of milliseconds up to ${MAX_TIMER_MS}, not ${JSON.stringify(raw)}`);
  }
  return Number(raw);
}

// How long a run that reads once waits for a cluster it cannot reach, and how long each of its connects,
// and then its authentication, may take: read by the CLIs that route (./consumer.js and ./subscriber.js,
// which merge this into their config and hand the connect timeout to ./links.js through connOptions), and
// by no other. Their defaults are what a person running one gets; the variables exist so their own tests
// can wait seconds rather than tens of them (#390).
function waits(env = process.env) {
  return {
    unreachableWaitMs: msFromEnv('MALACHI_UNREACHABLE_WAIT_MS', 10000, env),
    connectTimeout: msFromEnv('MALACHI_CONNECT_TIMEOUT_MS', 15000, env),
  };
}

// What a routing client connects with (./links.js): the config's credentials, how long a request may wait
// for its answer, and how long a connect and its authentication may take (the config's own, from waits(),
// or the client's default when the config has none).
function connOptions(cfg, timeout) {
  return { user: cfg.username, pass: cfg.password, timeout, connectTimeout: cfg.connectTimeout };
}

// Splits argv into positional args and a flag map. `--group g`/`--max 10` take the next token as a value;
// bare flags like `--follow` become `true`. `-h`/`--help` is surfaced as flags.help.
function parseArgs(argv, valueFlags = []) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') {
      flags.help = true;
    } else if (a.startsWith('--')) {
      const name = a.slice(2);
      if (valueFlags.includes(name)) {
        flags[name] = argv[++i];
      } else {
        flags[name] = true;
      }
    } else {
      positional.push(a);
    }
  }
  return { positional, flags };
}

// Prints the error and exits non-zero. The "is the server up?" hint only helps for a connection failure:
// a Node network/system error carries an `err.code` (ECONNREFUSED, ETIMEDOUT, ...); an error the server sent
// back (a MalachiError like permission_denied / invalid_operation) has none, meaning the server is reachable,
// so the hint is suppressed there.
function fail(err, cfg) {
  console.error(colors.red(`\nError: ${err.message}`));
  if (cfg && err.code) console.error(colors.gray(`   Is the server running at ${cfg.host}:${cfg.port}?`));
  process.exit(1);
}

// Resolves after `ms`: what consumer.js waits between fetches that served nothing, and ./group_member.js
// before asking a moving coordinator again.
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// The group a consumer group CLI reads as and the member id it joins with: `--group`, and `--member` or
// `<host>-<pid>`, both null without `--group`. `--member` without `--group` exits non-zero: a member belongs
// to a group.
function groupMemberOf(flags) {
  const group = flags.group || null;
  if (flags.member && !group) {
    console.error(colors.red('--member requires --group (a member belongs to a consumer group)'));
    process.exit(1);
  }
  return { group, member: group ? flags.member || `${os.hostname()}-${process.pid}` : null };
}

// Joins `group` as `member` for a consumer group CLI reading `topic` with `reader` (./fetcher.js or
// ./consumer.js, sharing its `router`): every assignment printed and handed to the reader, the join waiting
// for the cluster `waitMs` at most (./group_member.js). Resolves with the joined GroupMember.
async function joinGroupAs({ cfg, router, topic, group, member, reader, waitMs }) {
  // required here, not at the top: ./group_member.js requires this module for `sleep`
  const { GroupMember } = require('./group_member');
  const groupMember = new GroupMember({
    router,
    connOpts: connOptions(cfg, 30000),
    topic,
    group,
    member,
    onAssignment: (assignment) => {
      printAssignment(assignment);
      reader.setAssignment(assignment.ranges);
    },
  });
  try {
    await groupMember.join({ waitMs });
  } catch (err) {
    // a join that went out and was given up on may still have been taken: undone, so the group does not
    // keep a member nobody heartbeats until its session ends
    await groupMember.leave();
    throw err;
  }
  return groupMember;
}

// What a consumer group CLI prints on every assignment the group hands it: the generation's rebalance count
// (its low 32 bits; the coordinator's epoch sits above them) and the ranges, in order.
function printAssignment({ generation, ranges }) {
  console.log(colors.gray(`   generation ${generation % 2 ** 32}: ranges ${JSON.stringify([...ranges].sort((a, b) => a - b))}`));
}

module.exports = { colors, config, msFromEnv, waits, connOptions, parseArgs, fail, sleep, groupMemberOf, joinGroupAs };
