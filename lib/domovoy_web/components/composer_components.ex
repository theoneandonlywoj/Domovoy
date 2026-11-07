defmodule DomovoyWeb.ComposerComponents do
  @moduledoc """
  The composer's hand-written pieces: the workflow and stage canvases, their cards, the
  inspectors, and the panels around them.

  Every control works by Tab and Enter, and every edit sends an ordinary event, so
  the composer doesn't depend on pointer gestures.

  Text inputs commit on submit or on blur. Committing forms set
  `phx-auto-recover="ignore"`, so a reconnect can't re-apply a stale value.
  """

  use DomovoyWeb, :html

  alias Domovoy.Composer

  @primary "soft-btn soft-btn-primary px-3 py-1.5 text-sm"
  @secondary "soft-btn px-3 py-1.5 text-sm"
  @quiet "soft-btn soft-btn-quiet whitespace-nowrap px-1.5 py-0.5 text-xs"
  @danger "soft-btn soft-btn-danger px-3 py-1.5 text-sm"
  @section_title "text-xs font-semibold uppercase tracking-wide text-muted"

  @doc """
  One plugin's status: installed or not, and whether its suite is verified.
  """
  attr :plugin, :map, required: true

  def plugin_status(assigns) do
    ~H"""
    <span
      id={"plugin-#{@plugin.id}"}
      class={[
        "soft-chip inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs",
        @plugin.installed? && "text-base-content"
      ]}
    >
      <span class="font-medium">{@plugin.name}</span>
      <span id={"plugin-#{@plugin.id}-status"}>{plugin_state(@plugin)}</span>
    </span>
    """
  end

  defp plugin_state(%{installed?: false}), do: "not installed"
  defp plugin_state(%{verified?: true}), do: "verified"
  defp plugin_state(_plugin), do: "installed, not verified"

  @doc """
  The title, engine target, Validate, validity, fingerprint, Export and Undo.
  """
  attr :draft, :map, required: true
  attr :stage, :string, default: nil
  attr :validity, :map, default: nil
  attr :undo?, :boolean, required: true
  attr :tools_open?, :boolean, required: true
  attr :issue_count, :integer, required: true
  attr :runs_enabled?, :boolean, default: false
  attr :latest_run, :string, default: nil, doc: "the id of the newest unfinished run"

  def composer_header(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <header
      id="composer-header"
      class="soft-panel flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2"
    >
      <nav id="breadcrumb" aria-label="Breadcrumb" class="min-w-0 text-sm">
        <.link
          navigate={~p"/composer"}
          class="soft-link"
        >
          Drafts
        </.link>
        <span class="text-muted">/</span>
        <span id="draft-title" class="font-semibold">{@draft.title}</span>
        <span class="text-muted">/</span>
        <.link
          :if={@stage}
          id="breadcrumb-workflow"
          patch={composer_path(@draft.id, nil, nil)}
          class="soft-link"
        >
          Workflow
        </.link>
        <span :if={!@stage} id="breadcrumb-workflow">Workflow</span>
        <span :if={@stage} class="text-muted">/</span>
        <span :if={@stage} id="breadcrumb-stage">{@stage}</span>
        <span :if={@stage} class="text-muted">/ Stage graph</span>
      </nav>

      <span
        id="engine-target"
        class="soft-chip rounded-full px-2 py-0.5 text-xs"
      >
        Core 0.3.4
      </span>

      <div class="ml-auto flex items-center gap-2">
        <span
          :if={@validity}
          id="definition-valid"
          class="inline-flex items-center gap-1 text-sm font-medium text-success"
        >
          <.icon name="hero-check-circle" class="size-4" /> Definition valid
        </span>
        <code
          :if={@validity}
          id="definition-fingerprint"
          title={@validity.fingerprint}
          class="max-w-32 truncate text-xs text-muted"
        >
          {@validity.fingerprint}
        </code>
        <button
          id="open-tools"
          type="button"
          phx-click="open_tools"
          aria-expanded={to_string(@tools_open?)}
          aria-controls="composer-tools"
          class={@secondary}
        >
          <.icon name="hero-adjustments-horizontal" class="size-4" /> Issues / Tools
          <span id="tools-issue-count">{@issue_count}</span>
        </button>
        <button id="undo" type="button" phx-click="undo" disabled={not @undo?} class={@secondary}>
          Undo
        </button>
        <button
          id="validate"
          type="button"
          phx-click="validate"
          phx-disable-with="Validating…"
          class={@secondary}
        >
          Validate
        </button>
        <.link
          :if={@validity}
          id="export"
          href={~p"/composer/#{@draft.id}/export"}
          class={@secondary}
        >
          Export
        </.link>
        <.link
          :if={@runs_enabled? && @latest_run}
          id="latest-run-link"
          patch={composer_path(@draft.id, @stage, @latest_run)}
          class="soft-link text-sm"
        >
          Unfinished run
        </.link>
        <button
          :if={@runs_enabled?}
          id="start-run"
          type="button"
          phx-click="open_start"
          class={@primary}
        >
          Start
        </button>
      </div>
    </header>
    """
  end

  @doc """
  The stale-tab banner, and the explanation of a rejected edit with its adapters.
  """
  attr :conflict, :boolean, required: true
  attr :rejection, :map, default: nil

  def notices(assigns) do
    assigns = assign(assigns, secondary: @secondary, quiet: @quiet)

    ~H"""
    <div
      :if={@conflict}
      id="conflict-banner"
      role="alert"
      class="soft-panel flex items-center gap-3 px-4 py-2 text-sm"
    >
      <span class="flex-1 text-warning">Another tab saved this draft. Your last edit wasn't saved.</span>
      <button id="load-latest" type="button" phx-click="load_latest" class={@secondary}>
        Load latest
      </button>
    </div>

    <div
      :if={@rejection}
      id="rejection"
      role="alert"
      class="soft-panel flex flex-wrap items-center gap-3 px-4 py-2 text-sm"
    >
      <span id="rejection-message" class="min-w-0 flex-1 text-error">
        {@rejection.issue.message}
        <code :if={@rejection.issue.core_id} id="rejection-core-id" class="text-xs text-muted">
          {@rejection.issue.core_id}
        </code>
      </span>
      <button
        :for={adapter <- adapters(@rejection)}
        id={"adapter-#{adapter.dom_id}"}
        type="button"
        phx-click="insert_adapter"
        phx-value-runner={adapter.id}
        class={@secondary}
      >
        Insert {adapter.label}
      </button>
      <button
        id="dismiss-rejection"
        type="button"
        phx-click="dismiss_rejection"
        aria-label="Dismiss"
        class={[@quiet, "text-base-content"]}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  The composer's path: a draft at a level, and in a run when `run_id` is set.
  """
  @spec composer_path(
          draft_id :: String.t(),
          stage :: String.t() | nil,
          run_id :: String.t() | nil
        ) :: String.t()
  def composer_path(draft_id, nil, nil), do: ~p"/composer/#{draft_id}"
  def composer_path(draft_id, nil, run_id), do: ~p"/composer/#{draft_id}?#{[run: run_id]}"
  def composer_path(draft_id, stage, nil), do: ~p"/composer/#{draft_id}/stages/#{stage}"

  def composer_path(draft_id, stage, run_id),
    do: ~p"/composer/#{draft_id}/stages/#{stage}?#{[run: run_id]}"

  defp adapters(%{connect: nil}), do: []

  defp adapters(%{issue: issue}) do
    Enum.map(issue.adapters, &Map.put(&1, :dom_id, String.replace(&1.id, ".", "-")))
  end

  @doc """
  Engine name and title.
  """
  attr :draft, :map, required: true
  attr :name, :string, required: true

  def workflow_settings(assigns) do
    assigns =
      assign(assigns,
        section_title: @section_title,
        name_form: to_form(%{"value" => assigns.name}, as: :workflow_name, id: "workflow-name"),
        title_form: to_form(%{"value" => assigns.draft.title}, as: :title, id: "workflow-title")
      )

    ~H"""
    <section id="workflow-settings" tabindex="-1" aria-label="Workflow settings" class="space-y-2 p-3">
      <h2 class={@section_title}>Workflow</h2>
      <.form for={@title_form} id="title-form" phx-submit="save_title" phx-auto-recover="ignore">
        <.input field={@title_form[:value]} type="text" label="Title" phx-blur="save_title" />
      </.form>
      <.form
        for={@name_form}
        id="workflow-name-form"
        phx-submit="set_workflow_name"
        phx-auto-recover="ignore"
      >
        <.input
          field={@name_form[:value]}
          type="text"
          label="Engine name"
          phx-blur="set_workflow_name"
        />
      </.form>
    </section>
    """
  end

  @doc """
  Workflow inputs, each usable as a source, and the form that adds or changes one.
  """
  attr :inputs, :list, required: true
  attr :prior, :list, default: []
  attr :connect?, :boolean, default: true
  attr :form, :any, required: true
  attr :types, :list, required: true

  def input_rail(assigns) do
    assigns = assign(assigns, section_title: @section_title, secondary: @secondary)

    ~H"""
    <section
      id="inputs-rail"
      aria-label="Workflow inputs"
      class="space-y-2 border-t border-base-300 p-3"
    >
      <h2 class={@section_title}>Inputs</h2>
      <ul id="inputs-rows" class="space-y-1.5">
        <.input_row :for={input <- @inputs} :key={input.name} input={input} connect?={@connect?} />
      </ul>
      <.prior_sources :if={@prior != []} sources={@prior} />
      <.input_form form={@form} types={@types} />
    </section>
    """
  end

  attr :sources, :list, required: true

  defp prior_sources(assigns) do
    assigns = assign(assigns, quiet: @quiet, section_title: @section_title)

    ~H"""
    <h2 class={["pt-2", @section_title]}>From earlier</h2>
    <ul id="prior-sources" class="space-y-1.5">
      <li
        :for={source <- @sources}
        :key={source.name}
        id={source.dom_id}
        class="soft-row relative px-2 py-1.5 text-xs"
      >
        <span
          :if={not source.bound?}
          data-socket={source.socket}
          data-source={source.name}
          aria-hidden="true"
          title="Drag onto a field to bind it"
          class="socket socket-out -right-[6px]"
        ></span>
        <p id={"#{source.dom_id}-origin"} class="break-words pr-2">{source.origin}</p>
        <p id={"#{source.dom_id}-generation"} class="text-muted">
          may be from an earlier generation
        </p>
        <button
          :if={not source.bound?}
          id={"#{source.dom_id}-connect"}
          type="button"
          phx-click={JS.push_focus() |> JS.push("open_connect", value: %{source: source.name})}
          class={@quiet}
        >
          Connect to
        </button>
      </li>
    </ul>
    <p id="any-across-stages" class="text-xs text-muted">
      Across stages, Any matches only Any. An Any field can read one of these only while
      another field of this stage reads it with its concrete type.
    </p>
    """
  end

  attr :input, :map, required: true
  attr :connect?, :boolean, required: true

  defp input_row(assigns) do
    assigns = assign(assigns, quiet: @quiet)

    ~H"""
    <li
      id={@input.dom_id}
      tabindex="-1"
      class={["soft-row relative px-2 py-1.5 text-sm", @input.issues != [] && "ring-2 ring-error"]}
    >
      <span
        :if={@connect?}
        data-socket={@input.socket}
        data-source={@input.name}
        aria-hidden="true"
        title="Drag onto a field to bind it"
        class="socket socket-out -right-[6px]"
      ></span>
      <div class="flex items-center gap-1">
        <span class="min-w-0 flex-1 truncate font-medium">{@input.name}</span>
        <.description_icon id={"#{@input.dom_id}-description"} description={@input.description} />
        <.type_chip label={@input.type_label} />
      </div>
      <div class="mt-1 flex flex-wrap items-center gap-1 text-xs text-muted">
        <span id={"#{@input.dom_id}-required"}>
          {if @input.required, do: "required", else: "optional"}
        </span>
        <span>·</span>
        <span id={"#{@input.dom_id}-default"}>{default_label(@input)}</span>
        <span class="flex-1"></span>
        <button
          :if={@connect?}
          id={"#{@input.dom_id}-connect"}
          type="button"
          phx-click={JS.push_focus() |> JS.push("open_connect", value: %{source: @input.name})}
          class={@quiet}
        >
          Connect to
        </button>
        <button
          id={"#{@input.dom_id}-edit"}
          type="button"
          phx-click="edit_input"
          phx-value-name={@input.name}
          class={@quiet}
        >
          Edit
        </button>
        <button
          id={"#{@input.dom_id}-remove"}
          type="button"
          phx-click="remove_input"
          phx-value-name={@input.name}
          class={@quiet}
        >
          Remove
        </button>
      </div>
    </li>
    """
  end

  defp default_label(%{default_state: :absent}), do: "no default"
  defp default_label(%{default_state: :null}), do: "null default"
  defp default_label(%{default_state: :value}), do: "has default"

  attr :form, :any, required: true
  attr :types, :list, required: true

  defp input_form(assigns) do
    editor = Composer.literal_editor(assigns.form[:type].value)

    assigns =
      assign(assigns,
        primary: @primary,
        editor: editor,
        value?: assigns.form[:default_state].value == "value"
      )

    ~H"""
    <.form
      for={@form}
      id="inputs-form"
      phx-change="preview_input"
      phx-submit="save_input"
      phx-auto-recover="ignore"
      class="soft-row space-y-1 p-2"
    >
      <.input field={@form[:name]} type="text" label="Name" />
      <.input
        field={@form[:type]}
        type="select"
        label="Type"
        options={Enum.map(@types, &{&1.label, &1.id})}
      />
      <.input field={@form[:required]} type="checkbox" label="Required" />
      <p :if={@editor == :bind_only} id="inputs-bind-only" class="text-xs text-muted">
        Values of this type come only through a binding, so it can't have a default.
      </p>
      <%= if @editor != :bind_only do %>
        <.input
          field={@form[:default_state]}
          type="select"
          label="Default"
          options={[{"None", "absent"}, {"Null", "null"}, {"Value", "value"}]}
        />
        <.literal_input :if={@value?} editor={@editor} field={@form[:default]} label="Default value" />
      <% end %>
      <button id="save-input" type="submit" class={@primary}>Save input</button>
    </.form>
    """
  end

  attr :editor, :atom, required: true
  attr :field, :any, required: true
  attr :label, :string, default: nil
  attr :rest, :global

  defp literal_input(%{editor: :boolean} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label={@label}
      prompt="Not set"
      options={["true", "false"]}
      {@rest}
    />
    """
  end

  defp literal_input(%{editor: editor} = assigns) when editor in [:json, :json_object] do
    ~H"""
    <.input field={@field} type="textarea" label={@label} rows="2" {@rest} />
    """
  end

  defp literal_input(assigns) do
    ~H"""
    <.input field={@field} type="text" label={@label} {@rest} />
    """
  end

  @doc """
  Searches the catalog and adds the picked runner as a node.
  """
  attr :runners, :any, required: true
  attr :plugins, :list, required: true
  attr :query, :string, required: true
  attr :picked, :map, default: nil
  attr :source, :string, default: nil
  attr :form, :any, required: true

  def catalog_picker(assigns) do
    assigns =
      assign(assigns,
        primary: @primary,
        quiet: @quiet,
        section_title: @section_title,
        search: to_form(%{"text" => assigns.query}, as: :catalog, id: "catalog")
      )

    ~H"""
    <section
      id="catalog-picker"
      aria-label="Runner catalog"
      class="space-y-2 border-t border-base-300 p-3"
    >
      <div class="flex items-center">
        <h2 class={["flex-1", @section_title]}>Add a runner</h2>
        <button
          :if={@picked || @source}
          id="close-picker"
          type="button"
          phx-click="close_picker"
          class={@quiet}
        >
          Close
        </button>
      </div>
      <p :if={@source} id="picker-source" class="text-xs text-muted">
        Runners that can read {@source}.
      </p>
      <.form for={@search} id="catalog-search" phx-change="catalog_search" phx-submit="catalog_search">
        <.input
          field={@search[:text]}
          type="search"
          label="Search runners or types"
          phx-debounce="150"
        />
      </.form>

      <.form
        :if={@picked}
        for={@form}
        id="add-node-form"
        phx-submit="add_node"
        phx-auto-recover="ignore"
      >
        <p id="picked-runner" class="mb-1 text-xs text-muted">{@picked.label}</p>
        <.input field={@form[:runner]} type="hidden" />
        <.input field={@form[:name]} type="text" label="Node name" />
        <button id="add-node" type="submit" class={@primary}>Add node</button>
      </.form>

      <ul id="catalog-runners" phx-update="stream" class="max-h-64 space-y-0.5 overflow-y-auto">
        <li id="catalog-empty" class="hidden py-2 text-xs text-muted only:block">
          No runner matches.
        </li>
        <li :for={{id, runner} <- @runners} id={id}>
          <button
            id={"pick-#{id}"}
            type="button"
            phx-click="pick_runner"
            phx-value-runner={runner.id}
            class="w-full rounded-lg px-2 py-1 text-left text-sm transition-colors hover:bg-sunken"
          >
            <span class="block truncate">{runner.label}</span>
            <span class="block truncate text-xs text-muted">{runner.plugin}</span>
          </button>
        </li>
      </ul>

      <ul id="catalog-plugins" aria-label="Plugin status" class="flex flex-wrap gap-1">
        <li :for={plugin <- @plugins}><.plugin_status plugin={plugin} /></li>
      </ul>
    </section>
    """
  end

  @doc """
  Names a canvas level: a gesture on one world must not land on another.
  """
  @spec canvas_level(stage :: String.t() | nil) :: String.t()
  def canvas_level(nil), do: "workflow"
  def canvas_level(stage), do: "stage:#{stage}"

  @doc """
  The stage's cards and source nodes, placed at their positions, and the wire layer the
  `ComposerCanvas` hook owns. The hook adds pan, zoom, drag and connect gestures; each
  ends in an ordinary event, and rules stay on the server.
  """
  attr :cards, :list, required: true
  attr :sources, :list, default: []
  attr :edges, :list, required: true
  attr :selected, :string, default: nil
  attr :run_statuses, :map, default: %{}
  attr :read_only?, :boolean, default: false

  attr :stage, :string, required: true

  def stage_canvas(assigns) do
    ~H"""
    <.canvas_frame
      label="Stage graph"
      level={canvas_level(@stage)}
      edges={@edges}
      read_only?={@read_only?}
    >
      <:empty :if={@cards == []}>
        This stage has no nodes yet. Pick a runner on the left to add one.
      </:empty>
      <.runner_card
        :for={card <- @cards}
        :key={card.name}
        card={card}
        selected?={card.name == @selected}
        run_status={@run_statuses[card.name]}
      />
      <.source_node :for={source <- @sources} :key={source.name} source={source} />
    </.canvas_frame>
    """
  end

  @doc """
  The workflow's Stage and Decision cards, on the same layer and gestures as a stage's
  runner cards. Dragging a Stage's handle onto a card sets its single next route.
  """
  attr :cards, :list, required: true
  attr :edges, :list, required: true
  attr :selected, :string, default: nil
  attr :draft_id, :string, required: true
  attr :run_statuses, :map, default: %{}
  attr :read_only?, :boolean, default: false
  attr :run_id, :string, default: nil

  def workflow_canvas(assigns) do
    ~H"""
    <.canvas_frame
      label="Workflow graph"
      level={canvas_level(nil)}
      edges={@edges}
      read_only?={@read_only?}
    >
      <:empty :if={@cards == []}>
        This draft has no vertices yet. Add a stage on the left.
      </:empty>
      <.vertex_card
        :for={card <- @cards}
        :key={card.name}
        card={card}
        selected?={card.name == @selected}
        draft_id={@draft_id}
        run_status={@run_statuses[card.name]}
        run_id={@run_id}
      />
    </.canvas_frame>
    """
  end

  attr :label, :string, required: true
  attr :level, :string, required: true
  attr :edges, :list, required: true
  attr :read_only?, :boolean, required: true
  slot :empty
  slot :inner_block, required: true

  defp canvas_frame(assigns) do
    ~H"""
    <section
      id="stage-canvas"
      tabindex="-1"
      aria-label={@label}
      data-read-only={@read_only?}
      class="soft-tray relative touch-none select-none overflow-hidden"
    >
      <p :if={@empty != []} id="canvas-empty" class="p-8 text-sm text-muted">
        {render_slot(@empty)}
      </p>
      <div id="stage-world" data-level={@level} class="absolute left-0 top-0 origin-top-left">
        <div
          id="composer-wires"
          phx-hook="ComposerCanvas"
          phx-update="ignore"
          data-edges={Jason.encode!(@edges)}
          class="pointer-events-none absolute left-0 top-0"
        >
        </div>
        {render_slot(@inner_block)}
      </div>
      <div
        id="canvas-zoom"
        role="group"
        aria-label="Canvas zoom"
        data-canvas-control
        class="soft-panel absolute bottom-3 right-3 z-20 flex items-center gap-1 p-1.5 text-xs"
      >
        <input
          id="canvas-zoom-slider"
          type="range"
          min="25"
          max="200"
          step="5"
          value="100"
          aria-label="Canvas zoom level"
          aria-valuetext="100%"
          phx-update="ignore"
          class="ml-1 h-8 w-36 cursor-pointer accent-[var(--color-primary)]"
        />
        <output
          id="canvas-zoom-percent"
          aria-label="Canvas zoom percentage"
          aria-live="polite"
          class="min-w-12 text-center tabular-nums"
        >100%</output>
        <button
          id="canvas-zoom-reset"
          type="button"
          aria-label="Reset canvas view"
          class="soft-btn ml-1 cursor-pointer h-8 px-3"
        >
          Reset
        </button>
      </div>
      <p
        id="canvas-notice"
        phx-update="ignore"
        aria-live="polite"
        class="soft-row pointer-events-none absolute bottom-3 left-3 z-20 max-w-md px-2 py-1 text-xs empty:hidden"
      >
      </p>
    </section>
    """
  end

  attr :card, :map, required: true
  attr :selected?, :boolean, required: true
  attr :draft_id, :string, required: true
  attr :run_status, :string, default: nil
  attr :run_id, :string, default: nil

  defp vertex_card(assigns) do
    assigns = assign(assigns, quiet: @quiet)

    ~H"""
    <article
      id={@card.dom_id}
      aria-label={"#{kind_label(@card.kind)} #{@card.name}"}
      data-node={@card.name}
      data-run-status={@run_status}
      data-x={@card.x}
      data-y={@card.y}
      style={"left:#{@card.x}px;top:#{@card.y}px"}
      class={[
        "soft-panel isolate absolute w-[280px] hover:z-10 focus-within:z-10",
        cond do
          @selected? -> "ring-2 ring-primary"
          @card.issue_count > 0 -> "ring-2 ring-error"
          true -> nil
        end
      ]}
    >
      <.run_pill :if={@run_status} id={"#{@card.dom_id}-run-status"} status={@run_status} />
      <header class="relative flex items-start gap-2 border-b border-base-300 px-3 py-2">
        <span
          data-socket={@card.in_socket}
          aria-hidden="true"
          class="socket socket-after -left-[6px]"
        ></span>
        <span
          :if={@card.out_socket}
          data-socket={@card.out_socket}
          data-after-source={@card.name}
          aria-hidden="true"
          title="Drag onto a card to route to it next"
          class="socket socket-after -right-[6px]"
        ></span>
        <button
          id={"#{@card.dom_id}-select"}
          data-card-grip
          type="button"
          phx-click="select_node"
          phx-value-node={@card.name}
          aria-pressed={to_string(@selected?)}
          class="soft-grip min-w-0 flex-1 text-left"
        >
          <span class="block truncate font-semibold">{@card.name}</span>
          <span class="block text-xs text-muted">{kind_label(@card.kind)}</span>
        </button>
        <.description_icon id={"#{@card.dom_id}-description"} description={@card.description} />
        <span
          :if={@card.start?}
          id={"#{@card.dom_id}-start"}
          class="soft-pill-active px-1.5 text-xs font-medium"
        >
          Start
        </span>
        <span
          :if={@card.issue_count > 0}
          id={"#{@card.dom_id}-issue-count"}
          class="soft-pill-failed px-1.5 text-xs font-medium"
        >
          {@card.issue_count}
        </span>
      </header>

      <div :if={@card.kind == "stage"} class="flex items-center gap-2 px-3 py-2 text-xs">
        <span id={"#{@card.dom_id}-nodes"}>{@card.node_count} nodes</span>
        <span
          id={if(@card.next, do: "#{@card.dom_id}-next", else: "#{@card.dom_id}-finish")}
          class="min-w-0 flex-1 truncate text-muted"
        >
          {if(@card.next, do: "then #{@card.next}", else: "Finish")}
        </span>
        <.link
          id={"#{@card.dom_id}-open"}
          data-card-open
          patch={composer_path(@draft_id, @card.name, @run_id)}
          class={@quiet}
        >
          Open
        </.link>
      </div>

      <p
        :if={@card.kind == "decision" and @card.choices == []}
        class="px-3 py-2 text-xs text-muted"
      >
        No choices yet.
      </p>
      <ul :if={@card.choices != []} class="divide-y divide-base-300 text-xs">
        <li
          :for={route <- @card.choices}
          :key={route.key}
          id={route.dom_id}
          tabindex="-1"
          class="relative px-3 py-1.5"
        >
          <span
            data-socket={route.socket}
            aria-hidden="true"
            class="socket socket-after -right-[6px]"
          ></span>
          <span class="font-medium">{route.name}</span>
          <span id={"#{route.dom_id}-route"} class="block truncate text-muted">
            {route.label}{if(route.target, do: " #{route.target}")}
          </span>
        </li>
      </ul>
    </article>
    """
  end

  @doc """
  A run status as a word, with a spinning icon while running. On a card it is placed
  over the edge, so it takes no layout space and moves no socket.
  """
  attr :id, :string, required: true
  attr :status, :string, required: true
  attr :class, :string, default: "run-pill-card"

  def run_pill(assigns) do
    ~H"""
    <span id={@id} data-run-pill={@status} class={["run-pill", @class]}>
      <span :if={@status == "running"} aria-hidden="true" class="flex">
        <.icon name="hero-arrow-path" class="run-spin size-3" />
      </span>
      {run_status_word(@status)}
    </span>
    """
  end

  @doc """
  The word for a run status.
  """
  @spec run_status_word(status :: String.t()) :: String.t()
  def run_status_word("running"), do: "Running"
  def run_status_word("succeeded"), do: "Done"
  def run_status_word("needs_you"), do: "Needs you"
  def run_status_word("uncertain"), do: "Check this"
  def run_status_word("failed"), do: "Failed"
  def run_status_word("interrupted"), do: "Interrupted"
  def run_status_word("cancelled"), do: "Cancelled"
  def run_status_word("skipped"), do: "Skipped"
  def run_status_word(_unknown), do: "Unknown"

  defp kind_label("stage"), do: "Stage"
  defp kind_label("decision"), do: "Decision"

  attr :card, :map, required: true
  attr :selected?, :boolean, required: true
  attr :run_status, :string, default: nil

  defp runner_card(assigns) do
    assigns = assign(assigns, quiet: @quiet)

    ~H"""
    <article
      id={@card.dom_id}
      aria-label={"Node #{@card.name}"}
      data-node={@card.name}
      data-run-status={@run_status}
      data-x={@card.x}
      data-y={@card.y}
      style={"left:#{@card.x}px;top:#{@card.y}px"}
      class={[
        "soft-panel isolate absolute w-[320px] hover:z-10 focus-within:z-10",
        cond do
          @selected? -> "ring-2 ring-primary"
          @card.issue_count > 0 -> "ring-2 ring-error"
          true -> nil
        end
      ]}
    >
      <.run_pill :if={@run_status} id={"#{@card.dom_id}-run-status"} status={@run_status} />
      <header class="relative flex items-start gap-2 border-b border-base-300 px-3 py-2">
        <span
          data-socket={@card.after_in_socket}
          aria-hidden="true"
          class="socket socket-after -left-[6px]"
        ></span>
        <span
          data-socket={@card.after_out_socket}
          data-after-source={@card.name}
          aria-hidden="true"
          title="Drag onto a node to make it run after this one"
          class="socket socket-after -right-[6px]"
        ></span>
        <button
          id={"#{@card.dom_id}-select"}
          data-card-grip
          type="button"
          phx-click="select_node"
          phx-value-node={@card.name}
          aria-pressed={to_string(@selected?)}
          class="soft-grip min-w-0 flex-1 text-left"
        >
          <span class="block truncate font-semibold">{@card.name}</span>
          <span id={"#{@card.dom_id}-runner"} class="block truncate text-xs text-muted">
            {@card.label}
          </span>
        </button>
        <.description_icon id={"#{@card.dom_id}-description"} description={@card.description} />
        <span
          :if={@card.issue_count > 0}
          id={"#{@card.dom_id}-issue-count"}
          class="soft-pill-failed px-1.5 text-xs font-medium"
        >
          {@card.issue_count}
        </span>
      </header>

      <p :for={issue <- @card.issues} class="px-3 pt-2 text-xs text-error">{issue.message}</p>

      <ul id={"#{@card.dom_id}-required"} class="divide-y divide-base-300 text-sm">
        <.field_row :for={row <- @card.required} :key={row.id} row={row} node={@card.name} />
        <.field_row :for={row <- @card.configured} :key={row.id} row={row} node={@card.name} />
      </ul>

      <details
        :if={@card.unset != []}
        id={"#{@card.dom_id}-optional"}
        phx-mounted={JS.ignore_attributes("open")}
        class="border-t border-base-300 text-sm"
      >
        <summary class="cursor-pointer px-3 py-1 text-xs text-muted">
          <span id={"#{@card.dom_id}-optional-count"}>{length(@card.unset)}</span> optional
        </summary>
        <ul class="divide-y divide-base-300">
          <.field_row :for={row <- @card.unset} :key={row.id} row={row} node={@card.name} />
        </ul>
      </details>

      <footer class="space-y-1 border-t border-base-300 px-3 py-2 text-xs text-muted">
        <div :if={@card.output} class="relative flex items-center gap-1">
          <span
            data-socket={@card.output_socket}
            data-source={@card.name}
            aria-hidden="true"
            title="Drag onto a field to bind it"
            class="socket socket-out -right-[18px]"
          ></span>
          <span>Output</span>
          <span id={"#{@card.dom_id}-output"}><.type_chip label={@card.output} /></span>
          <span class="flex-1"></span>
          <button
            id={"#{@card.dom_id}-connect"}
            type="button"
            phx-click={JS.push_focus() |> JS.push("open_connect", value: %{source: @card.name})}
            class={@quiet}
          >
            Connect to
          </button>
        </div>
        <div id={"#{@card.dom_id}-validators"}>
          <span :if={@card.inherited == [] and @card.added == []}>No validators</span>
          <span :for={validator <- @card.inherited} class="mr-1 inline-block">{validator.label}</span>
          <span :for={validator <- @card.added} class="mr-1 inline-block">{validator.label}</span>
        </div>
        <div id={"#{@card.dom_id}-policy"}>{policy_text(@card.policy)}</div>
      </footer>
    </article>
    """
  end

  attr :source, :map, required: true

  # Follows `runner_card`'s contract, so it syncs, drags and clears wires like a card. It
  # isn't selectable and takes no connection.
  defp source_node(assigns) do
    assigns = assign(assigns, quiet: @quiet, detail: source_detail(assigns.source))

    ~H"""
    <article
      id={@source.dom_id}
      aria-label={"#{source_kind_label(@source.kind)} #{@source.name}"}
      data-node={@source.name}
      data-source-node
      data-x={@source.x}
      data-y={@source.y}
      style={"left:#{@source.x}px;top:#{@source.y}px"}
      class={[
        "soft-panel isolate absolute w-[240px] px-3 py-2 text-xs hover:z-10 focus-within:z-10",
        @source.issues != [] && "ring-2 ring-error"
      ]}
    >
      <span
        data-socket={@source.socket}
        data-source={@source.name}
        aria-hidden="true"
        title="Drag onto a field to bind it"
        class="socket socket-out -right-[6px]"
      ></span>
      <div class="flex items-center gap-1">
        <span class="min-w-0 flex-1 truncate text-sm font-medium">{@source.name}</span>
        <.description_icon id={"#{@source.dom_id}-description"} description={@source.description} />
        <.type_chip label={@source.type_label} />
      </div>
      <div class="mt-1 flex items-center gap-1 text-muted">
        <span id={"#{@source.dom_id}-detail"} title={@detail} class="min-w-0 flex-1 truncate">
          {@detail}
        </span>
        <button
          id={@source.connect_id}
          type="button"
          phx-click={JS.push_focus() |> JS.push("open_connect", value: %{source: @source.name})}
          class={@quiet}
        >
          Connect to
        </button>
      </div>
    </article>
    """
  end

  defp source_kind_label(:input), do: "Input"
  defp source_kind_label(:prior), do: "Earlier source"

  defp source_detail(%{kind: :prior, row: row}), do: row.origin

  defp source_detail(%{kind: :input, row: row}) do
    "#{if row.required, do: "required", else: "optional"} · #{default_label(row)}"
  end

  defp policy_text(%{max_attempts: nil, store: store}) do
    "Declared policy unknown · #{store_text(store)}"
  end

  defp policy_text(policy) do
    "Max attempts #{policy.max_attempts} · #{policy.effect || "unknown"} effect · #{store_text(policy.store)}"
  end

  defp store_text(true), do: "stored"
  defp store_text(false), do: "not stored"

  attr :row, :map, required: true
  attr :node, :string, required: true

  defp field_row(assigns) do
    ~H"""
    <li
      id={@row.dom_id}
      tabindex="-1"
      data-node={@node}
      data-field={@row.id}
      class="relative px-3 py-1.5"
    >
      <span data-socket={@row.socket} aria-hidden="true" class="socket socket-in -left-[6px]"></span>
      <div class="flex items-center gap-1.5">
        <span class="min-w-0 flex-1 truncate">
          {@row.id}<span :if={@row.required} class="text-error" title="Required"> *</span>
        </span>
        <.type_chip label={@row.type_label} />
      </div>
      <p id={"#{@row.dom_id}-value"} class="truncate text-xs text-muted">
        <%= case @row.value do %>
          <% {:bind, source} -> %>
            reads <span class="font-medium">{source}</span>
            <span
              :if={@row.unresolved?}
              id={"#{@row.dom_id}-unresolved"}
              class="soft-pill-failed ml-1 px-1"
            >
              unresolved
            </span>
          <% {:literal, raw} -> %>
            <code>{raw}</code>
          <% :empty -> %>
            <span :if={@row.required} id={"#{@row.dom_id}-missing"} class="text-error">missing input</span>
            <span :if={!@row.required}>not set</span>
        <% end %>
      </p>
      <p :for={issue <- @row.issues} class="text-xs text-error">{issue.message}</p>
    </li>
    """
  end

  attr :label, :string, required: true

  defp type_chip(assigns) do
    ~H"""
    <span class="soft-chip shrink-0 px-1.5 py-0.5 text-[0.6875rem]">
      {@label}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :description, :any, required: true

  defp description_icon(%{description: :absent} = assigns), do: ~H""

  defp description_icon(%{description: {:ok, text}} = assigns) do
    assigns = assign(assigns, text: text)

    ~H"""
    <span id={@id} role="img" aria-label={@text} title={@text} class="flex shrink-0 text-muted">
      <.icon name="hero-information-circle" class="size-4" />
    </span>
    """
  end

  defp description_icon(%{description: :malformed} = assigns) do
    assigns = assign(assigns, text: "This description can't be read.")

    ~H"""
    <span id={@id} role="img" aria-label={@text} title={@text} class="flex shrink-0 text-error">
      <.icon name="hero-information-circle" class="size-4" />
    </span>
    """
  end

  @doc """
  One row and one delete control per binding and After edge.
  """
  attr :relationships, :list, required: true

  def relationship_list(assigns) do
    assigns = assign(assigns, section_title: @section_title, quiet: @quiet)

    ~H"""
    <section
      id="relationships"
      aria-label="Relationships"
      class="space-y-1 border-t border-base-300 p-3"
    >
      <h2 class={@section_title}>Relationships</h2>
      <p :if={@relationships == []} class="text-xs text-muted">None yet.</p>
      <ul class="space-y-0.5 text-sm">
        <li
          :for={row <- @relationships}
          :key={row.dom_id}
          id={row.dom_id}
          tabindex="-1"
          class="flex items-center gap-2"
        >
          <span
            id={"#{row.dom_id}-name"}
            aria-label={row.label}
            class={["min-w-0 flex-1 truncate", row.problem? && "text-error"]}
            title={row.label}
          >
            {row.label}
          </span>
          <button
            id={"#{row.dom_id}-delete"}
            type="button"
            phx-click={if(row.kind == :after, do: "remove_after", else: "clear_input")}
            phx-value-node={row.node}
            phx-value-field={row.field}
            phx-value-source={row.source}
            aria-label={"Delete: #{row.label}"}
            class={@quiet}
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  Every issue, each linking to and focusing what it is about.
  """
  attr :rows, :list, required: true
  attr :draft_id, :string, required: true

  def issue_list(assigns) do
    assigns = assign(assigns, section_title: @section_title)

    ~H"""
    <section id="issues" aria-label="Issues" class="space-y-1 p-3">
      <h2 class={@section_title}>Issues <span id="issue-count">{length(@rows)}</span></h2>
      <p :if={@rows == []} id="issues-empty" class="text-xs text-muted">No issues found.</p>
      <ol class="space-y-1 text-sm">
        <li
          :for={row <- @rows}
          :key={row.key}
          id={"issue-#{row.key}"}
          class="soft-note-failed px-2 py-1"
        >
          <.link
            :if={row.patch_workflow}
            patch={~p"/composer/#{@draft_id}"}
            class="block transition-colors hover:text-error"
          >
            {row.issue.message}
          </.link>
          <.link
            :if={row.patch_stage}
            patch={~p"/composer/#{@draft_id}/stages/#{row.patch_stage}"}
            class="block transition-colors hover:text-error"
          >
            {row.issue.message}
          </.link>
          <.link
            :if={!row.patch_stage and !row.patch_workflow}
            href={"##{row.anchor}"}
            phx-click={focus_issue(row)}
            class="block transition-colors hover:text-error"
          >
            {row.issue.message}
          </.link>
          <code :if={row.issue.core_id} id={"issue-#{row.key}-core-id"} class="text-xs text-muted">
            {row.issue.core_id}
          </code>
        </li>
      </ol>
    </section>
    """
  end

  defp focus_issue(%{node: nil, anchor: anchor}), do: JS.focus(to: "##{anchor}")

  defp focus_issue(%{issue: %{target: {:after, _, _, _}}, node: node, anchor: anchor}) do
    JS.push("select_node", value: %{node: node, focus: anchor, tools: true})
  end

  defp focus_issue(%{node: node, anchor: anchor}) do
    JS.push("select_node", value: %{node: node, focus: anchor})
  end

  @doc """
  Binds a source to any field of the stage. Incompatible fields stay selectable, so
  selecting one gives the explained rejection with its adapters.
  """
  attr :connect, :map, default: nil

  def connect_to(%{connect: nil} = assigns), do: ~H""

  def connect_to(assigns) do
    query = String.downcase(assigns.connect.query)

    assigns =
      assign(assigns,
        quiet: @quiet,
        section_title: @section_title,
        form: to_form(%{"query" => assigns.connect.query}, as: :connect, id: "connect"),
        targets:
          Enum.filter(
            assigns.connect.targets,
            &String.contains?(String.downcase("#{&1.node}.#{&1.field}"), query)
          )
      )

    ~H"""
    <section id="connect-to" aria-label="Connect to" class="space-y-1 border-t border-base-300 p-3">
      <div class="flex items-center">
        <h2 class={["flex-1", @section_title]}>Connect {@connect.source} to</h2>
        <button
          id="connect-close"
          type="button"
          phx-click={JS.push("close_connect") |> JS.pop_focus()}
          class={@quiet}
        >
          Close
        </button>
      </div>
      <.form for={@form} id="connect-search" phx-change="connect_search" phx-submit="connect_search">
        <.input field={@form[:query]} type="search" label="Search fields" phx-debounce="100" />
      </.form>
      <ul id="connect-targets" class="max-h-64 space-y-0.5 overflow-y-auto">
        <li :for={target <- @targets} :key={target.dom_id}>
          <button
            id={target.dom_id}
            type="button"
            phx-click={
              JS.push_focus()
              |> JS.push("connect",
                value: %{source: @connect.source, node: target.node, field: target.field}
              )
            }
            aria-label={target.label}
            class={[
              "flex w-full items-center gap-2 rounded-lg px-2 py-1 text-left text-sm transition-colors hover:bg-sunken",
              target.fit == :incompatible && "text-muted"
            ]}
          >
            <span class="min-w-0 flex-1 truncate">{target.node}.{target.field}</span>
            <.type_chip label={target.type_label} />
          </button>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  Asks before a binding replaces a literal. Escape cancels, and focus returns to the
  control that opened this.
  """
  attr :confirm, :map, default: nil

  def confirm_replace_literal(%{confirm: nil} = assigns), do: ~H""

  def confirm_replace_literal(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <div class="soft-scrim fixed inset-0 z-40 flex items-center justify-center">
      <div
        id="confirm-replace-literal"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="confirm-replace-title"
        phx-window-keydown={cancel_confirm()}
        phx-key="escape"
        class="soft-panel w-96 space-y-3 p-5"
      >
        <h2 id="confirm-replace-title" class="font-semibold">
          Replace the literal in {@confirm.node}.{@confirm.field}?
        </h2>
        <p class="text-sm text-muted">
          It will read {@confirm.source} instead. Undo brings the literal back.
        </p>
        <div class="flex justify-end gap-2">
          <button
            id="cancel-replace-literal"
            type="button"
            phx-mounted={JS.focus()}
            phx-click={cancel_confirm()}
            class={@secondary}
          >
            Cancel
          </button>
          <button
            id="confirm-replace-literal-button"
            type="button"
            phx-click={JS.push("confirm_replace_literal") |> JS.pop_focus()}
            class={@primary}
          >
            Replace
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp cancel_confirm, do: JS.push("cancel_replace_literal") |> JS.pop_focus()

  @doc """
  What clearing a field would break, such as an Any field losing its concrete sibling.
  """
  attr :clear, :map, default: nil

  def clear_input_preview(%{clear: nil} = assigns), do: ~H""

  def clear_input_preview(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <section id="clear-preview" class="space-y-1 border-t border-base-300 p-3 text-sm">
      <p class="font-medium text-warning">Clear {@clear.node}.{@clear.field}?</p>
      <ul id="clear-warnings" class="list-inside list-disc text-xs text-error">
        <li :for={issue <- @clear.warnings}>{issue.message}</li>
      </ul>
      <div class="flex justify-end gap-2 pt-1">
        <button
          id="cancel-clear-input"
          type="button"
          phx-click="cancel_clear_input"
          class={@secondary}
        >
          Cancel
        </button>
        <button
          id="confirm-clear-input"
          type="button"
          phx-click="confirm_clear_input"
          class={@primary}
        >
          Clear
        </button>
      </div>
    </section>
    """
  end

  @doc """
  Adds a Stage or a Decision.
  """
  attr :form, :any, required: true

  def add_vertex(assigns) do
    assigns = assign(assigns, primary: @primary, section_title: @section_title)

    ~H"""
    <section id="vertices" aria-label="Add a vertex" class="space-y-2 border-t border-base-300 p-3">
      <h2 class={@section_title}>Add to the workflow</h2>
      <.form
        for={@form}
        id="add-vertex-form"
        phx-change="preview_vertex"
        phx-submit={JS.push("add_vertex") |> JS.focus(to: "#add-vertex")}
        phx-auto-recover="ignore"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <.input
          field={@form[:kind]}
          type="select"
          label="Kind"
          options={[{"Stage", "stage"}, {"Decision", "decision"}]}
        />
        <button id="add-vertex" type="submit" class={@primary}>Add</button>
      </.form>
    </section>
    """
  end

  @doc """
  The limits Core applies to a workflow that loops. Static: they aren't editable here.
  """
  def loop_limits(assigns) do
    ~H"""
    <section id="loop-limits" class="border-t border-base-300 p-3 text-xs text-muted">
      This workflow loops. A run stops at Core's limits: max_generations 10, max_steps 1000.
    </section>
    """
  end

  @doc """
  The selected vertex: its start and route controls, and a Decision's prompt and choices.
  """
  attr :card, :map, default: nil
  attr :cards, :list, required: true
  attr :deciders, :list, required: true
  attr :types, :list, required: true
  attr :choice_form, :any, required: true

  def vertex_inspector(%{card: nil} = assigns) do
    ~H"""
    <section
      id="inspector"
      aria-label="Inspector"
      class="border-t border-base-300 p-3 text-xs text-muted"
    >
      Select a Stage or a Decision to edit it.
    </section>
    """
  end

  def vertex_inspector(assigns) do
    assigns =
      assign(assigns,
        quiet: @quiet,
        secondary: @secondary,
        danger: @danger,
        section_title: @section_title,
        others: Enum.map(assigns.cards, & &1.name) -- [assigns.card.name],
        next_form:
          to_form(%{"stage" => assigns.card.name, "vertex" => assigns.card.next || ""},
            as: :next,
            id: "next"
          )
      )

    ~H"""
    <section id="inspector" aria-label="Inspector" class="space-y-4 border-t border-base-300 p-3">
      <button
        id="deselect-node"
        type="button"
        phx-click="deselect_node"
        class={["float-right", @quiet]}
      >
        Close
      </button>
      <h3 class={@section_title}>{kind_label(@card.kind)} {@card.name}</h3>
      <p :for={issue <- @card.issues} class="text-xs text-error">{issue.message}</p>

      <.form
        :if={@card.kind == "stage"}
        for={@next_form}
        id="next-form"
        phx-change="set_next"
        phx-auto-recover="ignore"
      >
        <.input field={@next_form[:stage]} type="hidden" />
        <.input
          field={@next_form[:vertex]}
          type="select"
          label="Next"
          prompt="Finish"
          options={@others}
        />
      </.form>

      <.decision_inspector
        :if={@card.kind == "decision"}
        card={@card}
        cards={@cards}
        deciders={@deciders}
        types={@types}
        choice_form={@choice_form}
      />

      <div class="flex items-center gap-2">
        <button
          :if={!@card.start?}
          id="set-start"
          type="button"
          phx-click="set_start"
          phx-value-vertex={@card.name}
          class={@secondary}
        >
          Set as start
        </button>
        <button
          id="remove-vertex"
          type="button"
          phx-click="remove_vertex"
          phx-value-vertex={@card.name}
          class={@danger}
        >
          Remove
        </button>
      </div>
    </section>
    """
  end

  attr :card, :map, required: true
  attr :cards, :list, required: true
  attr :deciders, :list, required: true
  attr :types, :list, required: true
  attr :choice_form, :any, required: true

  defp decision_inspector(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        quiet: @quiet,
        secondary: @secondary,
        section_title: @section_title,
        form:
          to_form(
            %{
              "name" => card.name,
              "prompt" => card.prompt,
              "decider" => card.decider,
              "node" => card.decider_node
            },
            as: :decision,
            id: "decision"
          )
      )

    ~H"""
    <.form for={@form} id="decision-form" phx-submit="save_decision" phx-auto-recover="ignore">
      <.input field={@form[:name]} type="hidden" />
      <.input field={@form[:prompt]} type="textarea" label="Prompt" rows="2" />
      <.input
        field={@form[:decider]}
        type="select"
        label="Decider"
        options={Enum.map(@deciders, &{&1.label, &1.id})}
      />
      <.input
        field={@form[:node]}
        type="select"
        label="Node the decider reads"
        prompt="None"
        options={@card.node_names}
      />
      <button id="save-decision" type="submit" class={@secondary}>Save</button>
    </.form>

    <div id="decision-choices" class="space-y-1">
      <h3 class={@section_title}>Choices</h3>
      <ul class="space-y-1 text-sm">
        <li
          :for={route <- @card.choices}
          :key={route.key}
          class="soft-row p-2"
        >
          <div class="flex items-center gap-1">
            <span class="min-w-0 flex-1 truncate font-medium">{route.name}</span>
            <button
              id={"edit-#{route.dom_id}"}
              type="button"
              phx-click="edit_choice"
              phx-value-decision={@card.name}
              phx-value-name={route.name}
              class={@quiet}
            >
              Edit
            </button>
            <button
              id={"remove-#{route.dom_id}"}
              type="button"
              phx-click="remove_choice"
              phx-value-decision={@card.name}
              phx-value-name={route.name}
              class={@quiet}
            >
              Remove
            </button>
          </div>
          <p class="text-xs text-muted">{route.description}</p>
          <p class="text-xs text-muted">
            {route.label}{if(route.target, do: " #{route.target}")}
          </p>
          <p :for={{key, type} <- route.inputs} id={"#{route.dom_id}-input-#{key}"} class="text-xs">
            Input {key}: {type}
          </p>
          <p :for={issue <- route.issues} class="text-xs text-error">{issue.message}</p>
        </li>
      </ul>
    </div>

    <.choice_form form={@choice_form} card={@card} cards={@cards} types={@types} />
    """
  end

  attr :form, :any, required: true
  attr :card, :map, required: true
  attr :cards, :list, required: true
  attr :types, :list, required: true

  defp choice_form(assigns) do
    kind = assigns.form[:kind].value
    vertex = assigns.form[:vertex].value

    assigns =
      assign(assigns,
        primary: @primary,
        halt?: kind == "halt",
        typed?:
          kind == "rerun" and
            Enum.any?(assigns.cards, &(&1.name == vertex and &1.kind == "stage"))
      )

    ~H"""
    <.form
      for={@form}
      id="choice-form"
      phx-change="preview_choice"
      phx-submit={JS.push("save_choice") |> JS.focus(to: "#save-choice")}
      phx-auto-recover="ignore"
      class="soft-row space-y-1 p-2"
    >
      <input type="hidden" name="choice[decision]" value={@card.name} />
      <.input field={@form[:name]} type="text" label="Choice name" />
      <.input field={@form[:description]} type="text" label="Description" required />
      <.input
        field={@form[:kind]}
        type="select"
        label="Target"
        options={[{"Run", "run"}, {"Rerun / next generation", "rerun"}, {"Halt", "halt"}]}
      />
      <.input
        :if={!@halt?}
        field={@form[:vertex]}
        type="select"
        label="Vertex"
        prompt="Choose a vertex"
        options={Enum.map(@cards, & &1.name)}
      />
      <%= if @typed? do %>
        <p id="choice-new-generation" class="text-xs text-muted">
          This starts a new generation of the stage, which can read the inputs below.
        </p>
        <.input field={@form[:input_name]} type="text" label="Add an input" />
        <.input
          field={@form[:input_type]}
          type="select"
          label="Input type"
          options={Enum.map(@types, &{&1.label, &1.id})}
        />
      <% end %>
      <button id="save-choice" type="submit" class={@primary}>Save choice</button>
    </.form>
    """
  end

  @doc """
  What replacing a runner would change, before it commits as one undo entry.
  """
  attr :replace, :map, default: nil

  def replace_runner_preview(%{replace: nil} = assigns), do: ~H""

  def replace_runner_preview(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <div id="replace-runner-preview" class="soft-row space-y-1 p-2 text-sm">
      <p class="font-medium text-warning">Replace {@replace.node} with {@replace.label}?</p>
      <ul id="replace-dropped" class="list-inside list-disc text-xs">
        <li :for={{kind, id} <- @replace.preview.dropped} :key={id}>Drops {kind} {id}</li>
      </ul>
      <ul id="replace-consumers" class="list-inside list-disc text-xs">
        <li :for={consumer <- @replace.consumers} :key={consumer}>{consumer} reads this node</li>
      </ul>
      <ul id="replace-warnings" class="list-inside list-disc text-xs text-error">
        <li :for={issue <- @replace.preview.warnings ++ @replace.preview.new_issues}>
          {issue.message}
        </li>
      </ul>
      <div class="flex justify-end gap-2 pt-1">
        <button
          id="cancel-replace-runner"
          type="button"
          phx-click="cancel_replace_runner"
          class={@secondary}
        >
          Cancel
        </button>
        <button
          id="confirm-replace-runner"
          type="button"
          phx-click="confirm_replace_runner"
          class={@primary}
        >
          Replace
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The selected node's Runner, Inputs, Validations, Execution and Advanced sections.
  """
  attr :card, :map, default: nil
  attr :replace, :map, default: nil
  attr :runner_options, :list, required: true

  def inspector(%{card: nil} = assigns) do
    ~H"""
    <section
      id="inspector"
      aria-label="Inspector"
      class="border-t border-base-300 p-3 text-xs text-muted"
    >
      Select a node to edit it.
    </section>
    """
  end

  def inspector(assigns) do
    assigns = assign(assigns, quiet: @quiet)

    ~H"""
    <section id="inspector" aria-label="Inspector" class="space-y-4 border-t border-base-300 p-3">
      <button
        id="deselect-node"
        type="button"
        phx-click="deselect_node"
        class={["float-right", @quiet]}
      >
        Close
      </button>
      <.runner_section card={@card} replace={@replace} runner_options={@runner_options} />
      <.inputs_section card={@card} />
      <.validations_section card={@card} />
      <.execution_section card={@card} />
      <.advanced_section card={@card} />
    </section>
    """
  end

  attr :card, :map, required: true
  attr :replace, :map, default: nil
  attr :runner_options, :list, required: true

  defp runner_section(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        secondary: @secondary,
        section_title: @section_title,
        rename: to_form(%{"node" => card.name, "name" => card.name}, as: :rename, id: "rename"),
        swap:
          to_form(%{"node" => card.name, "runner" => card.runner_id}, as: :replace, id: "replace")
      )

    ~H"""
    <div id="inspector-runner" class="space-y-2">
      <h3 class={@section_title}>Runner</h3>
      <p id="inspector-runner-label" class="text-sm">{@card.label}</p>
      <.form for={@rename} id="rename-form" phx-submit="rename_node" phx-auto-recover="ignore">
        <.input field={@rename[:node]} type="hidden" />
        <.input
          field={@rename[:name]}
          type="text"
          label="Name"
          phx-blur="rename_node"
          phx-value-node={@card.name}
        />
      </.form>
      <.form
        for={@swap}
        id="replace-runner-form"
        phx-submit="preview_replace_runner"
        phx-auto-recover="ignore"
      >
        <.input field={@swap[:node]} type="hidden" />
        <.input field={@swap[:runner]} type="select" label="Replace with" options={@runner_options} />
        <button id="preview-replace-runner" type="submit" class={@secondary}>Preview</button>
      </.form>
      <.replace_runner_preview replace={@replace} />
    </div>
    """
  end

  attr :card, :map, required: true

  defp inputs_section(assigns) do
    assigns = assign(assigns, section_title: @section_title)

    ~H"""
    <div id="inspector-inputs" class="space-y-2">
      <h3 class={@section_title}>Inputs</h3>
      <.field_editor
        :for={row <- @card.required ++ @card.configured ++ @card.unset}
        :key={row.id}
        node={@card.name}
        row={row}
      />
    </div>
    """
  end

  attr :node, :string, required: true
  attr :row, :map, required: true

  defp field_editor(assigns) do
    row = assigns.row
    params = %{"node" => assigns.node, "field" => row.id}
    prefix = row.key

    literal =
      case row.value do
        {:literal, raw} -> raw
        _other -> ""
      end

    assigns =
      assign(assigns,
        quiet: @quiet,
        secondary: @secondary,
        prefix: prefix,
        literal_form:
          to_form(Map.put(params, "value", literal), as: :literal, id: "literal-#{prefix}"),
        bind_form: to_form(Map.put(params, "source", ""), as: :bind, id: "bind-#{prefix}")
      )

    ~H"""
    <div id={"editor-#{@prefix}"} class="soft-row space-y-1 p-2">
      <div class="flex items-center gap-1.5 text-sm">
        <span class="min-w-0 flex-1 truncate font-medium">{@row.id}</span>
        <.type_chip label={@row.type_label} />
        <button
          :if={@row.value != :empty}
          id={"clear-#{@prefix}"}
          type="button"
          phx-click="clear_input"
          phx-value-node={@node}
          phx-value-field={@row.id}
          class={@quiet}
        >
          Clear
        </button>
      </div>

      <p
        :if={match?({:bind, _source}, @row.value)}
        id={"reads-#{@prefix}"}
        class="text-xs text-muted"
      >
        reads {elem(@row.value, 1)}
      </p>

      <p
        :if={@row.editor == :bind_only and !match?({:bind, _source}, @row.value)}
        id={"bind-only-#{@prefix}"}
        class="text-xs text-muted"
      >
        Values of this type come only through a binding.
      </p>

      <.form
        :if={@row.editor != :bind_only and !match?({:bind, _source}, @row.value)}
        for={@literal_form}
        id={"literal-form-#{@prefix}"}
        phx-submit="commit_literal"
        phx-auto-recover="ignore"
      >
        <.input field={@literal_form[:node]} type="hidden" />
        <.input field={@literal_form[:field]} type="hidden" />
        <.literal_input
          editor={@row.editor}
          field={@literal_form[:value]}
          label="Literal"
          phx-blur="commit_literal"
          phx-value-node={@node}
          phx-value-field={@row.id}
        />
      </.form>

      <.form
        :if={@row.sources != []}
        for={@bind_form}
        id={"bind-form-#{@prefix}"}
        phx-submit={JS.push_focus() |> JS.push("bind_field")}
        phx-auto-recover="ignore"
        class="flex items-end gap-1"
      >
        <.input field={@bind_form[:node]} type="hidden" />
        <.input field={@bind_form[:field]} type="hidden" />
        <div class="min-w-0 flex-1">
          <.input
            field={@bind_form[:source]}
            type="select"
            label="Source"
            prompt="Choose a source"
            options={@row.sources}
          />
        </div>
        <button id={"bind-submit-#{@prefix}"} type="submit" class={["mb-2", @secondary]}>Bind</button>
      </.form>
    </div>
    """
  end

  attr :card, :map, required: true

  defp validations_section(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        section_title: @section_title,
        secondary: @secondary,
        quiet: @quiet,
        form: to_form(%{"node" => card.name, "validator" => ""}, as: :validator, id: "validator")
      )

    ~H"""
    <div id="inspector-validations" class="space-y-2">
      <h3 class={@section_title}>Validations</h3>
      <ol
        id="execution-order"
        class="list-inside list-decimal space-y-0.5 text-xs text-muted"
      >
        <li>Resolve bound values and literals.</li>
        <li>Cast the input and check required fields.</li>
        <li>Run the runner's validators, in order.</li>
        <li>Run this node's validators, in order.</li>
        <li>Run the runner, if the input is still valid.</li>
        <li>Cast the output to its declared type.</li>
      </ol>

      <ul id="inherited-validators" class="space-y-0.5 text-sm">
        <li :for={validator <- @card.inherited} :key={validator.id}>
          {validator.label}
          <span class="text-xs text-muted">inherited from {@card.label}</span>
        </li>
      </ul>

      <ul id="inspector-node-validators" class="space-y-0.5 text-sm">
        <li :for={validator <- @card.added} :key={validator.id} class="flex items-center gap-1">
          <span class="min-w-0 flex-1 truncate">{validator.label}</span>
          <button
            :for={{direction, icon} <- [{"up", "hero-arrow-up"}, {"down", "hero-arrow-down"}]}
            type="button"
            phx-click="move_validator"
            phx-value-node={@card.name}
            phx-value-id={validator.id}
            phx-value-direction={direction}
            aria-label={"Move #{validator.label} #{direction}"}
            class={@quiet}
          >
            <.icon name={icon} class="size-3.5" />
          </button>
          <button
            type="button"
            phx-click="remove_validator"
            phx-value-node={@card.name}
            phx-value-id={validator.id}
            aria-label={"Remove #{validator.label}"}
            class={@quiet}
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ul>

      <.form
        :if={@card.available != []}
        for={@form}
        id="add-validator-form"
        phx-submit="add_validator"
        phx-auto-recover="ignore"
        class="flex items-end gap-1"
      >
        <.input field={@form[:node]} type="hidden" />
        <div class="min-w-0 flex-1">
          <.input
            field={@form[:validator]}
            type="select"
            label="Add a validator"
            prompt="Choose a validator"
            options={Enum.map(@card.available, &{&1.label, &1.id})}
          />
        </div>
        <button id="add-validator" type="submit" class={["mb-2", @secondary]}>Add</button>
      </.form>
    </div>
    """
  end

  attr :card, :map, required: true

  defp execution_section(assigns) do
    card = assigns.card

    params = %{
      "node" => card.name,
      "max_attempts" => to_string(card.policy.override),
      "store" => to_string(card.policy.store)
    }

    assigns =
      assign(assigns,
        section_title: @section_title,
        secondary: @secondary,
        form: to_form(params, as: :execution, id: "execution")
      )

    ~H"""
    <div id="inspector-execution" class="space-y-1">
      <h3 class={@section_title}>Execution</h3>
      <.form for={@form} id="execution-form" phx-submit="set_execution" phx-auto-recover="ignore">
        <.input field={@form[:node]} type="hidden" />
        <.input
          field={@form[:max_attempts]}
          type="text"
          label="Max attempts"
          placeholder={"Declared: #{@card.policy.max_attempts}"}
        />
        <.input field={@form[:store]} type="checkbox" label="Store the output" />
        <button id="save-execution" type="submit" class={@secondary}>Save</button>
      </.form>
    </div>
    """
  end

  attr :card, :map, required: true

  defp advanced_section(assigns) do
    card = assigns.card

    assigns =
      assign(assigns,
        section_title: @section_title,
        secondary: @secondary,
        danger: @danger,
        form: to_form(%{"node" => card.name, "source" => ""}, as: :after, id: "after"),
        options: card.after_options -- card.after
      )

    ~H"""
    <div id="inspector-advanced" class="space-y-2">
      <h3 class={@section_title}>Advanced</h3>
      <p class="break-all text-xs text-muted">{@card.runner_id}</p>
      <.form
        :if={@options != []}
        for={@form}
        id="add-after-form"
        phx-submit="add_after"
        phx-auto-recover="ignore"
        class="flex items-end gap-1"
      >
        <.input field={@form[:node]} type="hidden" />
        <div class="min-w-0 flex-1">
          <.input
            field={@form[:source]}
            type="select"
            label="Run after"
            prompt="Choose a node"
            options={@options}
          />
        </div>
        <button id="add-after" type="submit" class={["mb-2", @secondary]}>Add</button>
      </.form>
      <button
        id="remove-node"
        type="button"
        phx-click="remove_node"
        phx-value-node={@card.name}
        class={@danger}
      >
        Delete node
      </button>
    </div>
    """
  end
end
