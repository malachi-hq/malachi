defmodule Malachi.Console.GroupsViewTest do
  use ExUnit.Case, async: true

  alias Malachi.Console.GroupsView
  alias Malachi.Metadata

  defp apply!(state, command) do
    {state, reply} = Metadata.apply(state, command)
    assert reply == :ok or elem(reply, 0) == :ok, "#{inspect(command)}: #{inspect(reply)}"
    state
  end

  # "billing" committed on two ranges of "orders" at epoch 2; "audit" never committed.
  defp metadata do
    {state, {:ok, root}} = Metadata.apply(Metadata.new(), {:create_topic, "orders", 4})

    state
    |> apply!({:split_range, root})
    |> apply!({:open_group, "billing", "orders"})
    |> apply!({:open_group, "billing", "orders"})
    |> apply!({:commit_offset, "billing", "orders", %{{"orders", 1} => {0, 120}, {"orders", 2} => :start}})
  end

  defp coordinator(group, generation, members),
    do: %{group: group, topic: "orders", generation: generation, members: members}

  defp member(name, ranges), do: %{member: name, idle_ms: 5, ranges: ranges}

  defp fanout(answers), do: %{answers: answers, unanswered: [], unsupported: []}

  test "a group either source knows is listed, with what each knows of it" do
    held = [coordinator("audit", 7, [member("m-1", [{"orders", 1}])])]
    gathered = %{fanout: fanout([{:a@h, %{groups: held, unanswered: 0}}]), metadata: metadata()}

    assert [audit, billing] = GroupsView.groups(gathered)

    assert GroupsView.render_summary(audit) == %{
             "group" => "audit",
             "topic" => "orders",
             "coordinator" => "a@h",
             "generation" => 7,
             "members" => 1,
             "committed_ranges" => 0,
             "epoch" => 0
           }

    assert GroupsView.render_summary(billing) == %{
             "group" => "billing",
             "topic" => "orders",
             "coordinator" => nil,
             "generation" => nil,
             "members" => 0,
             "committed_ranges" => 2,
             "epoch" => 2
           }
  end

  test "a group's detail lists its members' ranges and each range's position, never a lag" do
    held = [coordinator("billing", 9, [member("m-2", [{"orders", 2}]), member(:m1, [{"orders", 1}])])]
    gathered = %{fanout: fanout([{:a@h, %{groups: held, unanswered: 0}}]), metadata: metadata()}
    [billing] = GroupsView.groups(gathered)
    detail = GroupsView.render_detail(billing)

    assert detail["members"] == [
             %{"member" => "m-2", "idle_ms" => 5, "ranges" => [2]},
             %{"member" => "m1", "idle_ms" => 5, "ranges" => [1]}
           ]

    assert detail["positions"] == [
             %{
               "range" => 1,
               "at" => "position",
               "source_index" => 0,
               "source_offset" => 120,
               "time_lag_ms" => nil,
               "behind" => nil,
               "headroom" => nil
             },
             %{
               "range" => 2,
               "at" => "start",
               "source_index" => nil,
               "source_offset" => nil,
               "time_lag_ms" => nil,
               "behind" => nil,
               "headroom" => nil
             }
           ]

    assert %{"generation" => 9, "epoch" => 2, "committed_ranges" => 2} = detail
  end

  test "a group no coordinator holds has no members in its detail" do
    gathered = %{fanout: fanout([]), metadata: metadata()}
    assert [billing] = GroupsView.groups(gathered)
    assert %{"members" => [], "coordinator" => nil} = GroupsView.render_detail(billing)
  end

  test "of two coordinators holding a group the higher generation is current, and a missing one is the lowest" do
    answers = [
      {:a@h, %{groups: [coordinator("g", nil, [])], unanswered: 0}},
      {:b@h, %{groups: [coordinator("g", 4, [member("m", [{"orders", 0}])])], unanswered: 1}},
      {:c@h, %{groups: [coordinator("g", 3, [])], unanswered: 2}}
    ]

    gathered = %{fanout: fanout(answers), metadata: Metadata.new()}
    assert [%{coordinator: %{node: :b@h, generation: 4}}] = GroupsView.groups(gathered)
    assert GroupsView.unanswered_coordinators(fanout(answers)) == 3
  end

  test "a range or member that is not the usual shape still renders" do
    held = [coordinator("odd", 1, [member({:pid, 1}, [:r0])])]
    gathered = %{fanout: fanout([{:a@h, %{groups: held, unanswered: 0}}]), metadata: Metadata.new()}
    [odd] = GroupsView.groups(gathered)
    assert [%{"member" => "{:pid, 1}", "ranges" => ["r0"]}] = GroupsView.render_detail(odd)["members"]
  end
end
