defmodule GenerateDistCertsTest do
  # scripts/generate-dist-certs.sh (#385): the certificates inter-node TLS runs on, for development and the cluster
  # harnesses. OTP checks the dialled host against the peer's certificate, so the certificate has to name every host
  # the nodes reach each other by; the options file has to name the files where the node reads them; and nothing in
  # the directory may let a reader mint another certificate the cluster trusts.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/generate-dist-certs.sh", __DIR__)

  defp run(dir, env, args \\ []) do
    System.cmd("bash", [@script | args], env: [{"DIST_CERT_DIR", dir} | env], stderr_to_stdout: true)
  end

  defp text(cert) do
    {out, 0} = System.cmd("openssl", ~w(x509 -noout -text -in #{cert}), stderr_to_stdout: true)
    out
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "names every host it is given, plus localhost and 127.0.0.1, in one CA-signed node certificate", %{
    tmp_dir: dir
  } do
    assert {_out, 0} = run(dir, [{"DIST_CERT_HOSTS", "malachi1, malachi2,10.0.0.7,malachi-0.malachi-headless.ns.svc"}])
    cert = text(Path.join(dir, "node.crt"))

    for san <- ~w(DNS:malachi1 DNS:malachi2 DNS:malachi-0.malachi-headless.ns.svc DNS:localhost),
        do: assert(cert =~ san, "no #{san}")

    assert cert =~ "IP Address:10.0.0.7"
    assert cert =~ "IP Address:127.0.0.1"
    assert cert =~ "TLS Web Server Authentication, TLS Web Client Authentication"
    assert cert =~ "ASN1 OID: prime256v1"

    ca = Path.join(dir, "ca.crt")

    assert {_out, 0} =
             System.cmd("openssl", ~w(verify -CAfile #{ca} #{Path.join(dir, "node.crt")}), stderr_to_stdout: true)
  end

  test "keeps no CA key, and only the node key is private", %{tmp_dir: dir} do
    assert {_out, 0} = run(dir, [])
    assert Enum.sort(File.ls!(dir)) == ~w(ca.crt dist_tls.conf node.crt node.key)
    assert mode(Path.join(dir, "node.key")) == 0o600

    for public <- ~w(ca.crt node.crt dist_tls.conf), do: assert(mode(Path.join(dir, public)) == 0o644)
  end

  test "the options file verifies both ways, under the given prefix", %{tmp_dir: dir} do
    assert {_out, 0} = run(dir, [{"DIST_CONF_PREFIX", "/dist"}])
    {:ok, [conf]} = :file.consult(String.to_charlist(Path.join(dir, "dist_tls.conf")))

    server = Keyword.fetch!(conf, :server)
    client = Keyword.fetch!(conf, :client)

    for side <- [server, client] do
      assert side[:certfile] == ~c"/dist/node.crt"
      assert side[:keyfile] == ~c"/dist/node.key"
      assert side[:cacertfile] == ~c"/dist/ca.crt"
      assert side[:verify] == :verify_peer
      assert side[:versions] == [:"tlsv1.3", :"tlsv1.2"]
    end

    assert server[:fail_if_no_peer_cert] == true
  end

  test "names the files under the directory's own absolute path by default", %{tmp_dir: dir} do
    assert {out, 0} = run(dir, [])
    {:ok, [conf]} = :file.consult(String.to_charlist(Path.join(dir, "dist_tls.conf")))
    assert conf[:server][:certfile] == String.to_charlist(Path.join(dir, "node.crt"))
    assert out =~ "MALACHI_DIST_TLS_OPTFILE=#{dir}/dist_tls.conf"
  end

  test "a second run starts over with a new CA", %{tmp_dir: dir} do
    assert {_out, 0} = run(dir, [])
    first = File.read!(Path.join(dir, "ca.crt"))
    assert {_out, 0} = run(dir, [])
    refute File.read!(Path.join(dir, "ca.crt")) == first
  end

  for {name, env} <- [
        {"a host name that is not one", [{"DIST_CERT_HOSTS", "bad host"}]},
        {"an injected extension", [{"DIST_CERT_HOSTS", "a,IP:1.2.3.4"}]},
        {"a wildcard name, which OTP's exact host name check never matches",
         [{"DIST_CERT_HOSTS", "*.malachi-headless.ns.svc"}]},
        {"an IPv4 octet over 255", [{"DIST_CERT_HOSTS", "10.0.0.256"}]},
        {"a relative prefix", [{"DIST_CONF_PREFIX", "dist"}]},
        {"a prefix with a quote", [{"DIST_CONF_PREFIX", ~s(/di"st)}]},
        {"a validity that is not a number", [{"DIST_CERT_DAYS", "ten"}]}
      ] do
    test "refuses #{name}, writing nothing", %{tmp_dir: dir} do
      assert {out, 2} = run(dir, unquote(Macro.escape(env)))
      assert out =~ "generate-dist-certs:"
      assert File.ls!(dir) == []
    end
  end

  test "a wildcard name is refused saying why, not as a malformed host", %{tmp_dir: dir} do
    assert {out, 2} = run(dir, [{"DIST_CERT_HOSTS", "malachi1,*.malachi-headless.ns.svc"}])
    assert out =~ "a wildcard name (*.malachi-headless.ns.svc) never matches"
    assert out =~ "list each host instead"
  end

  test "refuses an argument, since settings come from the environment", %{tmp_dir: dir} do
    assert {out, 2} = run(dir, [], ["priv/x"])
    assert out =~ "takes no arguments"
  end
end
