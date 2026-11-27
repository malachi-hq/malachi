defmodule TlsJsTest do
  # The Node client over TLS (scripts/lib/tls.selftest.js): verification against the given CA and by host name,
  # nothing sent before the handshake, --insecure as the only way past verification, a client certificate
  # authenticating by mtls_auth, every routed connection verified, and settings failing closed. The certificates
  # are generated here, per run, since a private key is never committed.
  use ExUnit.Case, async: true

  alias Malachi.Test.CertFixtures

  @moduletag :tmp_dir

  @selftest Path.expand("../../scripts/lib/tls.selftest.js", __DIR__)

  setup_all do
    # A missing runtime fails loudly instead of skipping: a skipped client test reads as a passing one.
    %{node: System.find_executable("node") || flunk("node is required; install Node 22.15+ (zstd in zlib)")}
  end

  test "the Node client's TLS cases pass", %{node: node, tmp_dir: dir} do
    ca = CertFixtures.ca!(dir)
    CertFixtures.leaf!(ca, dir, "server", "localhost", ["DNS:localhost", "IP:127.0.0.1"])
    CertFixtures.leaf!(ca, dir, "other", "other.test", ["DNS:other.test"])
    CertFixtures.leaf!(ca, dir, "client", "selftest-client", ["DNS:selftest-client"])
    CertFixtures.ca!(dir, "ca2")

    {out, status} =
      System.cmd(node, [@selftest], env: [{"MALACHI_TLS_SELFTEST_DIR", dir}], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "passed 12 tls cases"
  end

  test "the fixtures name the hosts the cases connect by", %{tmp_dir: dir} do
    ca = CertFixtures.ca!(dir)
    %{cert: cert} = CertFixtures.leaf!(ca, dir, "server", "localhost", ["DNS:localhost", "IP:127.0.0.1"])
    {text, 0} = System.cmd("openssl", ~w(x509 -in #{cert} -noout -text), stderr_to_stdout: true)
    assert text =~ "DNS:localhost"
    assert text =~ "IP Address:127.0.0.1"
    {_out, 0} = System.cmd("openssl", ~w(verify -CAfile #{ca.cert} #{cert}), stderr_to_stdout: true)
  end
end
