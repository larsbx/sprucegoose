defmodule SpruceGoose.AgentHooks.OutboxHook do
  @moduledoc "Schedule triage durably; never call the agent during outbox delivery."
  alias SpruceGoose.AgentHooks.{Config, Store}
  alias SpruceGoose.Outbox.Event

  def deliver(%Event{event_type: "inbox.captured"} = event) do
    if Config.enabled?() do
      with {:ok, _run_id} <- Store.schedule(event),
           do: :ok
    else
      :ok
    end
  end

  def deliver(%Event{}), do: :ok
end
