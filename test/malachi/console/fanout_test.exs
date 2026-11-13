defmodule Malachi.Console.FanoutTest do
  use ExUnit.Case, async: true

  alias Malachi.Console.Fanout

  # A stand-in for `:erpc.call/5` that answers per node: a value, a delay past the bound, a raise, an
  # `erpc` error as a remote `:undef` arrives, or an exit as a node that went away.
  defp rpc(behaviours) do
    fn node, Malachi.Console.Reads, function, args, _timeout ->
      case Map.fetch!(behaviours, node) do
        {:value, value} -> {node, function, args, value}
        :slow -> Process.sleep(:infinity)
        :raise -> raise ArgumentError, "read failed"
        :remote_undef -> :erlang.error({:exception, :undef, [{Malachi.Console.Reads, function, args, []}]})
        :other_undef -> :erlang.error({:exception, :undef, [{SomeOther, :thing, [], []}]})
        :local_undef -> apply(Malachi.Console.Reads, :not_a_read, args)
        :local_other_undef -> apply(String.to_atom("Elixir.NoSuchModule"), :thing, args)
        :down -> exit({:erpc, :noconnection})
      end
    end
  end

  test "every node answers, in node name order" do
    behaviours = %{b@h: {:value, 2}, a@h: {:value, 1}}

    assert Fanout.call(:thing, [:x], nodes: [:b@h, :a@h], rpc: rpc(behaviours)) == %{
             answers: [{:a@h, {:a@h, :thing, [:x], 1}}, {:b@h, {:b@h, :thing, [:x], 2}}],
             unanswered: [],
             unsupported: [],
             asked: [:a@h, :b@h],
             membership_unavailable: false
           }
  end

  test "a slow node, a node that raised and a node that went away are unanswered, and the rest still answer" do
    behaviours = %{a@h: {:value, 1}, b@h: :slow, c@h: :raise, d@h: :down}
    result = Fanout.call(:thing, [], nodes: Map.keys(behaviours), rpc: rpc(behaviours), timeout_ms: 50)

    assert [{:a@h, _value}] = result.answers
    assert result.unanswered == [:b@h, :c@h, :d@h]
    assert result.unsupported == []
    assert Fanout.partial?(result)
  end

  test "a node whose release lacks the read is unsupported, told apart from one missing something else" do
    behaviours = %{a@h: :remote_undef, b@h: :local_undef, c@h: :other_undef, d@h: :local_other_undef}
    result = Fanout.call(:not_a_read, [], nodes: Map.keys(behaviours), rpc: rpc(behaviours))

    assert result.unsupported == [:a@h, :b@h]
    assert result.unanswered == [:c@h, :d@h]

    assert Fanout.members(result) == %{
             "unanswered_nodes" => ["c@h", "d@h"],
             "unsupported_nodes" => ["a@h", "b@h"]
           }
  end

  test "a node named twice is asked once, and no nodes is an empty result" do
    behaviours = %{a@h: {:value, 1}}
    assert %{answers: [{:a@h, _}]} = Fanout.call(:thing, [], nodes: [:a@h, :a@h], rpc: rpc(behaviours))
    result = Fanout.call(:thing, [], nodes: [], rpc: rpc(%{}))
    assert result == %{answers: [], unanswered: [], unsupported: [], asked: [], membership_unavailable: false}
    refute Fanout.partial?(result)
  end

  test "a result whose membership could not be read is partial and says so, though every node asked answered" do
    result = %{answers: [{:a@h, 1}], unanswered: [], unsupported: [], asked: [:a@h], membership_unavailable: true}
    assert Fanout.partial?(result)
    assert Fanout.members(result)["membership"] == %{"state" => "unavailable"}

    refute Fanout.partial?(%{result | membership_unavailable: false})
    refute Map.has_key?(Fanout.members(%{result | membership_unavailable: false}), "membership")
  end

  test "by default this node is asked through :erpc, and answers" do
    assert node() in Fanout.alive_nodes()
    assert %{answers: [{node, %{streams: _, unanswered: _}}]} = Fanout.call(:producers, [10], nodes: [node()])
    assert node == node()
  end
end
