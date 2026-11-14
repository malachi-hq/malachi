defmodule Malachi.Topics do
  @moduledoc """
  The administrative entry point for deleting a topic. It audits and logs each request.

  A delete removes the topic, its ranges and its segments from the control plane, and the replicas'
  directories become orphans that `Malachi.Retention.OrphanSweeper` reclaims. A topic under a legal hold
  (`Malachi.LegalHold`, #307) is refused by its vnode itself, so the refusal holds whichever node the
  request reaches, and it is audited like any other.

  No wire key, CLI or dashboard route calls this yet: those belong to the console's mutation contract
  (#234). It exists so the delete has one place that audits it.
  """

  alias Malachi.AdminCall
  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter

  @typedoc "Why a delete was refused. `Malachi.AdminCall.reason_string/1` renders every one of them."
  @type reason :: :invalid_topic | :no_such_topic | :legal_hold | :migrating | :timeout | term()

  @doc "Deletes `topic` on behalf of `actor`. Audited either way."
  @spec delete(String.t(), AdminCall.actor()) :: :ok | {:error, reason()}
  def delete(topic, actor) do
    result =
      with :ok <- AdminCall.check_topic(topic) do
        AdminCall.call(fn -> BrokerServer.delete_topic(DataPlaneRouter.shard_for(topic), topic) end)
      end

    AdminCall.audit(:topic_deleted, actor, "delete_topic", result, %{topic: topic})
    AdminCall.log(result, :topic_deleted, topic: topic, actor: actor)
    result
  end
end
