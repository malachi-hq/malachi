# Legal hold

[Per-topic retention](per-topic-retention.md) deletes data by policy, and a [purge](purging-a-topic.md) by
request. A **legal hold** is the opposite of both: it keeps a topic's data, whatever its retention policy
says, until you release it. Use it when a legal or audit requirement says the data must be preserved, without
touching the policy that will apply again once the requirement ends.

## What a hold does

While a topic is held:

- **Retention expires none of its segments**, by age, by size or below a purged start. The sweep still
  judges the topic by its policy, and counts what it would have expired as held instead
  (`malachi_retention_held_segments{topic}` and `malachi_retention_held_bytes{topic}`), so the disk a hold
  keeps is visible.
- **The topic cannot be deleted, and it cannot be purged.** The control plane refuses the delete, the purge
  and the delete of any of its segments with `legal_hold`. A refused delete or purge is audited; a segment
  delete refused during a retention sweep is counted in
  `malachi_retention_expire_failures_total{reply="legal_hold"}`. The refusal is made
  by the topic's own vnode, so it holds whichever node the request reaches and however stale that node's
  view is. A sweep that read the metadata just before the hold landed is refused at its deletes too.
- **Writes and reads go on.** A hold keeps data; it does not stop a topic.

A hold covers **segment data only**. The control plane snapshots and truncates its own Raft log as always,
and copy repair, the scrubber and failover still replace damaged or divergent copies of a segment, which
keeps the data rather than losing it.

**Releasing the hold lets the next retention sweep expire whatever the policy would have expired
meanwhile**, possibly a great deal at once. Read `malachi_retention_held_bytes` before releasing.

The hold belongs to the topic and travels with it when a vnode split moves it.

## Placing, reading and releasing a hold

```bash
mix malachi.hold set orders --reason "case 2026-114, preserve until released"
mix malachi.hold show orders
mix malachi.hold release orders
```

Connection options are `--node` (or `$MALACHI_NODE`) and the cookie in `$RELEASE_COOKIE` (or `--cookie`, which
shows in `ps` and the shell history), as for every `mix malachi.*` task.

On the wire the keys are 36 (`set_topic_hold`, the topic and a reason), 37 (`release_topic_hold`) and 38
(`get_topic_hold`), all `admin` only. The hold records **who placed it** (the session's user on the wire,
`cli@<node>` from the CLI, never a name the request carries), **why**, and **when** the control plane
committed it. `mix malachi.policy get <topic>` shows the retention that applies once the hold is released;
`Malachi.Policies.topic_policy/1` reports the hold beside it.

Every placement and release is in the audit log (`topic_hold_set`, `topic_hold_released`), refused ones
included, with the reason.

## The reason

The reason is free text written verbatim into the audit log, so it is checked: 1 to 1024 bytes of UTF-8
with no control character, no line or paragraph separator and no formatting character (such as a
right-to-left override). Anything else is refused with `invalid_hold`, so a reason cannot forge a line in
the audit trail.

## Refusals

| reason | meaning |
|---|---|
| `already_held` | the topic is already held; release it first to place a hold with another reason |
| `not_held` | there is no hold to release |
| `invalid_hold` | the reason is empty, too long, or holds a character it may not |
| `no_such_topic` | the topic does not exist |
| `legal_hold` | a delete or a purge of a held topic |
| `unsupported_command` | the cluster has not finished the upgrade to a release with holds (below) |

## Upgrades

Holding needs control-plane machine version 11. Until every node runs a release that implements it and the
version pin is lifted, `mix malachi.hold` and api keys 36 and 37 are refused with a message saying to finish
the rolling upgrade, and a vnode split cannot move a held topic to a vnode below 11.
