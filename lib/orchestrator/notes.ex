defmodule Orchestrator.Notes do
  use Ash.Domain

  resources do
    resource Orchestrator.Notes.Note
    resource Orchestrator.Events.Event
  end
end
