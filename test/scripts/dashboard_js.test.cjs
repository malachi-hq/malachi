'use strict';

// Unit tests for the dashboard's extracted scripts (#38), run by test/scripts/dashboard_js_test.exs with
// `node --test`. Only the pure functions are exercised; the page itself is exercised in a browser by
// site/checks/dashboard.mjs.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const dir = path.join(__dirname, '..', '..', 'priv', 'static', 'dashboard');
const app = require(path.join(dir, 'app.js'));
const login = require(path.join(dir, 'login.js'));

const topic = (overrides = {}) => ({
  name: 'orders',
  state: 'active',
  groups: [],
  range_count: 2,
  active_range_count: 1,
  segment_count: 3,
  active_segment_count: 1,
  total_bytes: 2048,
  domain_violations: 0,
  ...overrides
});

// A stand-in for a DOM element: closest() walks up a chain of these, as the browser's does.
function element(attributes = {}, parent = null) {
  return {
    attributes,
    parent,
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
    },
    closest(selector) {
      const name = selector.replace(/^\[|\]$/g, '');
      for (let node = this; node; node = node.parent) {
        if (node.getAttribute(name) !== null) return node;
      }
      return null;
    }
  };
}

test('escapeHtml escapes every character that can open markup or an attribute', () => {
  assert.equal(app.escapeHtml(`<img src=x onerror="a('b')">&`), '&lt;img src=x onerror=&quot;a(&#039;b&#039;)&quot;&gt;&amp;');
  assert.equal(app.escapeHtml(42), '42');
  assert.equal(app.escapeHtml(null), 'null');
});

test('formatBytes at its edges', () => {
  assert.equal(app.formatBytes(0), '0 B');
  assert.equal(app.formatBytes(null), '0 B');
  assert.equal(app.formatBytes(undefined), '0 B');
  assert.equal(app.formatBytes(1023), '1023 B');
  assert.equal(app.formatBytes(1024), '1.0 KB');
  assert.equal(app.formatBytes(1536), '1.5 KB');
  assert.equal(app.formatBytes(1024 ** 4), '1.0 TB');
  assert.equal(app.formatBytes(1024 ** 5), '1024.0 TB');
});

test('a topic card carries its index for the delegated listener and no inline handler or style', () => {
  for (const open of [false, true]) {
    const html = app.renderTopicCard(topic({ groups: ['g1'] }), 7, open, { ranges: [] });

    assert.match(html, /data-topic-index="7"/);
    assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
    assert.doesNotMatch(html, /\sstyle\s*=/i);
  }
});

test('an expanded card shows its groups in a class, not a style attribute, and a loading row until detail lands', () => {
  const loading = app.renderTopicCard(topic({ groups: ['billing'] }), 0, true, undefined);
  assert.match(loading, /<div class="topic-groups">groups: <span class="group-chip">billing<\/span><\/div>/);
  assert.match(loading, /loading…/);

  const noGroups = app.renderTopicCard(topic(), 0, true, undefined);
  assert.match(noGroups, /no consumer groups/);

  const closed = app.renderTopicCard(topic({ groups: ['billing'] }), 0, false, undefined);
  assert.doesNotMatch(closed, /topic-detail/);
});

test('a malicious topic name, group and state are escaped', () => {
  const evil = '<img src=x onerror=alert(1)>';
  const html = app.renderTopicCard(topic({ name: evil, state: evil, groups: [evil] }), 0, true, undefined);

  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
});

test('the HA warning badge appears only with domain violations', () => {
  assert.doesNotMatch(app.renderTopicCard(topic(), 0, false), /badge-warn/);
  assert.match(app.renderTopicCard(topic({ domain_violations: 2 }), 0, false), /badge-warn">⚠ 2 HA/);
});

test('ranges and segments render, with an empty-segments row and singular/plural segment counts', () => {
  const html = app.renderRanges([
    { seq: 1, key_start: 0, key_end: 10, state: 'active', segments: [] },
    { seq: 2, key_start: 10, key_end: 20, state: 'sealed', segments: [{ start_offset: 5, length: null, byte_size: 2048, state: 'sealed' }] }
  ]);

  assert.match(html, /range #1 · keys \[0, 10\)/);
  assert.match(html, /0 segs/);
  assert.match(html, /1 seg\n/);
  assert.match(html, /no segments/);
  assert.match(html, /off 5/);
  assert.match(html, /len -/);
  assert.match(html, /2\.0 KB/);
  assert.equal(app.renderRanges(undefined), '');
  assert.match(app.renderSegments(null), /no segments/);
});

test('topicIndexFrom resolves the header from a nested target and ignores everything else', () => {
  const header = element({ 'data-topic-index': '3' });
  const name = element({}, header);
  const badge = element({}, name);

  assert.equal(app.topicIndexFrom(header), 3);
  assert.equal(app.topicIndexFrom(badge), 3);
  assert.equal(app.topicIndexFrom(element({}, element({}))), null);
  assert.equal(app.topicIndexFrom(element({ 'data-topic-index': 'x' })), null);
  assert.equal(app.topicIndexFrom(element({ 'data-topic-index': '' })), null);
  assert.equal(app.topicIndexFrom(element({ 'data-topic-index': '-1' })), null);
  assert.equal(app.topicIndexFrom(null), null);
  assert.equal(app.topicIndexFrom({}), null);
});

test('the login error messages map known problem types and fall back for anything else', () => {
  assert.equal(login.getErrorMessage('errors.auth.invalid_credentials'), 'Invalid username or password');
  assert.equal(login.getErrorMessage('errors.http.rate_limited'), 'Too many attempts. Please try again later.');
  assert.equal(login.getErrorMessage('errors.http.invalid_request'), 'Enter a username and a password.');
  assert.match(login.getErrorMessage('errors.http.header_fields_too_large'), /Clear the cookies/);

  for (const other of ['Login failed', 'toString', '__proto__', 'constructor', undefined, '']) {
    assert.equal(login.getErrorMessage(other), 'An error occurred. Please try again.', String(other));
  }
});
