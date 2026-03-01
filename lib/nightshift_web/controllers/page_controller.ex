defmodule NightshiftWeb.PageController do
  use NightshiftWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
