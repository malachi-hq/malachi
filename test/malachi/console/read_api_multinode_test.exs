defmodule Malachi.Console.ReadApiMultinodeTest do
  # The read API gathers what each node holds for itself through `Malachi.Console.Fanout`, by `:erpc`, so
  # what a single node test cannot show is shown here with real peers: one that answers, one whose read
  # fails there, one that went away, and one whose release lacks the read (a rolling upgrade).
  use ExUnit.Case, async: false

  @moduletag :multinode

  alias Malachi.Console.Fanout
  alias Malachi.Test.AccessHelper
  alias Malachi.Test.Distribution

  setup do
    Distribution.ensure_started()
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    on_exit(fn -> Application.delete_env(:malachi, :console_fanout) end)
    :ok
  end

  # A peer running this node's code with a producer directory of its own, which holds no stream, and the
  # console's read side every node runs (`Malachi.Application.console_read_children/0`).
  defp answering_peer(prefix) do
    {peer, node, _name} = Distribution.start_peer(prefix)
    {:ok, _elixir} = :erpc.call(node, :application, :ensure_all_started, [:elixir])

    children = [
      Malachi.ProducerDirectory.child_spec([]),
      Supervisor.child_spec({Task.Supervisor, name: Malachi.Console.SamplerTasks}, []),
      Supervisor.child_spec(Malachi.Console.Sampler, [])
    ]

    for child <- children, do: {:ok, _pid} = :erpc.call(node, :supervisor, :start_child, [:kernel_sup, child])
    {peer, node}
  end

  test "every node is asked, and one that answers counts, while the others are named as they failed" do
    {_peer, answering} = answering_peer("console_ok")
    # no producer directory runs there, so the read raises on that node
    {_peer, failing, _name} = Distribution.start_peer("console_failing")
    {gone_peer, gone, _name} = Distribution.start_peer("console_gone")
    Distribution.stop_peer(gone_peer)
    {_peer, older} = answering_peer("console_older")
    # a release from before the read: the module is there, the function is not. Loaded before the peer
    # ever loads the real one from the shared code path, so nothing has to be purged.

    {:module, _} =
      :erpc.call(older, :code, :load_binary, [Malachi.Console.Reads, ~c"reads.beam", reads_without_producers()])

    nodes = [node(), answering, failing, gone, older]
    result = Fanout.call(:producers, [100], nodes: nodes, timeout_ms: 2_000)

    assert Enum.map(result.answers, &elem(&1, 0)) == Enum.sort([node(), answering])
    assert result.unanswered == Enum.sort([failing, gone])
    assert result.unsupported == [older]

    Application.put_env(:malachi, :console_fanout, nodes: nodes, timeout_ms: 2_000)
    token = AccessHelper.account!("multinode_viewer", [], :viewer)
    response = AccessHelper.call(:console, "GET", "/api/v1/producers", token, [])

    assert %{
             status: 200,
             json: %{
               "total" => %{"relation" => "gte"},
               "complete" => false,
               "unanswered_nodes" => unanswered,
               "unsupported_nodes" => [unsupported]
             }
           } = response

    assert Enum.sort(unanswered) == Enum.sort([Atom.to_string(failing), Atom.to_string(gone)])
    assert unsupported == Atom.to_string(older)

    # the cluster view asks the same nodes what each says about itself: the node with no producer directory
    # can answer that one, the node that went away cannot
    cluster = AccessHelper.call(:console, "GET", "/api/v1/cluster", token, [])
    assert %{status: 200, json: %{"unsupported_nodes" => [^unsupported]}} = cluster
    assert cluster.json["unanswered_nodes"] == [Atom.to_string(gone)]
  end

  test "a peer answers the node facts read over :erpc with plain data" do
    {_peer, answering} = answering_peer("console_facts")

    assert %{answers: [{^answering, facts}], unanswered: [], unsupported: []} =
             Fanout.call(:node_info, [], nodes: [answering], timeout_ms: 2_000)

    assert %{uptime_seconds: uptime, format: %{state: _}, machine_versions: versions} = facts
    assert is_integer(uptime) and is_list(versions)

    # a peer that runs no broker and no scrubber holds no copies and says nothing about damage
    assert %{answers: [{^answering, %{failed: [], damaged: :not_scrubbed}}]} =
             Fanout.call(:copy_health, [], nodes: [answering], timeout_ms: 2_000)

    # and no group coordinator, so no groups
    assert %{answers: [{^answering, %{groups: [], unanswered: 0}}]} =
             Fanout.call(:groups, [], nodes: [answering], timeout_ms: 2_000)
  end

  # The object code of a `Malachi.Console.Reads` that has no `producers/1`, compiled without loading it here.
  defp reads_without_producers do
    forms = [
      {:attribute, 1, :module, Malachi.Console.Reads},
      {:attribute, 1, :export, [other: 0]},
      {:function, 1, :other, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
    ]

    {:ok, Malachi.Console.Reads, binary} = :compile.forms(forms)
    binary
  end
end
