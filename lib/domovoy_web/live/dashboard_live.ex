defmodule DomovoyWeb.DashboardLive do
  @moduledoc """
  The dashboard: one panel per live action, beside the drawer. The overview links to each
  section through a tile with its count. Projects is a card grid
  and Jobs a row list with status chips, both over mock data. Workflows lists the real
  drafts as cards, each opening the composer under `/dashboard/workflows`. Search and
  status live in the URL, so a reload restores them; an unknown status falls back to All
  and is never carried into the next patch.
  """

  use DomovoyWeb, :live_view

  import DomovoyWeb.DashboardComponents

  alias Domovoy.Composer
  alias Domovoy.Dashboard.Mock

  @statuses [
    {"All", "all"},
    {"Running", "running"},
    {"Queued", "queued"},
    {"Succeeded", "succeeded"},
    {"Failed", "failed"},
    {"Cancelled", "cancelled"}
  ]
  @status_values Enum.map(@statuses, &elem(&1, 1))

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:projects, dom_id: &"project-#{&1.id}")
     |> stream_configure(:jobs, dom_id: &"job-#{&1.id}")
     |> stream_configure(:drafts, dom_id: &"workflow-#{&1.id}")
     |> assign(query: "", status: "all", count: 0, total: 0, chips: [])
     |> assign(latest_runs: %{}, create_form: draft_form(""), tiles: [], deleting: nil)
     |> stream(:projects, [])
     |> stream(:jobs, [])
     |> stream(:drafts, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = if is_binary(params["q"]), do: String.trim(params["q"]), else: ""
    status = if params["status"] in @status_values, do: params["status"], else: "all"

    {:noreply,
     socket
     |> assign(query: query, status: status, form: to_form(%{"q" => query}, as: :search))
     |> load(socket.assigns.live_action)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="dashboard" active={Atom.to_string(@live_action)}>
      <div id="dashboard-panel" class="mx-auto max-w-6xl space-y-6 px-4 py-6 sm:px-6">
        <header :if={@live_action != :dashboard} class="flex flex-wrap items-center gap-3">
          <div class="w-full">
            <.search_bar form={@form} placeholder={placeholder(@live_action)} />
          </div>
          <.query_chip
            :if={@live_action != :jobs}
            query={@query}
            clear={panel_path(@live_action, "", @status)}
          />
        </header>

        <div :if={@live_action == :dashboard} id="dashboard-tiles" class="grid gap-4 sm:grid-cols-3">
          <.link
            :for={tile <- @tiles}
            id={"dashboard-tile-#{tile.key}"}
            navigate={tile.path}
            class="soft-panel flex flex-col gap-2 p-5"
          >
            <span class="text-sm text-muted">{tile.label}</span>
            <span id={"dashboard-tile-#{tile.key}-count"} class="font-display text-4xl">
              {tile.count}
            </span>
          </.link>
        </div>

        <.new_workflow :if={@live_action == :workflows} form={@create_form} />
        <.confirm_delete_workflow :if={@live_action == :workflows} draft={@deleting} />

        <div
          :if={@live_action == :workflows}
          id="drafts"
          phx-update="stream"
          class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3"
        >
          <p id="drafts-empty" class="hidden py-6 text-sm text-muted only:block">
            No workflows match.
          </p>
          <div :for={{id, draft} <- @streams.drafts} id={id} class="group relative">
            <.workflow_card draft={draft} run={@latest_runs[draft.id]} />
            <.delete_workflow_button draft={draft} />
          </div>
        </div>

        <div
          :if={@live_action == :projects}
          id="projects"
          phx-update="stream"
          class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3"
        >
          <p id="projects-empty" class="hidden py-6 text-sm text-muted only:block">
            No projects match.
          </p>
          <.project_card :for={{id, project} <- @streams.projects} id={id} project={project} />
        </div>

        <section :if={@live_action == :jobs} aria-label="Jobs" class="space-y-3">
          <.status_chips
            chips={@chips}
            status={@status}
            query={@query}
            clear={panel_path(:jobs, "", @status)}
          />
          <p id="jobs-count" class="text-xs text-muted">Showing {@count} of {@total}</p>
          <ul id="jobs" phx-update="stream" class="space-y-2">
            <.jobs_empty total={@total} />
            <.job_row :for={{id, job} <- @streams.jobs} id={id} job={job} />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # Only the panels with a search box patch; a stray "search" on any other action is ignored.
  @impl true
  def handle_event("search", %{"search" => %{"q" => q}}, socket) when is_binary(q) do
    case socket.assigns.live_action do
      action when action in [:projects, :jobs, :workflows] ->
        {:noreply,
         push_patch(socket,
           to: panel_path(action, String.trim(q), socket.assigns.status),
           replace: true
         )}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("create", %{"draft" => %{"title" => title}}, socket) when is_binary(title) do
    case Composer.create_draft(%{title: title}) do
      {:ok, draft} ->
        {:noreply, push_navigate(socket, to: ~p"/dashboard/workflows/#{draft.id}")}

      {:error, changeset} ->
        shown = if Composer.text_safe?(title), do: title, else: ""
        {:noreply, assign(socket, :create_form, draft_form(shown, changeset.errors))}
    end
  end

  # Delete asks first: `ask_delete` opens the confirmation, `delete` runs it. A draft gone
  # meanwhile just refreshes the list.
  def handle_event("ask_delete", %{"id" => id}, socket)
      when is_binary(id) and socket.assigns.live_action == :workflows do
    case Composer.get_draft(id) do
      {:ok, draft} -> {:noreply, assign(socket, :deleting, draft)}
      _gone -> {:noreply, load(socket, :workflows)}
    end
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete", _params, %{assigns: %{deleting: %Composer.Draft{} = draft}} = socket) do
    socket = assign(socket, :deleting, nil)

    case Composer.delete_draft(draft) do
      {:ok, deleted} ->
        {:noreply, stream_delete(socket, :drafts, deleted)}

      {:error, :runs_unfinished} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That workflow has a run that isn't finished. Cancel it first."
         )}

      {:error, :gone} ->
        {:noreply, load(socket, :workflows)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @spec load(socket :: Phoenix.LiveView.Socket.t(), action :: atom()) ::
          Phoenix.LiveView.Socket.t()
  defp load(socket, :dashboard) do
    active_jobs = Enum.count(Mock.jobs(), &(&1.status in [:running, :queued]))

    tiles = [
      %{
        key: "projects",
        label: "Projects",
        count: length(Mock.projects()),
        path: ~p"/dashboard/projects"
      },
      %{key: "jobs", label: "Active jobs", count: active_jobs, path: ~p"/dashboard/jobs"},
      %{
        key: "workflows",
        label: "Workflows",
        count: Composer.count_drafts(),
        path: ~p"/dashboard/workflows"
      }
    ]

    assign(socket, tiles: tiles, page_title: "Dashboard")
  end

  defp load(socket, :projects) do
    %{query: query} = socket.assigns
    all = Mock.projects()
    shown = Enum.filter(all, &matches?(query, [&1.name, &1.description, &1.path]))

    socket
    |> stream(:projects, shown, reset: true)
    |> assign(count: length(shown), total: length(all), page_title: "Projects")
  end

  defp load(socket, :jobs) do
    %{query: query, status: status} = socket.assigns
    all = Mock.jobs()

    matched =
      Enum.filter(
        all,
        &matches?(query, ["##{&1.id}", &1.title, &1.workflow, &1.project, &1.branch])
      )

    counts = Enum.frequencies_by(matched, &Atom.to_string(&1.status))

    shown =
      if status == "all",
        do: matched,
        else: Enum.filter(matched, &(Atom.to_string(&1.status) == status))

    chips =
      for {label, value} <- @statuses do
        count = if value == "all", do: length(matched), else: Map.get(counts, value, 0)
        %{value: value, label: label, count: count, path: panel_path(:jobs, query, value)}
      end

    socket
    |> stream(:jobs, shown, reset: true)
    |> assign(count: length(shown), total: length(all), chips: chips, page_title: "Jobs")
  end

  # The cards show each draft's newest run, so the stream is reset whenever that map is.
  defp load(socket, :workflows) do
    %{query: query} = socket.assigns
    all = Composer.list_drafts()
    shown = Enum.filter(all, &matches?(query, [text(&1.title), text(&1.document["name"])]))

    socket
    |> assign(latest_runs: latest_runs(shown))
    |> stream(:drafts, shown, reset: true)
    |> assign(count: length(shown), total: length(all), page_title: "Workflows")
  end

  @spec latest_runs(drafts :: [Composer.Draft.t()]) :: %{String.t() => Composer.Run.t()}
  defp latest_runs(drafts) do
    case Composer.latest_runs(Enum.map(drafts, & &1.id)) do
      %{} = runs -> runs
      {:error, :runs_disabled} -> %{}
    end
  end

  # A malformed document can hold anything, which searches as empty text.
  @spec text(value :: term()) :: String.t()
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  @spec draft_form(title :: String.t(), errors :: keyword()) :: Phoenix.HTML.Form.t()
  defp draft_form(title, errors \\ []) do
    to_form(%{"title" => title}, as: :draft, id: "draft", errors: errors)
  end

  @spec matches?(query :: String.t(), fields :: [String.t()]) :: boolean()
  defp matches?("", _fields), do: true

  defp matches?(query, fields) do
    needle = String.downcase(query)
    Enum.any?(fields, &String.contains?(String.downcase(&1), needle))
  end

  # Empty and "all" values are dropped; only Jobs carries a status.
  @spec panel_path(action :: atom(), query :: String.t(), status :: String.t()) :: String.t()
  defp panel_path(:projects, query, _status), do: ~p"/dashboard/projects?#{params(q: query)}"

  defp panel_path(:jobs, query, status),
    do: ~p"/dashboard/jobs?#{params(q: query, status: status)}"

  defp panel_path(:workflows, query, _status),
    do: ~p"/dashboard/workflows?#{params(q: query)}"

  @spec params(pairs :: keyword()) :: keyword()
  defp params(pairs), do: for({key, value} <- pairs, value not in ["", "all"], do: {key, value})

  @spec placeholder(action :: atom()) :: String.t()
  defp placeholder(:projects), do: "Search projects"
  defp placeholder(:jobs), do: "Search jobs"
  defp placeholder(:workflows), do: "Search workflows"
end
