#!/bin/bash
# Generates certificates for Malachi inter-node TLS (Erlang distribution): a CA, one node certificate signed by it
# (each node is both TLS server and client, so one certificate serves every node it names), and a ready ssl_dist
# options file. For development and the cluster harnesses; use your real PKI in production.
#
# The connecting node checks that the peer's certificate names the host it dialled (OTP passes that host as the
# TLS server name), so the certificate must carry every host name the nodes reach each other by: the host part of
# each node name (malachi@<host>). OTP's default check matches names exactly and takes no wildcard, so a wildcard
# name is refused here: list the hosts, or issue one certificate per node.
#
# Settings, from the environment:
#   DIST_CERT_DIR     where to write ca.crt, node.crt, node.key and dist_tls.conf (default priv/dist_cert)
#   DIST_CERT_HOSTS   comma-separated host names or IPv4 addresses the certificate names (default malachi-node);
#                     localhost and 127.0.0.1 are always added. A wildcard ("*.") is refused, see above.
#   DIST_CONF_PREFIX  the directory the options file names the files under, for a file read inside a container
#                     where DIST_CERT_DIR is mounted elsewhere (default: DIST_CERT_DIR's absolute path)
#   DIST_CERT_DAYS    validity in days (default 825)
#
# The CA's private key is deleted once the node certificate is signed: nothing that mounts the directory can mint
# another certificate the cluster would trust. Run the script again to start over with a new CA.
set -euo pipefail
umask 077

CERT_DIR="${DIST_CERT_DIR:-priv/dist_cert}"
HOSTS="${DIST_CERT_HOSTS:-malachi-node}"
DAYS="${DIST_CERT_DAYS:-825}"

fail() {
  echo "generate-dist-certs: $*" >&2
  exit 2
}

[ "$#" -eq 0 ] || fail "takes no arguments (settings come from the environment, see the header)"
case "$DAYS" in '' | *[!0-9]*) fail "DIST_CERT_DAYS must be a whole number of days" ;; esac

# Each host becomes one subjectAltName entry: an IPv4 address as IP:, anything else, checked, as DNS:.
sans=""
add_san() {
  case ",$sans," in *",$1,"*) return ;; esac
  sans="${sans:+$sans,}$1"
}
IFS=',' read -r -a requested <<<"$HOSTS"
for host in "${requested[@]}" localhost 127.0.0.1; do
  host="${host#"${host%%[![:space:]]*}"}"
  host="${host%"${host##*[![:space:]]}"}"
  [ -n "$host" ] || continue
  if [[ "$host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for octet in "${BASH_REMATCH[@]:1}"; do [ "$octet" -le 255 ] || fail "not an IPv4 address: $host"; done
    add_san "IP:$host"
  elif [[ "$host" == \** ]]; then
    fail "a wildcard name ($host) never matches: OTP's distribution checks host names exactly; list each host instead"
  elif [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
    add_san "DNS:$host"
  else
    fail "not a host name or IPv4 address: $host"
  fi
done

mkdir -p "$CERT_DIR"
ABS="$(cd "$CERT_DIR" && pwd)"
PREFIX="${DIST_CONF_PREFIX:-$ABS}"
case "$PREFIX" in /*) ;; *) fail "DIST_CONF_PREFIX must be an absolute path" ;; esac
case "$PREFIX" in *'"'* | *'\'*) fail "DIST_CONF_PREFIX cannot hold a quote or a backslash" ;; esac

echo "Generating inter-node TLS certificates in $CERT_DIR for $sans"

rm -f "$ABS/ca.key" "$ABS/ca.crt" "$ABS/node.key" "$ABS/node.crt" "$ABS/dist_tls.conf"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# P-256 keys: milliseconds to generate, where RSA 4096 took seconds on every harness run.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days "$DAYS" \
  -keyout "$work/ca.key" -out "$ABS/ca.crt" -subj "/O=Malachi/CN=Malachi Distribution CA"

openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$ABS/node.key" -out "$work/node.csr" -subj "/O=Malachi/CN=malachi-node"
cat >"$work/node.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=$sans
EOF
openssl x509 -req -days "$DAYS" -in "$work/node.csr" -CA "$ABS/ca.crt" -CAkey "$work/ca.key" \
  -CAcreateserial -CAserial "$work/ca.srl" -extfile "$work/node.ext" -out "$ABS/node.crt"

chmod 600 "$ABS/node.key"
chmod 644 "$ABS/ca.crt" "$ABS/node.crt"

# The options file names the files under PREFIX, where the node reads them.
cat >"$ABS/dist_tls.conf" <<EOF
[
  {server, [
    {certfile, "$PREFIX/node.crt"},
    {keyfile, "$PREFIX/node.key"},
    {cacertfile, "$PREFIX/ca.crt"},
    {verify, verify_peer},
    {fail_if_no_peer_cert, true},
    {secure_renegotiate, true},
    {versions, ['tlsv1.3', 'tlsv1.2']}
  ]},
  {client, [
    {certfile, "$PREFIX/node.crt"},
    {keyfile, "$PREFIX/node.key"},
    {cacertfile, "$PREFIX/ca.crt"},
    {verify, verify_peer},
    {secure_renegotiate, true},
    {versions, ['tlsv1.3', 'tlsv1.2']}
  ]}
].
EOF
chmod 644 "$ABS/dist_tls.conf"

echo "Done: ca.crt, node.crt, node.key and dist_tls.conf in $CERT_DIR (the CA key is not kept)."
echo "Run a release with inter-node TLS:"
echo "  MALACHI_DIST_TLS=true MALACHI_DIST_TLS_OPTFILE=$PREFIX/dist_tls.conf bin/malachi start"
