defmodule Malachi.Console.Samples do
  @moduledoc """
  The named reads of costly or hot state the console takes through `Malachi.Console.Sampler`, in one place
  so two routes that need the same state share its sample instead of each reading it.

  Each answers `{:ok, sample}`, `{:error, :unavailable}` when it could not be read and there is no earlier
  sample, or `:none` when this node does not run what it reads (a single node has no membership, an
  unsharded control plane no ring).
  """

  alias Malachi.Auth.LockoutManager
  alias Malachi.BrokerServer
  alias Malachi.Cluster.MembershipServer
  alias Malachi.Cluster.RaCluster
  alias Malachi.Cluster.ReplicationServer
  alias Malachi.Cluster.Scrubber
  alias Malachi.Console.Sampler
  alias Malachi.Consumer.GroupCoordinator
  alias Malachi.Metadata
  alias Malachi.ProducerDirectory

  # How long a read may take before the sample answers with what it had: under the second a console request
  # can reasonably wait, and well under a client's own timeout.
  @read_timeout_ms 1_000
  @sample_opts [timeout_ms: @read_timeout_ms]

  @typedoc "A sampled read."
  @type result :: {:ok, Sampler.sample()} | {:error, :unavailable} | :none

  @doc """
  The broker's merged metadata on this node (`Malachi.BrokerServer.metadata/1`): every topic, range and
  segment, as this node's cache of the control plane holds it.
  """
  @spec metadata() :: result()
  def metadata do
    if Process.whereis(Malachi.LogBroker),
      do: Sampler.fetch(:metadata, fn -> {:ok, BrokerServer.metadata(Malachi.LogBroker)} end, @sample_opts),
      else: :none
  end

  @doc "This node's SWIM view (`Malachi.Cluster.MembershipServer.view/2`)."
  @spec membership() :: result()
  def membership do
    if Process.whereis(Malachi.LogMembership),
      do:
        Sampler.fetch(
          :membership,
          fn -> {:ok, MembershipServer.view(Malachi.LogMembership, @read_timeout_ms)} end,
          @sample_opts
        ),
      else: :none
  end

  @doc """
  The state of a replicated store this node is a member of (`Malachi.LogRing`, `Malachi.LogLease`), by a
  consistent query to its leader.
  """
  @spec replicated(atom()) :: result()
  def replicated(cluster) do
    if RaCluster.local_member?({cluster, node()}),
      do: Sampler.fetch(cluster, fn -> RaCluster.query({cluster, node()}, @read_timeout_ms) end, @sample_opts),
      else: :none
  end

  @doc """
  What the consumer group coordinator registered as `name` on this node holds
  (`Malachi.Consumer.GroupCoordinator.describe/2`). The coordinator serves its members' joins, heartbeats and
  commits, so it is read through the sampler, once per interval however many look.
  """
  @spec group_coordinator(atom()) :: result()
  def group_coordinator(name) do
    if Process.whereis(name),
      do:
        Sampler.fetch(
          {:group_coordinator, name},
          fn -> {:ok, GroupCoordinator.describe(name, @read_timeout_ms)} end,
          @sample_opts
        ),
      else: :none
  end

  @doc """
  The producer streams open on this node, as their connections describe them
  (`Malachi.ProducerDirectory.list/1`, which asks each connection between its frames and waits at most
  `timeout_ms`). The connections are the produce path itself, so they are asked once per interval however
  many operators page through the listing.
  """
  @spec producers(non_neg_integer()) :: result()
  def producers(timeout_ms),
    do: Sampler.fetch(:producers, fn -> {:ok, ProducerDirectory.list(timeout_ms)} end, @sample_opts)

  @doc """
  The accounts locked out across the cluster, from this node's replica of the lockout store
  (`Malachi.Auth.LockoutManager.locked_accounts/0`): a query to the replica's own process, so it is bounded
  here rather than waited for.
  """
  @spec lockouts() :: result()
  def lockouts, do: Sampler.fetch(:lockouts, &LockoutManager.locked_accounts/0, @sample_opts)

  @doc """
  The segments this node's scrubber found damaged (`Malachi.Cluster.Scrubber.damaged/1`). The scrubber
  verifies a whole segment inside its own process, so the call can wait behind a scan: the sample is
  bounded, and an overrun keeps the last list.
  """
  @spec damaged() :: result()
  def damaged do
    if Process.whereis(Malachi.LogScrubber),
      do: Sampler.fetch(:damaged, fn -> {:ok, Scrubber.damaged(Malachi.LogScrubber)} end, @sample_opts),
      else: :none
  end

  @doc """
  The segments whose copy on this node failed in storage and will never be written again
  (`Malachi.Cluster.ReplicationServer.failed_segments/3`, a lookup in the failure latch with no disk
  access), asked of each replication server of this node about the segments it holds by the metadata.

  The list is only as current as this node's metadata it asked about: a segment registered after that
  metadata was never asked about, and a copy of it that failed would be missing from the list. So a list built
  from another metadata sample than this node's current one counts as old and is taken again, on the
  sampler's usual terms (once per interval, not again soon after a read that failed), and a list that does
  not match the current metadata, or a metadata sample that is stale, is answered stale, which the console
  shows as a copy whose state is unknown rather than as a healthy one. A console on another node renders
  segments from its own metadata, which this does not compare against.
  """
  @spec failed() :: result()
  def failed do
    case metadata() do
      {:ok, %{value: %Metadata{} = metadata, sampled_at: basis, stale: metadata_stale}} ->
        read = fn ->
          with {:ok, failed} <- read_failed(metadata), do: {:ok, {failed, basis}}
        end

        current? = fn {_failed, built_from} -> built_from == basis end

        :failed
        |> Sampler.fetch(read, Keyword.put(@sample_opts, :current?, current?))
        |> current_as_of(basis, metadata_stale)

      other ->
        other
    end
  end

  # A list built from other metadata than the caller's (an older sample, or a read another caller started
  # and this one joined) does not answer about the caller's segments.
  defp current_as_of({:ok, %{value: {failed, built_from}} = sample}, basis, metadata_stale),
    do: {:ok, %{sample | value: failed, stale: sample.stale or metadata_stale or built_from != basis}}

  defp current_as_of({:error, :unavailable} = unavailable, _basis, _metadata_stale), do: unavailable

  defp read_failed(metadata) do
    metadata.segments
    |> Map.values()
    |> Enum.flat_map(fn segment -> for ref <- segment.replica_set, local?(ref), do: {ref, segment.id} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {ref, ids}, {:ok, acc} ->
      case ReplicationServer.failed_segments(ref, ids, @read_timeout_ms) do
        {:ok, failed} -> {:cont, {:ok, MapSet.union(acc, failed)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A replica reference that names a replication server on this node.
  defp local?({_name, node}) when is_atom(node), do: node == node()
  defp local?(pid) when is_pid(pid), do: node(pid) == node()
  defp local?(_other), do: false
end
