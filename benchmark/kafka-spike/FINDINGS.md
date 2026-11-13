# Kafka gateway spike (#166): findings for #165

Measured on 2026-11-13, in Docker on Linux (Colima, 4 CPUs, kernel 6.8.0-117, aarch64), server pinned to
cores 1-3 and clients to core 0. Every number below comes from a run whose raw output is under
`benchmark/kafka-spike/results/`, and every harness can be rerun with the command named beside it.

## 1. Codec: kafka_protocol for schemas and request decoding, our own response and batch encoding

`kafka_protocol` 4.3.7 (4.3.8 was under two weeks old) can serve the server side, but only in part:

- **Usable as is.** Its message schemas (`kpro_schema`) describe requests and responses alike, and its
  struct decoder (`kpro_rsp_lib:dec_struct/4`) is exported, so request bodies decode against the request
  schema. Every request frame captured from the Java client 3.9.2 and 4.4.0 and from kcat (23 frames, in
  `test/fixtures/kafka/`) decodes whole and re-encodes to the same bytes through the library.
- **Missing: a response encoder.** The struct encoder is private to the request path, so responses are
  encoded by walking the library's response schemas with its exported primitive encoder (about 40 lines,
  `Malachi.KafkaSpike.Codec`).
- **Not usable for record batches.** `kpro_batch` is a client's codec: it decodes a null key, value or
  header value as an empty binary (a tombstone becomes an empty value), cannot encode a null key, numbers
  the records of a batch from offset 0, and asserts the CRC with a match that crashes the caller. Its
  varint encoder stops at 35 bits, so a timestamp delta above about 199 days in one batch (two records of a
  quiet topic fetched later) cannot be written. RecordBatch v2 is encoded and decoded by our own module
  (`Malachi.KafkaSpike.RecordBatch`), with the library's `crc32cer` NIF for CRC32C.
- **Its null collapse reaches request fields too.** A null `nullable_string` decodes as `<<>>` (a Produce's
  null `transactional_id` reads as an empty one), which the gateway must keep in mind wherever null and
  empty differ.
- **Its version ceiling.** It has schemas up to Produce v8, Fetch v11, Metadata v9, ApiVersions v3 and
  InitProducerId v2. Java 3.9.2 and 4.4.0 and librdkafka 1.8.2 all negotiate down to those and work (Java
  4.4.0 first sends ApiVersions v5, gets UNSUPPORTED_VERSION as v0 with the list, and retries at v3).
  Against a real 4.4.0 broker the same clients use Produce v13 and Fetch v18. A client that drops the old
  versions is the point where a codec generated from Kafka's JSON schemas becomes necessary.

**Decision: go,** with the split above: the library's schemas and request decoding, our own response
encoder and RecordBatch codec. A generated codec is not needed for the minimum viable gateway; it becomes
the plan when the version ceiling bites.

## 2. Idempotence per client and version

`benchmark/kafka-spike/clients.sh 200`, a fresh node per case, 200 records per case (null keys, empty
values, binary and repeated headers), read back with assign and seek and compared byte for byte
(`results/clients-20261113T062611Z/results.jsonl`):

| client | idempotence | spike hides InitProducerId | spike advertises it |
|---|---|---|---|
| Java 3.9.2 | default (on) | **fails**: `UnsupportedVersionException: The node does not support INIT_PRODUCER_ID` | 200/200 |
| Java 3.9.2 | false | 200/200 | 200/200 |
| Java 4.4.0 | default (on) | **fails**, same exception | 200/200 |
| Java 4.4.0 | false | 200/200 | 200/200 |
| kcat 1.7.1, librdkafka 1.8.2 | default (off) | 200/200 | 200/200 |
| kcat 1.7.1, librdkafka 1.8.2 | true | **fails**: fatal, idempotent producer not supported | 200/200 |

An unmodified Java application cannot produce to a gateway without InitProducerId, which confirms #165's
decision 2. No client asked for any API beyond ApiVersions, Metadata, Produce, Fetch and InitProducerId,
because the consumers used assign and seek; a consumer group or a logical start offset needs FindCoordinator,
the group APIs and ListOffsets. `cp-kcat` 8.2.4 still ships librdkafka 1.8.2 (2021): librdkafka 2.x, and
franz-go and Sarama, are untested.

## 3. MirrorMaker 2's API list

`benchmark/kafka-spike/mm2.sh`: MirrorMaker 2 4.4.0 copying topic `orders` (3 partitions, 1000 records)
and group `app` between two Kafka 4.4.0 clusters, every request logged by the brokers
(`results/mm2-20261113T063250Z/apis-*.tsv`). It copied the topic as `src.orders` and translated the
group's offsets onto it.

- **Target cluster (where Malachi would sit):** Produce, Fetch, ListOffsets, Metadata, OffsetCommit,
  OffsetFetch, FindCoordinator, JoinGroup, Heartbeat, LeaveGroup, SyncGroup, DescribeGroups, ApiVersions,
  CreateTopics, IncrementalAlterConfigs, DescribeCluster, ConsumerGroupDescribe, DescribeTopicPartitions.
- **Source cluster (stays Kafka):** the same data and group APIs plus ListGroups, InitProducerId,
  DescribeAcls and DescribeConfigs.
- CreatePartitions was not called (the source never grew); group offsets are written to the target with
  OffsetCommit, from the checkpoint connector's admin client.

Against the spike as its target (`results/mm2-20261113T070522Z`), MirrorMaker 2 stops before copying
anything: in dedicated mode it is a Kafka Connect cluster whose offsets, configs and status live in
**compacted** topics on the target, which it creates with CreateTopics and checks with DescribeConfigs.
The spike advertises neither, the Java admin client fails inside the client without sending the request
(so the spike's refusal log stays empty), and the worker gives up waiting for `mm2-offsets.src.internal`.

**Consequence for #171:** "MirrorMaker 2 through the gateway" needs, on top of the data path and the group
protocol, CreateTopics, IncrementalAlterConfigs, DescribeCluster and **log compaction**, which #165 puts
out of scope. The alternative that avoids compaction is to run the mirror connectors in a Connect cluster
whose internal topics live on the source Kafka, so Malachi only receives the data and the group offsets;
that has to be verified before the migration story is promised.

## 4. Overhead against the native protocol

`benchmark/kafka-spike/overhead.sh`: the same generator on both wires (`mix malachi.loadtest --wire
malachi` against `--wire kafka`), 5 repetitions in alternating order, a fresh node per run, the node in the
regime of `docker-compose.bench.yml` (group commit, replication factor 1, admission limits off), 256-byte
records. Medians (`results/overhead-20261113T073655Z` for produce, `results/overhead-20261113T080647Z`
for fetch, after the fix below):

| case | scenario | native rec/s | kafka rec/s | ratio | native p50 | kafka p50 |
|---|---|---|---|---|---|---|
| 1 conn, batch 1, pipeline 1 | produce | 223 | 221 | 0.99x | 4.10 ms | 4.10 ms |
| 1 conn, batch 1, pipeline 1 | fetch | 152,050 | 133,861 | 0.88x | 0.64 ms | 0.64 ms |
| 16 conn, batch 10, pipeline 4 | produce | 173,190 | 37,264 | **0.22x** | 2.90 ms | 16.38 ms |
| 16 conn, batch 10, pipeline 4 | fetch | 220,830 | 218,172 | 0.99x | 7.19 ms | 28.77 ms |

The codec alone (`codec_bench.exs`, same image): decoding a Produce of 10 records takes 6.0 us, encoding a
Fetch response of 100 records 71 us. The codec is not where the overhead is:

- **Produce is serialized per connection.** The spike answers one request at a time per connection (as a
  Kafka broker does) and each answer waits for `BrokerServer.produce/3`, a synchronous call that returns
  once the append is durable (about 4 ms under group commit). 16 connections x 10 records / 4 ms is about
  40k rec/s, which is what was measured. The native producer pipelines appends on its streams. The gateway
  needs the asynchronous append path (the producer streams' `send_stream_produce`) with answers released
  in order, not the in-process produce.
- **Fetch matched once the read size did.** The first run read 1000 records per request and trimmed them
  to the byte limit (0.43x); reading the native page size (100) gives 0.99x. A Malachi read is bounded by
  records, not bytes: the gateway needs a byte-bounded read.
- **Latency is the group commit's.** One request at a time costs the same on both wires.

These are lower bounds for one partition on one node, as #166 warned.

## 5. Native libraries in CI and the image

- `crc32cer` needs `cmake` (absent on macOS by default; present on the Ubuntu runner). The Alpine builder
  now installs `cmake`, and also `bash` and `curl` for the optional compression NIFs: `ezstd` clones zstd at
  a pinned commit through a bash script, and `lz4b` downloads the lz4 tarball with curl **without verifying
  a checksum** (a supply chain gap to close before #168 adopts it). The same applies to
  `benchmark/Dockerfile.loadtest`.
- The five libraries add about 2.4 MB to the release (image 64.4 MB). A cold build of the deps stage on 4
  CPUs took about 19 minutes; the compression NIFs are most of it.
- All five are clean on OSV, and are in a new `kafka` tier of `scripts/deps_check.exs` (Dependabot group
  `hex`).

## 6. Requirements the spike found for #167

- **Null value (tombstone), null header value and negative timestamps** have no representation in
  `Malachi.Log.Record`; the spike refuses them with INVALID_RECORD.
- **A split moves the offsets:** a topic split after the gateway resolved it lands a produce in the
  children, and the spike refuses it (verified by test); #167's "splits forbidden" is required, not optional.
- **Leader epochs** are announced as unknown (-1): a known epoch makes the Java consumer validate its
  position with OffsetsForLeaderEpoch.
- **Fetch sessions** stay off (session id 0). kafka_protocol's Fetch v7+ schema describes
  `forgotten_topics_data` with full partition entries where Kafka sends a list of partition ids, so an
  incremental fetch session would not decode.

## Revised estimates

The codec risk is retired: about two weeks of the gateway's codec work is the response encoder, the
batch codec and the version table, all prototyped here. Two risks moved the other way: the produce path
needs the asynchronous append with in-order answers to reach native throughput (#168), and the MirrorMaker
2 migration needs either compaction or a Connect topology that keeps the internal topics on Kafka (#171).
The 4 to 7 months for a minimum viable gateway stands; the MirrorMaker 2 part of #171 should not be
promised until that topology is shown to work.
