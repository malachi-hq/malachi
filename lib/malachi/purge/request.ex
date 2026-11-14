defmodule Malachi.Purge.Request do
  @moduledoc """
  A data subject's request that a purge answers (#308): the reference of the request and the reason, as
  the operator states them. `Malachi.Purge.purge/4` records it in the audit trail before it applies the
  purge, and the purge's own audit entry carries the same id, so the request and what was done about it
  can be read back together. One request that covers several topics is several purges with the same id.

  A purge is a **logical purge**: every reader is clamped past the purged records, which stay on disk, on
  every replica, until retention removes their whole segment. See the guide, "Data subject requests".

  ## What the fields may hold

  Both fields are kept in the audit trail, which nothing purges, so neither may identify the data subject:
  never their name, e-mail, document number, or a hash of any of them (a hash of a low-entropy identifier
  is recovered by brute force). The id is the reference of the request in the controller's own system,
  such as a ticket number; the reason says why, in words that name no one. The same holds for the topic
  and the consumer group a purge names: they are written to the audit trail and the logs too, so a topic or
  group kept per subject must have an opaque name.

    * `id`: 1 to 128 bytes of printable ASCII (`0x21..0x7E`), so no whitespace.
    * `reason`: 1 to 512 bytes of valid UTF-8 with no control character (Unicode category Cc), no format
      character (Cf: bidirectional overrides, zero-width characters) and no line or paragraph separator
      (Zl, Zp), so a reason cannot break, forge or disguise an audit line.
  """

  @enforce_keys [:id, :reason]
  defstruct [:id, :reason]

  @typedoc "A validated request: an opaque reference and a reason, both within their bounds."
  @type t :: %__MODULE__{id: String.t(), reason: String.t()}

  @max_id_bytes 128
  @max_reason_bytes 512

  @doc """
  Validates a request's id and reason. Anything outside the bounds above, or not a binary, is refused.

      iex> Malachi.Purge.Request.new("DSR-2026-0042", "LGPD art. 18 request")
      {:ok, %Malachi.Purge.Request{id: "DSR-2026-0042", reason: "LGPD art. 18 request"}}
      iex> Malachi.Purge.Request.new("DSR 42", "reason")
      {:error, :invalid_request}
      iex> Malachi.Purge.Request.new("DSR-42", "line\\nbreak")
      {:error, :invalid_request}
  """
  @spec new(term(), term()) :: {:ok, t()} | {:error, :invalid_request}
  def new(id, reason) do
    if valid_id?(id) and valid_reason?(reason),
      do: {:ok, %__MODULE__{id: id, reason: reason}},
      else: {:error, :invalid_request}
  end

  @doc "The bounds `new/2` applies, for the refusal message: `{max id bytes, max reason bytes}`."
  @spec limits() :: {pos_integer(), pos_integer()}
  def limits, do: {@max_id_bytes, @max_reason_bytes}

  defp valid_id?(id) when is_binary(id) and byte_size(id) in 1..@max_id_bytes,
    do: printable_ascii?(id)

  defp valid_id?(_id), do: false

  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(<<byte, rest::binary>>) when byte in 0x21..0x7E, do: printable_ascii?(rest)
  defp printable_ascii?(_other), do: false

  @doc """
  Whether `text` is valid UTF-8 with no control character (Cc), no format character (Cf) and no line or
  paragraph separator (Zl, Zp): text that can sit in an audit entry or a log line without breaking it,
  forging another, or reading differently from what it holds. The reason obeys it, and so does a consumer
  group name a purge names (`Malachi.Purge`).

      iex> Malachi.Purge.Request.safe_text?("billing-2026")
      true
      iex> Malachi.Purge.Request.safe_text?("bill\\u202Eing")
      false
  """
  @spec safe_text?(binary()) :: boolean()
  def safe_text?(text) when is_binary(text),
    do: String.valid?(text) and not Regex.match?(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, text)

  defp valid_reason?(reason) when is_binary(reason) and byte_size(reason) in 1..@max_reason_bytes,
    do: safe_text?(reason)

  defp valid_reason?(_reason), do: false
end
