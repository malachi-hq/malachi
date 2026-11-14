defmodule Malachi.AdminCall do
  @moduledoc """
  What every administrative service shares: the call into a broker that must not take its caller down,
  the topic check, the audit entry and the I18n log line written for each request, and the rendering of
  the refusals every service can meet. `Malachi.Policies` and `Malachi.Purge` are built on it, so a
  timeout, a dead broker or an unfinished upgrade reads the same whichever request met it.
  """

  require Logger

  alias Malachi.AuditLog
  alias Malachi.Cluster.MachineVersion
  alias Malachi.I18n
  alias Malachi.Metadata

  @typedoc "Who asked for a change, as the audit log records it: a username, or `cli@<node>`."
  @type actor :: String.t()

  @typedoc "What an administrative request answers: `:ok`, `{:ok, value}` or `{:error, reason}`."
  @type result :: :ok | {:ok, term()} | {:error, term()}

  @doc """
  Runs `fun`, a call into a broker. A broker that does not answer is an error to report and audit, never
  an exit that takes the caller (a client connection, a dashboard request) down with it. A timed out
  request may still commit: the control plane answered nobody, and the operator is told to read it back.
  """
  @spec call((-> result)) :: result
  def call(fun) do
    fun.()
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, reason -> {:error, {:broker_unavailable, reason}}
  end

  # A topic name is a range log directory's name, so the file system's NAME_MAX bounds every topic that can
  # hold data; a longer name cannot exist, and refusing it here keeps an arbitrary 16 MiB frame out of the
  # audit entry and the log line.
  @max_topic_bytes 255

  @doc """
  `:ok` for a topic name a request can carry, `{:error, :invalid_topic}` otherwise: the control plane's own
  allowlist (`Malachi.Metadata.valid_topic_name?/1`) and at most 255 bytes. Checked before anything is
  audited or logged, so a name that reaches the audit trail or a log line never carries a newline, a
  control character or an `I18n` placeholder.

      iex> Malachi.AdminCall.check_topic("events")
      :ok
      iex> Malachi.AdminCall.check_topic("a\\n%{actor}")
      {:error, :invalid_topic}
  """
  @spec check_topic(term()) :: :ok | {:error, :invalid_topic}
  def check_topic(topic) do
    if Metadata.valid_topic_name?(topic) and byte_size(topic) <= @max_topic_bytes,
      do: :ok,
      else: {:error, :invalid_topic}
  end

  @doc """
  Writes the audit entry for one request: `:success` with `metadata` when `result` is `:ok` or
  `{:ok, _}`, `:failure` with the refusal rendered by `render` otherwise.
  """
  @spec audit(atom(), actor(), String.t(), result, map(), (term() -> String.t())) :: :ok
  def audit(event, actor, action, result, metadata, render \\ &reason_string/1) do
    {status, metadata} = entry(result, metadata, render)
    AuditLog.log_event(event, %{username: actor}, action, status, metadata)
    :ok
  end

  @doc """
  Like `audit/6`, for an entry the caller must not act without: it answers `:ok` only once the entry is
  written out (`Malachi.AuditLog.log_event_durably/6`), and `{:error, :audit_unavailable}` when the audit
  log is not running, does not answer within `timeout`, fails while writing it, or, with file output,
  has no file to write it to.
  """
  @spec audit_durably(atom(), actor(), String.t(), result, map(), timeout()) :: :ok | {:error, :audit_unavailable}
  def audit_durably(event, actor, action, result, metadata, timeout \\ 5_000) do
    {status, metadata} = entry(result, metadata, &reason_string/1)

    case AuditLog.log_event_durably(event, %{username: actor}, action, status, metadata, timeout) do
      :ok -> :ok
      {:error, _not_written} -> {:error, :audit_unavailable}
    end
  catch
    :exit, _reason -> {:error, :audit_unavailable}
  end

  defp entry({:error, reason}, metadata, render), do: {:failure, Map.put(metadata, :reason, render.(reason))}
  defp entry(_ok, metadata, _render), do: {:success, metadata}

  @doc """
  How a refused field is recorded in an audit entry: by its size, never by its bytes, so an arbitrary
  value from a frame (a newline, a placeholder, 16 MiB) never reaches the audit trail.

      iex> Malachi.AdminCall.describe_invalid("a\\n%{actor}")
      "<10 bytes>"
      iex> Malachi.AdminCall.describe_invalid(nil)
      "<none>"
      iex> Malachi.AdminCall.describe_invalid(42)
      "<not a string>"
  """
  @spec describe_invalid(term()) :: String.t()
  def describe_invalid(value) when is_binary(value), do: "<#{byte_size(value)} bytes>"
  def describe_invalid(nil), do: "<none>"
  def describe_invalid(_value), do: "<not a string>"

  @doc """
  A topic as an audit entry records it: as it is when `check_topic/1` accepts it, by its size otherwise.

      iex> Malachi.AdminCall.describe_topic("events")
      "events"
      iex> Malachi.AdminCall.describe_topic("a/b")
      "<3 bytes>"
  """
  @spec describe_topic(term()) :: String.t()
  def describe_topic(topic), do: if(check_topic(topic) == :ok, do: topic, else: describe_invalid(topic))

  @doc """
  A free-text field an audit entry records (a policy name, say): as it is when it is `nil` or at most
  `max_bytes` of `safe_text?/1` text, by its size otherwise, so a request's bytes never reach the trail
  unchecked.

      iex> Malachi.AdminCall.describe_text("retain-7d", 255)
      "retain-7d"
      iex> Malachi.AdminCall.describe_text("x\\n%{actor}", 255)
      "<10 bytes>"
  """
  @spec describe_text(term(), pos_integer()) :: String.t() | nil
  def describe_text(nil, _max_bytes), do: nil

  def describe_text(text, max_bytes) when is_binary(text) and byte_size(text) in 1..max_bytes//1,
    do: if(safe_text?(text), do: text, else: describe_invalid(text))

  def describe_text(text, _max_bytes), do: describe_invalid(text)

  @doc """
  Whether `text` is valid UTF-8 with no control character (Cc), no format character (Cf) and no line or
  paragraph separator (Zl, Zp): text that can sit in an audit entry or a log line without breaking it,
  forging another, or reading differently from what it holds. Spaces are allowed.

      iex> Malachi.AdminCall.safe_text?("billing team")
      true
      iex> Malachi.AdminCall.safe_text?("bill\\u202Eing")
      false
  """
  @spec safe_text?(binary()) :: boolean()
  def safe_text?(text) when is_binary(text),
    do: String.valid?(text) and not Regex.match?(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, text)

  @doc "Logs the I18n line `key` for a request that succeeded; a refusal is in the audit log and the reply."
  @spec log(result, atom(), keyword()) :: :ok
  def log({:error, _reason}, _key, _bindings), do: :ok
  def log(_ok, key, bindings), do: Logger.info(I18n.t(key, bindings))

  @doc """
  The rendering of the refusals any administrative request can meet. It starts with the reason's name,
  so a client can still branch on it; services render their own reasons first and fall back to this.

  ## Examples

      iex> Malachi.AdminCall.reason_string(:invalid_topic)
      "invalid_topic"

  """
  @spec reason_string(term()) :: String.t()
  def reason_string({:unsupported_command, _key, introduced, effective}),
    do: "unsupported_command: " <> MachineVersion.upgrade_pending_message(introduced, effective)

  def reason_string(:timeout),
    do: "timeout: the control plane did not answer in time; the change may still apply, read it back before retrying"

  def reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_string(reason), do: inspect(reason)
end
