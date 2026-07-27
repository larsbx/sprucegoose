defmodule SpruceGoose.Notes do
  use Ash.Domain

  resources do
    resource SpruceGoose.Notes.Note
    resource SpruceGoose.Events.Event
  end
end
