# The kit

What Malachi publishes about itself outside the repository, kept beside the site so it is versioned with it
(issue #373). The maintainer writes every sentence: each `<!-- narrative ... -->` marker below is a place for
that text, and nothing is published until it is filled in and approved. The texts already on the Page are
copied here as published.

## Images

| Source | Image | Size | Used as |
| --- | --- | --- | --- |
| `logo.svg` | `logo.png` | 300x300 | the LinkedIn Page's logo |
| `linkedin-cover.svg` | `linkedin-cover.png` | 1128x191 | the LinkedIn Page's cover |
| `social-preview.svg` | `social-preview.png` | 1280x640 | the repository's social preview, and the site's `og:image` (staged at `doc/kit/social-preview.png`) |

`site/kit/render.sh` draws the PNGs from their sources with the Playwright pinned in `site/checks`. The PNGs
are stored in Git LFS and checked against a 300 KB budget by `scripts/site-images-pull.sh`. The images carry
the mark and a name only (the cover the LinkedIn Page's name, MalachiHQ; the others the wordmark), no sentence,
so they never need the maintainer's text to change.

## The LinkedIn Page

The Page is <https://www.linkedin.com/company/malachi-hq>. It was created by the maintainer, who manages it and
names its admins.

| Field | Limit | Text |
| --- | --- | --- |
| Tagline | 120 characters | Nodes fail. Topics split. Not one record lost or copied. |
| About | 2,000 characters | below |
| Hashtags | 3 | <!-- narrative: up to three hashtags --> |

The About text, as published:

```text
Malachi is an open source log broker for systems that cannot afford to lose a record or deliver it twice.

Nodes fail. Disks fill up. Topics outgrow their partitions. Malachi is built for those moments: every write is replicated through Raft consensus, topics reshard while producers keep writing, and a restarted node rejoins without losing what it acknowledged.

It is written in Elixir and runs on the BEAM, the runtime built for systems that have to stay up.

What every release ships with, in the open:
• Benchmarks measured on that release's exact code, with the hardware and the run-to-run noise
• Chaos drills that kill nodes, break storage and roll out bad configs, with their results published
• A changelog and upgrade notes

Secure by default: mTLS, OIDC sign-in and per-topic access control.

Malachi is an independent implementation inspired by the public design of NorthGuard. It is not affiliated with or endorsed by LinkedIn.

Follow the Page for release results and the engineering behind them.
Code, docs and results: https://malachi-hq.github.io/malachi
```

Specialties: Distributed systems, Event streaming, Message broker, Log storage, Elixir, Erlang/OTP, Raft
consensus, Open source, Observability, Chaos engineering, Performance benchmarking. Founded: 2026.

Writing rules, for the About text above all: Malachi is an independent implementation inspired by the public
design of NorthGuard, with no affiliation with LinkedIn implied, and no claim that either system is better.
LinkedIn's Pages Terms ask the Page to reflect the organization's identity accurately, and let LinkedIn edit a
Page or add a clarification when a name causes confusion.

## Posts

- `linkedin-feed-post.md`: the feed post for each release.
- `linkedin-article.md`: the LinkedIn Article for a milestone, adapted from its blog post.

Each post is published from the browser after the maintainer approves its text
(`docs/guides/release-communication.md`).
