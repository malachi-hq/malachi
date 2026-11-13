defmodule Malachi.Console.ApiClusterTest do
  # `GET /api/v1/cluster` and `GET /api/v1/ring/vnodes` on the test node, which runs no membership.
  # `Malachi.Console.ClusterViewTest` covers every shape a cluster can be in, and the multinode suite the
  # fan-out over real peers.
  #
  # async: false. The fan-out options and the sampler are the node's.
  use ExUnit.Case, async: false

  alias Malachi.Cluster.Ring
  alias Malachi.Console.Sampler
  alias Malachi.Console.Samples
  alias Malachi.Test.AccessHelper

  setup do
    Malachi.RateLimiter.reset_bucket("127.0.0.1", :dashboard_auth)
    Sampler.clear()
    %{token: AccessHelper.account!("cluster_viewer", [], :viewer)}
  end

  defp get(path, token), do: AccessHelper.call(:console, "GET", path, token, [])

  test "a viewer sees this node with what it says about itself", %{token: token} do
    assert %{status: 200, json: body} = get("/api/v1/cluster", token)
    assert body["node"] == Atom.to_string(node())

    if sharded?() do
      assert body["control_plane"] == "sharded"
      assert %{"state" => _, "fence" => _, "vnodes" => _} = body["ring"]
    else
      assert body["control_plane"] == "unsharded"
      assert body["ring"] == nil and body["lease"] == nil
    end

    assert body["unanswered_nodes"] == [] and body["unsupported_nodes"] == []

    assert [%{"name" => name, "status" => "alive", "answered" => true} = self] = body["nodes"]
    assert name == Atom.to_string(node())
    assert is_integer(self["uptime_seconds"])
    assert self["version"] == :malachi |> Application.spec(:vsn) |> List.to_string()
    assert %{"state" => _state} = self["format"]
    assert is_list(self["machine_versions"])

    for version <- self["machine_versions"] do
      assert %{"machine" => _, "member" => _, "effective" => _, "supported" => _, "stuck" => false} = version
    end
  end

  test "a node that does not answer is named, and listed without its facts", %{token: token} do
    Application.put_env(:malachi, :console_fanout,
      nodes: [node()],
      rpc: fn _node, _module, _function, _args, _timeout -> exit(:noconnection) end
    )

    on_exit(fn -> Application.delete_env(:malachi, :console_fanout) end)

    assert %{status: 200, json: body} = get("/api/v1/cluster", token)
    assert body["unanswered_nodes"] == [Atom.to_string(node())]
    assert [%{"answered" => false, "unanswered" => true, "uptime_seconds" => nil}] = body["nodes"]
  end

  # sharded when this node's ring has a topology (every clustered node runs the ring store)
  defp sharded? do
    case Samples.replicated(Malachi.LogRing) do
      {:ok, %{value: %Ring{topology: topology}}} -> topology != nil
      _none -> false
    end
  end

  test "the vnodes are paged in token order, or there are none to page without a ring", %{token: token} do
    walk = fn walk, query, acc ->
      assert %{status: 200, json: body} = get("/api/v1/ring/vnodes?" <> query, token)
      acc = acc ++ body["vnodes"]

      case body["next_page_token"] do
        "" -> {acc, body}
        next -> walk.(walk, "page_size=1&page_token=" <> next, acc)
      end
    end

    {vnodes, last} = walk.(walk, "page_size=1", [])
    assert last["complete"] == true
    assert Enum.map(vnodes, & &1["token"]) == vnodes |> Enum.map(& &1["token"]) |> Enum.sort()
    assert last["total"] == %{"count" => length(vnodes), "relation" => "eq"}

    if sharded?() do
      # a ring member with no topology recorded yet has no vnodes either
      assert last["control_plane"] == "sharded"
      assert Enum.all?(vnodes, &match?(%{"vnode" => _, "nodes" => [_ | _]}, &1))
    else
      assert %{"control_plane" => "unsharded", "ring" => nil} = last
      assert vnodes == []
    end

    # a token of this listing past the last token resumes after it, and finds nothing
    past = "v1.vnodes.0." <> Base.url_encode64("#{Integer.pow(2, 40)}", padding: false)
    assert %{status: 200, json: %{"vnodes" => []}} = get("/api/v1/ring/vnodes?page_token=" <> b64(past), token)

    for invalid <- ["v1.vnodes.0.x", "v1.vnodes.0." <> b64("x"), "v1.vnodes.0." <> b64("1") <> "." <> b64("2")] do
      assert %{status: 400, json: %{"type" => "errors.http.invalid_request"}} =
               get("/api/v1/ring/vnodes?page_token=" <> b64(invalid), token),
             invalid
    end
  end

  defp b64(text), do: Base.url_encode64(text, padding: false)

  test "both take a viewer", %{token: _token} do
    wire_only = AccessHelper.account!("cluster_wire_only", [:produce], nil)

    for path <- ["/api/v1/cluster", "/api/v1/ring/vnodes"] do
      assert %{status: 401} = get(path, nil)
      assert %{status: 403} = get(path, wire_only)
    end
  end
end
