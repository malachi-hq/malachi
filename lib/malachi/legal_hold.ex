defmodule Malachi.LegalHold do
  @moduledoc """
  The administrative entry point for the legal hold (#307): keep a topic's data, whatever its retention
  policy says, until the hold is released. The wire keys and `mix malachi.hold` are thin adapters over
  this module, so validation, the error vocabulary, the audit entry and the log line are written once.

  ## What a hold does

  The hold is the topic's own state, in its vnode's `Malachi.Metadata` (`{:set_topic_hold, topic, request}`),
  so it travels with the topic when a vnode split moves it. While it is in place:

    * retention expires none of the topic's segments, by age, by size or below a purged start
      (`Malachi.Cluster.Retention.plan/5`), and reports what it kept (`malachi_retention_held_bytes`);
    * the control plane refuses to delete the topic, to delete one of its segments and to move its logical
      start (`{:error, :legal_hold}`), so a purge (`Malachi.Purge`) and a topic delete (`Malachi.Topics`)
      are refused, and audited as refused.

  Writes and reads go on: a hold keeps data, it does not stop a topic. It covers segment data only; the
  control plane's own Raft log is snapshotted and truncated as always.

  Releasing the hold lets the next retention sweep expire whatever the policy would have expired meanwhile.

  ## Who and why

  The `actor` is who the request authenticated as (the session's user on the wire, `cli@<node>` from the
  CLI), never a value the request carries. The reason is the operator's: valid UTF-8 of 1 to 1024 bytes
  with no control or line-breaking character (`Malachi.Metadata.valid_hold_text?/1`), because it is
  written verbatim into the audit trail.

  ## Upgrades

  Holding needs machine version 11. Until every member of a topic's metadata group runs a release that
  implements it and the operator has lifted the version pin, the control plane refuses it identically on
  every member with `{:unsupported_command, key, 11, effective}`, which `reason_string/1` turns into
  "finish the rolling upgrade".
  """

  alias Malachi.AdminCall
  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.Metadata

  @typedoc "Why a hold request was refused. `reason_string/1` renders every one of them."
  @type reason ::
          :invalid_topic
          | :invalid_hold
          | :already_held
          | :not_held
          | :no_such_topic
          | :metadata_unavailable
          | :migrating
          | :timeout
          | {:unsupported_command, term(), non_neg_integer(), non_neg_integer()}
          | term()

  @doc """
  Places a legal hold on `topic` for `reason`, on behalf of `actor`. Refuses a topic already held
  (`:already_held`): changing the reason is a release and a new hold, each audited. Audited either way.
  """
  @spec set(String.t(), String.t(), AdminCall.actor()) :: :ok | {:error, reason()}
  def set(topic, reason, actor) do
    result =
      with :ok <- AdminCall.check_topic(topic),
           :ok <- check_text(reason),
           :ok <- check_text(actor) do
        submit(topic, %{reason: reason, actor: actor})
      end

    AdminCall.audit(:topic_hold_set, actor, "set_topic_hold", result, %{topic: topic, reason: reason}, &reason_string/1)
    AdminCall.log(result, :legal_hold_set, topic: topic, actor: actor, reason: reason)
    result
  end

  @doc "Releases the legal hold on `topic`, on behalf of `actor`. Refuses a topic not held. Audited either way."
  @spec release(String.t(), AdminCall.actor()) :: :ok | {:error, reason()}
  def release(topic, actor) do
    result =
      with :ok <- AdminCall.check_topic(topic), do: submit(topic, nil)

    AdminCall.audit(:topic_hold_released, actor, "release_topic_hold", result, %{topic: topic}, &reason_string/1)
    AdminCall.log(result, :legal_hold_released, topic: topic, actor: actor)
    result
  end

  @doc "The legal hold on `topic`, `nil` when it is not held, or why it could not be read. A read, not audited."
  @spec get(String.t()) :: {:ok, Metadata.legal_hold() | nil} | {:error, reason()}
  def get(topic) do
    with :ok <- AdminCall.check_topic(topic) do
      AdminCall.call(fn -> BrokerServer.legal_hold(DataPlaneRouter.shard_for(topic), topic) end)
    end
  end

  @doc """
  A stable, human-readable rendering of a refusal, the same on the wire and in the CLI. It starts with
  the reason's name, so a client can still branch on it.

  ## Examples

      iex> Malachi.LegalHold.reason_string(:already_held)
      "already_held: the topic is already under a legal hold; release it first to place another"

      iex> Malachi.LegalHold.reason_string(:no_such_topic)
      "no_such_topic"

  """
  @spec reason_string(reason()) :: String.t()
  def reason_string(:invalid_hold),
    do: "invalid_hold: the reason must be 1 to 1024 bytes of UTF-8 with no control or line-breaking character"

  def reason_string(:already_held),
    do: "already_held: the topic is already under a legal hold; release it first to place another"

  def reason_string(:not_held), do: "not_held: the topic is not under a legal hold"
  def reason_string(reason), do: AdminCall.reason_string(reason)

  defp submit(topic, request),
    do: AdminCall.call(fn -> BrokerServer.set_topic_hold(DataPlaneRouter.shard_for(topic), topic, request) end)

  # Checked here as well as in the vnode, so a request the vnode would refuse is answered without a Raft round.
  defp check_text(text), do: if(Metadata.valid_hold_text?(text), do: :ok, else: {:error, :invalid_hold})
end
