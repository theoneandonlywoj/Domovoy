defmodule DomovoyWeb.DashboardComponents do
  @moduledoc """
  The dashboard's panels: the search bar, project cards, job rows, the job status chips
  and workflow cards.

  Status pills reuse the composer's `.run-pill` tones, so there is one pill system.
  """

  use DomovoyWeb, :html

  @chip "soft-btn inline-flex items-center gap-2 px-2.5 py-1 text-sm"
  @count "rounded-full bg-sunken px-1.5 text-xs text-muted"
  @meta "text-xs text-muted"

  @doc """
  The panel's search box. It sends `search` as you type, debounced.
  """
  attr :form, Phoenix.HTML.Form, required: true, doc: "a form `as: :search` with a `q` field"
  attr :placeholder, :string, required: true, doc: "the placeholder, also its accessible name"

  def search_bar(assigns) do
    ~H"""
    <.form for={@form} id="dashboard-search" phx-change="search" phx-submit="search">
      <.input
        field={@form[:q]}
        type="search"
        phx-debounce="300"
        placeholder={@placeholder}
        aria-label={@placeholder}
      />
    </.form>
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
  The job status chips, each with its count, patching the URL. The current one is marked
  `aria-current`, which shares the pressed look.
  """
  attr :chips, :list, required: true, doc: "`[%{value, label, count, path}]`"
  attr :status, :string, required: true, doc: "the current status value"

  def status_chips(assigns) do
    assigns = assign(assigns, chip_class: @chip, count_class: @count)

    ~H"""
    <div id="jobs-chips" role="group" aria-label="Filter jobs by status" class="flex flex-wrap gap-2">
      <.link
        :for={chip <- @chips}
        id={"jobs-chip-#{chip.value}"}
        patch={chip.path}
        aria-current={chip.value == @status && "true"}
        class={@chip_class}
      >
        {chip.label}
        <span id={"jobs-chip-#{chip.value}-count"} class={@count_class}>{chip.count}</span>
      </.link>
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
      <header class="flex items-center gap-3">
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
