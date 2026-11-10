defmodule DomovoyWeb.Shell do
  @moduledoc """
  Which shell a LiveView renders in, set per `live_session` in the router: `:composer`
  is the standalone composer, `:dashboard` the drawer shell. The composer's layout and
  every path it builds read the `:shell` assign, so its links stay in the shell it opened in.
  """
  import Phoenix.Component, only: [assign: 3]

  @type t :: :composer | :dashboard

  @spec on_mount(
          shell :: t(),
          params :: map() | :not_mounted_at_router,
          session :: map(),
          socket :: Phoenix.LiveView.Socket.t()
        ) :: {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(shell, _params, _session, socket) when shell in [:composer, :dashboard],
    do: {:cont, assign(socket, :shell, shell)}
end
