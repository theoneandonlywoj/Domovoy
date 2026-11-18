defmodule DomovoyWeb.DashboardLive do
  @moduledoc """
  The dashboard: one panel per live action, beside the drawer. The overview links to each
  section through a tile with its count. Projects is a card grid
  and Jobs a row list with status chips, both read from `Domovoy.Dashboard`. Workflows
  lists the drafts as cards, each opening the composer under `/dashboard/workflows`. Search and
  status live in the URL, so a reload restores them; an unknown status falls back to All
  and is never carried into the next patch. Workflows, Projects and Jobs each have a +
  button that opens the create modal for their own entity, and only there.
  """

  use DomovoyWeb, :live_view

  import DomovoyWeb.DashboardComponents

  alias Domovoy.Composer
  alias Domovoy.Dashboard

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
     |> stream_configure(:jobs, dom_id: &"job-#{&1.number}")
     |> stream_configure(:drafts, dom_id: &"workflow-#{&1.id}")
     |> assign(query: "", status: "all", count: 0, total: 0, chips: [], creating: nil)
     |> assign(latest_runs: %{}, create_form: draft_form(""), tiles: [], deleting: nil)
     |> assign(project_options: [], workflow_options: [])
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

        <.new_fab
          :if={@live_action == :workflows}
          entity="workflow"
          label="New workflow"
          action="new.workflow"
        />
        <.create_modal
          :if={@creating == :workflow}
          entity="workflow"
          title="New workflow"
          explainer="A workflow is a graph of stages the agent engine runs. You'll shape it in the composer next."
          form={@create_form}
          submit="create"
        >
          <.input
            field={@create_form[:title]}
            type="text"
            label="Title"
            placeholder="Title"
            phx-mounted={JS.focus()}
            required
          />
        </.create_modal>
        <.new_fab
          :if={@live_action == :projects}
          entity="project"
          label="New project"
          action="new.project"
        />
        <.new_fab :if={@live_action == :jobs} entity="job" label="New job" action="new.job" />
        <.create_modal
          :if={@creating == :project}
          entity="project"
          title="New project"
          explainer="A project is a repository folder Domovoy works in. Its stats start at zero."
          form={@create_form}
          submit="create_project"
        >
          <.input
            field={@create_form[:name]}
            type="text"
            label="Name"
            phx-mounted={JS.focus()}
            required
          />
          <.input
            field={@create_form[:path]}
            type="text"
            label="Path"
            placeholder="~/Repos/name"
            required
          />
          <.input field={@create_form[:description]} type="textarea" label="Description" />
        </.create_modal>
        <.create_modal
          :if={@creating == :job}
          entity="job"
          title="New job"
          explainer="A job queues a workflow to run on a project's branch. It starts as Queued; nothing runs it yet."
          form={@create_form}
          submit="create_job"
        >
          <.input
            field={@create_form[:title]}
            type="text"
            label="Title"
            phx-mounted={JS.focus()}
            required
          />
          <.input
            field={@create_form[:draft_id]}
            type="select"
            label="Workflow"
            prompt={
              if @workflow_options == [], do: "Create a workflow first", else: "Choose a workflow"
            }
            options={@workflow_options}
          />
          <.input
            field={@create_form[:project_id]}
            type="select"
            label="Project"
            prompt={if @project_options == [], do: "Create a project first", else: "Choose a project"}
            options={@project_options}
          />
          <.input field={@create_form[:branch]} type="text" label="Branch" />
          <p
            :if={@project_options == [] or @workflow_options == []}
            id="dashboard-new-job-hint"
            class="text-sm text-muted"
          >
            {job_hint(@project_options, @workflow_options)}
          </p>
        </.create_modal>
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
          <.projects_empty total={@total} />
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

  # Each create modal opens only on its own panel; an unknown entity is ignored.
  def handle_event("open_create", %{"entity" => "workflow"}, socket)
      when socket.assigns.live_action == :workflows,
      do: {:noreply, assign(socket, creating: :workflow, create_form: draft_form(""))}

  def handle_event("open_create", %{"entity" => "project"}, socket)
      when socket.assigns.live_action == :projects,
      do:
        {:noreply,
         assign(socket, creating: :project, create_form: to_form(Dashboard.change_project()))}

  def handle_event("open_create", %{"entity" => "job"}, socket)
      when socket.assigns.live_action == :jobs do
    {:noreply,
     socket
     |> assign(creating: :job, create_form: to_form(Dashboard.change_job()))
     |> assign_job_options()}
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :creating, nil)}

  def handle_event("create", %{"draft" => %{"title" => title}}, socket)
      when is_binary(title) and socket.assigns.live_action == :workflows do
    case Composer.create_draft(%{title: title}) do
      {:ok, draft} ->
        {:noreply, push_navigate(socket, to: ~p"/dashboard/workflows/#{draft.id}")}

      {:error, changeset} ->
        shown = if Composer.text_safe?(title), do: title, else: ""

        {:noreply,
         assign(socket, creating: :workflow, create_form: draft_form(shown, changeset.errors))}
    end
  end

  def handle_event("create_project", %{"project" => params}, socket)
      when is_map(params) and socket.assigns.live_action == :projects do
    case Dashboard.create_project(params) do
      {:ok, _project} ->
        {:noreply, socket |> assign(:creating, nil) |> load(:projects)}

      {:error, changeset} ->
        {:noreply, assign(socket, creating: :project, create_form: error_form(changeset))}
    end
  end

  # The options are reloaded on error too, so a submit without an open modal still
  # shows the right prompts.
  def handle_event("create_job", %{"job" => params}, socket)
      when is_map(params) and socket.assigns.live_action == :jobs do
    case Dashboard.create_job(params) do
      {:ok, _job} ->
        {:noreply, socket |> assign(:creating, nil) |> load(:jobs)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(creating: :job, create_form: error_form(changeset))
         |> assign_job_options()}
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
    tiles = [
      %{
        key: "projects",
        label: "Projects",
        count: Dashboard.count_projects(),
        path: ~p"/dashboard/projects"
      },
      %{
        key: "jobs",
        label: "Active jobs",
        count: Dashboard.count_active_jobs(),
        path: ~p"/dashboard/jobs"
      },
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
    all = Dashboard.list_projects()
    shown = Enum.filter(all, &matches?(query, [&1.name, &1.description, &1.path]))

    socket
    |> stream(:projects, shown, reset: true)
    |> assign(count: length(shown), total: length(all), page_title: "Projects")
  end

  defp load(socket, :jobs) do
    %{query: query, status: status} = socket.assigns
    all = Dashboard.list_jobs()

    matched =
      Enum.filter(
        all,
        &matches?(query, ["##{&1.number}", &1.title, &1.workflow, &1.project.name, &1.branch])
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

  @spec assign_job_options(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp assign_job_options(socket) do
    assign(socket,
      project_options: Enum.map(Dashboard.list_projects(), &{&1.name, &1.id}),
      workflow_options: Enum.map(Composer.list_drafts(), &{&1.title, &1.id})
    )
  end

  # Phoenix.Ecto reads a field from `changes` before `params`, and both can hold text the
  # page can't carry (NUL, broken UTF-8) or a non-string an `<.input>` can't render. Such
  # params render empty and such changes are dropped; non-binary changes, like the
  # looked-up keys, are kept.
  @spec error_form(changeset :: Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  defp error_form(changeset) do
    safe? = &(is_binary(&1) and Composer.text_safe?(&1))
    params = Map.new(changeset.params, fn {k, v} -> {k, if(safe?.(v), do: v, else: "")} end)
    changes = Map.reject(changeset.changes, fn {_k, v} -> is_binary(v) and not safe?.(v) end)
    to_form(%{changeset | params: params, changes: changes})
  end

  @spec job_hint(projects :: list(), workflows :: list()) :: String.t()
  defp job_hint(projects, workflows) do
    [
      projects == [] && "Create a project first.",
      workflows == [] && "Create a workflow first."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  @spec matches?(query :: String.t(), fields :: [String.t() | nil]) :: boolean()
  defp matches?("", _fields), do: true

  defp matches?(query, fields) do
    needle = String.downcase(query)
    Enum.any?(fields, &String.contains?(String.downcase(text(&1)), needle))
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
