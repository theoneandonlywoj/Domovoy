defmodule DomovoyWeb.PageController do
  use DomovoyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
