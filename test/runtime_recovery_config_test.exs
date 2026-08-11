defmodule SpruceGoose.RuntimeRecoveryConfigTest do
  use ExUnit.Case, async: true

  defp read_runtime(extra_env, opts \\ []) do
    code = """
    config = Config.Reader.read!(\"config/runtime.exs\", env: :prod)
    app = Keyword.fetch!(config, :spruce_goose)
    oban = Keyword.fetch!(app, Oban)
    IO.puts(\"queues=\#{inspect(Keyword.fetch!(oban, :queues))}\")
    IO.puts(\"plugins=\#{inspect(Keyword.fetch!(oban, :plugins))}\")
    IO.puts(\"expected_genesis_actor=\#{Keyword.fetch!(app, :expected_genesis_actor)}\")
    IO.puts(\"oauth_client_actor_bindings=\#{inspect(Keyword.get(app, :oauth_client_actor_bindings, %{}))}\")
    """

    genesis_env =
      if Keyword.get(opts, :include_genesis?, true) do
        [{"SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR", "configured-genesis"}]
      else
        []
      end

    System.cmd("elixir", ["-e", code],
      env:
        [
          {"DATABASE_URL", "ecto://rehearsal:rehearsal@127.0.0.1/rehearsal"},
          {"TOKEN_SIGNING_SECRET", String.duplicate("x", 64)},
          {"SPRUCE_GOOSE_MCP_ENABLED", "false"},
          {"OUTBOX_DISPATCHER_ENABLED", "false"}
        ] ++ genesis_env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  test "recovery mode can disable every Oban queue and plugin" do
    {output, status} = read_runtime([{"SPRUCE_GOOSE_OBAN_ENABLED", "false"}])
    assert status == 0, output
    assert output =~ "queues=false"
    assert output =~ "plugins=false"
    assert output =~ "expected_genesis_actor=configured-genesis"
  end

  test "production runtime refuses to start without an expected Genesis actor" do
    {output, status} =
      read_runtime([{"SPRUCE_GOOSE_OBAN_ENABLED", "false"}], include_genesis?: false)

    assert status != 0
    assert output =~ "SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR is required in production"
  end

  test "MCP production runtime refuses to start without immutable OAuth actor bindings" do
    {output, status} =
      read_runtime([
        {"SPRUCE_GOOSE_MCP_ENABLED", "true"},
        {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
        {"SECRET_KEY_BASE", String.duplicate("s", 64)},
        {"OAUTH2_SIGNING_SECRET", String.duplicate("o", 64)}
      ])

    assert status != 0
    assert output =~ "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS is required when MCP is enabled"
  end

  test "MCP production runtime parses immutable OAuth client ID to actor ID bindings" do
    client_id = "018f1234-5678-7abc-8def-0123456789ab"
    actor_id = "123e4567-e89b-42d3-a456-426614174000"

    {output, status} =
      read_runtime([
        {"SPRUCE_GOOSE_MCP_ENABLED", "true"},
        {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
        {"SECRET_KEY_BASE", String.duplicate("s", 64)},
        {"OAUTH2_SIGNING_SECRET", String.duplicate("o", 64)},
        {"SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS", "#{client_id}=#{actor_id}"}
      ])

    assert status == 0, output
    assert output =~ ~s(oauth_client_actor_bindings=%{"#{client_id}" => "#{actor_id}"})
  end

  test "MCP production runtime rejects malformed and duplicate OAuth bindings" do
    client_id = "018f1234-5678-7abc-8def-0123456789ab"
    actor_id = "123e4567-e89b-42d3-a456-426614174000"

    for {bindings, expected_error} <- [
          {"caller-name=#{actor_id}", "canonical lowercase UUID=UUID pairs"},
          {"#{client_id}=#{actor_id},#{client_id}=#{actor_id}", "duplicate OAuth client ID"}
        ] do
      {output, status} =
        read_runtime([
          {"SPRUCE_GOOSE_MCP_ENABLED", "true"},
          {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
          {"SECRET_KEY_BASE", String.duplicate("s", 64)},
          {"OAUTH2_SIGNING_SECRET", String.duplicate("o", 64)},
          {"SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS", bindings}
        ])

      assert status != 0
      assert output =~ expected_error
    end
  end

  test "outbox dispatch refuses to start while Oban is disabled" do
    {output, status} =
      read_runtime([
        {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
        {"OUTBOX_DISPATCHER_ENABLED", "true"},
        {"OUTBOX_HANDLER", "SpruceGoose.Outbox.TestHandler"}
      ])

    assert status != 0
    assert output =~ "OUTBOX_DISPATCHER_ENABLED requires SPRUCE_GOOSE_OBAN_ENABLED"
  end
end
