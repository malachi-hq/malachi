---
name: Release communication
about: The routine that turns one release into its communication. The release workflow opens one per release.
title: Release vX.Y.Z communication
---

The routine of [the release communication playbook](https://malachi-hq.github.io/malachi/release-communication.html)
for vX.Y.Z. Tick each step as it is done; the maintainer writes every public text and approves every post
before it is published.

## Routine per release

- [ ] Generate the post with `mix malachi.release.post vX.Y.Z` and write its narrative.
- [ ] Open the post's pull request and merge it.
- [ ] Comment the post's link on the release's Announcements discussion.
- [ ] Review the dev.to draft the feed import made from the post, add its tags, and publish it on dev.to.

## From the browser, each post approved before it is published

- [ ] Import the post into Medium.
- [ ] Import the post into Hashnode.
- [ ] A feed post on the Malachi LinkedIn Page (and an Article for a milestone).
- [ ] Elixir Forum.
- [ ] ElixirStatus.
- [ ] Reddit.
- [ ] Bluesky.
- [ ] X.
