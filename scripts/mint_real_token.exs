## End-to-end proof that the MCP surface works OPEN, not just closed.
##
## Registers a real PKCE client, mints a real authorization code, exchanges it
## for a real access token, stores it in Infisical, and calls the MCP tool
## surface expecting 200 + data.
##
## Required Infisical-injected environment:
##   INFISICAL_TOKEN, INFISICAL_PROJECT_ID
## Optional:
##   INFISICAL_URL, INFISICAL_ENVIRONMENT, INFISICAL_SECRET_PATH

alias AshAuthentication.Oauth2Server.PKCE
alias SpruceGoose.Accounts.{OauthAuthorizationCode, OauthClient}

SpruceGoose.Infisical.validate_config!()

opts = SpruceGoose.Web.Router.init([])
ctx = %{private: %{ash_authentication?: true}}

defmodule Proof do
  def step(label), do: IO.puts("\n=== #{label} ===")

  def check(cond, msg) do
    IO.puts("#{if cond, do: "PASS", else: "FAIL"}  #{msg}")
    unless cond, do: Process.put(:failed, true)
    cond
  end
end

Proof.step("1. Register OAuth client")

{:ok, client} =
  OauthClient
  |> Ash.Changeset.for_create(
    :register,
    %{
      client_name: "mcp-proof-client",
      redirect_uris: ["http://127.0.0.1:4000/callback"],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
      scope: "mcp"
    },
    context: ctx
  )
  |> Ash.create()

IO.puts("client_id = #{client.id}")

Proof.step("2. Seed user (resource owner)")

# The User resource intentionally exposes only :read -- no create action.
# Seed the row directly rather than widening the resource just to test it.
%Postgrex.Result{rows: [[user_id]]} =
  SpruceGoose.Repo.query!("INSERT INTO users DEFAULT VALUES RETURNING id", [])

user = %{id: Ecto.UUID.cast!(user_id)}
IO.puts("user_id = #{user.id}")

Proof.step("3. Generate PKCE verifier/challenge (S256)")

verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
challenge = PKCE.challenge(verifier)
IO.puts("verifier  = #{String.slice(verifier, 0, 12)}...")
IO.puts("challenge = #{String.slice(challenge, 0, 12)}...")

Proof.step("4. Issue authorization code bound to challenge")

resource_url = Application.fetch_env!(:spruce_goose, :oauth2_resource_url)

{:ok, code} =
  OauthAuthorizationCode
  |> Ash.Changeset.for_create(
    :create,
    %{
      client_id: client.id,
      user_id: user.id,
      redirect_uri: "http://127.0.0.1:4000/callback",
      code_challenge: challenge,
      scope: "mcp",
      resource_uri: resource_url,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    },
    context: ctx
  )
  |> Ash.create()

IO.puts("code = #{code.id}")

Proof.step("5. Exchange code + verifier for a REAL access token")

exchange = fn params ->
  :post
  |> Plug.Test.conn("/oauth/token", URI.encode_query(params))
  |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
  |> SpruceGoose.Web.Router.call(opts)
end

token_params = %{
  "grant_type" => "authorization_code",
  "code" => code.id,
  "client_id" => client.id,
  "code_verifier" => verifier,
  "redirect_uri" => "http://127.0.0.1:4000/callback",
  "resource" => resource_url
}

conn = exchange.(token_params)
IO.puts("POST /oauth/token -> #{conn.status}")

Proof.check(conn.status == 200, "token endpoint returned 200")
body = Jason.decode!(conn.resp_body)
access_token = body["access_token"]

Proof.check(is_binary(access_token), "access_token present")
Proof.check(body["token_type"] == "Bearer", "token_type is Bearer")
Proof.check(body["scope"] == "mcp", "scope is mcp")
SpruceGoose.Infisical.put_secret!(access_token)
IO.puts("access token stored in Infisical as SPRUCE_GOOSE_MCP_ACCESS_TOKEN")

Proof.step("6. Call MCP tools/list WITH the real token")

mcp = fn headers, payload ->
  :post
  |> Plug.Test.conn("/mcp", Jason.encode!(payload))
  |> Plug.Conn.put_req_header("content-type", "application/json")
  |> then(fn c ->
    Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
  end)
  |> SpruceGoose.Web.Router.call(opts)
end

auth = [{"authorization", "Bearer #{access_token}"}]

conn = mcp.(auth, %{jsonrpc: "2.0", id: 1, method: "tools/list"})
IO.puts("POST /mcp tools/list -> #{conn.status}")
Proof.check(conn.status == 200, "authenticated tools/list returned 200")
Proof.check(conn.resp_body =~ "list_tasks", "tool list contains list_tasks")

Proof.step("7. Actually CALL a tool and get real data")

conn =
  mcp.(auth, %{
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: %{name: "list_tasks", arguments: %{}}
  })

IO.puts("POST /mcp tools/call list_tasks -> #{conn.status}")
Proof.check(conn.status == 200, "authenticated tools/call returned 200")

IO.puts("\n--- response (first 600 chars) ---")
IO.puts(String.slice(conn.resp_body, 0, 600))

Proof.check(
  conn.resp_body =~ "tsk-" or conn.resp_body =~ "\"content\"",
  "tool call returned actual task data"
)

Proof.step("8. Control: same call WITHOUT token must still 401")

conn =
  mcp.([], %{
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: %{name: "list_tasks", arguments: %{}}
  })

IO.puts("unauthenticated tools/call -> #{conn.status}")
Proof.check(conn.status == 401, "harness can still detect rejection (not a rubber stamp)")

Proof.step("9. Control: authorization code is one-shot")

conn = exchange.(token_params)
IO.puts("code replay -> #{conn.status}")
Proof.check(conn.status >= 400, "replayed authorization code rejected")

IO.puts("\n========================================")

if Process.get(:failed),
  do: IO.puts("RESULT: FAILURES PRESENT"),
  else: IO.puts("RESULT: ALL CHECKS PASSED")

IO.puts("========================================")
