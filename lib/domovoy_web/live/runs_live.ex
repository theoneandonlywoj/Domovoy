defmodule DomovoyWeb.RunsLive do
  @moduledoc """
  The Runs view: every run, newest first, filtered by draft and status and paged 25 at a
  time, each row showing its run summary and opening that run's page. Rendering opens
  no run. After each page, its rows with no summary, or an unfinished one older than 30
  seconds, are refreshed in the background. A summary is only what history last saw;
  a run's own page re-reads Core. With runs off it says so and reads nothing.
  """

  use DomovoyWeb, :live_view

  import DomovoyWeb.ComposerComponents, only: [run_link: 3]
  import DomovoyWeb.ComposerRunComponents, only: [start_time: 1, summary_chip: 1]

  alias Domovoy.Composer

  @page_size 25
  @stale_seconds 30

  @statuses [
    {"All", "all"},
    {"Needs attention", "attention"},
    {"Running", "running"},
    {"Waiting", "waiting"},
    {"Stopped", "stopped"},
    {"Failed", "failed"},
    {"Succeeded", "succeeded"},
    {"Cancelled", "cancelled"}
  ]
  @status_values Enum.map(@statuses, &elem(&1, 1))

  @impl true
  def mount(_params, _session, socket) do
    runs_enabled? = Composer.runs_enabled?()

    {:ok,
     socket
     |> stream_configure(:runs, dom_id: &"run-row-#{&1.id}")
     |> assign(
       page_title: "Runs",
       runs_enabled?: runs_enabled?,
       statuses: @statuses,
       drafts: if(runs_enabled?, do: draft_options(), else: []),
       filters: %{draft_id: nil, status: "all"},
       form: filter_form(nil, "all"),
       next: nil,
       count: 0,
       refreshes: []
     )
     |> stream(:runs, [])}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{runs_enabled?: true}} = socket) do
    draft = if is_binary(params["draft"]) and params["draft"] != "", do: params["draft"]
    status = if params["status"] in @status_values, do: params["status"], else: "all"

    {:noreply,
     socket
     |> assign(filters: %{draft_id: draft, status: status}, form: filter_form(draft, status))
     |> load_page(nil)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div class="space-y-1">
            <nav aria-label="Breadcrumb" class="text-sm">
              <.link navigate={~p"/composer"} class="soft-link">Drafts</.link>
              <span class="text-muted">/</span>
              <span>Runs</span>
            </nav>
            <h1 class="text-2xl font-semibold tracking-tight">Runs</h1>
            <p class="text-sm text-muted">
              Status here is what history last saw. A run's page reads it fresh.
            </p>
          </div>
        </header>

        <p
          :if={!@runs_enabled?}
          id="runs-unavailable"
          role="status"
          class="soft-panel px-4 py-3 text-sm"
        >
          Runs are turned off on this host.
        </p>

        <.form
          :if={@runs_enabled?}
          for={@form}
          id="runs-filter"
          phx-change="filter"
          class="flex flex-wrap items-end gap-3"
        >
          <div class="w-60">
            <.input field={@form[:draft]} type="select" label="Draft" options={@drafts} />
          </div>
          <div class="w-48">
            <.input field={@form[:status]} type="select" label="Status" options={@statuses} />
          </div>
        </.form>

        <section :if={@runs_enabled?} aria-label="Runs" class="space-y-3">
          <p id="runs-count" class="text-xs text-muted">
            Showing {@count} {if @count == 1, do: "run", else: "runs"}, newest first
          </p>
          <ul id="runs" phx-update="stream" class="space-y-2">
            <li id="runs-empty" class="hidden py-6 text-sm text-muted only:block">
              No runs match.
            </li>
            <li :for={{id, run} <- @streams.runs} id={id}>
              <.link
                id={"open-#{id}"}
                navigate={run_link(run.draft_id, nil, run.id)}
                class="soft-row flex items-center gap-3 px-4 py-2.5 text-sm transition-colors"
              >
                <.summary_chip id={"#{id}-status"} summary={run.summary} />
                <span class="min-w-0 flex-1 truncate font-medium">{run.workflow_name}</span>
                <span :if={is_nil(run.draft_id)} class="text-xs text-muted">Draft deleted</span>
                <span class="text-xs text-muted">{start_time(run.inserted_at)}</span>
                <code class="text-xs text-muted">{String.slice(run.id, 0, 8)}</code>
              </.link>
            </li>
          </ul>
          <button
            :if={@next}
            id="runs-more"
            type="button"
            phx-click="more"
            phx-disable-with="Loading…"
            class="soft-btn px-3 py-1.5 text-sm"
          >
            Show older runs
          </button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event(
        "filter",
        %{"runs_filter" => filter},
        %{assigns: %{runs_enabled?: true}} = socket
      )
      when is_map(filter) do
    query =
      for {key, value} <- [draft: filter["draft"], status: filter["status"]],
          is_binary(value) and value not in ["", "all"],
          do: {key, value}

    {:noreply, push_patch(socket, to: ~p"/composer/runs?#{query}")}
  end

  def handle_event("more", _params, %{assigns: %{next: next}} = socket) when not is_nil(next),
    do: {:noreply, load_page(socket, next)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A refresh for filters since changed is dropped.
  @impl true
  def handle_async({:refresh_page, filters, _cursor} = key, {:ok, {:ok, runs}}, socket) do
    socket = refreshed(socket, key)

    if filters == socket.assigns.filters,
      do: {:noreply, Enum.reduce(runs, socket, &stream_insert(&2, :runs, &1))},
      else: {:noreply, socket}
  end

  def handle_async({:refresh_page, _filters, _cursor} = key, _failed, socket),
    do: {:noreply, refreshed(socket, key)}

  @spec refreshed(socket :: Phoenix.LiveView.Socket.t(), key :: tuple()) ::
          Phoenix.LiveView.Socket.t()
  defp refreshed(socket, key),
    do: assign(socket, :refreshes, List.delete(socket.assigns.refreshes, key))

  @spec load_page(socket :: Phoenix.LiveView.Socket.t(), cursor :: term()) ::
          Phoenix.LiveView.Socket.t()
  defp load_page(socket, cursor) do
    filters = socket.assigns.filters
    %{runs: runs, next: next} = Composer.run_page(filters, cursor, @page_size)
    count = if(cursor, do: socket.assigns.count, else: 0) + length(runs)

    socket
    |> stream(:runs, runs, reset: is_nil(cursor))
    |> assign(next: next, count: count)
    |> refresh_stale(runs, filters, cursor)
  end

  # Only rows that may have moved on are read again, so a settled page opens no run. A
  # first page replaces the list, so the refreshes of the list before it are cancelled:
  # filter events in a row never run more than one.
  @spec refresh_stale(
          socket :: Phoenix.LiveView.Socket.t(),
          runs :: [Composer.Run.t()],
          filters :: map(),
          cursor :: term()
        ) :: Phoenix.LiveView.Socket.t()
  defp refresh_stale(socket, runs, filters, cursor) do
    stale = for run <- runs, stale?(run.summary), do: run.id
    key = {:refresh_page, filters, cursor}

    socket =
      if is_nil(cursor),
        do:
          socket.assigns.refreshes
          |> Enum.reduce(socket, &cancel_async(&2, &1))
          |> assign(:refreshes, []),
        else: socket

    if stale != [] and connected?(socket),
      do:
        socket
        |> assign(:refreshes, [key | List.delete(socket.assigns.refreshes, key)])
        |> start_async(key, fn -> Composer.refresh_run_summaries(stale) end),
      else: socket
  end

  @spec stale?(summary :: map() | nil) :: boolean()
  defp stale?(nil), do: true
  defp stale?(%{terminal: true}), do: false

  defp stale?(%{refreshed_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) > @stale_seconds

  @spec draft_options() :: [{String.t(), String.t()}]
  defp draft_options do
    drafts = for draft <- Composer.list_drafts(), do: {draft.title, draft.id}
    [{"All drafts", ""}] ++ drafts ++ [{"Deleted drafts", "deleted"}]
  end

  @spec filter_form(draft :: String.t() | nil, status :: String.t()) :: Phoenix.HTML.Form.t()
  defp filter_form(draft, status),
    do:
      to_form(%{"draft" => draft || "", "status" => status}, as: :runs_filter, id: "runs-filter")
end
