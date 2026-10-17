defmodule SpruceGoose.Accounts.OauthClient do
  use Ash.Resource,
    otp_app: :spruce_goose,
    domain: SpruceGoose.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.Oauth2Server.ClientResource]

  postgres do
    table "oauth_clients"
    repo SpruceGoose.Repo
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :client_name, :string do
      allow_nil? false
      public? true
    end

    attribute :redirect_uris, {:array, :string} do
      allow_nil? false
      public? true
    end

    attribute :grant_types, {:array, :string} do
      public? true
    end

    attribute :response_types, {:array, :string} do
      public? true
    end

    attribute :token_endpoint_auth_method, :string do
      public? true
    end

    attribute :scope, :string do
      public? true
    end

    attribute :cimd_url, :string do
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [
        :client_name,
        :redirect_uris,
        :grant_types,
        :response_types,
        :token_endpoint_auth_method,
        :scope
      ]
    end

    create :register_cimd do
      upsert? true
      upsert_identity :by_cimd_url

      accept [
        :cimd_url,
        :client_name,
        :redirect_uris,
        :grant_types,
        :response_types,
        :token_endpoint_auth_method,
        :scope
      ]
    end

    update :touch do
      accept []
      change atomic_update(:last_used_at, expr(now()))
    end
  end

  identities do
    identity :by_cimd_url, [:cimd_url]
  end
end
