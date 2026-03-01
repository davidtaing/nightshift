defmodule Nightshift.Repo do
  use Ecto.Repo,
    otp_app: :nightshift,
    adapter: Ecto.Adapters.SQLite3
end
