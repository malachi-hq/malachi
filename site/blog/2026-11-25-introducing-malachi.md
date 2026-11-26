---
title: Introducing Malachi, an open source log broker in Elixir
date: 2026-11-25
versions: [0.28.4]
author: Hector Cardoso
cover: cover.png
summary: Malachi is an open source log broker in Elixir whose topics change shape without breaking their clients, and every release publishes the evidence behind it.
---
Some systems cannot afford to lose a [record](https://en.wikipedia.org/wiki/Record_(computer_science)), or to deliver one twice: a payment, an order,
an [audit trail](https://en.wikipedia.org/wiki/Audit_trail).
They need a log that keeps every write it acknowledged while [nodes fail](https://en.wikipedia.org/wiki/Fault_tolerance), disks fill up and the data outgrows
the layout it started with.

[Malachi](https://github.com/malachi-hq/malachi) is an [open source](https://en.wikipedia.org/wiki/Open-source_software)
[log broker](https://en.wikipedia.org/wiki/Message_broker) built for that. It is written in [Elixir](https://elixir-lang.org/) and runs on the
[BEAM](https://www.erlang.org/blog/a-brief-beam-primer/), the virtual machine of
[Erlang/OTP](https://www.erlang.org/), and it is an independent implementation inspired by the public design of
[LinkedIn](https://en.wikipedia.org/wiki/LinkedIn)'s [NorthGuard](https://www.linkedin.com/blog/engineering/infrastructure/introducing-northguard-and-xinfra)
log storage. It is not
affiliated with or endorsed by LinkedIn. This post introduces Malachi as it is in v0.28.4.

## A log that can change shape

In most log brokers a [topic](https://en.wikipedia.org/wiki/Publish%E2%80%93subscribe_pattern) is cut into a fixed number of
[partitions](https://kafka.apache.org/documentation/#intro_concepts_and_terms), and that number decides where
every [key](https://en.wikipedia.org/wiki/Partition_(database)) lands. Growing a topic means moving keys, and the
[clients](https://en.wikipedia.org/wiki/Client_(computing)) notice.

A Malachi client deals in three things: a topic, a key and a [position](../log-model.html). Under the hood a topic is a set of
[ranges](../log-model.html), slices of its [keyspace](https://en.wikipedia.org/wiki/Shard_(database_architecture)), and an operator
[splits and merges them](../clustering-and-resharding.html) while [producers](https://en.wikipedia.org/wiki/Producer%E2%80%93consumer_problem) keep writing. A
[consumer](https://kafka.apache.org/documentation/#intro_concepts_and_terms)'s position is an [opaque token](../produce-and-consume.html), and after a split the new ranges accept the tokens of the range they
came from, so a consumer resumes where it was. It may read its share of the parent's records again, [at least
once](https://kafka.apache.org/documentation/#semantics), and it never loses one.

![A range A splits into ranges B and C while producers keep writing; a consumer's token in A is accepted by both](2026-11-25-introducing-malachi/range-split.png)

## What an acknowledgement means

Each range is a series of [segments](../log-model.html), and each segment is
[replicated](https://en.wikipedia.org/wiki/Replication_(computing)) across nodes. A write is acknowledged once a
[majority](https://en.wikipedia.org/wiki/Quorum_(distributed_computing)) of its segment's replicas has written it to disk with [fsync](https://man7.org/linux/man-pages/man2/fsync.2.html). The [metadata](https://en.wikipedia.org/wiki/Metadata), which topics and ranges
exist and where their segments live, is replicated by [Raft](https://raft.github.io/). Membership uses [SWIM](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf), placement is rack-aware, and
the cluster repairs the replicas it finds missing.

![A producer's write reaches the segment's primary and two replicas, and is acknowledged once two of the three have fsynced it](2026-11-25-introducing-malachi/acknowledgement.png)

Security is on by default: [TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security), with [mTLS for clients](../authentication.html),
[OIDC](https://openid.net/developers/how-connect-works/) sign-in and
[access control per topic](../per-topic-acls.html).

## Evidence with every release

A claim about [durability](https://en.wikipedia.org/wiki/Durability_(database_systems)) is worth the test behind it. Every release of Malachi ships with:

- [chaos drills](../running-chaos-drills.html) that kill nodes, break storage and roll out bad configurations, then check that every
  acknowledged write is still there;
- [load tests](https://en.wikipedia.org/wiki/Load_testing) run on the release's exact code, published with the hardware they ran on and the noise between
  runs;
- a [changelog](https://github.com/malachi-hq/malachi/blob/main/CHANGELOG.md) and upgrade notes.

![Each release feeds chaos drills, load tests and its changelog, and their results are published with it](2026-11-25-introducing-malachi/release-evidence.png)

The results of every run are published beside the code, in the
[benchmark results](https://github.com/malachi-hq/malachi/blob/main/benchmark/README.md).

## Where it stands

Malachi is in active development and is not production-ready. Its interfaces and on-disk formats can still
change, it has not been tested at scale, and it makes no stability guarantee yet. It is ready to learn from
and to experiment with. What comes next is on the
[project board](https://github.com/orgs/malachi-hq/projects/1).

## Try it

One node on your machine, with [Docker](https://www.docker.com/):

```bash
docker run --name malachi \
  -p 127.0.0.1:4040:4040 -p 127.0.0.1:4041:4041 \
  -e MALACHI_ADMIN_PASS=your_secure_password \
  -e MALACHI_REQUIRE_TLS=false \
  -e MALACHI_ADVERTISED_HOST=127.0.0.1 \
  hectorcardoso/malachi:latest
```

It serves [plaintext](https://en.wikipedia.org/wiki/Plaintext) on [localhost](https://en.wikipedia.org/wiki/Localhost) only, which is why TLS is turned off there. The
[documentation](../introduction.html) covers [clusters](https://en.wikipedia.org/wiki/Computer_cluster), TLS and the client protocol, and the code is on
[GitHub](https://github.com/malachi-hq/malachi), [MIT licensed](https://github.com/malachi-hq/malachi/blob/main/LICENSE). Issues labelled
[good first issue](https://github.com/malachi-hq/malachi/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
are a place to start contributing.

## Follow along

New posts arrive with each release: subscribe to the [newsletter](index.html) on the blog, follow the
[Atom feed](feed.xml) or the [Malachi page on LinkedIn](https://www.linkedin.com/company/malachi-hq).

## What changed in v0.28.4

### Performance

- batch the sealed copy integrity probe (#372)
