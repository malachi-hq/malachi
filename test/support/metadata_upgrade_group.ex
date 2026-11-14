defmodule Malachi.Test.MetadataUpgradeGroup do
  @moduledoc """
  A metadata `ra` group over peer nodes, each optionally pinned to an older machine version, for the
  rolling-upgrade tests of a metadata command (`Malachi.Cluster.MachineVersion`): start it, send it
  commands, restart a member on another pin, and compare what every member applied.

  The caller must be an `ExUnit` test (it registers `on_exit/1`) with distribution on
  (`Malachi.Test.RaPeers.ensure_distribution/0`).
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Malachi.Cluster.MetadataMachine
  alias Malachi.Cluster.RaCluster
  alias Malachi.Metadata
  alias Malachi.Test.RaPeers

  @type t :: %{cluster: atom(), handles: pid()}

  @doc "Starts a group with one peer per entry of `pins` (`nil` runs this build's version)."
  @spec start([non_neg_integer() | nil], String.t()) :: t()
  def start(pins, prefix) do
    cluster = :"#{prefix}_#{System.unique_integer([:positive])}"
    peers = Enum.map(pins, &RaPeers.start/1)
    {:ok, handles} = Agent.start(fn -> peers |> Enum.with_index() |> Map.new(fn {peer, index} -> {index, peer} end) end)

    on_exit(fn ->
      handles |> Agent.get(&Map.values/1) |> Enum.each(&RaPeers.stop/1)
      Agent.stop(handles)
    end)

    {:ok, _member} = RaCluster.start(MetadataMachine, cluster, Enum.map(peers, & &1.node))
    %{cluster: cluster, handles: handles}
  end

  @doc "The group's peers, in the order they were started."
  @spec peers(t()) :: [map()]
  def peers(%{handles: handles}), do: handles |> Agent.get(& &1) |> Enum.sort() |> Enum.map(&elem(&1, 1))

  @doc "Restarts the member at `index` pinned to `pin` (`nil` for this build's version)."
  @spec restart(t(), non_neg_integer(), non_neg_integer() | nil) :: map()
  def restart(group, index, pin) do
    peer = Enum.at(peers(group), index)
    restarted = RaPeers.restart(peer, pin, [group.cluster])
    Agent.update(group.handles, &Map.put(&1, index, restarted))
    restarted
  end

  @doc "Every member stops before any comes back, so the whole log replays."
  @spec restart_all(t()) :: :ok
  def restart_all(group) do
    Enum.each(peers(group), &RaPeers.stop/1)
    for index <- 0..(length(peers(group)) - 1), do: restart(group, index, nil)
    :ok
  end

  @doc "Sends `command` through whichever member answers: `{:ok, reply}`."
  @spec command(t(), term()) :: {:ok, term()}
  def command(group, command) do
    nodes = Enum.map(peers(group), & &1.node)

    RaPeers.eventually(fn ->
      Enum.find_value(nodes, fn node ->
        case RaCluster.command({group.cluster, node}, command) do
          {:ok, reply} -> {:ok, reply}
          {:error, _unreachable} -> nil
        end
      end)
    end)
  end

  @doc "Commits a marker topic and waits until every member has applied it, so their states compare."
  @spec barrier(t()) :: String.t()
  def barrier(group) do
    marker = "barrier-#{System.unique_integer([:positive])}"
    assert {:ok, {:ok, _root}} = command(group, {:create_topic, marker, 1})

    assert RaPeers.eventually(fn ->
             Enum.all?(peers(group), &Metadata.get_topic(RaPeers.local_state(&1.node, group.cluster), marker))
           end)

    marker
  end

  @doc "Each member's applied state."
  @spec states(t()) :: [Metadata.t()]
  def states(group), do: Enum.map(peers(group), &RaPeers.local_state(&1.node, group.cluster))

  @doc "Asserts every member applied the same state."
  @spec assert_identical(t()) :: :ok
  def assert_identical(group) do
    [first | rest] = states(group)
    for state <- rest, do: assert(state == first)
    :ok
  end

  @doc "Waits until every member's effective machine version is `expected`."
  @spec await_effective(t(), non_neg_integer()) :: true
  def await_effective(group, expected) do
    assert RaPeers.eventually(fn ->
             Enum.all?(peers(group), &(RaPeers.effective(&1.node, group.cluster) == expected))
           end),
           "effective versions: #{inspect(Enum.map(peers(group), &RaPeers.effective(&1.node, group.cluster)))}"
  end
end
