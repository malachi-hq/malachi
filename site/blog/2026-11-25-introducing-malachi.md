---
title: Introducing Malachi
date: 2026-11-25
versions: [0.28.4]
author: Hector Cardoso
summary: Malachi is an open source log broker in Elixir whose topics change shape without breaking their clients, and every release publishes the evidence behind it.
---
Some systems cannot afford to lose a record, or to deliver one twice: a payment, an order, an audit trail.
They need a log that keeps every write it acknowledged while nodes fail, disks fill up and the data outgrows
the layout it started with.

Malachi is an open source log broker built for that. It is written in Elixir and runs on the BEAM, and it is
an independent implementation inspired by the public design of LinkedIn's NorthGuard log storage. It is not
affiliated with or endorsed by LinkedIn. This post introduces Malachi as it is in v0.28.4.

## A log that can change shape

In most log brokers a topic is cut into a fixed number of partitions, and that number decides where every key
lands. Growing a topic means moving keys, and the clients notice.

A Malachi client deals in three things: a topic, a key and a position. Under the hood a topic is a set of
ranges, slices of its keyspace, and an operator splits and merges them while producers keep writing. A
consumer's position is an opaque token, and after a split the new ranges accept the tokens of the range they
came from, so a consumer resumes where it was. It may read its share of the parent's records again, at least
once, and it never loses one.

![A range A splits into ranges B and C while producers keep writing; a consumer's token in A is accepted by both](2026-11-25-introducing-malachi/range-split.png)

## What an acknowledgement means

Each range is a series of segments, and each segment is replicated across nodes. A write is acknowledged once
a majority of its segment's replicas has written it to disk with fsync. The metadata, which topics and ranges
exist and where their segments live, is replicated by Raft. Membership uses SWIM, placement is rack-aware, and
the cluster repairs the replicas it finds missing.

![A producer's write reaches the segment's primary and two replicas, and is acknowledged once two of the three have fsynced it](2026-11-25-introducing-malachi/acknowledgement.png)

Security is on by default: TLS, with mTLS for clients, OIDC sign-in and access control per topic.

## Evidence with every release

A claim about durability is worth the test behind it. Every release of Malachi ships with:

- chaos drills that kill nodes, break storage and roll out bad configurations, then check that every
  acknowledged write is still there;
- load tests run on the release's exact code, published with the hardware they ran on and the noise between
  runs;
- a changelog and upgrade notes.

![Each release feeds chaos drills, load tests and its changelog, and their results are published with it](2026-11-25-introducing-malachi/release-evidence.png)

The results of every run are published beside the code, in the
[benchmark results](https://github.com/malachi-hq/malachi/blob/main/benchmark/README.md).

## Where it stands

Malachi is in active development and is not production-ready. Its interfaces and on-disk formats can still
change, it has not been tested at scale, and it makes no stability guarantee yet. It is ready to learn from
and to experiment with. What comes next is on the
[project board](https://github.com/orgs/malachi-hq/projects/1).

## Try it

One node on your machine, with Docker:

```bash
docker run --name malachi \
  -p 127.0.0.1:4040:4040 -p 127.0.0.1:4041:4041 \
  -e MALACHI_ADMIN_PASS=your_secure_password \
  -e MALACHI_REQUIRE_TLS=false \
  -e MALACHI_ADVERTISED_HOST=127.0.0.1 \
  hectorcardoso/malachi:latest
```

It serves plaintext on localhost only, which is why TLS is turned off there. The
[documentation](../introduction.html) covers clusters, TLS and the client protocol, and the code is on
[GitHub](https://github.com/malachi-hq/malachi), MIT licensed. Issues labelled good first issue are a place
to start contributing.

## Follow along

New posts arrive with each release: subscribe to the newsletter below, follow the
[Atom feed](feed.xml) or the [Malachi page on LinkedIn](https://www.linkedin.com/company/malachi-hq).

## What changed in v0.28.4

### Performance

- batch the sealed copy integrity probe (#372)
