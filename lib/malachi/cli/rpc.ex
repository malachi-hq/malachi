defmodule Malachi.CLI.Rpc do
  @moduledoc """
  Shared Erlang-distribution/RPC plumbing for the operator mix tasks (`mix malachi.user`, `mix malachi.acl`):
  resolve the target node, bring this task's VM up as a distributed node and connect, and build the RPC
  **seam** the task's testable core calls through. Kept free of `Mix.*` (it returns `{:error, message}` rather
  than raising) so the tasks own their own output/exit behavior.
  """

  alias Malachi.Cluster.DistGuard

  @default_node "malachi@127.0.0.1"
  # How a task's VM starts with TLS distribution: the protocol is fixed when a VM boots.
  @tls_erl_options ~s(ELIXIR_ERL_OPTIONS="-proto_dist inet_tls -ssl_dist_optfile <options file>")
  @rpc_timeout 5_000
  # Connect budget: a fresh mix VM's distribution plus epmd churn from rapid successive tasks can take a
  # moment to settle, so retry generously (attempts x backoff) before giving up.
  @connect_attempts 30
  @connect_backoff_ms 200

  @doc "The target node: `--node`, else `$MALACHI_NODE`, else `malachi@127.0.0.1`."
  @spec target_node(keyword()) :: node()
  def target_node(opts) do
    (opts[:node] || System.get_env("MALACHI_NODE") || @default_node) |> String.to_atom()
  end

  @doc """
  Brings this task's VM up as a distributed node (if not already) and connects to `node`, applying `cookie`
  (or `$RELEASE_COOKIE`). Returns `:ok`, or `{:error, message}` when the node cannot be reached.
  """
  @spec connect(node(), String.t() | nil) :: :ok | {:error, String.t()}
  def connect(node, cookie) do
    with :ok <- ensure_distribution() do
      cookie_value = cookie || System.get_env("RELEASE_COOKIE")
      if cookie_value, do: Node.set_cookie(node, String.to_atom(cookie_value))

      if connect_with_retry(node, @connect_attempts) do
        :ok
      else
        {:error,
         "could not connect to #{node} (check --node/--cookie and that the node is running and named; a node on " <>
           "TLS distribution needs this task started with MALACHI_DIST_TLS=true and #{@tls_erl_options})"}
      end
    end
  end

  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      with :ok <- check_transport(System.get_env("MALACHI_DIST_TLS"), DistGuard.facts(false)) do
        start_distribution()
      end
    end
  end

  # Name the task's node by the OS pid: each `mix` invocation is a fresh VM where `System.unique_integer/1` resets, so
  # two back-to-back tasks would otherwise both pick `malachi_cli_1` and collide in epmd. The OS pid is distinct per
  # invocation, so rapid successive tasks never clash. A start failure (e.g. epmd not reachable) is surfaced, not
  # raised.
  defp start_distribution do
    case Node.start(:"malachi_cli_#{:os.getpid()}@127.0.0.1", name_domain: :longnames) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, "could not start distribution (#{inspect(reason)}); is epmd running?"}
    end
  end

  @doc """
  Whether this task's VM can speak the distribution `MALACHI_DIST_TLS` (`tls`) asks for, from the VM's facts
  (`Malachi.Cluster.DistGuard.facts/1`): `:ok`, or `{:error, message}` when TLS distribution was asked for and the VM
  was started without `-proto_dist inet_tls` or without an options file. The protocol is fixed when a VM boots, so
  a task cannot switch to TLS once it runs; the message says how to start it.
  """
  @spec check_transport(String.t() | nil, %{proto_dist: [String.t()], optfile: Path.t() | nil}) ::
          :ok | {:error, String.t()}
  def check_transport("true", %{proto_dist: protos, optfile: optfile}) do
    if "inet_tls" in protos and optfile not in [nil, ""],
      do: :ok,
      else:
        {:error,
         "MALACHI_DIST_TLS=true, but this task's VM was started without TLS distribution: run it with " <>
           @tls_erl_options}
  end

  def check_transport(_tls, _facts), do: :ok

  @doc """
  The usage text for reaching a node, which every task that does (`mix malachi.user`, `acl`, `ring`, `reshard`,
  `flag`, `hold`, `policy`, `purge`) prints.
  """
  @spec connection_usage() :: String.t()
  def connection_usage do
    """
    connection: --node (or $MALACHI_NODE, default malachi@127.0.0.1), and the cookie in $RELEASE_COOKIE
      (--cookie also takes it, but a flag shows in ps and in the shell history)
      a node on TLS distribution: MALACHI_DIST_TLS=true #{@tls_erl_options}\
    """
  end

  # A fresh node's distribution (and epmd, under rapid task churn) may not be ready the instant it boots, so
  # retry before giving up. `Node.connect/1` returns `true` (connected), `false` (unreachable), or `:ignored`
  # (local distribution not up yet); only `true` is done, the rest are retried while things settle.
  defp connect_with_retry(_node, 0), do: false

  defp connect_with_retry(node, attempts) do
    if Node.connect(node) == true do
      true
    else
      Process.sleep(@connect_backoff_ms)
      connect_with_retry(node, attempts - 1)
    end
  end

  @doc """
  The RPC seam: a `(module, fun, args -> {:ok, value} | {:error, reason})` function that calls `node` over
  Erlang distribution. The task's `execute/3` core calls through this, and tests substitute a fake.

  `timeout_ms` (5 s by default) bounds the wait. A call that runs out of it is answered `{:error,
  :timeout}`, but the remote call is not stopped and may still complete, so a task whose remote work
  waits on its own deadlines passes a budget above their sum.
  """
  @spec rpc(node(), pos_integer()) :: (module(), atom(), list() -> {:ok, term()} | {:error, term()})
  def rpc(node, timeout_ms \\ @rpc_timeout) do
    fn module, fun, args ->
      case :rpc.call(node, module, fun, args, timeout_ms) do
        {:badrpc, reason} -> {:error, reason}
        value -> {:ok, value}
      end
    end
  end

  @doc "Formats an RPC transport failure for display."
  @spec rpc_error(term()) :: String.t()
  def rpc_error(reason), do: "rpc failed: #{inspect(reason)}"
end
