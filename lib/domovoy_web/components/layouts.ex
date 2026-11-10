defmodule DomovoyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DomovoyWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :variant, :string,
    default: "page",
    values: ~w(page canvas dashboard),
    doc:
      "`canvas` gives the whole viewport to the content, with no navbar; `dashboard` puts it beside the drawer"

  attr :active, :string,
    default: nil,
    values: [nil, "dashboard", "projects", "jobs", "workflows"],
    doc: "the drawer item marked as the current page, in the `dashboard` variant"

  slot :inner_block, required: true

  # Shell ids start with `dashboard-`, since the shell shares a page with the composer.
  # No ancestor of the content takes a transform or filter, so a fixed scrim inside it
  # still covers the viewport.
  def app(%{variant: "dashboard"} = assigns) do
    ~H"""
    <div id="dashboard-shell" class="flex h-dvh overflow-hidden">
      <nav
        id="dashboard-drawer"
        aria-label="Dashboard"
        data-modal-background
        data-open={open_drawer()}
        data-close={close_drawer()}
        class="soft-panel m-2 flex w-64 shrink-0 flex-col gap-1 p-3"
      >
        <div id="dashboard-drawer-head" class="flex items-center gap-2">
          <button
            id="dashboard-toggle"
            type="button"
            phx-click={JS.dispatch("domovoy:toggle")}
            aria-controls="dashboard-drawer"
            class="soft-btn soft-btn-quiet flex size-10 shrink-0 items-center justify-center"
          >
            <.icon name="hero-bars-3" class="size-5" />
            <span class="sr-only">Toggle menu</span>
          </button>
          <span class="dashboard-brand font-display text-2xl">Domovoy</span>
        </div>
        <.link
          :for={item <- nav_items()}
          id={"dashboard-nav-#{item.key}"}
          navigate={item.path}
          aria-current={@active == item.key && "page"}
          aria-label={item.label}
          class="dashboard-nav soft-btn soft-btn-quiet flex items-center gap-3 px-3 py-2"
        >
          <.icon name={item.icon} class="size-5 shrink-0" />
          <span class="dashboard-nav-label">{item.label}</span>
        </.link>
      </nav>
      <div
        id="dashboard-scrim"
        class="soft-scrim fixed inset-0 z-20 hidden"
        phx-click={close_drawer()}
      >
      </div>
      <div id="dashboard-main" class="flex min-h-0 min-w-0 flex-1 flex-col">
        <main class="min-h-0 flex-1 overflow-y-auto has-[#composer]:overflow-hidden">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  def app(%{variant: "canvas"} = assigns) do
    ~H"""
    <main class="h-dvh overflow-hidden">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    ~H"""
    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # The only list of drawer items.
  @spec nav_items() :: [%{key: String.t(), label: String.t(), icon: String.t(), path: String.t()}]
  defp nav_items do
    [
      %{key: "dashboard", label: "Dashboard", icon: "hero-home", path: ~p"/dashboard"},
      %{
        key: "projects",
        label: "Projects",
        icon: "hero-squares-2x2",
        path: ~p"/dashboard/projects"
      },
      %{key: "jobs", label: "Jobs", icon: "hero-queue-list", path: ~p"/dashboard/jobs"},
      %{
        key: "workflows",
        label: "Workflows",
        icon: "hero-share",
        path: ~p"/dashboard/workflows"
      }
    ]
  end

  # Below md the rail widens into an overlay: a modal dialog over an inert page. Its
  # `aria-modal` is the open state the CSS reads. Choosing an item live-navigates, which
  # replaces this DOM, so that closes it too. Only the overlay sets `aria-expanded`: the
  # desktop collapse lives on <html>, which a patch of the toggle would not track.
  defp open_drawer do
    JS.set_attribute({"role", "dialog"}, to: "#dashboard-drawer")
    |> JS.set_attribute({"aria-modal", "true"}, to: "#dashboard-drawer")
    |> JS.set_attribute({"inert", ""}, to: "#dashboard-main")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#dashboard-toggle")
    |> JS.focus(to: "#dashboard-nav-dashboard")
  end

  defp close_drawer do
    JS.remove_attribute("role", to: "#dashboard-drawer")
    |> JS.remove_attribute("aria-modal", to: "#dashboard-drawer")
    |> JS.remove_attribute("inert", to: "#dashboard-main")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#dashboard-toggle")
    |> JS.focus(to: "#dashboard-toggle")
  end

  # The root layout reads the drawer's collapse from its cookie, and renders only the two
  # known values, so a tampered cookie is never echoed.
  @doc false
  @spec drawer_state(conn :: Plug.Conn.t() | nil) :: String.t()
  def drawer_state(%Plug.Conn{req_cookies: %{"domovoy_drawer" => "collapsed"}}), do: "collapsed"
  def drawer_state(_conn), do: "expanded"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
