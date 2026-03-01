defmodule Nightshift.Repo do
  use AshSqlite.Repo,
    otp_app: :nightshift
end
