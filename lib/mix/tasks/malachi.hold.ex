defmodule Mix.Tasks.Malachi.Hold do
  @shortdoc "Place, release or show a topic's legal hold on a running node"

  @moduledoc """
  Manages a topic's legal hold on a **running** Malachi node from the box, over Erlang distribution (RPC)
  (`Malachi.LegalHold`, #307):

      mix malachi.hold set <topic> --reason <text>
      mix malachi.hold release <topic>
      mix malachi.hold show <topic>

  While a topic is held, retention expires none of its segments whatever its policy says, and the control
  plane refuses to delete the topic or purge it. Releasing the hold lets the next retention sweep expire
  what the policy would have expired meanwhile. The reason is recorded in the audit trail with the actor,
  which is `cli@<this node>`.

  Holding needs control-plane machine version 11: during a rolling upgrade it is refused until every node
  runs a release that implements it and the version pin is lifted.

  Options:

    * `--node`: the target node (default `$MALACHI_NODE` or `malachi@127.0.0.1`)
    * `--cookie`: the Erlang cookie (default `$RELEASE_COOKIE`, else `~/.erlang.cookie`)

  The target node must be **named** (a release, or `iex --name ... -S mix`).
  """
  use Mix.Task

  alias Malachi.CLI.Options
  alias Malachi.CLI.Rpc
  alias Malachi.LegalHold

  @switches [node: :string, cookie: :string, reason: :string]

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
  The testable core: maps the subcommand to `Malachi.LegalHold` through `call` (a
  `(module, fun, args -> {:ok, value} | {:error, reason})` seam that in production is an RPC to the target
  node). `set` without a `--reason` is refused before anything is sent. Returns `{:ok, message}` /
  `{:error, message}` for the caller to print.
  """
  @spec execute([String.t()], keyword(), (module(), atom(), list() -> {:ok, term()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(["set", topic], opts, call) do
    case opts[:reason] do
      nil -> {:error, "set takes --reason <text>\n\n" <> usage()}
      reason -> finish(call.(LegalHold, :set, [topic, reason, actor()]), "#{topic}: legal hold placed")
    end
  end

  def execute(["release", topic], _opts, call),
    do: finish(call.(LegalHold, :release, [topic, actor()]), "#{topic}: legal hold released")

  def execute(["show", topic], _opts, call) do
    case call.(LegalHold, :get, [topic]) do
      {:ok, {:ok, nil}} -> {:ok, "#{topic}: not held"}
      {:ok, {:ok, hold}} -> {:ok, describe(topic, hold)}
      other -> finish(other, nil)
    end
  end

  def execute(_args, _opts, _call), do: {:error, usage()}

  defp describe(topic, hold) do
    since = hold.since_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    Enum.join(["topic\t#{topic}", "held\tsince #{since}", "actor\t#{hold.actor}", "reason\t#{hold.reason}"], "\n")
  end

  defp actor, do: "cli@#{node()}"

  # `call` returns `{:ok, reply}` (`:ok` or `{:error, reason}`) or `{:error, rpc_reason}`.
  defp finish({:ok, :ok}, message), do: {:ok, message}
  defp finish({:ok, {:error, reason}}, _message), do: {:error, LegalHold.reason_string(reason)}
  defp finish({:error, reason}, _message), do: {:error, Rpc.rpc_error(reason)}

  defp usage do
    """
    usage:
      mix malachi.hold set <topic> --reason <text>
      mix malachi.hold release <topic>
      mix malachi.hold show <topic>

    #{Rpc.connection_usage()}
    """
  end
end
