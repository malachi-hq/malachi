// The Java client side of the Kafka spike (#166): produces a fixed set of records to partition 0 of a topic
// through the spike, fetches them back with assign and seek (no consumer group, no ListOffsets), and
// compares every record byte for byte with what it sent: key (null included), value, headers and
// timestamp. Prints one JSON line with the outcome, so the harness can collect it.
//
// Usage: java -cp '/opt/kafka/libs/*' SpikeClient.java <bootstrap> <topic> <count> <idempotence>
//   idempotence: default (leave enable.idempotence unset, as an application does), true or false
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.Future;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.header.Header;
import org.apache.kafka.common.header.internals.RecordHeader;
import org.apache.kafka.common.serialization.ByteArrayDeserializer;
import org.apache.kafka.common.serialization.ByteArraySerializer;

public class SpikeClient {
  static final long BASE_TS = 1_700_000_000_000L;

  // Record i: a null key every 7th, an empty value every 11th, two headers (one binary, one repeated
  // key) every 3rd, and values of varying size from a seeded generator.
  static ProducerRecord<byte[], byte[]> record(String topic, int i) {
    Random random = new Random(i);
    byte[] key = i % 7 == 0 ? null : ("key-" + i).getBytes(StandardCharsets.UTF_8);
    byte[] value = new byte[i % 11 == 0 ? 0 : 1 + random.nextInt(2048)];
    random.nextBytes(value);
    List<Header> headers = new ArrayList<>();
    if (i % 3 == 0) {
      byte[] binary = new byte[16];
      random.nextBytes(binary);
      headers.add(new RecordHeader("bin", binary));
      headers.add(new RecordHeader("bin", "again".getBytes(StandardCharsets.UTF_8)));
    }
    return new ProducerRecord<>(topic, 0, BASE_TS + i, key, value, headers);
  }

  static String digest(Long ts, byte[] key, byte[] value, Iterable<Header> headers) throws Exception {
    MessageDigest md = MessageDigest.getInstance("SHA-256");
    md.update(Long.toString(ts).getBytes(StandardCharsets.UTF_8));
    md.update(key == null ? new byte[] {0} : concat(new byte[] {1}, key));
    md.update(value == null ? new byte[] {0} : concat(new byte[] {1}, value));
    for (Header h : headers) {
      md.update(h.key().getBytes(StandardCharsets.UTF_8));
      md.update(h.value() == null ? new byte[] {0} : concat(new byte[] {1}, h.value()));
    }
    return HexFormat.of().formatHex(md.digest());
  }

  static byte[] concat(byte[] a, byte[] b) {
    byte[] out = Arrays.copyOf(a, a.length + b.length);
    System.arraycopy(b, 0, out, a.length, b.length);
    return out;
  }

  static String json(Map<String, Object> fields) {
    StringBuilder sb = new StringBuilder("{");
    for (Map.Entry<String, Object> e : fields.entrySet()) {
      if (sb.length() > 1) sb.append(',');
      Object v = e.getValue();
      String s = v instanceof Number || v instanceof Boolean ? v.toString()
          : "\"" + String.valueOf(v).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ") + "\"";
      sb.append('"').append(e.getKey()).append("\":").append(s);
    }
    return sb.append('}').toString();
  }

  public static void main(String[] args) throws Exception {
    String bootstrap = args[0], topic = args[1], idempotence = args[3];
    int count = Integer.parseInt(args[2]);
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("client", "java");
    // AppInfoParser moved between 3.x and 4.x: the version is read from the kafka-clients jar's name
    String jar = new java.io.File(KafkaProducer.class.getProtectionDomain().getCodeSource().getLocation().getPath()).getName();
    String version = jar.replaceAll("^kafka-clients-(.*)\\.jar$", "$1");
    out.put("version", version);
    out.put("idempotence", idempotence);

    Properties p = new Properties();
    p.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
    p.put(ProducerConfig.CLIENT_ID_CONFIG, "java-" + version + "-producer");
    p.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class.getName());
    p.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class.getName());
    p.put(ProducerConfig.COMPRESSION_TYPE_CONFIG, "none");
    p.put(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 20_000);
    p.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, 10_000);
    p.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 20_000);
    if (!idempotence.equals("default")) p.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, idempotence);

    Map<String, String> expected = new LinkedHashMap<>();
    long firstOffset = -1;
    try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(p)) {
      List<Future<RecordMetadata>> sent = new ArrayList<>();
      for (int i = 0; i < count; i++) {
        ProducerRecord<byte[], byte[]> r = record(topic, i);
        sent.add(producer.send(r));
        expected.put(Integer.toString(i), digest(r.timestamp(), r.key(), r.value(), r.headers()));
      }
      producer.flush();
      List<Long> offsets = new ArrayList<>();
      for (Future<RecordMetadata> f : sent) offsets.add(f.get().offset());
      firstOffset = offsets.get(0);
      out.put("produce", "ok");
      out.put("first_offset", firstOffset);
      out.put("offsets_contiguous", offsets.equals(java.util.stream.LongStream.range(firstOffset, firstOffset + count).boxed().toList()));
    } catch (Exception e) {
      Throwable cause = e.getCause() != null ? e.getCause() : e;
      out.put("produce", "error");
      out.put("error", cause.getClass().getSimpleName() + ": " + cause.getMessage());
      System.out.println(json(out));
      System.exit(2);
    }

    Properties c = new Properties();
    c.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
    c.put(ConsumerConfig.CLIENT_ID_CONFIG, "java-" + version + "-consumer");
    c.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, ByteArrayDeserializer.class.getName());
    c.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, ByteArrayDeserializer.class.getName());
    c.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
    c.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 500);
    int matched = 0, mismatched = 0;
    try (KafkaConsumer<byte[], byte[]> consumer = new KafkaConsumer<>(c)) {
      TopicPartition tp = new TopicPartition(topic, 0);
      consumer.assign(List.of(tp));
      consumer.seek(tp, firstOffset);
      long deadline = System.currentTimeMillis() + 30_000;
      int seen = 0;
      while (seen < count && System.currentTimeMillis() < deadline) {
        for (ConsumerRecord<byte[], byte[]> r : consumer.poll(Duration.ofMillis(500))) {
          int i = (int) (r.offset() - firstOffset);
          String got = digest(r.timestamp(), r.key(), r.value(), r.headers());
          if (got.equals(expected.get(Integer.toString(i)))) matched++; else mismatched++;
          seen++;
        }
      }
      out.put("fetch", seen == count ? "ok" : "short");
    } catch (Exception e) {
      out.put("fetch", "error");
      out.put("error", e.getClass().getSimpleName() + ": " + e.getMessage());
    }
    out.put("matched", matched);
    out.put("mismatched", mismatched);
    out.put("count", count);
    System.out.println(json(out));
    System.exit(matched == count && mismatched == 0 ? 0 : 3);
  }
}
