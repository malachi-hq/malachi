# Release communication

Every release of Malachi opens its own announcement and a checklist issue, and its data becomes a blog post
whose text the maintainer writes. This guide is the routine that turns one release into its communication,
and the tools each step uses (issue #373).

## What the release does by itself

When `release.yml` publishes vX.Y.Z:

- the GitHub release opens a discussion in the **Announcements** category;
- `CHANGELOG.md` gains the release's section in the version bump commit: the highlights, the upgrade notes
  and the grouped changes, the same text as the release notes without the image and checkout lines;
- the `announce` job opens the issue **Release vX.Y.Z communication** from
  `.github/ISSUE_TEMPLATE/release-communication.md`, holding the routine below as a checklist.

A pull request contributes to the release text through two optional sections of its description,
`## Release highlights` and `## Upgrading`, read only from an author with write access to the repository.

## Routine per release

1. Generate the post with `mix malachi.release.post vX.Y.Z` and write its narrative.
2. Open the post's pull request and merge it.
3. Comment the post's link on the release's Announcements discussion.
4. Send the dev.to draft with `mix malachi.release.post --devto site/blog/<post>.md`, then review and publish it on dev.to.

The checklist issue holds the same steps, and a test keeps the two lists identical.

### 1. The post

```bash
mix malachi.release.post vX.Y.Z               # one release
mix malachi.release.post vA..vB               # consecutive patch releases of one minor version
```

The draft lands in `site/blog/`. It holds the measurements of the release's code, with the hardware and the
commit of each run, the changes and upgrade notes from `CHANGELOG.md`, the charts of a minor or major
release, and `<!-- narrative -->` placeholders. The release highlights are offered as a `malachi-seed`
block. Write the narrative, fold the highlights into it, and delete the block: the site check
(`mix malachi.docs.site --check`) refuses a post that still holds a placeholder or a seed.

The numbers are never typed by hand. Each one comes from the published run that measured the released code
(`Malachi.Release.Measurements`), not from the file as it was at the tag, which holds the previous version's
numbers. A change between two releases is shown only when both runs recorded the same CPU model and core
count (the Elixir load test records only the architecture, so it never shows one), and it is never
called a gain or a regression: on shared CI runners the published ceiling moves by more than 30% between runs
of unchanged code.

The charts are drawn inline on the site and published as PNG images for dev.to, Medium and LinkedIn. The task
renders them with the Playwright pinned in `site/checks`; the first time, install it:

```bash
cd site/checks && npm ci && npx playwright install --only-shell chromium
mix malachi.release.post --images site/blog/<post>.md   # again after editing a chart
```

The images are stored in Git LFS: run `git lfs install` once.

### 2. The pull request

A `docs:` pull request with the post and its images. Merging it publishes the post within minutes: a push to
main that touches `site/blog/` rebuilds the site (`pages.yml`).

### 3. The discussion

Comment the post's URL on the release's discussion in Announcements, so watchers of Discussions reach it.

### 4. dev.to

```bash
DEVTO_API_KEY=... mix malachi.release.post --devto site/blog/<post>.md
```

It sends the post as a draft (`published: false`) with its `canonical_url` set to the post on this site, the
charts as their PNG images and every relative link made absolute. A second run updates the same draft while it
is a draft; once it is published on dev.to the script refuses it, and the article is edited there. The key
stays in the maintainer's environment and never reaches CI. Review the draft on dev.to and publish it there.

## From the browser, each post approved before it is published

These channels have no integration here: each post is published from the browser, after the maintainer
approves its text. Accounts, logins, terms and verification codes stay with the maintainer.

- Medium and Hashnode: their import tools, from the post's URL, which keeps the canonical link.
- The Malachi LinkedIn Page: a feed post per release, and an Article for a milestone, with "originally
  published at" and the canonical link.
- Elixir Forum, ElixirStatus (the source of Elixir Weekly and Elixir Radar), Reddit, Bluesky and X.

## A first round, done once

- A thread in the Elixir Forum's libraries category.
- A pull request to awesome-elixir.
- A post in r/elixir.
- A pitch to the Thinking Elixir podcast.
- The ElixirConf and Code BEAM calls for talks.

## Gated channels

Hacker News, Lobsters and r/apachekafka wait until a benchmark with a published methodology exists.

## Writing rules

- The maintainer writes every public text. The generator writes data and placeholders only.
- Malachi is described as an independent implementation inspired by NorthGuard's public design. Nothing
  implies an affiliation with LinkedIn, and nothing says that either system is better than the other.
- A number cites the hardware and the commit that measured it, and a difference within the runners' noise is
  not presented as a change.
