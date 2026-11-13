defmodule Malachi.Console.Reads do
  @moduledoc """
  The reads one node answers for itself, for `Malachi.Console.Fanout` to gather across the cluster.

  Every function here is called by `:erpc` from whichever node received an `/api/v1` request, so the rules
  are strict: it reads only this node's state, it is bounded in time, it reaches a process that serves clients
  (the produce and consume path, the gossip loop, a coordinator) only through `Malachi.Console.Samples`, so
  at most once per interval however many ask, and it returns plain data (maps, lists, strings and numbers), never a pid or a
  reference that means nothing on the node that asked. A function removed or renamed here is a breaking
  change for the nodes of a rolling upgrade, which report it as unsupported; add a new function instead.
  """

  alias Malachi.Auth.SessionManager
  alias Malachi.Cluster.MachineVersion
  alias Malachi.Console.Access
  alias Malachi.Console.Samples
  alias Malachi.Metrics
  alias Malachi.Storage.FormatMarker

  # The replicated state machines by the name of their ra cluster. Every other cluster a node runs is the
  # metadata: the node-wide one (`MALACHI_LOG_CLUSTER`) or one per vnode on a sharded control plane.
  @machines %{
    Malachi.LogRing => "ring",
    Malachi.LogLease => "lease",
    Malachi.LogPolicies => "policy",
    Malachi.LogClusterFlags => "cluster_flags",
    Malachi.LogUsers => "user",
    Malachi.LogLockouts => "lockout",
    Malachi.LogAcls => "acl"
  }

  @doc """
  The producer streams open on this node, each naming the node that holds it, and how many connections did
  not answer within `timeout_ms`, from the node's sample of its connections
  (`Malachi.Console.Samples.producers/1`). A listing that could not be taken at all exits, which the
  fan-out counts as a node that did not answer, rather than as a node with no streams.
  """
  @spec producers(non_neg_integer()) :: %{streams: [map()], unanswered: non_neg_integer()}
  def producers(timeout_ms) do
    case Samples.producers(timeout_ms) do
      {:ok, %{value: %{streams: streams, unanswered: unanswered}}} ->
        node = Atom.to_string(node())
        %{streams: Enum.map(streams, &Map.put(&1, :node, node)), unanswered: unanswered}

      {:error, :unavailable} ->
        exit(:producer_listing_unavailable)
    end
  end

  @doc """
  What this node says about itself for the Cluster view (section 6.8 of
  `docs/design/operator-interfaces.md`): how long it has been up, the release it runs, the format marker of
  its data directory, and the effective machine version of every replicated state machine member it hosts.

  The format marker is read from disk (a few hundred bytes) and the versions from `ra`'s counters, so no
  process is called.
  """
  @spec node_info() :: map()
  def node_info do
    %{
      uptime_seconds: Metrics.uptime_seconds(),
      version: release_version(),
      format: format_marker(),
      machine_versions: machine_versions()
    }
  end

  @doc """
  The effective machine version of every `ra` member this node hosts, with the version this release
  supports and whether the member is stuck (it met a version above that, and stops applying until it runs
  newer code). Sorted by machine, then member. `system` is the `ra` system the members run in; none when
  it is not running (an in-memory node, or one starting or stopping).
  """
  @spec machine_versions(atom()) :: [map()]
  def machine_versions(system \\ :default) do
    supported = MachineVersion.version()

    for {name, _uid} <- registered_members(system),
        effective = effective_version({name, node()}),
        effective != nil do
      %{
        machine: Map.get(@machines, name, "metadata"),
        member: member_name(name),
        effective: effective,
        supported: supported,
        stuck: effective > supported
      }
    end
    |> Enum.sort_by(&{&1.machine, &1.member})
  end

  defp registered_members(system) do
    :ra_directory.list_registered(system)
  rescue
    _not_running -> []
  end

  defp effective_version(server_id) do
    case :ra_counters.counters(server_id, [:effective_machine_version]) do
      %{effective_machine_version: effective} -> effective
      _not_registered -> nil
    end
  end

  # `Malachi.LogRing` reads as `ring`, a vnode id as itself
  defp member_name(name) do
    case Atom.to_string(name) do
      "Elixir.Malachi.Log" <> rest -> Macro.underscore(rest)
      other -> other
    end
  end

  defp release_version do
    case Application.spec(:malachi, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  # The marker of the log data directory, or why it could not be read. A node with no data directory
  # configured (in memory) has none.
  defp format_marker do
    case Application.get_env(:malachi, :log_data_dir) do
      nil -> %{state: "none"}
      dir -> dir |> FormatMarker.read() |> marker()
    end
  end

  defp marker({:ok, {:ok, %{format: format, written_by: written_by, requires: requires}}}),
    do: %{state: "present", format: format, written_by: written_by, requires: requires}

  defp marker({:ok, {:absent, _kind}}), do: %{state: "absent"}
  defp marker({:ok, {:error, _parse_error}}), do: %{state: "invalid"}
  defp marker({:error, {:io, _posix}}), do: %{state: "unreadable"}

  @doc """
  The health of the segment copies this node holds, for the Segments view (section 6.6 of
  `docs/design/operator-interfaces.md`): the segments whose copy here failed in storage, and those the
  scrubber found damaged, each as a list of segment ids, or `:unknown` when it could not be read. A node
  that runs no scrubber reports `damaged: :not_scrubbed`, which says nothing either way.

  Both are taken through `Malachi.Console.Sampler` on this node, since the replication server and the
  scrubber are the processes that serve the data, and the two are taken at once, so a slow scrubber costs
  its own bound rather than adding to the other's. A list that could not be read this time is `:unknown`
  even when an older one is kept: a copy that failed after that older list was taken must not show as
  healthy.
  """
  @spec copy_health() :: %{failed: [term()] | :unknown, damaged: [term()] | :unknown | :not_scrubbed}
  def copy_health do
    failed = Task.async(fn -> Samples.failed() end)
    damaged = Samples.damaged()

    %{
      # a sample answers within its own bound; this one is only a backstop
      failed:
        case Task.await(failed, 5_000) do
          {:ok, %{value: failed, stale: false}} -> MapSet.to_list(failed)
          :none -> []
          _stale_or_unavailable -> :unknown
        end,
      damaged:
        case damaged do
          {:ok, %{value: damaged, stale: false}} -> damaged
          :none -> :not_scrubbed
          _stale_or_unavailable -> :unknown
        end
    }
  end

  # The node-wide coordinator's name, and the prefix of each vnode's (`Malachi.Consumer.CoordinatorRouter`).
  @coordinator Malachi.LogGroupCoordinator
  @vnode_coordinator_prefix "#{@coordinator}."

  @doc """
  The consumer groups the coordinators on this node hold, for the Consumers view (section 6.5 of
  `docs/design/operator-interfaces.md`): the node-wide coordinator, and one per vnode this node leads on a
  sharded control plane. Each is read through `Malachi.Console.Sampler`, since it serves its members' group
  keys, and they are read at once, so the time this takes is one coordinator's bound however many vnodes
  this node leads. A coordinator that could not be read at all is counted in `unanswered`; one whose read
  failed this time answers with what it held at its last sample.
  """
  @spec groups() :: %{groups: [map()], unanswered: non_neg_integer()}
  def groups do
    results =
      local_coordinators()
      |> Task.async_stream(&Samples.group_coordinator/1, ordered: false, timeout: 5_000, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _timeout} -> {:error, :unavailable}
      end)

    %{
      groups: for({:ok, %{value: groups}} <- results, group <- groups, do: group),
      unanswered: Enum.count(results, &match?({:error, :unavailable}, &1))
    }
  end

  defp local_coordinators do
    Enum.filter(Process.registered(), fn name ->
      name == @coordinator or String.starts_with?(Atom.to_string(name), @vnode_coordinator_prefix)
    end)
  end

  @doc """
  The active sessions of this node, which keeps its own (`Malachi.Auth.SessionManager`), each named by
  `Malachi.Console.Access.session_digest/1`, the identifier the API rate limit and its audit events use,
  and never by any part of its token. A read of an ETS table: no process is called.
  """
  @spec sessions() :: [map()]
  def sessions do
    node = Atom.to_string(node())

    for session <- SessionManager.list_sessions_identified(&Access.session_digest/1),
        do: Map.put(session, :node, node)
  end

  # The series `metrics_history/2` serves, by the name a client asks for, each a path into a sample of
  # `Malachi.Metrics.get_system_metrics/0`. Explicit, so the payload stays bounded and a renamed field in the
  # snapshot fails a test here rather than shipping an empty series. Counters are cumulative since the node
  # started: a rate is the difference between two points.
  @history_series %{
    "process_count" => [:process_count],
    "run_queue" => [:run_queue],
    "memory.total_mb" => [:memory, :total_mb],
    "memory.processes_mb" => [:memory, :processes_mb],
    "memory.ets_mb" => [:memory, :ets_mb],
    "memory.binary_mb" => [:memory, :binary_mb],
    "io.input_bytes" => [:io, :input_bytes],
    "io.output_bytes" => [:io, :output_bytes],
    "operations.records_produced" => [:operations, :records_produced],
    "operations.bytes_produced" => [:operations, :bytes_produced],
    "operations.records_consumed" => [:operations, :records_consumed],
    "operations.replication_ok" => [:operations, :replication_ok],
    "operations.replication_no_quorum" => [:operations, :replication_no_quorum],
    "operations.producer_streams_open" => [:operations, :producer_streams_open],
    "storage_flush.p50_us" => [:storage_flush, :p50_us],
    "storage_flush.p99_us" => [:storage_flush, :p99_us],
    "storage_flush.p999_us" => [:storage_flush, :p999_us],
    "security.active_sessions" => [:security, :active_sessions],
    "security.active_lockouts" => [:security, :active_lockouts]
  }

  @doc "The names of every series `metrics_history/2` serves, sorted."
  @spec history_series() :: [String.t()]
  def history_series, do: @history_series |> Map.keys() |> Enum.sort()

  @doc """
  This node's per second metrics history over the last `window_seconds` (`Malachi.Metrics.get_history/1`,
  an ETS read), as columns: the sample times in Unix seconds, oldest first, and one list of values per
  series in `series` (names from `history_series/0`), aligned with the times. A name it does not serve is
  left out, and a value missing from a sample is `nil`.
  """
  @spec metrics_history(pos_integer(), [String.t()]) :: %{timestamps: [integer()], series: %{String.t() => list()}}
  def metrics_history(window_seconds, series) do
    samples = window_seconds |> Metrics.get_history() |> Enum.sort_by(& &1.timestamp)

    %{
      timestamps: Enum.map(samples, & &1.timestamp),
      series:
        for name <- series, Map.has_key?(@history_series, name), into: %{} do
          path = Map.fetch!(@history_series, name)
          {name, Enum.map(samples, &get_in(&1.system, path))}
        end
    }
  end
end
