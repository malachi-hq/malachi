defmodule Mix.Tasks.Malachi.Purge do
  @shortdoc "Purge a topic up to a time, a position or a group's commit on a running node"

  @moduledoc """
  Purges a topic on a **running** Malachi node from the box, over Erlang distribution (RPC): moves the
  logical start of the topic's ranges up to a point, so no reader is served what lies below it
  (`Malachi.Purge`, #198). Exactly one point:

      mix malachi.purge <topic> --before <time>
      mix malachi.purge <topic> --cursor <token>
      mix malachi.purge <topic> --group <name>

  To answer a data subject's request (#308), add both `--request <id>` and `--reason <text>`:

      mix malachi.purge <topic> --group <name> --request DSR-2026-0042 --reason "LGPD art. 18 request"

  The request is recorded in the audit trail before the purge runs, and the purge's audit entry carries
  its id; a request that covers several topics is one run per topic with the same `--request`. The id is
  the request's reference in your own system, 1 to 128 bytes of printable ASCII; the reason is 1 to 512
  bytes of text. Neither may identify the data subject (no name, e-mail, document number or hash of
  them): both stay in the audit trail, and the command line stays in your shell history and process list.
  Both are checked here, before anything is sent.

  * `--before`: every record in a segment the control plane sealed at or before `<time>`, an ISO 8601
    datetime with an offset (`2026-11-13T10:00:00Z`) or epoch milliseconds. Record timestamps are client
    supplied, so the seal time is the only one the cluster vouches for: the point rounds DOWN to a
    segment boundary, and the active segment is never purged by time.
  * `--cursor`: up to an opaque position a read handed out, in hex. Only the range that issued it is
    purged, and a position still inside a range a split retired is refused (its siblings read it too).
  * `--group`: everything the consumer group has read; a range a split retired is purged only up to the
    least any of its active descendants has read, and a descendant the group never committed on keeps it.

  This is a **logical purge**, not erasure: the records stay on disk, on every replica, until retention
  removes their whole segment, which its next sweep does once the segment lies wholly below the start.
  It removes every record below the point from every reader, from every subject whose records are there.

  The node that runs the purge clamps its readers when it answers; every other node does on its next
  metadata refresh (1 s by default). Purging needs control-plane machine version 9: during a rolling
  upgrade it is refused until every node runs a release that implements it and the version pin is lifted.

  Options:

    * `--node`: the target node (default `$MALACHI_NODE` or `malachi@127.0.0.1`)
    * `--cookie`: the Erlang cookie (default `$RELEASE_COOKIE`, else `~/.erlang.cookie`)

  The target node must be **named** (a release, or `iex --name ... -S mix`).
  """
  use Mix.Task

  alias Malachi.CLI.Options
  alias Malachi.CLI.Rpc
  alias Malachi.Purge
  alias Malachi.Purge.Request

  @switches [
    node: :string,
    cookie: :string,
    before: :string,
    cursor: :string,
    group: :string,
    request: :string,
    reason: :string
  ]

  @impl Mix.Task
  def run(argv) do
    case Options.parse(argv, @switches) do
      {:ok, {opts, args}} -> connect_and_run(args, opts)
      {:error, message} -> Mix.raise(message <> "\n\n" <> usage())
    end
  end

  defp connect_and_run(args, opts) do
    node = Rpc.target_node(opts)

    case Rpc.connect(node, opts[:cookie]) do
      :ok -> report(execute(args, opts, Rpc.rpc(node)))
      {:error, message} -> Mix.raise(message)
    end
  end

  defp report({:ok, message}), do: Mix.shell().info(message)

  defp report({:error, message}) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end

  @doc """
  The testable core: parses the point and maps it to `Malachi.Purge.purge/3` through `call` (a
  `(module, fun, args -> {:ok, value} | {:error, reason})` seam that in production is an RPC to the target
  node). A malformed point is refused before anything is sent. Returns `{:ok, message}` /
  `{:error, message}` for the caller to print.
  """
  @spec execute([String.t()], keyword(), (module(), atom(), list() -> {:ok, term()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute([topic], opts, call) do
    with {:ok, point} <- point(opts),
         {:ok, request} <- request(opts) do
      finish(call.(Purge, :purge, purge_args(topic, point, request)), topic, point, request)
    end
  end

  def execute(_args, _opts, _call), do: {:error, usage()}

  defp point(opts) do
    case Keyword.take(opts, [:before, :cursor, :group]) do
      [before: raw] -> parse_time(raw)
      [cursor: raw] -> parse_token(raw)
      [group: ""] -> {:error, "--group takes a non-empty name"}
      [group: group] -> {:ok, {:group, group}}
      _none_or_several -> {:error, "give exactly one of --before, --cursor, --group\n\n" <> usage()}
    end
  end

  # A purge that answers no request keeps the three-argument call, so the request is never sent as nil.
  defp purge_args(topic, point, nil), do: [topic, point, actor()]
  defp purge_args(topic, point, request), do: [topic, point, actor(), request]

  defp request(opts) do
    case {opts[:request], opts[:reason]} do
      {nil, nil} ->
        {:ok, nil}

      {id, reason} when is_binary(id) and is_binary(reason) ->
        case Request.new(id, reason) do
          {:ok, request} -> {:ok, request}
          {:error, reason} -> {:error, Purge.reason_string(reason)}
        end

      _one_alone ->
        {:error, "--request and --reason go together: give both or neither\n\n" <> usage()}
    end
  end

  defp parse_time(raw) do
    case Integer.parse(raw) do
      {ms, ""} when ms >= 0 ->
        {:ok, {:before, ms}}

      _not_ms ->
        case DateTime.from_iso8601(raw) do
          {:ok, datetime, _offset} -> {:ok, {:before, DateTime.to_unix(datetime, :millisecond)}}
          {:error, _reason} -> {:error, "--before takes an ISO 8601 datetime with an offset or epoch ms, got: #{raw}"}
        end
    end
  end

  defp parse_token(raw) do
    case Base.decode16(raw, case: :mixed) do
      {:ok, token} -> {:ok, {:position, token}}
      :error -> {:error, "--cursor takes a position token in hex, got: #{raw}"}
    end
  end

  defp actor, do: "cli@#{node()}"

  # `call` returns `{:ok, reply}` (`{:ok, moves}` or `{:error, reason}`) or `{:error, rpc_reason}`.
  defp finish({:ok, {:ok, moves}}, topic, point, nil) when map_size(moves) == 0,
    do: {:ok, "#{topic}: nothing to purge up to #{Purge.describe_point(point)}"}

  defp finish({:ok, {:ok, moves}}, topic, point, request) when map_size(moves) == 0,
    do: {:ok, "#{topic}: request #{request.id} recorded; nothing below #{Purge.describe_point(point)} was readable"}

  defp finish({:ok, {:ok, moves}}, topic, point, request) do
    lines =
      moves
      |> Enum.sort()
      |> Enum.map(fn {range_id, {from, to}} -> "#{inspect(range_id)}\t#{from} -> #{to}" end)

    {:ok, Enum.join([header(topic, point, request) | lines], "\n")}
  end

  defp finish({:ok, {:error, reason}}, _topic, _point, _request), do: {:error, Purge.reason_string(reason)}
  defp finish({:error, reason}, _topic, _point, _request), do: {:error, Rpc.rpc_error(reason)}

  @limits "(logical purge, not erasure: every record below the point, from every subject, is no longer " <>
            "readable; the bytes stay on disk until their segment expires)"

  defp header(topic, point, nil),
    do: "#{topic}: logical start moved up to #{Purge.describe_point(point)} #{@limits}"

  defp header(topic, point, request),
    do: "#{topic}: request #{request.id} applied, logical start moved up to #{Purge.describe_point(point)} #{@limits}"

  defp usage do
    """
    usage:
      mix malachi.purge <topic> --before <ISO 8601 datetime | epoch ms>
      mix malachi.purge <topic> --cursor <position token, hex>
      mix malachi.purge <topic> --group <consumer group>

    to answer a data subject's request, add both: --request <id> --reason <text>

    connection: --node (or $MALACHI_NODE, default malachi@127.0.0.1), --cookie (or $RELEASE_COOKIE)
    """
  end
end
