defmodule DomovoyWeb.ComposerRunComponents do
  @moduledoc """
  The composer's run pieces: the start form and its effect confirmation, the run
  header, the read-only workspace with its sidebar, a selected card's results, a
  person's decision form, recent runs, and the cancel dialog.

  A run page shows its snapshot: no control here edits a draft, and no input value is
  rendered back except a form's own text and a node's bounded output. No error reason
  is rendered, only its type and text written here.
  """

  use DomovoyWeb, :html

  import DomovoyWeb.ComposerComponents,
    only: [composer_path: 3, run_pill: 1, run_status_word: 1, stage_canvas: 1, workflow_canvas: 1]

  alias Domovoy.Catalog
  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.RunValues
  alias Domovoy.Composer.RunView

  @person "DomovoyCore.Decider.Person"

  @primary "soft-btn soft-btn-primary px-3 py-1.5 text-sm"
  @secondary "soft-btn px-3 py-1.5 text-sm"
  @quiet "soft-btn soft-btn-quiet whitespace-nowrap px-1.5 py-0.5 text-xs"
  @danger "soft-btn soft-btn-danger px-3 py-1.5 text-sm"
  @section_title "text-xs font-semibold uppercase tracking-wide text-muted"

  @doc """
  The start form, in the left rail. Fields keep what was typed after a refusal, and an
  error names the problem, never the value.
  """
  attr :start, :map, required: true

  def start_form(assigns) do
    blocking = Enum.filter(assigns.start.fields, &blocking?/1)

    assigns =
      assign(assigns,
        primary: @primary,
        secondary: @secondary,
        section_title: @section_title,
        blocking: blocking
      )

    ~H"""
    <section id="start-panel" aria-label="Start a run" class="space-y-3 p-3">
      <h2 class={@section_title}>Start a run</h2>
      <.effects_confirmation :if={@start.effects} start={@start} />
      <.form
        :if={!@start.effects}
        for={@start.form}
        id="start-form"
        phx-submit="submit_start"
        phx-auto-recover="ignore"
        class="space-y-2"
      >
        <p :if={@start.fields == []} class="text-sm text-muted">This workflow takes no inputs.</p>
        <.start_field
          :for={field <- @start.fields}
          field={field}
          form_field={@start.form[field.name]}
          error={@start.errors[field.name]}
        />
        <p :if={@blocking != []} id="start-blocked" class="text-sm text-warning">
          {Enum.map_join(@blocking, ", ", & &1.name)} can't be typed here, and this run needs {if length(
                                                                                                    @blocking
                                                                                                  ) ==
                                                                                                    1,
                                                                                                  do:
                                                                                                    "it",
                                                                                                  else:
                                                                                                    "them"}. Give {if length(
                                                                                                                        @blocking
                                                                                                                      ) ==
                                                                                                                        1,
                                                                                                                      do:
                                                                                                                        "it",
                                                                                                                      else:
                                                                                                                        "them"} a default in the draft to start.
        </p>
        <div class="flex gap-2">
          <button
            id="submit-start"
            type="submit"
            disabled={@blocking != [] or @start.pending?}
            class={@primary}
          >
            {if @start.pending?, do: "Starting…", else: "Start run"}
          </button>
          <button id="close-start" type="button" phx-click="close_start" class={@secondary}>
            Cancel
          </button>
        </div>
      </.form>
    </section>
    """
  end

  attr :field, :map, required: true
  attr :form_field, :any, required: true
  attr :error, :atom, default: nil

  defp start_field(%{field: %{editor: :none}} = assigns) do
    ~H"""
    <div id={"start-field-#{@field.name}"} class="text-sm">
      <p class="font-medium">{@field.name} <span class="text-muted">{@field.type}</span></p>
      <p class="text-xs text-muted">This type can't be typed here.</p>
    </div>
    """
  end

  defp start_field(assigns) do
    assigns =
      assign(assigns,
        errors: List.wrap(error_text(assigns.error, assigns.field)),
        label: "#{assigns.field.name} (#{assigns.field.type})",
        placeholder: if(assigns.field.default, do: "Leave blank for the default")
      )

    ~H"""
    <div id={"start-field-#{@field.name}"}>
      <.input
        :if={@field.editor == :boolean}
        type="select"
        id={@form_field.id}
        name={@form_field.name}
        value={@form_field.value}
        label={@label}
        prompt={if @field.default, do: "Default", else: "Not set"}
        options={["true", "false"]}
        errors={@errors}
      />
      <.input
        :if={@field.editor in [:json, :json_object]}
        type="textarea"
        id={@form_field.id}
        name={@form_field.name}
        value={@form_field.value}
        label={@label}
        rows="2"
        placeholder={@placeholder}
        errors={@errors}
      />
      <.input
        :if={@field.editor not in [:boolean, :json, :json_object]}
        type="text"
        id={@form_field.id}
        name={@form_field.name}
        value={@form_field.value}
        label={@label}
        placeholder={@placeholder}
        errors={@errors}
      />
    </div>
    """
  end

  @spec error_text(code :: atom() | nil, field :: map()) :: String.t() | nil
  defp error_text(nil, _field), do: nil
  defp error_text(:invalid, field), do: "This isn't a valid #{field.type}."
  defp error_text(:missing, _field), do: "This run needs a value here."
  defp error_text(:relative, _field), do: "Use an absolute path, starting with /."
  defp error_text(:input_error, _field), do: "Core refused this value. Check it and try again."

  # Without a text form and without a default, a needed input can't be given at all.
  @spec blocking?(field :: map()) :: boolean()
  defp blocking?(field) do
    field.editor == :none and (field.required or field.bound) and not is_binary(field.default)
  end

  @doc """
  The runners that can change things outside this app, confirmed before a start.
  """
  attr :start, :map, required: true

  def effects_confirmation(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <div id="start-effects" role="alertdialog" aria-labelledby="start-effects-title" class="space-y-2">
      <p id="start-effects-title" class="text-sm">
        These steps can change things outside this app. Check them before you start.
      </p>
      <ul id="start-effects-list" class="list-disc space-y-0.5 pl-5 text-sm">
        <li :for={effect <- @start.effects} id={"start-effect-#{dom_part(effect.id)}"}>
          {effect.label}
        </li>
      </ul>
      <div class="flex gap-2">
        <button
          id="confirm-start"
          type="button"
          phx-click="confirm_start"
          phx-mounted={JS.focus()}
          disabled={@start.pending?}
          class={@primary}
        >
          {if @start.pending?, do: "Starting…", else: "Start run"}
        </button>
        <button id="close-start" type="button" phx-click="close_start" class={@secondary}>
          Cancel
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The header of a run page: where it is, what the run needs, its controls and the way
  back to the draft. Notices about the run follow it.
  """
  attr :draft, :map, required: true
  attr :stage, :string, default: nil
  attr :run, :map, required: true

  def run_header(assigns) do
    controls = controls(assigns.run)

    assigns =
      assign(assigns,
        primary: @primary,
        secondary: @secondary,
        controls: controls,
        sentence: sentence(assigns.run),
        pending: if(controls == [:recover], do: [], else: pending(assigns.run.status))
      )

    ~H"""
    <header id="run-header" class="soft-panel flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2">
      <nav id="breadcrumb" aria-label="Breadcrumb" class="min-w-0 text-sm">
        <.link navigate={~p"/composer"} class="soft-link">Drafts</.link>
        <span class="text-muted">/</span>
        <span id="draft-title" class="font-semibold">{@draft.title}</span>
        <span class="text-muted">/</span>
        <span>Run <code id="run-id" class="text-xs">{String.slice(@run.id, 0, 8)}</code></span>
        <span class="text-muted">/</span>
        <.link
          :if={@stage}
          id="breadcrumb-workflow"
          patch={composer_path(@draft.id, nil, @run.id)}
          class="soft-link"
        >
          Workflow
        </.link>
        <span :if={!@stage} id="breadcrumb-workflow">Workflow</span>
        <span :if={@stage} class="text-muted">/</span>
        <span :if={@stage} id="breadcrumb-stage">{@stage}</span>
      </nav>

      <span id="engine-target" class="soft-chip rounded-full px-2 py-0.5 text-xs">Core 0.3.4</span>

      <p id="run-status" role="status" aria-live="polite" class="text-[15px] font-semibold">
        {@sentence}
      </p>

      <div class="ml-auto flex items-center gap-2">
        <.link
          :for={decision <- @pending}
          id={"run-pending-link-#{decision}"}
          patch={decision_path(@draft.id, @run.id, decision)}
          class={@secondary}
        >
          Answer {decision}
        </.link>
        <button
          :if={:recover in @controls}
          id="recover-run"
          type="button"
          phx-click="recover_run"
          class={@primary}
        >
          Recover
        </button>
        <button
          :if={:cancel in @controls}
          id="cancel-run"
          type="button"
          phx-click={JS.push_focus() |> JS.push("open_cancel_run")}
          class={@secondary}
        >
          Cancel run
        </button>
        <.link
          id="back-to-draft"
          patch={composer_path(@draft.id, @stage, nil)}
          class={@secondary}
        >
          Back to draft
        </.link>
      </div>
    </header>

    <.run_notices run={@run} draft_id={@draft.id} stage={@stage} />
    <.cancel_dialog :if={@run.cancel_open?} />
    """
  end

  attr :run, :map, required: true
  attr :draft_id, :string, required: true
  attr :stage, :string, default: nil

  defp run_notices(assigns) do
    assigns = assign(assigns, secondary: @secondary)

    ~H"""
    <div
      :if={@run.state == :never_started}
      id="run-never-started"
      role="status"
      class="soft-panel px-4 py-2 text-sm"
    >
      This run never started. Nothing ran, and nothing will.
    </div>
    <div
      :if={@run.state == :runner_unavailable}
      id="run-runner-unavailable"
      role="status"
      class="soft-panel px-4 py-2 text-sm text-warning"
    >
      A runner this run used is no longer in the catalog, so its state can't be read.
    </div>
    <div
      :if={@run.state == :definition_mismatch}
      id="run-definition-mismatch"
      role="status"
      class="soft-panel px-4 py-2 text-sm text-warning"
    >
      A runner's contract has changed since this run started, so it can't continue.
      <code class="text-xs text-muted">workflow_definition_mismatch</code>
    </div>
    <div
      :if={@run.state == :unavailable or @run.stale?}
      id="run-stale"
      role="alert"
      class="soft-panel flex items-center gap-3 px-4 py-2 text-sm"
    >
      <span class="flex-1 text-warning">
        This run's live status stopped updating, so what you see may be out of date.
      </span>
      <.link
        id="reload-run"
        navigate={composer_path(@draft_id, @stage, @run.id)}
        class={@secondary}
      >
        Reload
      </.link>
    </div>
    <div
      :if={@run.draft_changed?}
      id="run-draft-changed"
      role="status"
      class="soft-panel px-4 py-2 text-sm"
    >
      The draft has changed since this run started. This page shows the run as it started.
    </div>
    <div
      :if={@run.definition_changed?}
      id="run-definition-changed"
      role="status"
      class="soft-panel px-4 py-2 text-sm"
    >
      A runner has changed since this run.
    </div>
    """
  end

  @doc """
  The confirmation before a run is cancelled.
  """
  def cancel_dialog(assigns) do
    assigns = assign(assigns, secondary: @secondary, danger: @danger)

    ~H"""
    <div class="soft-scrim fixed inset-0 z-40 flex items-center justify-center">
      <div
        id="cancel-run-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="cancel-run-title"
        phx-window-keydown={JS.push("close_cancel_run") |> JS.pop_focus()}
        phx-key="escape"
        class="soft-panel w-96 space-y-3 p-5"
      >
        <h2 id="cancel-run-title" class="font-semibold">Cancel this run?</h2>
        <p class="text-sm text-muted">
          The step running now is stopped, and nothing after it runs. A cancelled run can't
          be resumed.
        </p>
        <div class="flex justify-end gap-2">
          <button
            id="close-cancel-run"
            type="button"
            phx-mounted={JS.focus()}
            phx-click={JS.push("close_cancel_run") |> JS.pop_focus()}
            class={@secondary}
          >
            Keep running
          </button>
          <button
            id="confirm-cancel-run"
            type="button"
            phx-click={JS.push("confirm_cancel_run") |> JS.pop_focus()}
            class={@danger}
          >
            Cancel run
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The run page below its header: recent runs and the snapshot's inputs, the read-only
  canvas with each card's status, and the summary rail, which is always open.
  """
  attr :draft, :map, required: true
  attr :stage, :string, default: nil
  attr :run, :map, required: true
  attr :view, :map, required: true
  attr :selected, :string, default: nil
  attr :recent, :list, required: true
  attr :document, :map, required: true

  def run_workspace(assigns) do
    fold = assigns.run.fold

    assigns =
      assign(assigns,
        statuses: RunView.card_statuses(fold, assigns.stage),
        edges: RunView.wire_statuses(fold, assigns.stage, assigns.view),
        section_title: @section_title
      )

    ~H"""
    <div
      id="run-workspace"
      class="grid min-h-0 flex-1 gap-4 max-lg:grid-cols-1 lg:grid-cols-[19rem_minmax(0,1fr)_24rem]"
    >
      <aside id="left-rail" class="soft-panel overflow-y-auto max-lg:order-3">
        <.recent_runs runs={@recent} draft_id={@draft.id} stage={@stage} current={@run.id} />
        <section id="run-inputs" aria-label="Inputs" class="space-y-2 border-t border-base-300 p-3">
          <h2 class={@section_title}>Inputs</h2>
          <p :if={@view.inputs == []} class="text-xs text-muted">This workflow takes no inputs.</p>
          <ul class="space-y-1.5">
            <li
              :for={input <- @view.inputs}
              :key={input.name}
              id={"run-#{input.dom_id}"}
              class="soft-row px-2 py-1.5 text-sm"
            >
              <div class="flex items-center gap-1">
                <span class="min-w-0 flex-1 truncate font-medium">{input.name}</span>
                <span class="soft-chip shrink-0 px-1.5 py-0.5 text-[0.6875rem]">
                  {input.type_label}
                </span>
              </div>
              <p :if={match?({:ok, _}, input.description)} class="mt-1 text-xs text-muted">
                {elem(input.description, 1)}
              </p>
            </li>
          </ul>
        </section>
      </aside>

      <.workflow_canvas
        :if={!@stage}
        cards={@view.cards}
        edges={@edges}
        selected={@selected}
        draft_id={@draft.id}
        run_statuses={@statuses}
        read_only?={true}
        run_id={@run.id}
      />
      <.stage_canvas
        :if={@stage}
        cards={@view.cards}
        sources={@view.source_nodes}
        edges={@edges}
        selected={@selected}
        stage={@stage}
        run_statuses={@statuses}
        read_only?={true}
      />

      <aside id="right-rail" class="soft-panel overflow-y-auto max-lg:order-2">
        <.run_summary
          run={@run}
          selected={@selected}
          statuses={@statuses}
          stage={@stage}
          document={@document}
          cards={@view.cards}
          draft_id={@draft.id}
        />
      </aside>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :selected, :string, default: nil
  attr :statuses, :map, required: true
  attr :stage, :string, default: nil
  attr :document, :map, required: true
  attr :cards, :list, required: true
  attr :draft_id, :string, required: true

  defp run_summary(assigns) do
    status = assigns.run.status

    detail =
      assigns.stage && RunView.node_detail(assigns.run.fold, assigns.document, assigns.selected)

    generation = detail && RunView.shown_generation(detail, assigns.run.generation)

    assigns =
      assign(assigns,
        quiet: @quiet,
        status: status,
        phase: status && RunView.phase(status),
        pending: pending(status),
        detail: detail,
        generation: generation,
        selected_status: selected_status(assigns, detail, generation),
        card: !assigns.stage && Enum.find(assigns.cards, &(&1.name == assigns.selected))
      )

    ~H"""
    <section id="run-summary" aria-label="Run" class="space-y-3 p-3 text-sm">
      <div :if={@selected} id="run-selected" class="space-y-3">
        <div class="space-y-1">
          <button
            id="deselect-node"
            type="button"
            phx-click="deselect_node"
            class={["float-right", @quiet]}
          >
            Close
          </button>
          <h2 id="run-selected-name" tabindex="-1" class="text-[15px] font-semibold">
            {@selected}
          </h2>
          <.run_pill
            :if={@selected_status}
            id="run-selected-status"
            status={@selected_status}
            class="run-pill-inline"
          />
          <p :if={!@selected_status && !@detail} id="run-selected-status" class="text-muted">
            Not run. The run didn't reach this step.
          </p>
        </div>
        <.node_results :if={@detail} detail={@detail} generation={@generation} result={@run.result} />
        <.vertex_results
          :if={@card && @card.kind == "stage"}
          stage={@selected}
          document={@document}
          detail={RunView.vertex_detail(@run.fold, @selected)}
        />
        <.decision_outcome
          :if={@card && @card.kind == "decision"}
          card={@card}
          detail={RunView.vertex_detail(@run.fold, @selected)}
        />
        <.decision_form
          :if={@card && @card.kind == "decision"}
          decision={@selected}
          card={@card}
          document={@document}
          run={@run}
        />
      </div>

      <h2 id="run-sentence" class={["text-[15px] font-semibold", @selected && "sr-only"]}>
        {sentence(@run)}
      </h2>
      <dl :if={@status} class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <dt class="text-muted">Phase</dt>
        <dd id="run-phase">{if RunView.frozen?(@status), do: "frozen", else: @phase}</dd>
        <dt class="text-muted">Outcome</dt>
        <dd id="run-outcome">{@status.outcome || "not yet"}</dd>
        <dt class="text-muted">Availability</dt>
        <dd id="run-availability">{@status.availability || "unknown"}</dd>
      </dl>
      <div :if={@pending != []} id="run-pending" class="space-y-1">
        <p :for={decision <- @pending}>
          <.link
            id={"run-pending-#{decision}"}
            patch={decision_path(@draft_id, @run.id, decision)}
            class="soft-link"
          >
            {decision} is waiting for a decision
          </.link>
        </p>
      </div>
    </section>
    """
  end

  # A node shows the status of the generation on screen; a workflow card its own.
  @spec selected_status(assigns :: map(), detail :: map() | nil, generation :: integer() | nil) ::
          String.t() | nil
  defp selected_status(_assigns, %{} = detail, generation) when is_integer(generation),
    do: detail.attempts[generation] |> List.last() |> RunView.attempt_status()

  defp selected_status(_assigns, %{}, nil), do: nil
  defp selected_status(assigns, nil, _generation), do: assigns.statuses[assigns.selected]

  @doc """
  A selected node's result, then its attempts and timing, runner and version, and
  where its inputs come from. Earlier generations stay selectable.
  """
  attr :detail, :map, required: true
  attr :generation, :integer, default: nil
  attr :result, :map, default: nil

  def node_results(assigns) do
    record = record(assigns.result)

    assigns =
      assign(assigns,
        quiet: @quiet,
        attempts:
          if(assigns.generation, do: assigns.detail.attempts[assigns.generation], else: []),
        version: record[:version]
      )

    ~H"""
    <div id="run-node-results" class="space-y-3">
      <div
        :if={length(@detail.generations) > 1}
        id="run-generations"
        role="group"
        aria-label="Generation"
        class="flex flex-wrap gap-1"
      >
        <button
          :for={generation <- @detail.generations}
          id={"run-generation-#{generation}"}
          type="button"
          phx-click="select_run_generation"
          phx-value-generation={generation}
          aria-pressed={to_string(generation == @generation)}
          class="soft-btn px-2 py-0.5 text-xs"
        >
          Gen {generation}
        </button>
      </div>

      <.result_body result={@result} store?={@detail.store?} />

      <section :if={@attempts != []} id="run-attempts" aria-label="Attempts" class="space-y-1">
        <h3 class="text-xs font-medium text-muted">
          {if length(@attempts) == 1, do: "Attempt", else: "Attempts"} at generation {@generation}
        </h3>
        <ul class="space-y-1">
          <li :for={attempt <- @attempts} id={"run-attempt-#{attempt.ordinal}"}>
            {attempt.ordinal}. {attempt_word(attempt)}
            <span class="text-xs text-muted">{timing(attempt)}</span>
          </li>
        </ul>
      </section>

      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <dt class="text-muted">Runner</dt>
        <dd id="run-node-runner">{@detail.runner}</dd>
        <dt class="text-muted">Version</dt>
        <dd id="run-node-version">{@version || "not recorded"}</dd>
      </dl>

      <section id="run-node-sources" aria-label="Input sources" class="space-y-1">
        <h3 class="text-xs font-medium text-muted">Input sources, from the definition</h3>
        <p :if={@detail.sources == []} class="text-xs text-muted">This step takes no inputs.</p>
        <ul class="space-y-0.5">
          <li :for={source <- @detail.sources} id={"run-node-source-#{source.field}"}>
            {source.field}
            <span class="text-muted">
              {if source.source, do: "from #{source.source}", else: "set in the definition"}
            </span>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :result, :map, default: nil
  attr :store?, :boolean, required: true

  defp result_body(%{result: %{state: :stored, record: record}} = assigns) do
    assigns = assign(assigns, record: record, secondary: @secondary)

    ~H"""
    <div id="run-node-result" class="space-y-1">
      <%= case @record do %>
        <% %{status: :ok, output: %{kind: :json} = output} -> %>
          <pre
            id="run-output"
            class="soft-tray max-h-96 overflow-auto bg-sunken p-3 font-mono text-[12.5px] leading-[1.55]"
          >{output.text}</pre>
          <p :if={output.truncated?} id="run-output-cut" class="text-xs text-muted">
            Showing the first {size(RunValues.preview_bytes())} of {size(output.bytes)}.
          </p>
        <% %{status: :ok, output: %{kind: :binary, bytes: bytes}} -> %>
          <p id="run-output-binary">Binary output, {size(bytes)}. Not shown.</p>
        <% %{status: :ok, output: %{kind: :bytes, bytes: bytes}} -> %>
          <p id="run-output-bytes">This output isn't text, {size(bytes)}. Not shown.</p>
        <% %{status: :ok, output: %{kind: :type, type: type}} -> %>
          <p id="run-output-type">
            This output can't be shown here. Its type is <code class="font-mono text-xs">{type}</code>.
          </p>
        <% %{status: :error} = failure -> %>
          <p><code id="run-error-type" class="font-mono text-xs">{failure.type}</code></p>
          <p id="run-error-text" data-retryable={to_string(failure.retryable?)}>{failure.text}</p>
        <% %{status: :cancelled} -> %>
          <p id="run-output-cancelled">Cancelled. This step was stopped before it finished.</p>
        <% %{status: :skipped} -> %>
          <p id="run-output-skipped">Skipped. The run didn't need this step.</p>
        <% %{status: :degraded} -> %>
          <p id="run-output-degraded">Could not be loaded.</p>
      <% end %>
    </div>
    """
  end

  defp result_body(%{result: %{state: state}} = assigns) when state in [:lag, :unavailable] do
    assigns = assign(assigns, secondary: @secondary)

    ~H"""
    <div id="run-node-result" class="flex items-center gap-3">
      <p class="flex-1">Loading the output</p>
      <button id="retry-run-record" type="button" phx-click="retry_run_record" class={@secondary}>
        Try again
      </button>
    </div>
    """
  end

  defp result_body(%{result: %{state: state}} = assigns) do
    assigns = assign(assigns, text: absence(state, assigns.store?), state: state)

    ~H"""
    <p id="run-node-result" data-result={@state}>{@text}</p>
    """
  end

  defp result_body(assigns), do: ~H""

  @spec absence(state :: atom(), store? :: boolean()) :: String.t()
  defp absence(:not_run, _store?), do: "Not run. The run didn't reach this step."
  defp absence(:running, _store?), do: "Running. The output appears when this step ends."
  defp absence(:interrupted, _store?), do: "Interrupted. This step ended before it finished."
  defp absence(:loading, _store?), do: "Loading the output"

  defp absence(:miss, false),
    do: "Not stored by policy. This step ran, but its output isn't kept."

  defp absence(:miss, _store?),
    do: "Result not available. This step ended, but no output was recorded."

  @spec record(result :: map() | nil) :: map()
  defp record(%{state: :stored, record: record}), do: record
  defp record(_result), do: %{}

  @spec attempt_word(attempt :: RunView.attempt()) :: String.t()
  defp attempt_word(attempt), do: attempt |> RunView.attempt_status() |> run_status_word()

  # Times as the events stamped them, so nothing here ticks.
  @spec timing(attempt :: RunView.attempt()) :: String.t()
  defp timing(attempt) do
    case {time(attempt.admitted_at), time(attempt.settled_at)} do
      {nil, _settled} ->
        ""

      {admitted, nil} ->
        "started #{Calendar.strftime(admitted, "%H:%M:%S")}"

      {admitted, settled} ->
        "started #{Calendar.strftime(admitted, "%H:%M:%S")}, took " <>
          duration(DateTime.diff(settled, admitted, :millisecond))
    end
  end

  @spec time(text :: String.t() | nil) :: DateTime.t() | nil
  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp time(_text), do: nil

  @spec duration(ms :: integer()) :: String.t()
  defp duration(ms) when ms < 1_000, do: "#{max(ms, 0)} ms"
  defp duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  @spec size(bytes :: non_neg_integer()) :: String.t()
  defp size(bytes) when bytes < 1_024, do: "#{bytes} bytes"
  defp size(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1_024)} KB"
  defp size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @doc """
  A stage's nodes on the workflow level, each with its status.
  """
  attr :stage, :string, required: true
  attr :document, :map, required: true
  attr :detail, :map, required: true

  def vertex_results(assigns) do
    assigns =
      assign(assigns,
        nodes: assigns.document |> Composer.nodes(assigns.stage) |> Map.keys() |> Enum.sort()
      )

    ~H"""
    <ul id="run-stage-nodes" aria-label="Steps" class="space-y-1">
      <li :for={node <- @nodes} id={"run-stage-node-#{node}"} class="flex items-center gap-2">
        <span class="min-w-0 flex-1 truncate">{node}</span>
        <.run_pill
          :if={@detail.nodes[node]}
          id={"run-stage-node-#{node}-status"}
          status={@detail.nodes[node]}
          class="run-pill-inline"
        />
        <span :if={!@detail.nodes[node]} class="text-xs text-muted">Not run</span>
      </li>
    </ul>
    """
  end

  @doc """
  What a decision chose at each of its occurrences, read-only. An automatic decider
  says so, and has no form.
  """
  attr :card, :map, required: true
  attr :detail, :map, required: true

  def decision_outcome(assigns) do
    assigns = assign(assigns, automatic?: assigns.card.decider != @person)

    ~H"""
    <div id="run-decision-outcome" class="space-y-2">
      <p class="text-[15px]">{@card.prompt}</p>
      <p :if={@automatic?} id="run-decision-automatic" class="text-xs text-muted">
        Decided automatically by {decider_label(@card.decider)}. Nothing here needs you.
      </p>
      <p :if={@detail.occurrences == []} class="text-muted">The run hasn't reached this decision.</p>
      <ul class="space-y-1">
        <li
          :for={{occurrence, index} <- Enum.with_index(@detail.occurrences)}
          id={"run-occurrence-#{index}"}
        >
          <span :if={occurrence.generation} class="text-xs text-muted">
            Gen {occurrence.generation}
          </span>
          <%= case occurrence do %>
            <% %{choice: choice} when is_binary(choice) and occurrence.state == :answered -> %>
              Chose <span id={"run-occurrence-#{index}-choice"} class="font-semibold">{choice}</span>
            <% %{state: :pending} -> %>
              Waiting for an answer
            <% _closed -> %>
              Closed without an answer
          <% end %>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  A person's answer to a pending decision: one form per choice, each saying what it
  does. It shows only while Core awaits this decision and the run isn't frozen, which
  includes a stopped run: there a halt finishes the run at once, and a rerun waits for
  Resume.
  """
  attr :decision, :string, required: true
  attr :card, :map, required: true
  attr :document, :map, required: true
  attr :run, :map, required: true

  def decision_form(assigns) do
    status = assigns.run.status
    occurrence = awaited(status, assigns.decision)
    choices = get_in(assigns.document, ["vertices", assigns.decision, "choices"]) || []

    assigns =
      assign(assigns,
        occurrence: occurrence,
        show?:
          assigns.card.decider == @person and is_binary(occurrence) and is_map(status) and
            not RunView.frozen?(status),
        stopped?: is_map(status) and RunView.phase(status) == "stopped",
        choices: choices,
        secondary: @secondary
      )

    ~H"""
    <section
      :if={@show?}
      id={"decision-form-#{@decision}"}
      aria-label="Answer this decision"
      class="space-y-3"
    >
      <p :if={@stopped?} id="decision-stopped-note" class="text-warning">
        This run is stopped. {stopped_note(@choices)}
      </p>
      <div
        :for={choice <- @choices}
        id={"decide-choice-#{choice["name"]}"}
        class="soft-row space-y-2 p-3"
      >
        <p>{choice["description"]}</p>
        <p class="text-xs text-muted">{does(choice["target"])}</p>
        <.form
          for={decide_form(@run.decision, choice["name"])}
          id={"decide-#{choice["name"]}"}
          phx-submit="decide"
          phx-auto-recover="ignore"
          class="space-y-2"
        >
          <input type="hidden" name="occurrence" value={@occurrence} />
          <input type="hidden" name="choice" value={choice["name"]} />
          <.start_field
            :for={field <- RunInputs.choice_fields(choice)}
            field={field}
            form_field={decide_form(@run.decision, choice["name"])[field.name]}
            error={decide_error(@run.decision, choice["name"], field.name)}
          />
          <p :if={choice["inputs"] != %{}} class="text-xs text-muted">
            Leave blank to keep the earlier value.
          </p>
          <button id={"decide-#{choice["name"]}-submit"} type="submit" class={@secondary}>
            {String.capitalize(choice["name"])}
          </button>
        </.form>
      </div>
    </section>
    """
  end

  @spec awaited(status :: map() | nil, decision :: String.t()) :: String.t() | nil
  defp awaited(%{awaiting: awaiting}, decision) when is_list(awaiting) do
    Enum.find_value(awaiting, fn
      %{decision: ^decision, occurrence: occurrence} when is_binary(occurrence) -> occurrence
      _other -> nil
    end)
  end

  defp awaited(_status, _decision), do: nil

  @spec decide_form(decision :: map() | nil, choice :: String.t()) :: Phoenix.HTML.Form.t()
  defp decide_form(%{choice: choice, params: params}, choice),
    do: to_form(params, as: :inputs, id: "decide-#{choice}")

  defp decide_form(_decision, choice), do: to_form(%{}, as: :inputs, id: "decide-#{choice}")

  @spec decide_error(decision :: map() | nil, choice :: String.t(), field :: String.t()) ::
          atom() | nil
  defp decide_error(%{choice: choice, errors: errors}, choice, field), do: errors[field]
  defp decide_error(_decision, _choice, _field), do: nil

  @spec does(target :: term()) :: String.t()
  defp does(["halt"]), do: "Finishes the run"
  defp does(["rerun", stage]), do: "Runs #{stage} again"
  defp does(["run", vertex]), do: "Goes on to #{vertex}"
  defp does(_target), do: ""

  # A halt answered on a stopped run finishes it; anything else waits for Resume.
  @spec stopped_note(choices :: [map()]) :: String.t()
  defp stopped_note(choices) do
    Enum.map_join(choices, " ", fn choice ->
      name = String.capitalize(choice["name"])

      if choice["target"] == ["halt"],
        do: "#{name} finishes it now.",
        else: "#{name} runs when you press Resume."
    end)
  end

  @spec decider_label(id :: String.t() | nil) :: String.t()
  defp decider_label(id) do
    case Enum.find(Catalog.deciders(), &(&1.id == id)) do
      %{label: label} -> label
      nil -> "its decider"
    end
  end

  @spec decision_path(draft_id :: String.t(), run_id :: String.t(), decision :: String.t()) ::
          String.t()
  defp decision_path(draft_id, run_id, decision),
    do: ~p"/composer/#{draft_id}?#{[run: run_id, node: decision]}"

  @doc """
  A draft's recent runs, newest first, each opening that run.
  """
  attr :runs, :list, required: true
  attr :draft_id, :string, required: true
  attr :stage, :string, default: nil
  attr :current, :string, default: nil

  def recent_runs(assigns) do
    assigns = assign(assigns, section_title: @section_title)

    ~H"""
    <section id="recent-runs" aria-label="Recent runs" class="space-y-2 p-3">
      <h2 class={@section_title}>Runs</h2>
      <p :if={@runs == []} id="recent-runs-empty" class="text-xs text-muted">No runs yet.</p>
      <ul class="space-y-1 text-sm">
        <li :for={row <- @runs} :key={row.id} id={"recent-run-#{row.id}"}>
          <.link
            patch={composer_path(@draft_id, @stage, row.id)}
            aria-current={if(row.id == @current, do: "page")}
            class={["soft-link block truncate", row.id == @current && "font-semibold"]}
          >
            {Calendar.strftime(row.inserted_at, "%Y-%m-%d %H:%M")}
            <code class="text-xs text-muted">{String.slice(row.id, 0, 8)}</code>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  # Which buttons show, once the run's view is known.
  @spec controls(run :: map()) :: [:recover | :cancel]
  defp controls(%{state: :open, status: %{} = status}), do: RunView.controls(status)
  defp controls(_run), do: []

  @spec pending(status :: map() | nil) :: [String.t()]
  defp pending(%{awaiting: awaiting}) when is_list(awaiting) do
    for %{decision: decision} when is_binary(decision) <- awaiting, uniq: true, do: decision
  end

  defp pending(_status), do: []

  @doc """
  One sentence that says where the run is and what it needs next.
  """
  @spec sentence(run :: map()) :: String.t()
  def sentence(%{state: :opening}), do: "Opening this run"
  def sentence(%{state: :never_started}), do: "This run never started"
  def sentence(%{state: :runner_unavailable}), do: "This run's runners are no longer available"
  def sentence(%{state: :definition_mismatch}), do: "This run can't continue"
  def sentence(%{state: :unavailable}), do: "This run can't be read right now"

  def sentence(%{status: status, fold: fold}) do
    if RunView.frozen?(status),
      do: "This run lost its process and is doing nothing. Recover to continue",
      else: phase_sentence(RunView.phase(status), status, fold)
  end

  @spec phase_sentence(phase :: String.t(), status :: map(), fold :: RunView.t()) :: String.t()
  defp phase_sentence("starting", _status, _fold), do: "Starting this run"
  defp phase_sentence("resuming", _status, _fold), do: "Resuming this run"
  defp phase_sentence("running", _status, fold), do: named("Running", fold, "running")

  defp phase_sentence("waiting", status, _fold) do
    case pending(status) do
      [] -> "Waiting"
      decisions -> "Waiting for your decision on #{Enum.join(decisions, ", ")}"
    end
  end

  defp phase_sentence("pausing", _status, _fold), do: "Pausing"
  defp phase_sentence("paused", _status, _fold), do: "Paused"

  defp phase_sentence("stopping", _status, _fold),
    do: "Stopping. Waiting for the current step to end"

  defp phase_sentence("stopped", _status, _fold), do: "Stopped. Resume when you're ready"

  defp phase_sentence("blocked", _status, fold) do
    case RunView.nodes_with(fold, "uncertain") do
      [] -> "Blocked"
      nodes -> "Blocked. #{Enum.join(nodes, ", ")} may already have had its effect"
    end
  end

  defp phase_sentence("cancelling", _status, _fold), do: "Cancelling this run"
  defp phase_sentence("finishing", _status, _fold), do: "Finishing this run"

  defp phase_sentence("finished", %{outcome: "failed"}, fold),
    do: named("Failed", fold, "failed", "at")

  defp phase_sentence("finished", %{outcome: "cancelled"}, _fold), do: "Cancelled"
  defp phase_sentence("finished", _status, _fold), do: "Finished"

  defp phase_sentence(_unknown, _status, _fold),
    do: "This run is in a state this page doesn't know"

  @spec named(
          lead :: String.t(),
          fold :: RunView.t(),
          status :: String.t(),
          joiner :: String.t() | nil
        ) :: String.t()
  defp named(lead, fold, status, joiner \\ nil) do
    case RunView.nodes_with(fold, status) do
      [] -> lead
      nodes -> Enum.join([lead, joiner, Enum.join(nodes, ", ")] |> Enum.reject(&is_nil/1), " ")
    end
  end

  @spec dom_part(id :: String.t()) :: String.t()
  defp dom_part(id), do: String.replace(id, ".", "-")
end
