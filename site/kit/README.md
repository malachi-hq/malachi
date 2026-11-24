# The kit

What Malachi publishes about itself outside the repository, kept beside the site so it is versioned with it
(issue #373). The maintainer writes every sentence: each `<!-- narrative ... -->` marker below is a place for
that text, and nothing here is published until it is filled in and approved.

## Images

| Source | Image | Size | Used as |
| --- | --- | --- | --- |
| `logo.svg` | `logo.png` | 300x300 | the LinkedIn Page's logo |
| `linkedin-cover.svg` | `linkedin-cover.png` | 1128x191 | the LinkedIn Page's cover |
| `social-preview.svg` | `social-preview.png` | 1280x640 | the repository's social preview, and the site's `og:image` once step 8 of #373 stages it |

`site/kit/render.sh` draws the PNGs from their sources with the Playwright pinned in `site/checks`. The PNGs
are stored in Git LFS and checked against a 300 KB budget by `scripts/site-images-pull.sh`. The images carry
the mark and a name only (the cover the LinkedIn Page's name, MalachiHQ; the others the wordmark), no sentence,
so they never need the maintainer's text to change.

## The LinkedIn Page

The Page is <https://www.linkedin.com/company/malachi-hq>. It was created by the maintainer, who manages it and
names its admins.

| Field | Limit | Text |
| --- | --- | --- |
| Tagline | 120 characters | <!-- narrative: the tagline --> |
| About | 2,000 characters | <!-- narrative: the About text --> |
| Hashtags | 3 | <!-- narrative: up to three hashtags --> |

Writing rules, for the About text above all: Malachi is an independent implementation inspired by the public
design of NorthGuard, with no affiliation with LinkedIn implied, and no claim that either system is better.
LinkedIn's Pages Terms ask the Page to reflect the organization's identity accurately, and let LinkedIn edit a
Page or add a clarification when a name causes confusion.

## Posts

- `linkedin-feed-post.md`: the feed post for each release.
- `linkedin-article.md`: the LinkedIn Article for a milestone, adapted from its blog post.

Each post is published from the browser after the maintainer approves its text
(`docs/guides/release-communication.md`).
