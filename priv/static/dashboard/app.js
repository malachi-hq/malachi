'use strict';

// The dashboard's script, served as /app.js so the Content-Security-Policy can say script-src 'self' with no
// 'unsafe-inline'. Nothing in the markup this builds carries an inline handler or a style attribute: the policy
// would block both. A topic header is a data-topic-index attribute, and one click listener on #topics resolves it.
//
// The rendering functions are pure (data in, markup out) and are exported under Node so they can be tested
// without a browser; everything that touches the DOM runs only in a browser, once the document is parsed.

// Topic names are user-controlled, so every value interpolated into HTML is escaped.
function escapeHtml(unsafe) {
  return String(unsafe)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function formatBytes(n) {
  if (!n) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return (i === 0 ? v : v.toFixed(1)) + ' ' + units[i];
}

function renderSegments(segments) {
  if (!segments || segments.length === 0) return '<div class="seg-empty">no segments</div>';
  return segments.map(s => `
    <div class="seg-row">
      <span>off ${s.start_offset}</span>
      <span>len ${s.length == null ? '-' : s.length}</span>
      <span>${formatBytes(s.byte_size)}</span>
      <span class="badge badge-${escapeHtml(s.state)}">${escapeHtml(s.state)}</span>
    </div>
  `).join('');
}

function renderRanges(ranges) {
  return (ranges || []).map(r => `
    <div class="range-block">
      <div class="range-head">
        range #${r.seq} · keys [${r.key_start}, ${r.key_end}) ·
        <span class="badge badge-${escapeHtml(r.state)}">${escapeHtml(r.state)}</span> ·
        ${r.segments.length} seg${r.segments.length === 1 ? '' : 's'}
      </div>
      ${renderSegments(r.segments)}
    </div>
  `).join('');
}

// `open` says whether the card is expanded and `detail` is its fetched ranges (undefined while loading). The
// card's index into the last rendered list rides on data-topic-index, which the click listener reads.
function renderTopicCard(t, i, open, detail) {
  const groups = (t.groups || []).map(g => `<span class="group-chip">${escapeHtml(g)}</span>`).join('');
  let detailHtml = '';
  if (open) {
    const body = detail ? renderRanges(detail.ranges) : '<div class="seg-empty">loading…</div>';
    detailHtml = `
    <div class="topic-detail">
      ${groups ? '<div class="topic-groups">groups: ' + groups + '</div>' : '<div class="seg-empty">no consumer groups</div>'}
      ${body}
    </div>`;
  }
  const warn = t.domain_violations > 0 ? ' · <span class="badge badge-warn">⚠ ' + t.domain_violations + ' HA</span>' : '';
  return `
    <div class="topic-card">
      <div class="topic-header" data-topic-index="${i}">
        <span class="topic-name">${open ? '▾' : '▸'} ${escapeHtml(t.name)} <span class="badge badge-${escapeHtml(t.state)}">${escapeHtml(t.state)}</span></span>
        <span class="topic-summary">${t.active_range_count}/${t.range_count} ranges · ${t.active_segment_count}/${t.segment_count} segs · ${formatBytes(t.total_bytes)} · ${(t.groups || []).length} grp${warn}</span>
      </div>
      ${detailHtml}
    </div>`;
}

// The topic index a click targets: the nearest element carrying data-topic-index, or null when the click landed
// outside every header (between cards, inside an expanded detail) or the attribute is not an index.
function topicIndexFrom(target) {
  if (!target || typeof target.closest !== 'function') return null;
  const header = target.closest('[data-topic-index]');
  if (!header) return null;
  const raw = header.getAttribute('data-topic-index');
  if (!/^\d+$/.test(raw || '')) return null;
  return Number(raw);
}

function startDashboard() {
  // Drill-down state, keyed by topic name, survives the per-second summary re-render. The heavy
  // per-range/segment detail is NOT in the stream: it is fetched once, on expand, into topicDetails.
  const expandedTopics = new Set();
  const topicDetails = {};
  let lastTopics = [];
  const topicsEl = document.getElementById('topics');

  function renderTopics(topics) {
    lastTopics = topics || [];
    if (lastTopics.length === 0) {
      topicsEl.innerHTML = '<div class="empty-state">No topics</div>';
      return;
    }
    topicsEl.innerHTML = lastTopics
      .map((t, i) => renderTopicCard(t, i, expandedTopics.has(t.name), topicDetails[t.name]))
      .join('');
  }

  // Fetch one topic's ranges/segments on demand; re-render only if it is still expanded when it lands.
  function loadTopicDetail(name) {
    fetch('/topic?name=' + encodeURIComponent(name))
      .then(resp => (resp.ok ? resp.json() : null))
      .then(detail => {
        if (detail && expandedTopics.has(name)) {
          topicDetails[name] = detail;
          renderTopics(lastTopics);
        }
      })
      .catch(() => {});
  }

  function toggleTopic(i) {
    const t = lastTopics[i];
    if (!t) return;
    if (expandedTopics.has(t.name)) {
      expandedTopics.delete(t.name);
      delete topicDetails[t.name];
      renderTopics(lastTopics);
    } else {
      expandedTopics.add(t.name);
      renderTopics(lastTopics); // show the header expanded + a loading row immediately
      loadTopicDetail(t.name);
    }
  }

  topicsEl.addEventListener('click', event => {
    const i = topicIndexFrom(event.target);
    if (i !== null) toggleTopic(i);
  });

  // Auth is handled via HttpOnly cookies, sent automatically by the browser.
  const source = new EventSource('/stream');
  source.onmessage = event => {
    const data = JSON.parse(event.data);
    document.getElementById('processes').textContent = data.system.process_count;
    document.getElementById('memory').textContent = data.system.memory.total_mb.toFixed(2) + ' MB';
    renderTopics(data.topics);
  };

  source.onerror = error => {
    console.error('EventSource error:', error);
    // Session likely expired - redirect to login
    if (source.readyState === EventSource.CLOSED) {
      window.location.href = '/login';
    }
  };
}

if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startDashboard);
  } else {
    startDashboard();
  }
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { escapeHtml, formatBytes, renderSegments, renderRanges, renderTopicCard, topicIndexFrom };
}
