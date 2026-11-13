defmodule Malachi.Console.ClusterView do
  @moduledoc """
  The Cluster view's data (section 6.8 of `docs/design/operator-interfaces.md`): the nodes with their SWIM
  status and what each says about itself, the ring, and the lease, for `GET /api/v1/cluster` and
  `GET /api/v1/ring/vnodes`.

  Gathering is split from rendering. `gather/1` takes the samples and the fan-out, which cost something;
  the `render_*` functions are pure, so every shape a node can be in is tested without a cluster.

  Where each part comes from:

    * **membership**: this node's SWIM view (`Malachi.Cluster.MembershipServer.view/2`), through
      `Malachi.Console.Sampler`, since the same process runs the gossip loop. It lists every member the
      view knows, alive, suspect or dead. A node that runs no membership (a single node) lists itself.
    * **each node's own facts** (uptime, release, format marker, machine versions): asked of every alive
      node (`Malachi.Console.Reads.node_info/0` through `Malachi.Console.Fanout`). A member that is not
      alive is not asked, and one that did not answer has `null` facts.
    * **ring and lease**: a consistent query to their Raft leader, through the sampler, only on a sharded
      control plane (one whose ring has a topology); elsewhere they are `null`, and `control_plane` says
      why (`control_plane/1`).
  """

  alias Malachi.Cluster.Advertised
  alias Malachi.Cluster.Capabilities
  alias Malachi.Cluster.Lease
  alias Malachi.Cluster.Membership
  alias Malachi.Cluster.Ring
  alias Malachi.Cluster.RingTopology
  alias Malachi.Console.Fanout
  alias Malachi.Console.Sampler
  alias Malachi.Console.Samples

  @typedoc "What the view is built from."
  @type gathered :: %{
          membership: Samples.result(),
          fanout: Fanout.result(),
          ring: Samples.result(),
          lease: Samples.result()
        }

  @doc "Takes what the view needs. `fanout_opts` go to `Malachi.Console.Fanout.call/3`."
  @spec gather(keyword()) :: gathered()
  def gather(fanout_opts \\ []) do
    %{
      membership: Samples.membership(),
      fanout: Fanout.call(:node_info, [], fanout_opts),
      ring: Samples.replicated(Malachi.LogRing),
      lease: Samples.replicated(Malachi.LogLease)
    }
  end

  @doc "The ring alone, for the vnode listing."
  @spec gather_ring() :: Samples.result()
  def gather_ring, do: Samples.replicated(Malachi.LogRing)

  @doc "The body of `GET /api/v1/cluster` from what `gather/1` took."
  @spec render(gathered()) :: map()
  def render(%{membership: membership, fanout: fanout, ring: ring, lease: lease}) do
    facts = Map.new(fanout.answers)
    unanswered = MapSet.new(fanout.unanswered ++ fanout.unsupported)

    %{
      "node" => Atom.to_string(node()),
      "nodes" => membership |> members() |> Enum.map(&render_node(&1, facts, unanswered)),
      "membership" => sample_state(membership),
      "control_plane" => control_plane(ring),
      "ring" => if(control_plane(ring) == "unsharded", do: nil, else: render_sample(ring, &render_ring/1)),
      "lease" => render_sample(lease, &render_lease/1)
    }
    |> Map.merge(Fanout.members(fanout))
  end

  # Every member the view knows, sorted by node name; a node with no membership is alone and alive.
  defp members({:ok, %{value: %Membership{members: members}}}) do
    members
    |> Enum.map(fn {{_name, node}, state} -> {node, state} end)
    |> Enum.sort_by(fn {node, _state} -> node end)
  end

  defp members(_none_or_unavailable), do: [{node(), %{status: :alive, incarnation: nil, attributes: %{}}}]

  defp sample_state(:none), do: %{"state" => "none"}
  defp sample_state({:error, :unavailable}), do: %{"state" => "unavailable"}

  defp sample_state({:ok, %{sampled_at: sampled_at, stale: stale}}),
    do: %{"state" => if(stale, do: "stale", else: "fresh"), "sampled_at" => iso8601(sampled_at)}

  defp render_node({node, %{status: status, incarnation: incarnation, attributes: attributes}}, facts, unanswered) do
    advertised = Advertised.of(attributes)

    %{
      "name" => Atom.to_string(node),
      "status" => Atom.to_string(status),
      "incarnation" => incarnation,
      "attributes" => for({key, value} <- attributes, is_binary(key), into: %{}, do: {key, to_text(value)}),
      "capabilities" => attributes |> Capabilities.of() |> Enum.map(&to_text/1),
      "advertised" => advertised && "#{advertised.host}:#{advertised.port}",
      "answered" => Map.has_key?(facts, node),
      "unanswered" => MapSet.member?(unanswered, node)
    }
    |> Map.merge(render_facts(Map.get(facts, node)))
  end

  defp render_facts(nil),
    do: %{"uptime_seconds" => nil, "version" => nil, "format" => nil, "machine_versions" => nil}

  defp render_facts(%{uptime_seconds: uptime, version: version, format: format, machine_versions: versions}) do
    %{
      "uptime_seconds" => uptime,
      "version" => version,
      "format" => Map.new(format, fn {key, value} -> {Atom.to_string(key), value} end),
      "machine_versions" =>
        Enum.map(versions, fn version ->
          Map.new(version, fn {key, value} -> {Atom.to_string(key), value} end)
        end)
    }
  end

  @doc """
  Whether the control plane is sharded, from this node's ring: `sharded` when the ring has a topology,
  `unsharded` when this node holds no ring or a ring with no topology (every clustered node runs the ring
  store, a sharded one or not), and `unknown` when the ring could not be read.
  """
  @spec control_plane(Samples.result()) :: String.t()
  def control_plane({:ok, %{value: %Ring{topology: %RingTopology{}}}}), do: "sharded"
  def control_plane({:error, :unavailable}), do: "unknown"
  def control_plane(_none_or_no_topology), do: "unsharded"

  defp render_sample(:none, _render), do: nil
  defp render_sample({:error, :unavailable}, _render), do: %{"state" => "unavailable"}

  defp render_sample({:ok, %{value: value, sampled_at: sampled_at, stale: stale}}, render) do
    value
    |> render.()
    |> Map.merge(%{"state" => if(stale, do: "stale", else: "fresh"), "sampled_at" => iso8601(sampled_at)})
  end

  defp render_ring(%Ring{topology: nil, fence: fence}),
    do: %{"version" => nil, "fence" => fence, "vnodes" => 0, "pending" => nil}

  defp render_ring(%Ring{topology: %RingTopology{} = topology, fence: fence}) do
    %{
      "version" => topology.version,
      "fence" => fence,
      "vnodes" => length(RingTopology.vnode_placement(topology)),
      "pending" => render_pending(topology.pending)
    }
  end

  defp render_pending(nil), do: nil

  defp render_pending(%{new_vnode: vnode, token: token, nodes: nodes}),
    do: %{"vnode" => to_text(vnode), "token" => token, "nodes" => Enum.map(nodes, &Atom.to_string/1)}

  defp render_lease(%Lease{holder: holder, fence: fence, renew_at: renew_at, duration_ms: duration_ms}) do
    %{
      "holder" => holder && to_text(holder),
      "fence" => fence,
      "renew_at" => renew_at && iso8601(renew_at),
      "duration_ms" => duration_ms
    }
  end

  @doc """
  The vnodes of a ring as the listing pages them: `{token, vnode, nodes}` in token order, which is the
  ring's own order. Empty without a topology.
  """
  @spec vnodes(Ring.t()) :: [map()]
  def vnodes(%Ring{topology: nil}), do: []

  def vnodes(%Ring{topology: topology}) do
    for {vnode, token, nodes} <- RingTopology.vnode_placement(topology),
        do: %{token: token, vnode: to_text(vnode), nodes: Enum.map(nodes, &Atom.to_string/1)}
  end

  @doc "The vnodes of a gathered ring (`gather_ring/0`): none when there is no ring or it could not be read."
  @spec vnodes_of({:ok, Sampler.sample()} | {:error, :unavailable} | :none) :: [map()]
  def vnodes_of({:ok, %{value: %Ring{} = ring}}), do: vnodes(ring)
  def vnodes_of(_none_or_unavailable), do: []

  @doc "One vnode of `vnodes/1` as JSON."
  @spec render_vnode(map()) :: map()
  def render_vnode(%{token: token, vnode: vnode, nodes: nodes}),
    do: %{"token" => token, "vnode" => vnode, "nodes" => nodes}

  @doc "The ring's state for the vnode listing: `sampled_at` and whether it is stale, or why there is none."
  @spec ring_state({:ok, Sampler.sample()} | {:error, :unavailable} | :none) :: map()
  def ring_state({:error, :unavailable}), do: %{"control_plane" => "unknown", "ring" => %{"state" => "unavailable"}}

  def ring_state({:ok, %{sampled_at: sampled_at, stale: stale}} = ring) do
    if control_plane(ring) == "unsharded", do: ring_state(:none), else: sharded_state(sampled_at, stale)
  end

  def ring_state(_none), do: %{"control_plane" => "unsharded", "ring" => nil}

  defp sharded_state(sampled_at, stale) do
    %{
      "control_plane" => "sharded",
      "ring" => %{"state" => if(stale, do: "stale", else: "fresh"), "sampled_at" => iso8601(sampled_at)}
    }
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_atom(value), do: Atom.to_string(value)
  defp to_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_text(value), do: inspect(value)

  defp iso8601(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
