FROM elixir:1.19-otp-28-alpine@sha256:07b2cb62c04ce868a1cc7105ab4b673511a8bd18cd1c3fea68d1ba99b969be59 AS builder

WORKDIR /app

RUN apk add --no-cache git build-base ca-certificates

# Patched OpenSSL, as explicit minimum versions. The runner copies libssl.so.3 and libcrypto.so.3 from
# this stage (see below), and that copy is what OTP's crypto NIF loads, so the fix has to land here. The
# base image predates the patched packages, so a digest bump alone does not bring them. Each future CVE
# in these packages moves these minimums; apk fails the build if the repository no longer has them.
RUN apk add --no-cache 'libssl3>=3.5.9-r1' 'libcrypto3>=3.5.9-r1'

ENV MIX_ENV=prod
ENV ERL_FLAGS="+JPperf true"

COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix deps.compile

COPY config config
COPY lib lib
COPY rel rel
# Only priv/static, never priv as a whole: a local checkout keeps gitignored development keys
# (priv/dist_cert, priv/cert) and dialyzer PLTs under priv, and none of them belong in the image.
COPY priv/static priv/static

# The release bakes a cookie into releases/COOKIE when it is built without one: every container of the published image
# would share it, and anyone who pulls the image could read it. The image ships none; rel/env.sh.eex gives a single
# node a random one per start, and a clustered node refuses to start without its own RELEASE_COOKIE.
RUN mix compile && \
    mix release && \
    rm _build/prod/rel/malachi/releases/COOKIE

FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS runner

ARG APP_VERSION

LABEL org.opencontainers.image.title="Malachi" \
      org.opencontainers.image.description="High-performance message system" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/malachi-hq/malachi" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="HectorIFC"

# zlib, libssl3 and libcrypto3 carry explicit minimum versions: the base image predates the patched
# packages, so neither a digest bump nor Dependabot brings them. The OpenSSL libraries are overwritten
# by the builder's copy below; pinning them here keeps the apk database, which image scanners read,
# honest about what ships. Each future CVE in these packages moves these minimums.
RUN apk add --no-cache \
        libstdc++ \
        libgcc \
        ncurses-libs \
        ca-certificates \
        'zlib>=1.4-r0' \
        'libssl3>=3.5.9-r1' \
        'libcrypto3>=3.5.9-r1'

# Copy OpenSSL libraries from builder to ensure binary compatibility with crypto.so
# The elixir:1.19-otp-28-alpine image has crypto.so compiled against a specific OpenSSL version
# that may not match the runner's Alpine package version (the two base images are bumped separately)
COPY --from=builder /usr/lib/libssl.so.3 /usr/lib/
COPY --from=builder /usr/lib/libcrypto.so.3 /usr/lib/

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR /app

RUN addgroup -g 1000 malachi && \
    adduser -u 1000 -G malachi -s /bin/sh -D malachi

# Create and own /app/data so a persistent volume mounted here inherits uid 1000 rather than root,
# which the non-root user below needs to write the log segments and the ra state stored under it.
RUN mkdir -p /app/data && \
    chown -R malachi:malachi /app/data

COPY --from=builder --chown=malachi:malachi /app/_build/prod/rel/malachi ./

USER malachi

ENV MALACHI_TCP_PORT=4040
ENV MALACHI_DASHBOARD_PORT=4041
ENV MALACHI_LOCALE=en_US
# Audit events go to stdout, where a container's logs are collected, instead of the release default of
# stdout plus /var/log/malachi/audit.log: that directory is not writable by the non-root user, and a file
# inside the container would be lost on every recreate. Mount a writable volume and set
# MALACHI_AUDIT_LOG_OUTPUT=both (or file) with MALACHI_AUDIT_LOG_FILE under it to keep a file as well.
ENV MALACHI_AUDIT_LOG_OUTPUT=stdout

# 4040 is the wire protocol, 4041 the dashboard (health, metrics) and 4042 the operator console.
EXPOSE 4040 4041 4042

# Uses busybox wget (bundled in the Alpine base) instead of curl, so the image does not ship the curl
# package and its CVEs just for a liveness probe. -q silences output, -O /dev/null discards the body, and a
# non-2xx response or a refused connection makes wget exit non-zero, which marks the container unhealthy.
# 127.0.0.1 rather than localhost: inside the container localhost resolves to ::1 first, and the dashboard
# listens on IPv4 only, so probing localhost is refused while the node serves fine (#282).
# scripts/docker-image-health-check.sh holds CI to this probe.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:4041/health || exit 1

# Security hardening recommendations:
#   docker run --security-opt=no-new-privileges:true \
#     --read-only --tmpfs /tmp:rw,noexec,nosuid \
#     hectorcardoso/malachi:0.5.0

CMD ["bin/malachi", "start"]
