# The Kafka Java client the spike is driven with: kafka-clients from an official apache/kafka image (the
# version under test, passed as KAFKA_IMAGE) on a JDK, so SpikeClient.java runs as a single-file program.
ARG KAFKA_IMAGE
FROM ${KAFKA_IMAGE} AS kafka

FROM eclipse-temurin:21.0.12_8-jdk@sha256:92a2a4d7a928d057e7bd999c418d66c26a34eb9a0442f3ab67721c3f88110b2d
COPY --from=kafka /opt/kafka/libs /opt/kafka/libs
COPY SpikeClient.java /app/SpikeClient.java
WORKDIR /app
ENTRYPOINT ["java", "-cp", "/opt/kafka/libs/*", "/app/SpikeClient.java"]
