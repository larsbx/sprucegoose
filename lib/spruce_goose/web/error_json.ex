defmodule SpruceGoose.Web.ErrorJSON do
  @moduledoc """
  Renders errors as JSON for the MCP/OAuth endpoint.

  Deliberately terse: this endpoint serves machine clients, so error bodies
  carry a status message and nothing about internal structure.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
