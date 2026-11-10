defmodule DomovoyWeb.DashboardComponents do
  @moduledoc """
  The dashboard's panels: the search bar, project cards, job rows, the job status chips
  and workflow cards.

  Status pills reuse the composer's `.run-pill` tones, so there is one pill system.
  """

  use DomovoyWeb, :html

  alias DomovoyWeb.Keymap

  @chip "soft-btn inline-flex items-center gap-2 px-2.5 py-1 text-sm"
  @count "rounded-full bg-sunken px-1.5 text-xs tabular-nums text-muted"
  @meta "text-xs text-muted"

  @doc """
  The panel's search field: a magnifier label, the text input and `⌘` `K` hints, shown only
  while `?` hints are on. It sends
  `search` as you type, debounced. The wrapper carries the `search.focus` key and
  `data-shortcut-focus`, so `/` and Cmd/Ctrl+K focus the input.

  The input is hand-built, a deliberate exception to `<.input>`: that component renders its
  own wrapper and label, so the icon and the kbd keys could not sit inside the field's frame.
  """
  attr :form, Phoenix.HTML.Form, required: true, doc: "a form `as: :search` with a `q` field"
  attr :placeholder, :string, required: true, doc: "the placeholder, also its accessible name"

  def search_bar(assigns) do
    ~H"""
    <.form for={@form} id="dashboard-search" role="search" phx-change="search" phx-submit="search">
      <div
        id="dashboard-search-field"
        data-shortcut={Keymap.key("search.focus")}
        data-shortcut-focus
        class="dashboard-search flex min-h-11 items-center gap-2.5 px-3"
      >
        <label for={@form[:q].id} class="flex text-muted">
          <.icon name="hero-magnifying-glass" class="size-5" />
          <span class="sr-only">{@placeholder}</span>
        </label>
        <input
          id={@form[:q].id}
          name={@form[:q].name}
          value={@form[:q].value}
          type="text"
          autocomplete="off"
          spellcheck="false"
          phx-debounce="300"
          placeholder={@placeholder}
          aria-keyshortcuts={"#{Keymap.aria(Keymap.key("search.focus"))} Meta+K Control+K"}
          class="h-10 min-w-0 flex-1 bg-transparent text-base outline-none placeholder:text-muted"
        />
        <kbd class="dashboard-kbd">⌘</kbd>
        <kbd class="dashboard-kbd">K</kbd>
      </div>
    </.form>
    """
  end

  @doc """
  The active text filter, with a link that clears it and keeps the status. Renders nothing
  for an empty query.
  """
  attr :query, :string, required: true
  attr :clear, :string, required: true, doc: "the panel path without q"

  def query_chip(assigns) do
    ~H"""
    <span
      :if={@query != ""}
      id="dashboard-filter-query"
      class="soft-chip inline-flex min-h-9 max-w-full items-center gap-1 pr-1 pl-2.5 text-sm"
    >
      <span class="max-w-[16rem] truncate">Filtered by "{@query}"</span>
      <.link
        id="dashboard-filter-clear"
        patch={@clear}
        aria-label="Clear the filter"
        class="flex size-7 items-center justify-center text-muted transition-colors hover:text-base-content"
      >
        <.icon name="hero-x-mark-micro" class="size-4" />
      </.link>
    </span>
    """
  end

  @doc """
  The floating New workflow button at the bottom right, with `c w` (`new.workflow`), and the
  form it opens above itself: a title and Create. Esc or Cancel closes the form and gives focus
  back to the button; Enter or Cmd/Ctrl+Enter creates. The form is always rendered (hidden until opened) and stays open while
  the title has an error.
  """
  attr :form, Phoenix.HTML.Form, required: true, doc: "a form `as: :draft` with a `title` field"

  def new_workflow(assigns) do
    ~H"""
    <div
      id="dashboard-new-workflow-dock"
      class="fixed right-8 bottom-8 z-10 flex flex-col items-end gap-3"
    >
      <div
        id="dashboard-new-workflow-panel"
        class={[
          "dashboard-popover w-[min(22.5rem,calc(100vw-4rem))] flex-col gap-3 p-4",
          if(@form.errors == [], do: "hidden", else: "flex")
        ]}
      >
        <.form
          for={@form}
          id="dashboard-new-workflow"
          phx-submit="create"
          phx-hook=".NewWorkflowKeys"
          data-close={close_new_workflow()}
          class="flex flex-col gap-3"
        >
          <.input field={@form[:title]} type="text" label="New workflow" placeholder="Title" required />
          <div class="flex justify-end gap-2">
            <button
              id="dashboard-cancel-workflow"
              type="button"
              phx-click={close_new_workflow()}
              class="soft-btn inline-flex items-center gap-2 px-3 py-1.5 text-sm"
            >
              Cancel <kbd class="dashboard-kbd">esc</kbd>
            </button>
            <button
              id="dashboard-create-workflow"
              type="submit"
              phx-disable-with="Creating…"
              aria-keyshortcuts="Meta+Enter Control+Enter"
              class="soft-btn soft-btn-primary inline-flex items-center gap-2 px-3 py-1.5 text-sm"
            >
              Create <kbd class="dashboard-kbd">⌘↵</kbd>
            </button>
          </div>
        </.form>
        <%!-- Enter submits natively; Cmd/Ctrl+Enter is made explicit, since browsers differ.
             Esc anywhere in the form (title or buttons) runs `data-close`. A key binding would
             not do: LiveView fires `phx-keydown` only on the focused element itself. --%>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".NewWorkflowKeys">
          export default {
            mounted() {
              this.el.addEventListener("keydown", event => {
                if (event.isComposing) return
                if (event.key === "Escape") {
                  event.preventDefault()
                  this.liveSocket.execJS(this.el, this.el.dataset.close)
                } else if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
                  event.preventDefault()
                  const create = document.getElementById("dashboard-create-workflow")
                  if (create && !create.disabled) this.el.requestSubmit(create)
                }
              })
            }
          }
        </script>
      </div>
      <div class="group flex items-center gap-3">
        <span
          aria-hidden="true"
          class="dashboard-popover flex translate-x-1 items-center gap-2 px-2.5 py-1.5 text-sm whitespace-nowrap opacity-0 transition duration-150 group-focus-within:translate-x-0 group-focus-within:opacity-100 group-hover:translate-x-0 group-hover:opacity-100 max-sm:hidden"
        >
          New workflow <kbd class="dashboard-kbd">{Keymap.key("new.workflow")}</kbd>
        </span>
        <button
          id="dashboard-new-workflow-open"
          type="button"
          aria-label="New workflow"
          aria-controls="dashboard-new-workflow-panel"
          phx-click={
            JS.toggle(to: "#dashboard-new-workflow-panel", display: "flex")
            |> JS.focus(to: "##{@form[:title].id}")
          }
          {Keymap.attrs("new.workflow")}
          class="dashboard-fab flex size-14 items-center justify-center rounded-full"
        >
          <.icon name="hero-plus" class="size-7" />
        </button>
      </div>
    </div>
    """
  end

  defp close_new_workflow do
    JS.hide(to: "#dashboard-new-workflow-panel")
    |> JS.focus(to: "#dashboard-new-workflow-open")
  end

  @doc """
  A card's Delete button, at its top right, outside the card's link. It shows on hover or
  focus (always on touch) and asks before deleting; focus comes back to it afterwards.
  """
  attr :draft, :map, required: true, doc: "a `Domovoy.Composer.Draft`"

  def delete_workflow_button(assigns) do
    ~H"""
    <button
      id={"workflow-#{@draft.id}-delete"}
      type="button"
      phx-click={JS.push_focus() |> JS.push("ask_delete", value: %{id: @draft.id})}
      aria-label={"Delete #{@draft.title}"}
      class="soft-btn soft-btn-quiet absolute top-3 right-3 flex size-9 items-center justify-center opacity-0 transition-opacity duration-150 group-hover:opacity-100 focus-visible:opacity-100 pointer-coarse:opacity-100 hover:text-error"
    >
      <.icon name="hero-trash" class="size-4" />
    </button>
    """
  end

  @doc """
  Asks before a workflow is deleted. Esc or Cancel keeps it; Delete or Cmd/Ctrl+Enter deletes
  it. Focus starts on Cancel and returns to the card's Delete button when this closes.
  """
  attr :draft, :map, default: nil, doc: "the `Domovoy.Composer.Draft` to delete, or nil"

  def confirm_delete_workflow(%{draft: nil} = assigns), do: ~H""

  def confirm_delete_workflow(assigns) do
    ~H"""
    <DomovoyWeb.ComposerComponents.modal_scrim focus_id="confirm-delete-workflow-focus">
      <div
        id="confirm-delete-workflow"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="confirm-delete-workflow-title"
        aria-describedby="confirm-delete-workflow-body"
        phx-window-keydown="cancel_delete"
        phx-key="escape"
        phx-hook=".ConfirmOnModEnter"
        class="dashboard-popover w-[min(24rem,calc(100vw-2rem))] space-y-3 p-5"
      >
        <h2 id="confirm-delete-workflow-title" class="font-semibold">
          Delete “{@draft.title}”?
        </h2>
        <p id="confirm-delete-workflow-body" class="text-sm text-muted">
          Its stages and saved inputs go with it. This can't be undone.
        </p>
        <div class="flex justify-end gap-2">
          <button
            id="cancel-delete-workflow"
            type="button"
            phx-mounted={JS.focus()}
            phx-click="cancel_delete"
            class="soft-btn inline-flex items-center gap-2 px-3 py-1.5 text-sm"
          >
            Cancel <kbd class="dashboard-kbd">esc</kbd>
          </button>
          <button
            id="confirm-delete-workflow-button"
            type="button"
            phx-click="delete"
            phx-disable-with="Deleting…"
            aria-keyshortcuts="Meta+Enter Control+Enter"
            class="soft-btn soft-btn-danger inline-flex items-center gap-2 px-3 py-1.5 text-sm"
          >
            Delete <kbd class="dashboard-kbd">⌘↵</kbd>
          </button>
        </div>
      </div>
      <%!-- Esc is the window binding above; Cmd/Ctrl+Enter clicks Delete, as in New workflow. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConfirmOnModEnter">
        export default {
          mounted() {
            this.onKey = event => {
              if (event.key !== "Enter" || event.isComposing || !(event.metaKey || event.ctrlKey)) return
              event.preventDefault()
              const confirm = document.getElementById("confirm-delete-workflow-button")
              if (confirm && !confirm.disabled) confirm.click()
            }
            window.addEventListener("keydown", this.onKey)
          },
          destroyed() { window.removeEventListener("keydown", this.onKey) }
        }
      </script>
    </DomovoyWeb.ComposerComponents.modal_scrim>
    """
  end

  @doc """
  The jobs list's empty row, shown only when it is the list's only child. It says whether
  there are no jobs at all or none match the filters.
  """
  attr :total, :integer, required: true, doc: "how many jobs exist, before any filter"

  def jobs_empty(assigns) do
    ~H"""
    <li id="jobs-empty" class="hidden py-6 text-sm text-muted only:block">
      {if @total == 0, do: "No jobs yet.", else: "No jobs match."}
    </li>
    """
  end

  @doc """
  One project as a card: badge, name and status, description, counts, path and its last
  14 days of activity.
  """
  attr :id, :string, required: true, doc: "the stream dom id, `project-<id>`"
  attr :project, :map, required: true, doc: "a `Domovoy.Dashboard.Mock.project()`"

  def project_card(assigns) do
    assigns = assign(assigns, :meta, @meta)

    ~H"""
    <article id={@id} class="soft-panel flex flex-col gap-3 p-4">
      <header class="flex items-center gap-3">
        <span
          aria-hidden="true"
          class="flex size-10 shrink-0 items-center justify-center rounded-field bg-sunken font-display text-lg text-primary"
        >
          {initials(@project.name)}
        </span>
        <h2 class="min-w-0 flex-1 truncate text-lg font-medium">{@project.name}</h2>
        <span
          id={"#{@id}-status"}
          data-run-pill={project_tone(@project.status)}
          class="run-pill shrink-0"
        >
          {status_word(@project.status)}
        </span>
      </header>
      <p class="text-sm">{@project.description}</p>
      <p id={"#{@id}-counts"} class={@meta}>
        {@project.repos} repos · {@project.worktrees} worktrees · {@project.jobs} jobs · {@project.workflows} workflows
      </p>
      <p class="truncate font-mono text-xs text-muted">{@project.path}</p>
      <.activity_strip id={"#{@id}-activity"} activity={@project.activity} />
    </article>
    """
  end

  @doc """
  A row of bars, one per day. The bars are decoration; the label carries the meaning.
  """
  attr :id, :string, required: true
  attr :activity, :list, required: true, doc: "values in `0..100`, oldest first"

  def activity_strip(assigns) do
    assigns = assign(assigns, :meta, @meta)

    ~H"""
    <div id={@id} class="flex items-end gap-2">
      <div aria-hidden="true" class="flex h-8 flex-1 items-end gap-0.5">
        <span
          :for={value <- @activity}
          class="min-h-px flex-1 rounded-sm bg-primary/70"
          style={"height: #{value}%"}
        ></span>
      </div>
      <span class={@meta}>14 days</span>
    </div>
    """
  end

  @doc """
  One job as a list row: status, number and title, then where and how it ran, with a
  progress bar while running.
  """
  attr :id, :string, required: true, doc: "the stream dom id, `job-<id>`"
  attr :job, :map, required: true, doc: "a `Domovoy.Dashboard.Mock.job()`"

  def job_row(assigns) do
    assigns = assign(assigns, :meta, @meta)

    ~H"""
    <li id={@id} class="soft-row grid gap-1.5 px-4 py-3 text-sm">
      <div class="flex min-w-0 items-center gap-3">
        <.icon name={status_icon(@job.status)} class="size-4 shrink-0 text-muted" />
        <span class="font-mono text-xs text-muted">#{@job.id}</span>
        <span class="min-w-0 flex-1 truncate font-medium">{@job.title}</span>
        <span id={"#{@id}-status"} data-run-pill={job_tone(@job.status)} class="run-pill shrink-0">
          <span :if={@job.status == :running} aria-hidden="true" class="flex">
            <.icon name="hero-arrow-path" class="run-spin size-3" />
          </span>
          {status_word(@job.status)}
        </span>
      </div>
      <div class={["flex flex-wrap gap-x-4 gap-y-1", @meta]}>
        <span id={"#{@id}-workflow"}>{@job.workflow}</span>
        <span id={"#{@id}-project"}>{@job.project}</span>
        <span id={"#{@id}-branch"} class="font-mono">{@job.branch}</span>
        <span>{@job.trigger}</span>
        <span>{@job.duration}</span>
        <span>{@job.when}</span>
      </div>
      <div :if={@job.progress} class="h-1 overflow-hidden rounded-full bg-sunken">
        <div
          id={"#{@id}-progress"}
          class="dashboard-progress h-full rounded-full"
          style={"width: #{@job.progress}%"}
        >
        </div>
      </div>
    </li>
    """
  end

  @doc """
  The job status chips, each with its count, patching the URL. The chips carry the
  `filter.pick` keys in order (`f 1` is All … `f 6` is Cancelled). The current one is marked
  `aria-current`, which shares the pressed look. The query chip follows the group.
  """
  attr :chips, :list, required: true, doc: "`[%{value, label, count, path}]`"
  attr :status, :string, required: true, doc: "the current status value"
  attr :query, :string, required: true, doc: "the current text filter"
  attr :clear, :string, required: true, doc: "the jobs path without q"

  def status_chips(assigns) do
    assigns = assign(assigns, chip_class: @chip, count_class: @count)

    ~H"""
    <div id="jobs-filters" class="flex flex-wrap items-center gap-2">
      <div
        id="jobs-chips"
        role="group"
        aria-label="Filter jobs by status"
        class="flex flex-wrap gap-2"
      >
        <.link
          :for={{chip, i} <- Enum.with_index(@chips)}
          id={"jobs-chip-#{chip.value}"}
          patch={chip.path}
          aria-current={chip.value == @status && "true"}
          class={@chip_class}
          {Keymap.attrs("filter.pick", i)}
        >
          {chip.label}
          <span id={"jobs-chip-#{chip.value}-count"} class={@count_class}>{chip.count}</span>
        </.link>
      </div>
      <.query_chip query={@query} clear={@clear} />
    </div>
    """
  end

  @doc """
  One draft as a card opening it in the dashboard's composer: title, engine name, stage
  count, a miniature of its workflow layout (or a placeholder when it has none) and its
  newest run's status when there is one.
  """
  attr :draft, :map, required: true, doc: "a `Domovoy.Composer.Draft`"
  attr :run, :map, default: nil, doc: "the draft's newest run with its summary, or nil"

  def workflow_card(assigns) do
    document = assigns.draft.document

    assigns =
      assign(assigns,
        meta: @meta,
        name: document["name"],
        stages: stage_count(document),
        points: layout_points(document)
      )

    ~H"""
    <.link
      id={"open-workflow-#{@draft.id}"}
      navigate={~p"/dashboard/workflows/#{@draft.id}"}
      class="soft-panel flex h-full flex-col gap-3 p-4"
    >
      <%!-- pr-10 keeps the title and last-run chip clear of the Delete button over this corner. --%>
      <header class="flex items-center gap-3 pr-10">
        <h2 class="min-w-0 flex-1 truncate text-lg font-medium">{@draft.title}</h2>
        <DomovoyWeb.ComposerRunComponents.summary_chip
          :if={@run}
          id={"workflow-#{@draft.id}-last-run"}
          summary={@run.summary}
        />
      </header>
      <.miniature :if={@points != []} id={"workflow-#{@draft.id}-miniature"} points={@points} />
      <div
        :if={@points == []}
        id={"workflow-#{@draft.id}-placeholder"}
        class="flex h-16 items-center justify-center rounded-field bg-sunken text-xs text-muted"
      >
        {stage_label(@stages)}
      </div>
      <p class={["flex flex-wrap gap-x-4 gap-y-1", @meta]}>
        <span :if={is_binary(@name)} class="font-mono">{@name}</span>
        <span id={"workflow-#{@draft.id}-stages"}>{stage_label(@stages)}</span>
      </p>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :points, :list, required: true, doc: "`[{x, y}]` in canvas pixels"

  defp miniature(assigns) do
    assigns = assign(assigns, :dots, scale(assigns.points))

    ~H"""
    <svg
      id={@id}
      aria-hidden="true"
      viewBox="0 0 160 64"
      class="h-16 w-full rounded-field bg-sunken"
    >
      <rect
        :for={{x, y} <- @dots}
        x={x - 6}
        y={y - 3}
        width="12"
        height="6"
        rx="1.5"
        class="fill-primary/70"
      />
    </svg>
    """
  end

  @spec stage_count(document :: map()) :: non_neg_integer()
  defp stage_count(%{"vertices" => vertices}) when is_map(vertices),
    do: Enum.count(vertices, fn {_name, vertex} -> match?(%{"kind" => "stage"}, vertex) end)

  defp stage_count(_document), do: 0

  @spec stage_label(count :: non_neg_integer()) :: String.t()
  defp stage_label(1), do: "1 stage"
  defp stage_label(count), do: "#{count} stages"

  # Only whole-number positions are drawn, so a malformed layout draws nothing.
  @spec layout_points(document :: map()) :: [{integer(), integer()}]
  defp layout_points(%{"layout" => %{"workflow" => %{} = positions}}) do
    for {_name, %{"x" => x, "y" => y}} <- positions, is_integer(x), is_integer(y), do: {x, y}
  end

  defp layout_points(_document), do: []

  # Fits the points into the 160x64 box with a margin, keeping their aspect ratio.
  @spec scale(points :: [{integer(), integer()}]) :: [{float(), float()}]
  defp scale(points) do
    {xs, ys} = Enum.unzip(points)
    {min_x, max_x} = Enum.min_max(xs)
    {min_y, max_y} = Enum.min_max(ys)
    factor = min(144 / max(max_x - min_x, 1), 52 / max(max_y - min_y, 1))
    offset_x = (160 - (max_x - min_x) * factor) / 2
    offset_y = (64 - (max_y - min_y) * factor) / 2

    for {x, y} <- points,
        do: {offset_x + (x - min_x) * factor, offset_y + (y - min_y) * factor}
  end

  @spec initials(name :: String.t()) :: String.t()
  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join(&String.first/1)
    |> String.slice(0, 2)
    |> String.upcase()
  end

  @spec project_tone(status :: atom()) :: String.t() | nil
  defp project_tone(:running), do: "running"
  defp project_tone(:healthy), do: "succeeded"
  defp project_tone(:failing), do: "failed"
  defp project_tone(:attention), do: "needs_you"
  defp project_tone(:idle), do: nil

  @spec job_tone(status :: atom()) :: String.t() | nil
  defp job_tone(status) when status in [:running, :succeeded, :failed], do: Atom.to_string(status)
  defp job_tone(_status), do: nil

  @spec status_icon(status :: atom()) :: String.t()
  defp status_icon(:running), do: "hero-play-circle"
  defp status_icon(:queued), do: "hero-clock"
  defp status_icon(:succeeded), do: "hero-check-circle"
  defp status_icon(:failed), do: "hero-x-circle"
  defp status_icon(:cancelled), do: "hero-minus-circle"

  @spec status_word(status :: atom()) :: String.t()
  defp status_word(status), do: status |> Atom.to_string() |> String.capitalize()
end
