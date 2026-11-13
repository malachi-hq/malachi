defmodule Malachi.Console.Fanout do
  @moduledoc """
  Asks every alive node of the cluster the same read, for the `/api/v1` routes whose data each node holds
  for itself (its producer streams, its sessions, its uptime). The console shows one cluster, the way
  NorthGuard's metadata layer gives its clients "a unified view" of the systems beneath it, so the node
  that receives a request answers for all of them rather than leaving three clients to gather it.

  Each node is asked by `:erpc` for a function of `Malachi.Console.Reads`, the one module whose functions are
  meant to be called this way: local, bounded, and reaching a process that serves clients only through its
  sample (`Malachi.Console.Samples`), once per interval however many ask. The
  calls run concurrently through `Malachi.Cluster.BoundedFanout`, each bounded by the same timeout, so a
  silent node costs that timeout once, not once per node.

  A node is in one of three buckets afterwards, and a route reports the last two:

    * **answered**, with its value;
    * **unanswered**: the call timed out, the node went away, or the read raised there;
    * **unsupported**: the node runs a release whose `Malachi.Console.Reads` lacks the function, which is
      what a rolling upgrade looks like from a newer node. It is told apart from silence because the
      operator's next step differs: wait for the upgrade, rather than look at the node.

  The nodes are the alive members of this node's membership view, read through its sample
  (`Malachi.Console.Samples.membership/0`), since the same process runs the gossip loop; or this node alone
  when it runs no membership (a single node) or its view could not be read.
  """

  alias Malachi.Cluster.BoundedFanout
  alias Malachi.Cluster.Membership
  alias Malachi.Console.Samples

  # Each read a node answers may wait on one sample of `Malachi.Console.Samples` (bounded at 1000 ms, after
  # which it answers with the previous sample), and at most on a sample that needs another first (the
  # failure latch reads the metadata's sample): the call waits for two such bounds and some slack, so a
  # node whose read is slow answers with its last sample instead of being counted as unanswered.
  @default_timeout_ms 2_500

  @typedoc "What every node said."
  @type result :: %{answers: [{node(), term()}], unanswered: [node()], unsupported: [node()]}

  @typedoc "How one node is called: `rpc.(node, module, function, args, timeout_ms)`, as `:erpc.call/5`."
  @type rpc :: (node(), module(), atom(), [term()], pos_integer() -> term())

  @doc """
  Calls `Malachi.Console.Reads.function(args...)` on every alive node. Options:

    * `:nodes`, the nodes to ask, in place of the membership's alive members;
    * `:timeout_ms`, the bound on each call, #{@default_timeout_ms} by default;
    * `:rpc`, how a node is called, `:erpc.call/5` by default (a test replaces it).

  The answers come back in node name order, and so do the two lists.
  """
  @spec call(atom(), [term()], keyword()) :: result()
  def call(function, args, opts \\ []) when is_atom(function) and is_list(args) do
    nodes = opts |> Keyword.get_lazy(:nodes, &alive_nodes/0) |> Enum.uniq() |> Enum.sort()
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    rpc = Keyword.get(opts, :rpc, &:erpc.call/5)

    nodes
    |> BoundedFanout.map(timeout, &ask(rpc, &1, function, args, timeout), &{&1, :unanswered})
    |> Enum.reduce(%{answers: [], unanswered: [], unsupported: []}, fn
      {node, {:ok, value}}, acc -> %{acc | answers: [{node, value} | acc.answers]}
      {node, :unsupported}, acc -> %{acc | unsupported: [node | acc.unsupported]}
      {node, :unanswered}, acc -> %{acc | unanswered: [node | acc.unanswered]}
    end)
    |> Map.new(fn {bucket, list} -> {bucket, Enum.reverse(list)} end)
  end

  defp ask(rpc, node, function, args, timeout) do
    {node, {:ok, rpc.(node, Malachi.Console.Reads, function, args, timeout)}}
  catch
    # `:erpc` raises a remote exception as `{:exception, reason, stacktrace}`, a remote `:undef` included
    :error, {:exception, :undef, [{Malachi.Console.Reads, ^function, _args, _location} | _stack]} ->
      {node, :unsupported}

    # the node asked is this one and the call ran in process (a test's stand-in does)
    :error, :undef ->
      {node, if(missing_read?(__STACKTRACE__, function), do: :unsupported, else: :unanswered)}

    _kind, _reason ->
      {node, :unanswered}
  end

  # An undefined function is the version mismatch only when it is the read itself that is missing.
  defp missing_read?([{Malachi.Console.Reads, function, _args, _location} | _stack], function), do: true
  defp missing_read?(_stacktrace, _function), do: false

  @doc "The nodes a fan-out asks by default: the alive members of the membership view, or this node alone."
  @spec alive_nodes() :: [node()]
  def alive_nodes do
    case Samples.membership() do
      {:ok, %{value: view}} ->
        view
        |> Membership.alive_members()
        |> Enum.map(fn {_name, node} -> node end)
        # the node answering is always asked, whatever its own view says of itself
        |> then(&Enum.uniq([node() | &1]))

      _none_or_unavailable ->
        [node()]
    end
  end

  @doc """
  The members a route adds when its data came from a fan-out: the nodes that did not answer and those that
  do not support the read, by name.
  """
  @spec members(result()) :: map()
  def members(%{unanswered: unanswered, unsupported: unsupported}) do
    %{
      "unanswered_nodes" => Enum.map(unanswered, &Atom.to_string/1),
      "unsupported_nodes" => Enum.map(unsupported, &Atom.to_string/1)
    }
  end

  @doc "Whether some node did not contribute its data, which makes a total a lower bound."
  @spec partial?(result()) :: boolean()
  def partial?(%{unanswered: unanswered, unsupported: unsupported}), do: unanswered != [] or unsupported != []
end
