# Purging a topic

[Per-topic retention](per-topic-retention.md) removes data by policy, on a schedule. A **purge** removes it
on demand: up to a point you name, now. Use it to drop a poison batch, a record produced by mistake, or
everything a decommissioned consumer group already processed, without deleting the topic and every group's
position with it.

## What a purge is

A purge is a **logical purge**. It moves each range's **logical start** forward, and no reader is served an
offset below it: every consume and history read is clamped there, and a reader positioned below it is moved
past and told so. The start only ever moves forward.

The records themselves stay where they are:

- They stay on disk, **on every replica** of their segment, until retention removes the whole segment.
  The next retention sweep removes every sealed segment that lies wholly below the start, whatever its age
  and size; the segment that holds the start stays until the start passes its end.
- Copy repair, the scrubber and replication still read those bytes, because they keep segments whole.

So a purge is not erasure. A secret produced by mistake is unreadable to consumers once the purge answers,
and stays on the disks of the segment's replicas until that segment expires.

## The point

Clients never see offsets, so a purge is up to one of three points:

| point | what is purged |
|---|---|
| a time | every record in a segment the control plane sealed at or before that time |
| an opaque position | the records before a position a read handed out, on the range that issued it |
| a consumer group | everything the group has read |

**A time rounds down to a segment boundary.** Record timestamps are set by the producer, so the only time
the cluster can vouch for is when it sealed a segment. Each range moves to the end of its oldest segments
that were all sealed by then. The active segment is never purged by time: to drop records that are still in
it, purge by position or by group.

**A position is purged only on the range that issued it.** A position still inside a range a split retired
is refused (`cursor_in_ancestor`), because that range's history is read by its other children too.

**A group's commit is resolved through the split lineage.** A range's own records are purged up to the
group's position in it. A range a split retired is purged only up to the least that any of its children has
read, so nothing a sibling's consumers have not read yet is removed. A child the group never committed on
has read nothing, and keeps the retired range whole.

## Running a purge

```bash
# mix task, over Erlang distribution
mix malachi.purge clicks --before 2026-11-13T10:00:00Z
mix malachi.purge clicks --before 1763028000000
mix malachi.purge clicks --cursor 01a3c5...      # a position token, in hex
mix malachi.purge clicks --group billing
```

The task prints each range whose start moved, with the start before and after. A point that moves nothing
(a time before any seal, a group that has read nothing, a point at or below the current start) answers that
there was nothing to purge.

On the wire it is api key 35 (`purge_topic`), `admin` only. Every purge, and every refusal, is written to
the audit log as `topic_purged`, with the user who made it (`cli@<node>` for the mix task), the point, and
each range's logical start before and after.

## When it takes effect

The purge answers after the control plane committed it and the node that ran it applied it, so that node
clamps every read it serves from then on. Every other node applies it on its next metadata refresh, one
second by default. A consume stream already holding a read view serves at most the page it is reading.

A reader moved past purged data reports it as a skip with cause `purged`, logged apart from the skips
retention causes. The cause is decided by position: everything below the logical start is `purged`, even
where retention had already deleted it, since the purge removed it from every reader anyway; anything a
reader loses at or above the start is `expired`. So a consumer that lost data to retention above the start
can still be told from one an operator purged. The retention skip metrics carry the cause as a label
(`cause="purged"` or `cause="expired"`), and the `expired` count a consume stream carries on the wire
leaves purged stretches out, so a client alerting on it does not page on a purge.

## Refusals

| reason | meaning |
|---|---|
| `no_such_topic` | the topic does not exist |
| `invalid_purge_point` | a negative time, an empty group name, or no point at all |
| `invalid_position` | the token does not decode, names another topic, or a range or source the topic does not have |
| `cursor_in_ancestor` | the position is inside a range a split retired; purge by time or by group instead |
| `start_past_end` | the point is past what the node knows of the range's end; retry once it has caught up |
| `metadata_unavailable` | the node has not heard from the topic's control plane yet; retry |
| `migrating` | a vnode split is moving the topic; retry |
| `unsupported_command` | the cluster has not finished upgrading to a release that knows the purge |

## Upgrades

Purging needs control-plane machine version 9. During a rolling upgrade it is refused, identically on every
member, until every node runs a release that implements it and the version pin is lifted. A topic with a
purged range can only be moved by a vnode split to a vnode at version 9 or later, since an older one would
keep the start without clamping its readers.
