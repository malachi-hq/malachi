defmodule Malachi.KafkaSpike.ErrorCodes do
  @moduledoc """
  The Kafka error codes the spike answers with, and the one place a Malachi error becomes one of them.

  Every reason the spike can meet has its own clause in `from_reason/1`, so the code a client sees decides
  how it retries (a retriable `NOT_LEADER_OR_FOLLOWER` against a fatal `UNKNOWN_SERVER_ERROR`), and that
  is part of what the spike observes. A reason with no clause is answered `UNKNOWN_SERVER_ERROR` and
  logged, so a gap in the table shows up instead of passing for a server fault.
  """
  require Logger
  alias Malachi.I18n

  @codes %{
    unknown_server_error: -1,
    none: 0,
    offset_out_of_range: 1,
    corrupt_message: 2,
    unknown_topic_or_partition: 3,
    leader_not_available: 5,
    not_leader_or_follower: 6,
    request_timed_out: 7,
    broker_not_available: 8,
    not_enough_replicas: 19,
    kafka_storage_error: 56,
    unsupported_version: 35,
    invalid_request: 42,
    unsupported_for_message_format: 43,
    unsupported_compression_type: 76,
    invalid_record: 87
  }

  @typedoc "A Kafka error name the spike knows."
  @type name ::
          :unknown_server_error
          | :none
          | :offset_out_of_range
          | :corrupt_message
          | :unknown_topic_or_partition
          | :leader_not_available
          | :not_leader_or_follower
          | :request_timed_out
          | :broker_not_available
          | :not_enough_replicas
          | :kafka_storage_error
          | :unsupported_version
          | :invalid_request
          | :unsupported_for_message_format
          | :unsupported_compression_type
          | :invalid_record

  @doc "The wire code of a Kafka error name."
  @spec code(name()) :: integer()
  def code(name), do: Map.fetch!(@codes, name)

  @doc """
  The Kafka error name for a reason the spike met: a Malachi broker error, or one of the spike's own
  refusals of a request or a record.
  """
  @spec from_reason(term()) :: name()
  # Malachi broker and read errors.
  def from_reason(:no_such_topic), do: :unknown_topic_or_partition
  def from_reason(:no_such_range), do: :unknown_topic_or_partition
  def from_reason(:not_primary), do: :not_leader_or_follower
  def from_reason(:no_quorum), do: :not_enough_replicas
  # A storage failure (a full or failing volume) as the store reports it, bare or tagged
  def from_reason(posix) when posix in [:enospc, :eio, :eacces], do: :kafka_storage_error
  def from_reason({:storage, _posix}), do: :kafka_storage_error
  def from_reason(:timeout), do: :request_timed_out
  def from_reason(:broker_down), do: :broker_not_available
  def from_reason(:invalid_position), do: :offset_out_of_range
  def from_reason(:metadata_unavailable), do: :leader_not_available
  def from_reason(:unavailable), do: :leader_not_available
  # A topic split into several ranges is no longer one partition with stable offsets (see `Topic`).
  def from_reason(:split_topic), do: :unknown_topic_or_partition
  # The spike's refusals of a batch.
  def from_reason(:corrupt_batch), do: :corrupt_message
  def from_reason(:compressed_batch), do: :unsupported_compression_type
  def from_reason(:unsupported_magic), do: :unsupported_for_message_format
  def from_reason(:transactional_batch), do: :invalid_record
  def from_reason(:control_batch), do: :invalid_record
  def from_reason(:transactions_unsupported), do: :invalid_request
  # The spike's refusals of a record that Malachi's record cannot represent (requirements for #167).
  def from_reason(:null_value), do: :invalid_record
  def from_reason(:null_header_value), do: :invalid_record
  def from_reason(:negative_timestamp), do: :invalid_record

  def from_reason(reason) do
    Logger.warning(I18n.t(:kafka_spike_unmapped_error, reason: inspect(reason)))
    :unknown_server_error
  end

  @doc "`code/1` of `from_reason/1`."
  @spec code_for(term()) :: integer()
  def code_for(reason), do: reason |> from_reason() |> code()
end
