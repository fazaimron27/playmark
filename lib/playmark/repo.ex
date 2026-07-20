defmodule Playmark.Repo do
  use Ecto.Repo,
    otp_app: :playmark,
    adapter: Ecto.Adapters.SQLite3
end
