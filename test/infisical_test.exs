defmodule SpruceGoose.InfisicalTest do
  use ExUnit.Case, async: true

  test "validates injected Infisical credentials before minting" do
    assert %{token: "token", project_id: "project"} =
             SpruceGoose.Infisical.validate_config!(token: "token", project_id: "project")
  end

  test "updates an existing secret without exposing its value" do
    parent = self()

    request = fn opts ->
      send(parent, {:request, opts})
      {:ok, %Req.Response{status: 200}}
    end

    assert :ok =
             SpruceGoose.Infisical.put_secret!("minted-token",
               token: "infisical-token",
               project_id: "project-id",
               request: request
             )

    assert_receive {:request, opts}
    assert opts[:method] == :patch
    assert opts[:json].secretValue == "minted-token"
    assert opts[:headers] == [authorization: "Bearer infisical-token"]
  end

  test "creates the secret when it does not exist" do
    parent = self()

    request = fn opts ->
      send(parent, {:request, opts})
      status = if opts[:method] == :patch, do: 404, else: 200
      {:ok, %Req.Response{status: status}}
    end

    assert :ok =
             SpruceGoose.Infisical.put_secret!("minted-token",
               token: "infisical-token",
               project_id: "project-id",
               request: request
             )

    assert_receive {:request, patch}
    assert_receive {:request, post}
    assert patch[:method] == :patch
    assert post[:method] == :post
  end

  test "fails closed when Infisical rejects the update" do
    request = fn _opts -> {:ok, %Req.Response{status: 401}} end

    assert_raise RuntimeError, "Infisical secret update failed (HTTP 401)", fn ->
      SpruceGoose.Infisical.put_secret!("minted-token",
        token: "bad-token",
        project_id: "project-id",
        request: request
      )
    end
  end
end
