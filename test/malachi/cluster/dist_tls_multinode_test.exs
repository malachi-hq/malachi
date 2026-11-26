defmodule Malachi.Cluster.DistTlsMultinodeTest do
  # TLS distribution between real nodes (#385), with the options file scripts/generate-dist-certs.sh writes: two
  # nodes whose certificates the shared CA signed connect, and a node whose certificate another CA signed does not,
  # whatever cookie it holds. The peers are driven over standard_io, not over the test node's own plaintext
  # distribution, so the only distribution link in each case is the one between peers.
  use ExUnit.Case, async: false

  alias Malachi.Test.CertFixtures

  @moduletag :multinode
  @moduletag :tmp_dir

  @cookie String.duplicate("t", 32)

  # An ssl_dist options file for `leaf`, trusting `ca`, verifying both ways as the release's does.
  defp optfile(dir, name, ca, leaf) do
    side = [certfile: leaf.cert, keyfile: leaf.key, cacertfile: ca.cert, verify: :verify_peer]
    path = Path.join(dir, "#{name}.conf")
    terms = [server: side ++ [fail_if_no_peer_cert: true], client: side]
    File.write!(path, :io_lib.format(~c"~p.~n", [Enum.map(terms, fn {k, v} -> {k, Enum.map(v, &charlists/1)} end)]))
    path
  end

  defp charlists({k, v}) when is_binary(v), do: {k, String.to_charlist(v)}
  defp charlists(kv), do: kv

  defp start_peer(name, optfile) do
    {:ok, peer, node} =
      :peer.start(%{
        name: :"#{name}_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args:
          [~c"-proto_dist", ~c"inet_tls", ~c"-ssl_dist_optfile", String.to_charlist(optfile)] ++
            [~c"-setcookie", String.to_charlist(@cookie)]
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _already_down -> :ok
      end
    end)

    {peer, node}
  end

  test "two nodes the shared CA signed connect over TLS distribution", %{tmp_dir: dir} do
    ca = CertFixtures.ca!(dir)
    leaf = CertFixtures.leaf!(ca, dir, "node", "malachi-node", ["IP:127.0.0.1", "DNS:localhost"])
    conf = optfile(dir, "node", ca, leaf)

    {a, _node_a} = start_peer("tls_a", conf)
    {b, node_b} = start_peer("tls_b", conf)

    assert :peer.call(a, :net_kernel, :connect_node, [node_b]) == true
    assert node_b in :peer.call(a, :erlang, :nodes, [])
    assert {:ok, [[~c"inet_tls"]]} = :peer.call(b, :init, :get_argument, [:proto_dist])
  end

  test "a node whose certificate another CA signed cannot connect, though it holds the cookie", %{tmp_dir: dir} do
    ca = CertFixtures.ca!(dir)
    leaf = CertFixtures.leaf!(ca, dir, "node", "malachi-node", ["IP:127.0.0.1", "DNS:localhost"])

    other_dir = Path.join(dir, "other")
    other_ca = CertFixtures.ca!(other_dir)
    other_leaf = CertFixtures.leaf!(other_ca, other_dir, "node", "malachi-node", ["IP:127.0.0.1", "DNS:localhost"])

    {a, node_a} = start_peer("tls_member", optfile(dir, "member", ca, leaf))
    {stranger, node_stranger} = start_peer("tls_stranger", optfile(dir, "stranger", other_ca, other_leaf))

    refute :peer.call(stranger, :net_kernel, :connect_node, [node_a]) == true
    refute :peer.call(a, :net_kernel, :connect_node, [node_stranger]) == true
    refute node_stranger in :peer.call(a, :erlang, :nodes, [])
  end

  test "a node whose certificate does not name the address it is reached at cannot be connected to", %{tmp_dir: dir} do
    ca = CertFixtures.ca!(dir)
    good = CertFixtures.leaf!(ca, dir, "good", "malachi-node", ["IP:127.0.0.1"])
    unnamed = CertFixtures.leaf!(ca, dir, "unnamed", "malachi-node", ["DNS:somewhere-else.test"])

    {a, _node_a} = start_peer("tls_dialler", optfile(dir, "good", ca, good))
    {_b, node_b} = start_peer("tls_unnamed", optfile(dir, "unnamed", ca, unnamed))

    refute :peer.call(a, :net_kernel, :connect_node, [node_b]) == true
  end
end
