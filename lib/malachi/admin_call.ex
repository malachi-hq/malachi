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
    {status, metadata} =
      case result do
        {:error, reason} -> {:failure, Map.put(metadata, :reason, render.(reason))}
        _ok -> {:success, metadata}
      end

    AuditLog.log_event(event, %{username: actor}, action, status, metadata)
    :ok
  end

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
