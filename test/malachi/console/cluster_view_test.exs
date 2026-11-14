defmodule Malachi.Console.ClusterViewTest do
  use ExUnit.Case, async: true

  alias Malachi.Cluster.HashRing
  alias Malachi.Cluster.Lease
  alias Malachi.Cluster.Membership
  alias Malachi.Cluster.Ring
  alias Malachi.Cluster.RingTopology
  alias Malachi.Console.ClusterView

  @at 1_791_720_000_000
  @iso "2026-10-11T12:00:00.000Z"

  defp sample(value, stale \\ false), do: {:ok, %{value: value, sampled_at: @at, stale: stale}}

  defp facts(uptime) do
    %{
      uptime_seconds: uptime,
      version: "0.23.5",
      format: %{state: "present", format: 2, written_by: "0.23.0", requires: "0.13.0"},
      machine_versions: [%{machine: "ring", member: "ring", effective: 2, supported: 2, stuck: false}]
    }
  end

  defp view do
    %Membership{
      self: {Malachi.LogMembership, :a@h},
      members: %{
        {Malachi.LogMembership, :b@h} => %{
          status: :suspect,
          incarnation: 4,
          attributes: %{"rack" => "r2", capabilities: [:sealed_copies], advertised: %{host: "10.0.0.2", port: 4040}}
        },
        {Malachi.LogMembership, :a@h} => %{status: :alive, incarnation: 1, attributes: %{"rack" => "r1"}},
        {Malachi.LogMembership, :c@h} => %{status: :dead, incarnation: 2, attributes: %{}}
      }
    }
  end

  defp ring do
    {:ok, hash_ring} = HashRing.new(ring_bits: 10) |> HashRing.add_vnode(:vnode_1, 100)
    {:ok, hash_ring} = HashRing.add_vnode(hash_ring, :vnode_2, 600)
    topology = RingTopology.new(hash_ring, %{vnode_1: [:a@h, :b@h], vnode_2: [:b@h]})
    %Ring{topology: %{topology | version: 3, pending: %{new_vnode: :vnode_3, token: 900, nodes: [:a@h]}}, fence: 7}
  end

  test "every member the view knows is listed with its status, and the facts of those that answered" do
    body =
      ClusterView.render(%{
        membership: sample(view()),
        fanout: %{answers: [{:a@h, facts(10)}], unanswered: [:b@h], unsupported: []},
        ring: :none,
        lease: :none
      })

    assert [a, b, c] = body["nodes"]
    assert %{"name" => "a@h", "status" => "alive", "incarnation" => 1, "answered" => true, "uptime_seconds" => 10} = a

    assert a["format"] == %{"state" => "present", "format" => 2, "written_by" => "0.23.0", "requires" => "0.13.0"}

    assert a["machine_versions"] == [
             %{"machine" => "ring", "member" => "ring", "effective" => 2, "supported" => 2, "stuck" => false}
           ]

    assert %{
             "name" => "b@h",
             "status" => "suspect",
             "attributes" => %{"rack" => "r2"},
             "capabilities" => ["sealed_copies"],
             "advertised" => "10.0.0.2:4040",
             "answered" => false,
             "unanswered" => true,
             "uptime_seconds" => nil,
             "machine_versions" => nil
           } = b

    # a dead member is listed, never asked, and so neither answered nor unanswered
    assert %{"status" => "dead", "answered" => false, "unanswered" => false} = c
    assert body["unanswered_nodes"] == ["b@h"]
    assert body["membership"] == %{"state" => "fresh", "sampled_at" => @iso}
    assert body["control_plane"] == "unsharded"
    assert body["ring"] == nil and body["lease"] == nil
  end

  test "a node with no membership lists itself, alive" do
    body =
      ClusterView.render(%{
        membership: :none,
        fanout: %{answers: [], unanswered: [], unsupported: []},
        ring: :none,
        lease: :none
      })

    assert [%{"name" => name, "status" => "alive", "incarnation" => nil}] = body["nodes"]
    assert name == Atom.to_string(node())
    assert body["membership"] == %{"state" => "none"}

    assert ClusterView.render(%{
             membership: {:error, :unavailable},
             fanout: %{answers: [], unanswered: [], unsupported: []},
             ring: :none,
             lease: :none
           })["membership"] == %{"state" => "unavailable"}
  end

  test "a membership the fan-out could not read keeps its object shape on the cluster view" do
    body =
      ClusterView.render(%{
        membership: {:error, :unavailable},
        fanout: %{answers: [], unanswered: [], unsupported: [], asked: [node()], membership_unavailable: true},
        ring: :none,
        lease: :none
      })

    assert body["membership"] == %{"state" => "unavailable"}
  end

  test "the ring and the lease of a sharded control plane, fresh, stale or unreadable" do
    lease = %Lease{holder: :a@h, fence: 5, renew_at: @at, duration_ms: 15_000}

    body =
      ClusterView.render(%{
        membership: :none,
        fanout: %{answers: [], unanswered: [], unsupported: [:c@h]},
        ring: sample(ring()),
        lease: sample(lease, true)
      })

    assert body["control_plane"] == "sharded"

    assert body["ring"] == %{
             "version" => 3,
             "fence" => 7,
             "vnodes" => 2,
             "pending" => %{"vnode" => "vnode_3", "token" => 900, "nodes" => ["a@h"]},
             "state" => "fresh",
             "sampled_at" => @iso
           }

    assert body["lease"] == %{
             "holder" => "a@h",
             "fence" => 5,
             "renew_at" => @iso,
             "duration_ms" => 15_000,
             "state" => "stale",
             "sampled_at" => @iso
           }

    assert body["unsupported_nodes"] == ["c@h"]

    unreadable =
      ClusterView.render(%{
        membership: :none,
        fanout: %{answers: [], unanswered: [], unsupported: []},
        ring: {:error, :unavailable},
        lease: sample(%Lease{})
      })

    assert unreadable["ring"] == %{"state" => "unavailable"}
    assert %{"holder" => nil, "renew_at" => nil, "fence" => 0} = unreadable["lease"]
  end

  test "a ring with no topology is an unsharded control plane, as every clustered node runs the ring store" do
    no_topology = sample(%Ring{topology: nil, fence: 0})

    body =
      ClusterView.render(%{
        membership: :none,
        fanout: %{answers: [], unanswered: [], unsupported: []},
        ring: no_topology,
        lease: :none
      })

    assert %{"control_plane" => "unsharded", "ring" => nil} = body
    assert ClusterView.ring_state(no_topology) == %{"control_plane" => "unsharded", "ring" => nil}
    assert ClusterView.vnodes(%Ring{topology: nil, fence: 0}) == []
  end

  test "a ring that could not be read leaves the control plane unknown" do
    assert ClusterView.control_plane({:error, :unavailable}) == "unknown"
    assert ClusterView.control_plane(:none) == "unsharded"
    assert ClusterView.control_plane(sample(ring())) == "sharded"

    body =
      ClusterView.render(%{
        membership: :none,
        fanout: %{answers: [], unanswered: [], unsupported: []},
        ring: {:error, :unavailable},
        lease: :none
      })

    assert %{"control_plane" => "unknown", "ring" => %{"state" => "unavailable"}} = body
  end

  test "vnodes are listed in token order with their nodes by name" do
    assert ClusterView.vnodes(ring()) == [
             %{token: 100, vnode: "vnode_1", nodes: ["a@h", "b@h"]},
             %{token: 600, vnode: "vnode_2", nodes: ["b@h"]}
           ]

    assert ClusterView.render_vnode(%{token: 1, vnode: "v", nodes: []}) == %{
             "token" => 1,
             "vnode" => "v",
             "nodes" => []
           }
  end

  test "a gathered ring lists its vnodes, and none when it is absent or unreadable" do
    assert ClusterView.vnodes_of(sample(ring())) == ClusterView.vnodes(ring())
    assert ClusterView.vnodes_of(:none) == []
    assert ClusterView.vnodes_of({:error, :unavailable}) == []
  end

  test "a ring with no split pending, integer vnode ids, and attribute values that are not text" do
    {:ok, hash_ring} = HashRing.new(ring_bits: 10) |> HashRing.add_vnode(7, 100)
    topology = RingTopology.new(hash_ring, %{7 => [:a@h]})

    view = %Membership{
      self: {Malachi.LogMembership, :a@h},
      members: %{
        {Malachi.LogMembership, :a@h} => %{
          status: :alive,
          incarnation: 1,
          attributes: %{"zone" => {:az, 1}, "tier" => 3}
        }
      }
    }

    body =
      ClusterView.render(%{
        membership: sample(view),
        fanout: %{answers: [], unanswered: [], unsupported: []},
        ring: sample(%Ring{topology: topology, fence: 1}),
        lease: :none
      })

    assert %{"pending" => nil, "vnodes" => 1} = body["ring"]
    assert [%{"attributes" => %{"zone" => "{:az, 1}", "tier" => "3"}}] = body["nodes"]
    assert ClusterView.vnodes(%Ring{topology: topology, fence: 1}) == [%{token: 100, vnode: "7", nodes: ["a@h"]}]
  end

  test "the vnode listing says why it has no ring" do
    assert ClusterView.ring_state(:none) == %{"control_plane" => "unsharded", "ring" => nil}

    assert ClusterView.ring_state({:error, :unavailable}) == %{
             "control_plane" => "unknown",
             "ring" => %{"state" => "unavailable"}
           }

    assert ClusterView.ring_state(sample(ring(), true))["ring"] == %{"state" => "stale", "sampled_at" => @iso}
  end
end
