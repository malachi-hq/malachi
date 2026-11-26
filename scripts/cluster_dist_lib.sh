# Erlang distribution for the Docker cluster harnesses (docker-compose.cluster.yml and the release image's
# docker-compose.cluster-durable.yml), sourced by scripts/chaos_lib.sh and the cluster benchmarks (#385).
#
# A clustered node refuses a committed cookie and plaintext distribution it did not opt into
# (Malachi.Cluster.DistGuard), so every run gets its own: `cluster_dist_setup <dir>` writes a CA and a node
# certificate for malachi1..3 into <dir> (scripts/generate-dist-certs.sh, the CA key not kept), and exports
#
#   MALACHI_COOKIE            a random cookie for this run
#   MALACHI_DIST_DIR          <dir>, which the compose files mount read-only at /dist on every node
#   MALACHI_DIST_TLS          true, or false with DIST_TLS=0
#   MALACHI_DIST_ERL_OPTIONS  the VM options of TLS distribution, empty with DIST_TLS=0
#
# DIST_TLS=0 runs plaintext distribution, explicitly: the baseline of the A/B in benchmark/docker-cluster.sh.
# The release image runs as uid 1000, so the files are readable by any user: they are throwaway material for one
# run, in a directory the caller removes when it exits. <dir> must be on a path the Docker host shares (under the
# repository, as the callers put it). The cookie shows in the nodes' process arguments, which is acceptable for a
# cookie that lives for one run.

# The host names the node certificate carries: the compose services, which are the nodes' host names.
CLUSTER_DIST_HOSTS="malachi1,malachi2,malachi3"

cluster_dist_setup() {
  local dir="$1"
  [ -n "$dir" ] || { echo "cluster_dist_setup: no directory given" >&2; return 1; }
  mkdir -p "$dir" && chmod 755 "$dir" || { echo "cluster_dist_setup: cannot create $dir" >&2; return 1; }

  case "${DIST_TLS:-1}" in
    1)
      DIST_CERT_DIR="$dir" DIST_CERT_HOSTS="$CLUSTER_DIST_HOSTS" DIST_CONF_PREFIX=/dist \
        bash scripts/generate-dist-certs.sh >/dev/null || { echo "cluster_dist_setup: certificates failed" >&2; return 1; }
      chmod 644 "$dir/node.key"
      export MALACHI_DIST_TLS=true
      export MALACHI_DIST_ERL_OPTIONS="-proto_dist inet_tls -ssl_dist_optfile /dist/dist_tls.conf"
      ;;
    0)
      export MALACHI_DIST_TLS=false
      export MALACHI_DIST_ERL_OPTIONS=""
      ;;
    *)
      echo "cluster_dist_setup: DIST_TLS must be 1 (TLS distribution) or 0 (plaintext baseline)" >&2
      return 1
      ;;
  esac

  MALACHI_COOKIE="$(openssl rand -hex 32)" && [ "${#MALACHI_COOKIE}" -eq 64 ] ||
    { echo "cluster_dist_setup: cannot generate a cookie" >&2; return 1; }
  export MALACHI_COOKIE
  export MALACHI_DIST_DIR="$dir"
}
