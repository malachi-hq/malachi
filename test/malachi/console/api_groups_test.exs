defmodule Malachi.Console.ApiGroupsTest do
  # `GET /api/v1/groups` and `GET /api/v1/groups/:group?topic=` against the test node's own broker and
  # node-wide group coordinator: a member joined through the group keys shows up with its ranges.
  # `Malachi.Console.GroupsViewTest` covers the shapes.
  #
  # async: false. The coordinator, the broker and the sampler are the node's.
  use ExUnit.Case, async: false

  alias Malachi.BrokerServer
  alias Malachi.Console.Sampler
  alias Malachi.Consumer.GroupCoordinator
  alias Malachi.Test.AccessHelper

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    Sampler.clear()
    on_exit(fn -> Sampler.clear() end)

    topic = "api_groups_#{System.unique_integer([:positive])}"
    {:ok, _root} = BrokerServer.create_topic(Malachi.LogBroker, topic, 4)
    {:ok, %{ranges: [_ | _]}} = GroupCoordinator.join_group(Malachi.LogGroupCoordinator, "api-group", topic, "member-1")
    on_exit(fn -> GroupCoordinator.leave(Malachi.LogGroupCoordinator, "api-group", topic, "member-1") end)

    %{topic: topic, token: AccessHelper.account!("groups_viewer", [], :viewer)}
  end

  defp get(path, token), do: AccessHelper.call(:console, "GET", path, token, [])

  test "a group with a member is listed with its coordinator and generation", %{topic: topic, token: token} do
    assert %{status: 200, json: body} = get("/api/v1/groups?topic=#{topic}", token)

    assert [%{"group" => "api-group", "topic" => ^topic, "members" => 1, "generation" => generation} = row] =
             body["groups"]

    assert is_integer(generation)
    assert row["coordinator"] == Atom.to_string(node())
    assert %{"unanswered_coordinators" => 0, "unanswered_nodes" => [], "complete" => true} = body

    # a second group pages after the first by token
    {:ok, _} = GroupCoordinator.join_group(Malachi.LogGroupCoordinator, "api-group-2", topic, "member-2")
    on_exit(fn -> GroupCoordinator.leave(Malachi.LogGroupCoordinator, "api-group-2", topic, "member-2") end)
    Sampler.clear()
    assert %{status: 200, json: first} = get("/api/v1/groups?topic=#{topic}&page_size=1", token)
    assert [%{"group" => "api-group"}] = first["groups"]

    assert %{status: 200, json: second} =
             get("/api/v1/groups?topic=#{topic}&page_size=1&page_token=" <> first["next_page_token"], token)

    assert [%{"group" => "api-group-2"}] = second["groups"]
    assert second["next_page_token"] == ""

    # without the filter it is one of every group on the node
    assert %{status: 200, json: %{"groups" => all}} = get("/api/v1/groups?page_size=1000", token)
    assert Enum.any?(all, &(&1["topic"] == topic))
  end

  test "a group's detail names its member's ranges, and positions it has not committed are absent",
       %{topic: topic, token: token} do
    assert %{status: 200, json: detail} = get("/api/v1/groups/api-group?topic=#{topic}", token)
    assert [%{"member" => "member-1", "ranges" => ranges, "idle_ms" => idle}] = detail["members"]
    assert ranges != [] and Enum.all?(ranges, &is_integer/1)
    assert is_integer(idle) and idle >= 0
    assert detail["positions"] == []
    assert {:ok, _at, 0} = DateTime.from_iso8601(detail["sampled_at"])
  end

  test "an unknown group, a missing topic and a malformed name are refused", %{topic: topic, token: token} do
    assert %{status: 404, json: %{"type" => "errors.groups.not_found", "group" => "nope", "topic" => ^topic}} =
             get("/api/v1/groups/nope?topic=#{topic}", token)

    for path <- ["/api/v1/groups/api-group", "/api/v1/groups/api-group?topic=", "/api/v1/groups/bad%zz?topic=t"] do
      assert %{status: 400, json: %{"type" => "errors.http.invalid_request"}} = get(path, token), path
    end

    assert %{status: 400} = get("/api/v1/groups?topic[]=x", token)
    b64 = &Base.url_encode64(&1, padding: false)
    assert %{status: 400} = get("/api/v1/groups?page_token=" <> b64.("v1.groups.0." <> b64.("only-one")), token)
  end

  describe "when a node does not answer" do
    setup do
      real = node()

      Application.put_env(:malachi, :console_fanout,
        nodes: [real, :ghost@h],
        rpc: fn
          ^real, module, function, args, timeout -> :erpc.call(real, module, function, args, timeout)
          _ghost, _module, _function, _args, _timeout -> exit({:erpc, :noconnection})
        end
      )

      on_exit(fn -> Application.delete_env(:malachi, :console_fanout) end)
    end

    test "the listing is a lower bound and the walk incomplete", %{topic: topic, token: token} do
      assert %{status: 200, json: body} = get("/api/v1/groups?topic=#{topic}", token)
      assert [%{"group" => "api-group"}] = body["groups"]
      assert %{"total" => %{"relation" => "gte"}, "complete" => false, "unanswered_nodes" => ["ghost@h"]} = body
    end

    test "a group not found is unavailable rather than missing, and one found is still served",
         %{topic: topic, token: token} do
      assert %{status: 503, json: %{"type" => "errors.http.unavailable", "unanswered_nodes" => ["ghost@h"]}} =
               get("/api/v1/groups/nope?topic=#{topic}", token)

      assert %{status: 200, json: %{"group" => "api-group", "unanswered_nodes" => ["ghost@h"]}} =
               get("/api/v1/groups/api-group?topic=#{topic}", token)
    end
  end

  describe "when every node answers but a coordinator does not" do
    setup do
      Sampler.clear()
      :ok = :sys.suspend(Malachi.LogGroupCoordinator)
      on_exit(fn -> :sys.resume(Malachi.LogGroupCoordinator) end)
      :ok
    end

    test "the listing is a lower bound and a missing group is unavailable, not missing",
         %{topic: topic, token: token} do
      assert %{status: 200, json: body} = get("/api/v1/groups?topic=#{topic}", token)

      assert %{"total" => %{"relation" => "gte"}, "complete" => false, "unanswered_coordinators" => 1} = body
      assert body["unanswered_nodes"] == []

      assert %{status: 503, json: %{"type" => "errors.http.unavailable", "unanswered_coordinators" => 1}} =
               get("/api/v1/groups/nope?topic=#{topic}", token)
    end
  end

  describe "when the membership cannot be read" do
    setup do
      Application.put_env(:malachi, :console_sample_ms, 60_000)
      on_exit(fn -> Application.delete_env(:malachi, :console_sample_ms) end)
      Sampler.clear()
      # a first read that failed: no sample, and none is tried again within the interval
      {:error, :unavailable} = Sampler.fetch(:membership, fn -> {:error, :down} end, interval_ms: 0)
      :ok
    end

    test "the listing is a lower bound and a missing group is unavailable, not missing",
         %{topic: topic, token: token} do
      assert %{status: 200, json: body} = get("/api/v1/groups?topic=#{topic}", token)

      assert %{"total" => %{"relation" => "gte"}, "complete" => false, "membership" => %{"state" => "unavailable"}} =
               body

      assert %{status: 503, json: %{"type" => "errors.http.unavailable", "membership" => %{"state" => "unavailable"}}} =
               get("/api/v1/groups/nope?topic=#{topic}", token)
    end
  end

  test "the group routes take a viewer", %{topic: topic} do
    wire_only = AccessHelper.account!("groups_wire_only", [:consume], nil)

    for path <- ["/api/v1/groups", "/api/v1/groups/api-group?topic=#{topic}"] do
      assert %{status: 401} = get(path, nil)
      assert %{status: 403} = get(path, wire_only)
    end
  end
end
