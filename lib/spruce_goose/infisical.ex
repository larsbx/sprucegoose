defmodule SpruceGoose.Infisical do
  @moduledoc false

  def validate_config!(opts \\ []) do
    %{
      token: Keyword.get_lazy(opts, :token, fn -> System.fetch_env!("INFISICAL_TOKEN") end),
      project_id:
        Keyword.get_lazy(opts, :project_id, fn -> System.fetch_env!("INFISICAL_PROJECT_ID") end)
    }
  end

  def put_secret!(value, opts \\ []) when is_binary(value) and value != "" do
    config = validate_config!(opts)

    base_url =
      Keyword.get(opts, :base_url, System.get_env("INFISICAL_URL", "http://127.0.0.1:8088"))

    environment = Keyword.get(opts, :environment, System.get_env("INFISICAL_ENVIRONMENT", "dev"))

    secret_path =
      Keyword.get(opts, :secret_path, System.get_env("INFISICAL_SECRET_PATH", "/sprucegoose"))

    secret_name = Keyword.get(opts, :secret_name, "SPRUCE_GOOSE_MCP_ACCESS_TOKEN")
    request = Keyword.get(opts, :request, &Req.request/1)

    request_opts = [
      url: "#{String.trim_trailing(base_url, "/")}/api/v3/secrets/raw/#{secret_name}",
      headers: [authorization: "Bearer #{config.token}"],
      json: %{
        workspaceId: config.project_id,
        environment: environment,
        secretPath: secret_path,
        secretValue: value,
        type: "shared"
      }
    ]

    case request.(Keyword.put(request_opts, :method, :patch)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        case request.(Keyword.put(request_opts, :method, :post)) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status}} ->
            raise "Infisical secret creation failed (HTTP #{status})"

          {:error, reason} ->
            raise "Infisical secret creation failed: #{inspect(reason)}"
        end

      {:ok, %Req.Response{status: status}} ->
        raise "Infisical secret update failed (HTTP #{status})"

      {:error, reason} ->
        raise "Infisical secret update failed: #{inspect(reason)}"
    end
  end
end
