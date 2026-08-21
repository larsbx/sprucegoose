defmodule SpruceGoose.Accounts do
  use Ash.Domain,
    otp_app: :spruce_goose

  resources do
    resource SpruceGoose.Accounts.Token
    resource SpruceGoose.Accounts.User
    resource SpruceGoose.Accounts.OauthClient
    resource SpruceGoose.Accounts.OauthAuthorizationCode
    resource SpruceGoose.Accounts.OauthRefreshToken
    resource SpruceGoose.Accounts.OauthConsent
  end
end
