defmodule SpruceGoose.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        SpruceGoose.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:spruce_goose, :token_signing_secret)
  end

  def secret_for([:issuer_url], SpruceGoose.Oauth2Server, _opts, _context) do
    Application.fetch_env(:spruce_goose, :oauth2_issuer_url)
  end

  def secret_for([:resource_url], SpruceGoose.Oauth2Server, _opts, _context) do
    Application.fetch_env(:spruce_goose, :oauth2_resource_url)
  end

  def secret_for([:signing_secret], SpruceGoose.Oauth2Server, _opts, _context) do
    Application.fetch_env(:spruce_goose, :oauth2_signing_secret)
  end
end
