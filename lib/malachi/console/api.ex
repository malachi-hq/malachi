defmodule Malachi.Console.Api do
  @moduledoc """
  The console's versioned API under `/api/v1`, matched by `Malachi.Console.Router` before the single page
  application fallback, which would otherwise answer any extensionless path with `index.html`.

  Every route is read from `Malachi.Console.Access`'s table, which also says the role it requires, so a route
  cannot be served without being declared there; every error is an
  `application/problem+json` body from `Malachi.HTTP.Problem`: a path no route serves is a 404 and a
  method a route does not take is a 405 with `Allow`, both answered before any credential is read, so
  probing for routes costs no rate limit budget and learns nothing about sessions.

  ## `GET /api/v1/me`

  Who the console is talking to, so the shell renders by role instead of discovering a 403 after a click
  (section 6.1 of `docs/design/operator-interfaces.md`, row 2 of table 10.3). It requires a valid session
  and no role: an account with only wire permissions is answered with `role: null` and no capabilities,
  which is what lets the shell say why it shows nothing.

      {
        "username": "alice",
        "authenticated": true,
        "role": "viewer",
        "capabilities": ["read_cluster"],
        "permissions": ["produce"],
        "locale": "en_US",
        "cluster": {"name": "prod-eu", "color": "#A1B2C3", "icon": "globe"}
      }

  ## `GET /api/v1/producers`

  The producer streams open across the cluster, for the Producers view (section 6.8.1 of
  `docs/design/operator-interfaces.md`, row 14 of table 10.3), at the `viewer` role. Every alive node is
  asked for its own (`Malachi.Console.Fanout`), and each asks the connections that hold streams to describe
  them (`Malachi.ProducerDirectory`). A connection that does not answer within its node's bound is counted in
  `unanswered_connections`; a node that does not answer is named in `unanswered_nodes`, and one whose release
  lacks the read in `unsupported_nodes`. Either makes `total.relation` `"gte"`.

  Paged as `Malachi.Console.Page` describes, oldest stream first, then by node, connection and stream id. A
  token names the position after the last stream it returned, so a stream that opened or ended in between
  shifts nothing already read; it is opaque, not secret, and carries an internal name for the stream's
  connection. `complete` is false once any page of the walk had a node or connection that did not answer: a
  walk whose last page says `complete: false` is restarted from the first page.

      {
        "node": "malachi@10.0.0.1",
        "streams": [
          {
            "stream_id": 1, "node": "malachi@10.0.0.2", "topic": "orders", "range": 3, "segment": 7,
            "primary": "malachi@10.0.0.1", "label": "billing-writer", "client_ip": "10.0.0.9",
            "window": {"appends": 64, "bytes": 16777216},
            "next_sequence": 120, "acked_sequence": 118,
            "in_flight": {"appends": 2, "bytes": 4096},
            "opened_at": "2026-10-11T10:00:00.000Z"
          }
        ],
        "total": {"count": 1, "relation": "eq"},
        "unanswered_connections": 0,
        "unanswered_nodes": [],
        "unsupported_nodes": [],
        "next_page_token": "",
        "complete": true
      }

  `node` at the top is the node that answered the request; a stream's `node` is the one its producer is
  connected to.

  ## `GET /api/v1/cluster`

  The Cluster view (section 6.8 of `docs/design/operator-interfaces.md`, row 5 of table 10.3), at the
  `viewer` role: every member of this node's SWIM view with its status, incarnation, attributes,
  capabilities and advertised address, and, for each alive member that answered, its uptime, release,
  format marker and the effective machine version of every replicated state machine member it hosts. The
  ring (version, fence, vnode count, a pending split) and the lease (holder, fence, renewal) on a sharded
  control plane, each with `sampled_at` and a `state` of `fresh`, `stale` or `unavailable`; `null`, with
  `control_plane: "unsharded"`, elsewhere (a ring store with no topology counts as unsharded), and
  `control_plane: "unknown"` when the ring could not be read. `Malachi.Console.ClusterView` builds it.

  ## `GET /api/v1/ring/vnodes`

  The vnodes of the ring with the nodes that hold each, in token order, paged as `/producers` is. Empty on
  an unsharded control plane.

  ## `GET /api/v1/topics`

  The topics by name with their state, keyspace, policy, ranges and segments (active of total), bytes and
  the consumer groups that committed a position (section 6.3), at the `viewer`
  role, read from this node's sampled metadata (`Malachi.Console.Samples.metadata/0`): `sampled_at` says
  when it was taken and `stale` whether a newer read failed. Metadata that could not be read at all is a
  503, never an empty list.

  ## `GET /api/v1/topics/:topic/ranges`

  The ranges of a topic in sequence order with their keyspace bounds, state and the ranges they were split
  or merged from (`parents`, by sequence).

  ## `GET /api/v1/topics/:topic/segments`

  The segments of a topic in range then segment order, with replicas named by node and each copy's health
  as each node reports it (`Malachi.Console.TopicsView` describes the conditions and how they resolve).
  Paged as above; a page of 100 segments takes about a millisecond to build and is about 50 KB, and the
  largest of 1000 about 9 ms and 500 KB, measured on Linux over 5000 segments of three replicas. An
  unknown topic is the `errors.topics.not_found` problem naming it, and a name with a malformed
  percent-escape a 400.

  ## `GET /api/v1/groups`

  The consumer groups (section 6.5, row 6 of table 10.3), by name then topic, with the node whose
  coordinator holds each, its generation and member count, how many ranges it committed and its fence
  epoch; `?topic=` keeps one topic's. `Malachi.Console.GroupsView` says where each part comes from. A
  coordinator that could not be read is counted in `unanswered_coordinators`.

  ## `GET /api/v1/groups/:group?topic=`

  One group in full: each member with how long it has been silent and its ranges, and each range's
  committed position, decomposed rather than as a number. The time lag, the records and bytes behind and
  the headroom are `null`: nothing records them yet. The topic is required; an unknown group is the
  `errors.groups.not_found` problem when every node and coordinator answered, and a 503
  (`errors.http.unavailable`, naming what did not answer) when one did not, since the group may be held
  there. The listing is then a lower bound (`gte`, `complete: false`).

  ## `GET /api/v1/sessions`

  The active sessions of every alive node (section 6.10, row 10 of table 10.3), at the `admin` role: user,
  address, whether the session is bound to it, when it was created, last used and expires, and the node
  that holds it. A session is named by its digest (`Malachi.Console.Access.session_digest/1`), the same
  value the API rate limit's audit events record, and never by any part of its token. Paged oldest first.

  ## `GET /api/v1/lockouts`

  The accounts locked out across the cluster, at the `admin` role: user, address, failed attempts, when the
  lock ends and how long remains, from this node's replica of the lockout store, sampled. A store that
  could not be read is a 503, never an empty list.

  ## `GET /api/v1/metrics/history`

  The per second history every node keeps for the last 300 seconds (row 11 of table 10.3), at the `viewer`
  role, as columns per node so a sparkline needs no transposing: `timestamps` (Unix seconds, oldest first)
  and one list per series aligned with them. `?window=` is the seconds wanted (1 to 300, 60 by default)
  and `?series=` a comma separated choice among `Malachi.Console.Reads.history_series/0` (all of them by
  default); an unknown series or a window out of range is a 400. Counters are cumulative since the node
  started, so a rate is the difference between two points.

  ## `GET /api/v1/stream`

  One Server-Sent Events stream per client with the overview's deltas (section 10.5), at the `viewer` role:
  `Malachi.Console.Stream` describes the wire, and `Malachi.Console.StreamHub` the events, their ids and
  how `Last-Event-ID` resumes a stream or reports a gap.

  `label` is what the client named itself when it opened the stream, printable ASCII only and at most 128
  bytes.

  `authenticated` is false, `username` null and `role` `"admin"` while authentication is disabled
  (`Malachi.Console.Access.anonymous/0`). `locale` is the node's (`Malachi.I18n.locale/0`); `cluster` comes
  from `MALACHI_CLUSTER_DISPLAY_NAME`, `MALACHI_CLUSTER_COLOR` and `MALACHI_CLUSTER_ICON`
  (`Malachi.Config.cluster_identity/3`), each `null` when unset.
  """

  import Plug.Conn

  alias Malachi.Console.Access
  alias Malachi.Console.AccessView
  alias Malachi.Console.ClusterView
  alias Malachi.Console.Fanout
  alias Malachi.Console.GroupsView
  alias Malachi.Console.Page
  alias Malachi.Console.Reads
  alias Malachi.Console.Samples
  alias Malachi.Console.TopicsView
  alias Malachi.HTTP.Problem
  alias Malachi.IPAddress

  # How long each node waits for its connections to describe their streams; the fan-out's own bound is
  # looser, so a node whose connections are slow still answers, with them counted.
  @producer_answer_ms 500

  @doc "Whether `conn` is addressed to this API, so the router hands it here."
  @spec api_request?(Plug.Conn.t()) :: boolean()
  def api_request?(%Plug.Conn{path_info: ["api", "v1" | _rest]}), do: true
  def api_request?(_conn), do: false

  @doc "Answers an `/api/v1` request."
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: ["api", "v1" | path]} = conn) do
    case Enum.filter(routes(), fn {_method, pattern} -> matches?(pattern, path) end) do
      [] ->
        problem(conn, :not_found)

      matching ->
        methods = matching |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        if conn.method in methods,
          do: authorized(conn, path),
          else: conn |> put_resp_header("allow", Enum.join(methods, ", ")) |> problem(:method_not_allowed)
    end
  end

  @doc """
  Every route this module serves, as `{method, pattern}` with the pattern below `/api/v1`. It is read from
  `Malachi.Console.Access.routes/0`, the one table that also says which role each route requires, so a
  route cannot be served without a row there.
  """
  @spec routes() :: [{String.t(), Access.pattern()}]
  def routes do
    for {method, ["api", "v1" | pattern], _level} <- Access.routes(), do: {method, pattern}
  end

  defp matches?(pattern, path) when length(pattern) != length(path), do: false

  defp matches?(pattern, path) do
    pattern
    |> Enum.zip(path)
    |> Enum.all?(fn
      {:param, segment} -> segment != ""
      {literal, segment} -> literal == segment
    end)
  end

  defp authorized(conn, path) do
    token = Access.token(header(conn, "authorization"), header(conn, "cookie"))

    request = %{
      ip: IPAddress.format(conn.remote_ip),
      user_agent: header(conn, "user-agent") || "",
      method: conn.method,
      path: conn.request_path
    }

    case Access.admit(token, Access.required_role(conn.method, conn.request_path), request) do
      {:ok, subject} ->
        serve(fetch_query_params(conn), path, subject)

      {:error, :api_rate_limit_exceeded, retry_after_ms, _digest, _username} ->
        problem(conn, {:rate_limited, retry_after_ms})

      {:error, :rate_limit_exceeded, retry_after_ms} ->
        problem(conn, {:rate_limited, retry_after_ms})

      {:error, reason} ->
        problem(conn, reason)
    end
  end

  defp serve(conn, ["me"], subject) do
    json(conn, 200, %{
      "username" => subject.username,
      "authenticated" => subject.authenticated,
      "role" => role_string(subject.role),
      "capabilities" => Enum.map(Access.capabilities(subject.role), &Atom.to_string/1),
      "permissions" => Enum.map(subject.permissions, &Atom.to_string/1),
      "locale" => Malachi.I18n.locale(),
      "cluster" => cluster_identity()
    })
  end

  defp serve(conn, ["producers"], _subject) do
    case Page.request(conn.query_params, producers_listing()) do
      {:ok, request} ->
        fanout = Fanout.call(:producers, [@producer_answer_ms], fanout_opts())
        streams = for {_node, %{streams: streams}} <- fanout.answers, stream <- streams, do: stream
        unanswered = fanout.answers |> Enum.map(fn {_node, %{unanswered: n}} -> n end) |> Enum.sum()
        page = Page.page(streams, request, producers_listing(), unanswered > 0 or Fanout.partial?(fanout))

        page
        |> Page.to_json("streams", &producer_stream/1)
        |> Map.merge(Fanout.members(fanout))
        |> Map.merge(%{"node" => Atom.to_string(node()), "unanswered_connections" => unanswered})
        |> then(&json(conn, 200, &1))

      :error ->
        problem(conn, :invalid_request)
    end
  end

  defp serve(conn, ["cluster"], _subject) do
    json(conn, 200, fanout_opts() |> ClusterView.gather() |> ClusterView.render())
  end

  defp serve(conn, ["ring", "vnodes"], _subject) do
    case Page.request(conn.query_params, vnodes_listing()) do
      {:ok, request} ->
        ring = ClusterView.gather_ring()

        vnodes = ClusterView.vnodes_of(ring)

        # a ring that could not be read lists nothing, which is a lower bound rather than an empty ring
        page = Page.page(vnodes, request, vnodes_listing(), match?({:error, _}, ring))

        page
        |> Page.to_json("vnodes", &ClusterView.render_vnode/1)
        |> Map.merge(ClusterView.ring_state(ring))
        |> then(&json(conn, 200, &1))

      :error ->
        problem(conn, :invalid_request)
    end
  end

  defp serve(conn, ["topics"], _subject) do
    with_metadata(conn, topics_listing(), fn metadata ->
      {:ok, {TopicsView.topics(metadata), "topics", &TopicsView.render_topic/1, %{}}}
    end)
  end

  defp serve(conn, ["topics", topic, "ranges"], _subject) do
    with_topic(conn, topic, integer_listing("ranges", & &1.seq), fn metadata, name ->
      {:ok, {TopicsView.ranges(metadata, name), "ranges", &TopicsView.render_range/1, %{"topic" => name}}}
    end)
  end

  defp serve(conn, ["topics", topic, "segments"], _subject) do
    with_topic(conn, topic, segments_listing(), fn metadata, name ->
      # one list of nodes for both the copies asked and the replica count
      fanout = Fanout.call(:copy_health, [], fanout_opts())
      alive = if fanout.membership_unavailable, do: :unknown, else: fanout.asked
      segments = TopicsView.segments(metadata, name, alive, replication_factor())
      health = TopicsView.health(fanout)

      {:ok,
       {segments, "segments", &TopicsView.render_segment(&1, health), Map.put(Fanout.members(fanout), "topic", name)}}
    end)
  end

  defp serve(conn, ["groups"], _subject) do
    with_metadata(conn, groups_listing(), fn metadata ->
      fanout = Fanout.call(:groups, [], fanout_opts())
      groups = GroupsView.groups(%{fanout: fanout, metadata: metadata})

      groups =
        case conn.query_params["topic"] do
          nil -> {:ok, groups}
          topic when is_binary(topic) -> {:ok, Enum.filter(groups, &(&1.topic == topic))}
          _repeated -> {:error, :invalid_request}
        end

      with {:ok, groups} <- groups do
        unanswered = GroupsView.unanswered_coordinators(fanout)

        members =
          fanout
          |> Fanout.members()
          |> Map.put("unanswered_coordinators", unanswered)
          # a group held only by a coordinator that did not answer is missing from the page
          |> Map.put(:partial, Fanout.partial?(fanout) or unanswered > 0)

        {:ok, {groups, "groups", &GroupsView.render_summary/1, members}}
      end
    end)
  end

  defp serve(conn, ["groups", raw_group], _subject) do
    with {:ok, group} <- decode_segment(raw_group),
         topic when is_binary(topic) and topic != "" <- conn.query_params["topic"],
         {:ok, metadata, sample_members} <- sampled_metadata() do
      fanout = Fanout.call(:groups, [], fanout_opts())

      case Enum.find(
             GroupsView.groups(%{fanout: fanout, metadata: metadata}),
             &(&1.group == group and &1.topic == topic)
           ) do
        # not found where something did not answer: the group may be held by what did not answer, so it
        # is not reported missing
        nil ->
          unanswered = GroupsView.unanswered_coordinators(fanout)

          if Fanout.partial?(fanout) or unanswered > 0,
            do: problem(conn, {:unavailable, Map.put(Fanout.members(fanout), "unanswered_coordinators", unanswered)}),
            else: problem(conn, {:group_not_found, group, topic})

        found ->
          body =
            found
            |> GroupsView.render_detail()
            |> Map.merge(Fanout.members(fanout))
            |> Map.merge(sample_members)
            |> Map.put("unanswered_coordinators", GroupsView.unanswered_coordinators(fanout))

          json(conn, 200, body)
      end
    else
      {:error, error} -> problem(conn, error)
      _missing_topic_or_bad_name -> problem(conn, :invalid_request)
    end
  end

  defp serve(conn, ["sessions"], _subject) do
    case page_request(conn, sessions_listing()) do
      {:ok, request} ->
        fanout = Fanout.call(:sessions, [], fanout_opts())
        sessions = Enum.flat_map(fanout.answers, fn {_node, sessions} -> sessions end)
        page = Page.page(sessions, request, sessions_listing(), Fanout.partial?(fanout))

        page
        |> Page.to_json("sessions", &AccessView.render_session/1)
        |> Map.merge(Fanout.members(fanout))
        |> then(&json(conn, 200, &1))

      {:error, error} ->
        problem(conn, error)
    end
  end

  defp serve(conn, ["lockouts"], _subject) do
    with {:ok, request} <- page_request(conn, lockouts_listing()),
         {:ok, lockouts, sample_members} <- sampled_lockouts() do
      page = Page.page(lockouts, request, lockouts_listing(), false)
      json(conn, 200, page |> Page.to_json("lockouts", &AccessView.render_lockout/1) |> Map.merge(sample_members))
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp serve(conn, ["stream"], _subject), do: Malachi.Console.Stream.serve(conn, stream_opts())

  defp serve(conn, ["metrics", "history"], _subject) do
    with {:ok, window} <- history_window(conn.query_params["window"]),
         {:ok, series} <- history_series(conn.query_params["series"]) do
      fanout = Fanout.call(:metrics_history, [window, series], fanout_opts())

      nodes =
        for {node, %{timestamps: timestamps, series: values}} <- fanout.answers do
          %{"node" => Atom.to_string(node), "timestamps" => timestamps, "series" => values}
        end

      body = Map.merge(%{"window_seconds" => window, "series" => series, "nodes" => nodes}, Fanout.members(fanout))
      json(conn, 200, body)
    else
      :error -> problem(conn, :invalid_request)
    end
  end

  @history_window_default 60
  @history_window_max 300

  # The window in whole seconds, 1 to the history the nodes keep (300 s), 60 when absent.
  defp history_window(nil), do: {:ok, @history_window_default}

  defp history_window(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {window, ""} when window in 1..@history_window_max -> {:ok, window}
      _invalid -> :error
    end
  end

  defp history_window(_repeated), do: :error

  # Comma separated names from the served list, every one of them when absent. An unknown name is refused
  # rather than dropped, so a typo is a 400 and not an empty chart.
  defp history_series(nil), do: {:ok, Reads.history_series()}

  defp history_series(raw) when is_binary(raw) do
    names = raw |> String.split(",", trim: true) |> Enum.uniq()
    known = Reads.history_series()
    if names != [] and Enum.all?(names, &(&1 in known)), do: {:ok, names}, else: :error
  end

  defp history_series(_repeated), do: :error

  # An empty list would say nobody is locked out; a store that could not be read is a 503 instead.
  defp sampled_lockouts do
    case Samples.lockouts() do
      {:ok, %{value: lockouts, sampled_at: at, stale: stale}} ->
        {:ok, lockouts, %{"sampled_at" => iso8601(at), "stale" => stale}}

      {:error, :unavailable} ->
        {:error, :lockouts_unavailable}
    end
  end

  # A listing read from this node's sampled metadata: `build` turns it into the items, the name they go
  # under, how each renders and the members the body adds, or refuses with an error. No broker on this node
  # is an empty listing; metadata that could not be read is a 503, since an empty page would read as no
  # topics.
  defp with_metadata(conn, listing, build) do
    with {:ok, request} <- page_request(conn, listing),
         {:ok, metadata, sample_members} <- sampled_metadata(),
         {:ok, {items, name, render, members}} <- build.(metadata) do
      # a builder that gathered from other nodes says whether some did not answer, which makes the
      # listing a lower bound
      page = Page.page(items, request, listing, Map.get(members, :partial, false))
      members = Map.delete(members, :partial)
      json(conn, 200, page |> Page.to_json(name, render) |> Map.merge(members) |> Map.merge(sample_members))
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp with_topic(conn, raw_topic, listing, build) do
    case decode_segment(raw_topic) do
      {:ok, topic} ->
        with_metadata(conn, listing, fn metadata ->
          if TopicsView.topic?(metadata, topic),
            do: build.(metadata, topic),
            else: {:error, {:topic_not_found, topic}}
        end)

      :error ->
        problem(conn, :invalid_request)
    end
  end

  defp page_request(conn, listing) do
    case Page.request(conn.query_params, listing) do
      {:ok, request} -> {:ok, request}
      :error -> {:error, :invalid_request}
    end
  end

  defp sampled_metadata do
    case Samples.metadata() do
      {:ok, %{value: metadata, sampled_at: at, stale: stale}} ->
        {:ok, metadata, %{"sampled_at" => iso8601(at), "stale" => stale}}

      :none ->
        {:ok, %Malachi.Metadata{}, %{"sampled_at" => nil, "stale" => false}}

      {:error, :unavailable} ->
        {:error, :metadata_unavailable}
    end
  end

  # A path segment arrives percent-encoded (`path_info` is not decoded); a topic name is the decoded text.
  # `URI.decode/1` leaves a malformed escape such as `%zz` as it is, which would then be looked up as a name,
  # so a `%` not followed by two hex digits is refused here.
  defp decode_segment(raw) do
    if raw =~ ~r/%(?![0-9A-Fa-f]{2})/, do: :error, else: {:ok, URI.decode(raw)}
  end

  defp replication_factor, do: Application.get_env(:malachi, :log_replication_factor, 3)

  defp iso8601(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # Groups sort by name, then topic, which together name one.
  defp groups_listing do
    %{
      kind: "groups",
      key: &{&1.group, &1.topic},
      encode: fn {group, topic} -> [group, topic] end,
      decode: fn
        [group, topic] -> {:ok, {group, topic}}
        _fields -> :error
      end
    }
  end

  # Sessions sort by when they were created, then by the node that holds them and their digest.
  defp sessions_listing do
    %{
      kind: "sessions",
      key: &{&1.created_at, &1.node, &1.session},
      encode: fn {created_at, node, session} -> [Integer.to_string(created_at), node, session] end,
      decode: fn
        [created_at, node, session] ->
          with {:ok, created_at} <- decode_integer([created_at]), do: {:ok, {created_at, node, session}}

        _fields ->
          :error
      end
    }
  end

  # Lockouts sort by user, then address, which together name one.
  defp lockouts_listing do
    %{
      kind: "lockouts",
      key: &{&1.username, IPAddress.format(&1.ip)},
      encode: fn {username, ip} -> [username, ip] end,
      decode: fn
        [username, ip] -> {:ok, {username, ip}}
        _fields -> :error
      end
    }
  end

  # Topics sort by name, which is unique.
  defp topics_listing, do: %{kind: "topics", key: & &1.name, encode: &[&1], decode: &decode_text/1}

  defp decode_text([text]), do: {:ok, text}
  defp decode_text(_fields), do: :error

  # A topic's segments sort by range, then by their sequence in it.
  defp segments_listing do
    %{
      kind: "segments",
      key: &{&1.range, &1.segment},
      encode: fn {range, segment} -> [Integer.to_string(range), Integer.to_string(segment)] end,
      decode: fn
        [range, segment] ->
          with {:ok, range} <- decode_integer([range]), {:ok, segment} <- decode_integer([segment]) do
            {:ok, {range, segment}}
          end

        _fields ->
          :error
      end
    }
  end

  defp integer_listing(kind, key),
    do: %{kind: kind, key: key, encode: &[Integer.to_string(&1)], decode: &decode_integer/1}

  # Vnodes sort by their token, the ring's own order, which is unique.
  defp vnodes_listing, do: integer_listing("vnodes", & &1.token)

  defp decode_integer([text]) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp decode_integer(_fields), do: :error

  # Streams sort by when they opened, then by the node and connection that hold them and the stream's id
  # on that connection, which together name one stream in the cluster.
  defp producers_listing do
    %{
      kind: "producers",
      key: &{&1.opened_at, &1.node, &1.connection, &1.stream_id},
      encode: fn {opened_at, node, connection, stream_id} ->
        [Integer.to_string(opened_at), node, connection, Integer.to_string(stream_id)]
      end,
      decode: &decode_producer_key/1
    }
  end

  defp decode_producer_key([opened_at, node, connection, stream_id]) do
    with {opened_at, ""} <- Integer.parse(opened_at),
         {stream_id, ""} <- Integer.parse(stream_id) do
      {:ok, {opened_at, node, connection, stream_id}}
    else
      _invalid -> :error
    end
  end

  defp decode_producer_key(_fields), do: :error

  # A test narrows the fan-out to chosen nodes and a stand-in call (`:console_fanout` in the app env).
  defp fanout_opts, do: Application.get_env(:malachi, :console_fanout, [])

  # A test points the stream at a hub of its own (`:console_stream` in the app env).
  defp stream_opts, do: Application.get_env(:malachi, :console_stream, [])

  defp producer_stream(stream) do
    %{
      "stream_id" => stream.stream_id,
      "node" => stream.node,
      "topic" => stream.topic,
      "range" => stream.range,
      "segment" => stream.segment,
      "primary" => stream.primary,
      "label" => stream.label,
      "client_ip" => stream.client_ip,
      "window" => %{"appends" => stream.window.appends, "bytes" => stream.window.bytes},
      "next_sequence" => stream.next_sequence,
      "acked_sequence" => stream.acked_sequence,
      "in_flight" => %{"appends" => stream.in_flight.appends, "bytes" => stream.in_flight.bytes},
      "opened_at" => stream.opened_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    }
  end

  defp cluster_identity do
    identity = Application.get_env(:malachi, :cluster_identity, %{})
    %{"name" => identity[:name], "color" => identity[:color], "icon" => identity[:icon]}
  end

  defp role_string(nil), do: nil
  defp role_string(role), do: Atom.to_string(role)

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  # Responses are about one operator and change with every role change, so nothing caches them.
  defp json(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp problem(conn, error) do
    {status, headers, body} = Problem.for_error(error)

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_resp_header(acc, String.downcase(name), value) end)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
    |> halt()
  end
end
