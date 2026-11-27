defmodule ClusterDistLibTest do
  # The Docker cluster harnesses' Erlang distribution (#385): scripts/cluster_dist_lib.sh gives every run its own
  # cookie and TLS certificates, and the compose files take both from it, holding neither themselves.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @need_vars ~w(MALACHI_COOKIE MALACHI_DIST_TLS MALACHI_DIST_DIR)

  # Sources the lib from the repository root, runs cluster_dist_setup on `dir`, and prints what it exported.
  defp setup_in(dir, env \\ []) do
    script = ~S"""
    . scripts/cluster_dist_lib.sh
    cluster_dist_setup "$1" || exit $?
    printf 'COOKIE=%s\nTLS=%s\nOPTS=%s\nDIR=%s\n' "$MALACHI_COOKIE" "$MALACHI_DIST_TLS" "$MALACHI_DIST_ERL_OPTIONS" "$MALACHI_DIST_DIR"
    """

    {out, status} = System.cmd("bash", ["-c", script, "bash", dir], cd: @root, env: env, stderr_to_stdout: true)

    vars =
      for line <- String.split(out, "\n"), [_, k, v] <- [Regex.run(~r/\A([A-Z]+)=(.*)\z/, line)], into: %{}, do: {k, v}

    {vars, out, status}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "cluster_dist_setup" do
    test "TLS by default: certificates for the three nodes, a fresh cookie, the options under /dist", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "dist")
      {vars, _out, 0} = setup_in(dir)

      assert vars["TLS"] == "true"
      assert vars["OPTS"] == "-proto_dist inet_tls -ssl_dist_optfile /dist/dist_tls.conf"
      assert vars["DIR"] == dir
      assert vars["COOKIE"] =~ ~r/\A[0-9a-f]{64}\z/

      assert Enum.sort(File.ls!(dir)) == ~w(ca.crt dist_tls.conf node.crt node.key)
      assert File.read!(Path.join(dir, "dist_tls.conf")) =~ ~s("/dist/node.crt")
      # read by the release image's uid 1000; throwaway material in a directory the caller removes
      assert mode(Path.join(dir, "node.key")) == 0o644
      assert mode(dir) == 0o755

      {text, 0} = System.cmd("openssl", ~w(x509 -noout -text -in #{Path.join(dir, "node.crt")}))
      for host <- ~w(malachi1 malachi2 malachi3), do: assert(text =~ "DNS:#{host}")
    end

    test "every run gets another cookie", %{tmp_dir: tmp} do
      {%{"COOKIE" => first}, _, 0} = setup_in(Path.join(tmp, "a"))
      {%{"COOKIE" => second}, _, 0} = setup_in(Path.join(tmp, "b"))
      refute first == second
    end

    test "DIST_TLS=0 is the explicit plaintext baseline, with no certificates", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "dist")
      {vars, _out, 0} = setup_in(dir, [{"DIST_TLS", "0"}])
      assert vars["TLS"] == "false"
      assert vars["OPTS"] == ""
      assert vars["COOKIE"] =~ ~r/\A[0-9a-f]{64}\z/
      assert File.ls!(dir) == []
    end

    test "any other DIST_TLS is refused", %{tmp_dir: tmp} do
      {_vars, out, 1} = setup_in(Path.join(tmp, "dist"), [{"DIST_TLS", "yes"}])
      assert out =~ "DIST_TLS must be 1 (TLS distribution) or 0 (plaintext baseline)"
    end

    test "no directory is refused", _ctx do
      {_vars, out, 1} = setup_in("")
      assert out =~ "no directory given"
    end
  end

  describe "the compose files" do
    for file <- ~w(docker-compose.cluster.yml docker-compose.cluster-durable.yml) do
      test "#{file} takes the cookie and the transport from the run, and mounts the certificates on every node" do
        text = File.read!(Path.join(@root, unquote(file)))

        for var <- @need_vars, do: assert(text =~ "${#{var}:?", "#{unquote(file)} does not require #{var}")

        mounts = Regex.scan(~r|"\$\{MALACHI_DIST_DIR:\?[^}]*\}:/dist:ro"|, text)
        assert length(mounts) == 3, "#{unquote(file)} mounts /dist on #{length(mounts)} nodes, not 3"
      end
    end

    test "the benchmark cluster starts its nodes with the run's cookie and distribution options" do
      text = File.read!(Path.join(@root, "docker-compose.cluster.yml"))
      assert text =~ ~s(exec elixir --sname malachi --cookie \\"$$MALACHI_COOKIE\\" -S mix run --no-halt)
      assert text =~ ~s(ELIXIR_ERL_OPTIONS: "${MALACHI_DIST_ERL_OPTIONS?)
    end

    test "the load generator service mounts no certificate: it speaks the client protocol, not distribution" do
      text = File.read!(Path.join(@root, "docker-compose.cluster.yml"))
      [_, loadtest] = String.split(text, ~r/^  loadtest:\n/m, parts: 2)
      [service | _] = String.split(loadtest, ~r/^\S/m, parts: 2)
      refute service =~ "/dist"
    end

    test "the durable cluster runs TLS distribution with the options file the run mounts" do
      text = File.read!(Path.join(@root, "docker-compose.cluster-durable.yml"))
      assert text =~ "MALACHI_DIST_TLS_OPTFILE: /dist/dist_tls.conf"
    end
  end
end
