# Data subject requests

A person whose records a topic holds can ask for them to be removed (for example under the LGPD, art. 18).
Malachi answers such a request with a [purge](purging-a-topic.md) that carries the request: the request is
recorded in the audit trail, the purge is applied, and both entries share the request's id.

Read this page in full before telling anyone their records were removed. A purge does less than its name
suggests, and what it does is stated below.

## What "purged" means

A purge is a **logical purge**. It moves each range's logical start forward, and from then on no reader is
served a record below it. The records themselves are not removed:

- They stay on disk, **on every replica** of their segment, until retention removes the whole segment. The
  next retention sweep removes every sealed segment that lies wholly below the start; the segment that holds
  the start stays until the start passes its end.
- Copy repair, the scrubber and replication still read those bytes, because they keep segments whole.
- Anyone with access to the disks, or to a backup of them, can still read them until then.

So a purge is not erasure. A secret produced by mistake is unreadable to consumers once the purge answers,
and stays readable from the disks of the segment's replicas until that segment expires. Removing a single
record from disk needs log compaction, which Malachi does not have yet.

## A purge removes everyone's records below the point

A purge is up to a point: a time, a position, or what a consumer group has read. It removes **every record
below that point, from every subject**, not only the requester's. To reach a subject's last record, a purge
also removes every earlier record on the same range, whoever it belongs to.

It answers one subject's request without touching anyone else's records only where the records below the
point belong to that subject alone:

- **Key the subject's records by the subject.** While the topic's ranges stay as they are, a key lands on
  one range, so a purge by position (`--cursor`) on that range leaves the topic's other ranges alone. The
  collateral is then the other subjects that share the range, not the whole topic. A split or a merge
  changes that: the subject's earlier records stay in the range that was split or merged away, which is
  now an ancestor that every child reads first, and a position purge never moves an ancestor (it is
  refused as `cursor_in_ancestor`). Those records stay readable until a purge by time or by group, or
  retention, passes them, and both purges act on the whole topic.
- **A topic per subject.** A purge then removes that subject's records only. Its name must be opaque (see
  below). A consumer group per subject does not do this: a purge by group removes everything the group has
  read, whoever's records they are.
- **A group that already processed everything.** A purge by group (`--group`) removes only what that group
  has read, which suits topics whose records are no longer needed once processed.

Look at what the purge will move before you run it: the command prints each range's logical start before
and after, and a purge cannot be undone.

## Running a request

```bash
mix malachi.purge clicks --cursor 01a3c5... --request DSR-2026-0042 --reason "LGPD art. 18 request"
```

`--request` and `--reason` go together, and are checked before anything is sent:

| field | what it holds | bounds |
|---|---|---|
| `--request` | the request's reference in your own system, such as a ticket number | 1 to 128 bytes of printable ASCII, no spaces |
| `--reason` | why the purge is made | 1 to 512 bytes of text, no control, format or line separator characters |

A request that covers several topics is one run per topic, each with the same `--request`. On the wire it is
api key 35 (`purge_topic`, `admin` only), whose request carries the same two fields; see
[Purging a topic](purging-a-topic.md#upgrades) for what an older client or node answers.

The command prints `request DSR-2026-0042 applied` with each range's start before and after, or
`request DSR-2026-0042 recorded; nothing below ... was readable` when the point moved nothing: the records
were purged by an earlier run, or the point is not where you thought.

If the command answers `timeout`, the purge may still have applied. Run the same command again, with the
same `--request`: a purge never moves a start backward, so the second run either moves what the first did
not or moves nothing, and its audit entries say which. What a timed out run moved is not in the audit
trail: its `topic_purged` entry holds the timeout, and the second run sees those starts already moved, so
neither entry holds the starts before the first run. No command shows a range's logical start yet, so
those starts cannot be read back either: keep the timeout and the second run's answer with the request's
own record, and say that the starts before the purge are unknown.

## What the audit trail records

Each run writes two entries to the audit log:

1. `purge_request_recorded`, before the purge runs: the request id, the reason, the topic, the point, and
   the user who ran it (`cli@<node>` for the mix task, the session user on the wire). The audit log is
   flushed before the purge is sent, so with file output the entry is on disk first, and a node killed
   right after the purge commits still leaves the request in the trail.
2. `topic_purged`, after: the same request id, and each range's logical start before and after, or the
   refusal.

A request that was refused (an unknown topic, a topic name or a point that is not valid, an unfinished
upgrade) is still recorded, followed by the refusal under the same id; a field that was not valid is
recorded by its size only. A request whose id or reason is out of bounds is refused without a
`purge_request_recorded` entry: on the wire the refusal's `topic_purged` entry keeps only the sizes of
what was sent, and the mix task refuses it before anything is sent, so nothing reaches the audit trail.

The audit log is kept in memory on the node that ran the purge for 30 days, and is lost if that process
restarts. For a record you can rely on later, ship it to storage you keep: set `MALACHI_AUDIT_LOG_OUTPUT` to
`stdout`, `file` or `both` (the default outside tests) and collect it with your log pipeline. The file
rotates at `MALACHI_AUDIT_LOG_MAX_SIZE_MB` and drops its oldest lines, so it is not an archive by itself.

## Keep the subject out of the record

The audit trail and the logs are never purged. Whatever you put in them about the subject stays there:

- The request id is a reference in your own system, never the subject's name, e-mail, document number, or
  a hash of any of them (a hash of a low-entropy identifier is recovered by brute force).
- The reason names no one.
- The topic and consumer group names are written to the audit trail and the logs too. A topic kept per
  subject must have an opaque name, never one that identifies the person. A purge by group takes a group
  name of 1 to 255 bytes of text with no control, format or separator characters; a group whose name is
  outside that can still be purged by time or by position.
- The command line stays in the shell history and the process list of the machine that runs it.

## Legal reading

Whether a logical purge satisfies a particular request is a legal question, and it depends on the request.
Neither this software nor this documentation decides it. Get a legal reading before you tell a requester
that their records were removed, or before anyone relies on a purge to meet an obligation. What can be said
is what this page states: after a purge, no reader of the cluster is served the purged records, and the
bytes remain on disk until their segment expires.
