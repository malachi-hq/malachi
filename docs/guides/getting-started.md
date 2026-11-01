# Getting started

This guide takes you from a clone to your first appended and consumed record, first in-process and then
over the network.

Requires Elixir `~> 1.19` / OTP 28+.

## Run the broker

```bash
git clone https://github.com/HectorIFC/malachi.git
cd malachi
mix deps.get
iex -S mix        # TCP on 4040, dashboard on 4041
```

A single node runs its control plane as a one-member `ra` cluster, so its topics and consumer positions
survive a restart as long as `MALACHI_LOG_DATA_DIR`, `MALACHI_RA_DATA_DIR` and the node name stay the same
(`iex -S mix` without `--name` always runs as `nonode@nohost`). Set `MALACHI_LOG_CLUSTER` /
`MALACHI_LOG_NODES` for a replicated, HA control plane across several nodes; the environment variables are
listed in the
[README](../../README.md) (the *Environment Variables* section).

Prefer containers? See [Running with Docker](../DOCKER_README.md).

## Your first records (from `iex`)

The quickest way to see the model is a client in that `iex` session. `Malachi.Loadtest.Client` speaks the
binary protocol over the network, as every client does: it reads the cluster state and the topic's routes
from the node it connects to, then writes and reads each range at the broker that leads it. The `app`
user is seeded in development only (see below):

```elixir
alias Malachi.Loadtest.Client
alias Malachi.Log.Record

{:ok, client} =
  Client.connect(host: "127.0.0.1", port: Malachi.TCPAcceptorPool.port(), user: "app", pass: "app123")

# the keyspace size is the server's to choose: it ignores the 8 asked for here
:ok = Client.create_topic(client, "events", 8)

# produce by key: no partitions, the key picks the range
{:ok, 2} =
  Client.produce(client, "events", [Record.new("hello", key: "user-1"), Record.new("world", key: "user-2")], 5_000)

# consume from the start of every range
{:ok, %{values: values, positions: positions}} = Client.read(client, "events")
values        #=> ["hello", "world"]
positions     #=> %{0 => <<1, ...>>}: an opaque token for where range 0's next page starts
```

Two things to notice, because they are the whole design:

1. You addressed records by **key**, never by partition.
2. A read hands back, per range, an opaque **position in the range's history**, which keeps its meaning
   when the range splits. You compare two (`Client.compare_positions/2`) and hand one back, never compute
   one. A consumer group checkpoints those positions on the server
   ([Produce and consume](produce-and-consume.md) shows how).

`Malachi.Loadtest.Client` is a small client for checks like this one (`connect/1`, `create_topic/3`,
`produce/4`, `read/3`, `join/4`, `commit/6`, `leave/4`); see its documentation for every return shape.

## Over the network

External clients speak the binary protocol on port **4040**. The repository ships reference clients in
`scripts/` (Node.js, no dependencies):

```bash
cd scripts

# append 10 records to "orders" (creating the topic first)
node producer.js orders --create

# read them back from the start
node consumer.js orders

# keep long-polling for new records
node consumer.js orders --follow
```

Each client authenticates first. In development the seeded users are `producer` / `producer123`,
`consumer` / `consumer123` and `app` / `app123` (both permissions); the scripts default to the first two,
and `MALACHI_USER` / `MALACHI_PASS` override them. Point them at another node with `MALACHI_HOST` /
`MALACHI_PORT`: they read the cluster's routes there and go on to the broker that leads each range.

> #### Development credentials only {: .warning}
> Those seeded users exist in `dev`/`test` only. Production refuses to boot with them: you either supply
> passwords explicitly or let the node generate a random admin password and print it in the logs. That is
> a one-time event only when `MALACHI_RA_DATA_DIR` is a persistent volume; on the temp default it repeats
> whenever the temp directory does not survive (a recreated container or a reboot). See the
> *Authentication* section of the [README](../../README.md).

## The dashboard

Open <http://localhost:4041> for the built-in dashboard (metrics, topics, live stream). It requires an
authenticated admin session: see the dashboard section of the README for the credentials it expects.

## Next steps

- [The log model](log-model.md): why a position survives a split and what a *range* is.
- [Produce and consume](produce-and-consume.md): batching, keys and ordering, consumer groups, and the
  errors a correct client retries.
- [Streaming with backpressure](streaming-with-backpressure.md): server push and the credit window.
- `Malachi.Wire`: the binary protocol, if you are writing a client.
- The *Observability* section of the [README](../../README.md), Prometheus metrics, telemetry, tracing.
