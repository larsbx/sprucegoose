ExUnit.start()

defmodule SpruceGoose.TestDatabaseConfigTest do
  use ExUnit.Case, async: true

  @keys ~w(DATABASE DATABASE_USERNAME DATABASE_PASSWORD DATABASE_HOSTNAME DATABASE_PORT)
  @config Path.expand("../config/test.exs", __DIR__)
  @reader """
  config = Config.Reader.read!(hd(System.argv()), env: :test)
  repo = config |> Keyword.fetch!(:spruce_goose) |> Keyword.fetch!(SpruceGoose.Repo)
  IO.write(repo |> :erlang.term_to_binary() |> Base.encode64())
  """

  defp read_config(overrides) do
    env =
      Enum.map(@keys, fn key ->
        {"SPRUCE_GOOSE_TEST_" <> key, Map.get(overrides, key)}
      end)

    System.cmd("elixir", ["-e", @reader, @config], env: env, stderr_to_stdout: true)
  end

  defp repo_config(overrides) do
    {output, 0} = read_config(overrides)
    output |> Base.decode64!() |> :erlang.binary_to_term()
  end

  test "absent and exported empty values use the same defaults" do
    defaults = repo_config(%{})
    assert defaults[:database] == "spruce_goose_test"
    assert defaults[:username] == "postgres"
    assert defaults[:hostname] == "localhost"
    assert defaults[:port] == 5432
    refute Keyword.has_key?(defaults, :password)

    for key <- @keys do
      assert repo_config(%{key => ""}) == defaults
    end

    assert repo_config(Map.new(@keys, &{&1, ""})) == defaults
  end

  test "nonempty overrides are preserved including password whitespace" do
    repo =
      repo_config(%{
        "DATABASE" => "spruce_goose_ci_123",
        "DATABASE_USERNAME" => "isolated_user",
        "DATABASE_HOSTNAME" => "127.0.0.1",
        "DATABASE_PORT" => "55432",
        "DATABASE_PASSWORD" => " test-only password "
      })

    assert repo[:database] == "spruce_goose_ci_123"
    assert repo[:username] == "isolated_user"
    assert repo[:hostname] == "127.0.0.1"
    assert repo[:port] == 55432
    assert repo[:password] == " test-only password "
  end

  test "invalid ports refuse during configuration" do
    for port <- ["abc", "5432suffix", "0", "-1", "65536", " 5432"] do
      {output, status} = read_config(%{"DATABASE_PORT" => port})
      assert status != 0
      assert output =~ "SPRUCE_GOOSE_TEST_DATABASE_PORT must be an integer in 1..65535"
    end

    assert repo_config(%{"DATABASE_PORT" => "1"})[:port] == 1
    assert repo_config(%{"DATABASE_PORT" => "65535"})[:port] == 65_535
  end
end
