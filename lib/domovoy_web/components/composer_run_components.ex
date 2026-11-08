defmodule DomovoyWeb.ComposerRunComponents do
  @moduledoc """
  The composer's run pieces: the New run launcher and its effect confirmation, the run
  header, the run's outline, a selected card's results, the Results panel, a person's
  decision form with its evidence, recent runs, an uncertain effect's review, and the
  cancel and reconcile dialogs.

  A run page shows its snapshot: no control here edits a draft, and no input value is
  rendered back except a form's own text and a node's bounded output. No error reason
  is rendered, only its type and text written here.
  """

  use DomovoyWeb, :html

  import DomovoyWeb.ComposerComponents,
    only: [
      canvas_only_toggle: 1,
      composer_path: 3,
      modal_scrim: 1,
      outline_toggle: 1,
      panel: 1,
      run_link: 3,
      run_link: 4,
      run_pill: 1,
      run_status_word: 1,
      surface_switcher: 1
    ]

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
  The New run launcher, an overlay panel built from the current saved draft. Fields keep
  what was typed after a refusal, and an error names the problem, never the value. From
  a run page, Fix in editor leads to the draft's issues; on the draft it opens them.
  The draft's saved input sets fill the fields in; an opt-in value a set holds is named,
  never shown, and a set that no longer fits the draft blocks Start until acknowledged.
  """
  attr :start, :map, required: true
  attr :open?, :boolean, required: true
  attr :draft_id, :string, required: true
  attr :run_page?, :boolean, default: false
  attr :run_active?, :boolean, default: false, doc: "the run on screen hasn't finished"

  def start_form(assigns) do
    start = assigns.start
    blocking = Enum.filter(start.fields, &blocking?/1)

    assigns =
      assign(assigns,
        primary: @primary,
        secondary: @secondary,
        quiet: @quiet,
        blocking: blocking,
        drift_blocked?: start.drift != [] and not start.drift_acked?,
        set_name:
          start.input_set_id &&
            (Enum.find_value(start.sets, &(&1.id == start.input_set_id && &1.name)) ||
               "the saved set"),
        opt_in_fields: Enum.filter(start.fields, &(&1.reuse == :opt_in))
      )

    ~H"""
    <.panel id="launcher-panel" side="right" label="New run" close="close_start" open?={@open?}>
      <section id="start-panel" aria-label="Start a run" class="space-y-3 p-3">
        <p id="launcher-source" class="text-sm text-muted">
          Starts a separate run from the current saved draft{if @run_active?,
            do: "; the current run continues"}.
        </p>
        <p
          :if={@start.notice == :draft_changed}
          id="launcher-draft-changed"
          role="alert"
          class="text-sm text-warning"
        >
          The saved draft changed since this opened. Check the inputs below, then start again.
        </p>
        <div :if={@start.issues} id="launcher-invalid" role="alert" class="space-y-2 text-sm">
          <p class="text-warning">
            The saved draft has {@start.issues} {if @start.issues == 1,
              do: "issue",
              else: "issues"} to fix before it can run.
          </p>
          <.link
            :if={@run_page?}
            id="launcher-fix"
            navigate={~p"/composer/#{@draft_id}?#{[tools: 1]}"}
            class={@secondary}
          >
            Fix in editor
          </.link>
          <button
            :if={!@run_page?}
            id="launcher-fix"
            type="button"
            phx-click="open_tools"
            class={@secondary}
          >
            Fix in editor
          </button>
        </div>
        <.input_sets :if={!@start.effects} start={@start} quiet={@quiet} />
        <div :if={@start.drift != []} id="start-drift" role="alert" class="space-y-2 text-sm">
          <p class="text-warning">{@set_name} no longer matches the draft:</p>
          <ul class="list-disc space-y-0.5 pl-5">
            <li :for={drift <- @start.drift} id={"start-drift-#{drift.name}"}>
              {drift.name} {if drift.kind == :removed,
                do: "was removed from the draft, so its value is left out.",
                else: "changed type, so its value is left out."}
            </li>
          </ul>
          <button
            :if={!@start.drift_acked?}
            id="ack-drift"
            type="button"
            phx-click="ack_drift"
            class={@secondary}
          >
            Start without those values
          </button>
        </div>
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
            reused_from={is_map_key(@start.reused, field.name) && @set_name}
            unset_in={field.name in @start.blank && @set_name}
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
              disabled={@blocking != [] or @start.pending? or @drift_blocked?}
              class={@primary}
            >
              {if @start.pending?, do: "Starting…", else: "Start run"}
            </button>
            <button id="close-start" type="button" phx-click="close_start" class={@secondary}>
              Cancel
            </button>
          </div>
          <div id="save-input-set-controls" class="space-y-2 border-t border-white/5 pt-3">
            <.input
              type="text"
              id="save-input-set-name"
              name="set_name"
              value=""
              label="Save these values as"
              placeholder="A name, such as Sample flat"
              phx-hook=".SaveSetOnEnter"
            />
            <%!-- Enter here would submit through the form's first button, Start run. --%>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".SaveSetOnEnter">
              export default {
                mounted() {
                  this.el.addEventListener("keydown", event => {
                    if (event.key !== "Enter" || event.isComposing) return
                    event.preventDefault()
                    const save = document.getElementById("save-input-set")
                    if (save && !save.disabled) this.el.form?.requestSubmit(save)
                  })
                }
              }
            </script>
            <.input
              :for={field <- @opt_in_fields}
              type="checkbox"
              id={"save-opt-in-#{field.name}"}
              name={"opt_in[#{field.name}]"}
              value={false}
              label={"Also keep #{field.name}. It's used again but never shown."}
            />
            <button
              id="save-input-set"
              type="submit"
              name="intent"
              value="save"
              disabled={@start.pending?}
              class={@secondary}
            >
              Save input set
            </button>
            <p :if={@start.set_notice} id="input-set-notice" role="status" class="text-sm">
              {set_notice(@start.set_notice)}
            </p>
          </div>
        </.form>
      </section>
    </.panel>
    """
  end

  attr :field, :map, required: true
  attr :form_field, :any, required: true
  attr :error, :atom, default: nil
  attr :id_prefix, :string, default: "start-field", doc: "unique per form on the page"
  attr :reused_from, :any, default: false, doc: "the set whose hidden value this field uses"
  attr :unset_in, :any, default: false, doc: "the chosen set, which leaves this field empty"

  defp start_field(%{field: %{editor: :none}} = assigns) do
    ~H"""
    <div id={"#{@id_prefix}-#{@field.name}"} class="text-sm">
      <p class="font-medium">{@field.name} <span class="text-muted">{@field.type}</span></p>
      <p class="text-xs text-muted">This type can't be typed here.</p>
      <.field_notes field={@field} id_prefix={@id_prefix} />
    </div>
    """
  end

  defp start_field(assigns) do
    assigns =
      assign(assigns,
        quiet: @quiet,
        errors: List.wrap(error_text(assigns.error, assigns.field)),
        label: "#{assigns.field.name} (#{assigns.field.type})",
        placeholder: if(assigns.field.default, do: "Leave blank for the default")
      )

    ~H"""
    <div id={"#{@id_prefix}-#{@field.name}"}>
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
      <.field_notes field={@field} id_prefix={@id_prefix} />
      <p
        :if={@reused_from}
        id={"#{@id_prefix}-#{@field.name}-reused"}
        class="flex flex-wrap items-center gap-x-2 text-xs text-muted"
      >
        Using the saved value from {@reused_from}.
        <button
          id={"#{@id_prefix}-#{@field.name}-clear"}
          type="button"
          phx-click="clear_reused"
          phx-value-name={@field.name}
          class={@quiet}
        >
          Clear
        </button>
      </p>
      <p :if={@unset_in} id={"#{@id_prefix}-#{@field.name}-unset"} class="text-xs text-muted">
        Not saved in {@unset_in}.
      </p>
    </div>
    """
  end

  # What a field says of itself: its description, whether this run needs it and why, and
  # its default, which is shown only for a type a set may keep.
  attr :field, :map, required: true
  attr :id_prefix, :string, required: true

  defp field_notes(assigns) do
    assigns = assign(assigns, needed?: assigns.field.required or assigns.field.bound)

    ~H"""
    <p
      :if={@field.description}
      id={"#{@id_prefix}-#{@field.name}-description"}
      class="mt-0.5 text-xs text-muted"
    >
      {@field.description}
    </p>
    <p
      :if={@needed? or is_binary(@field.default)}
      class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted"
    >
      <span
        :if={@needed?}
        id={"#{@id_prefix}-#{@field.name}-required"}
        class="soft-chip rounded-full px-2 py-0.5 font-medium"
      >
        Required to run
      </span>
      <span :if={@needed?}>
        {if @field.required, do: "The draft marks it required.", else: "A step reads it."}
      </span>
      <span :if={is_binary(@field.default)} id={"#{@id_prefix}-#{@field.name}-default"}>
        {if @field.reuse == :eligible, do: "Default: #{@field.default}", else: "Has a default"}
      </span>
    </p>
    """
  end

  # The draft's saved input sets. Use fills the form; Start with this set also submits it.
  attr :start, :map, required: true
  attr :quiet, :string, required: true

  defp input_sets(assigns) do
    ~H"""
    <section id="input-sets" aria-labelledby="input-sets-title" class="space-y-1">
      <p id="input-sets-title" class="text-xs font-medium text-muted">Saved input sets</p>
      <p :if={@start.sets == []} class="text-xs text-muted">
        None yet. Fill in the inputs below, then save them under a name.
      </p>
      <ul class="space-y-1">
        <li
          :for={set <- @start.sets}
          id={"input-set-#{set.id}"}
          class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm"
        >
          <span
            class={["min-w-0 flex-1 truncate", set.id == @start.input_set_id && "font-semibold"]}
            aria-current={set.id == @start.input_set_id && "true"}
          >
            {set.name}
          </span>
          <button
            id={"input-set-use-#{set.id}"}
            type="button"
            phx-click="choose_input_set"
            phx-value-id={set.id}
            disabled={@start.pending?}
            class={@quiet}
          >
            Use
          </button>
          <button
            id={"input-set-start-#{set.id}"}
            type="button"
            phx-click="start_with_input_set"
            phx-value-id={set.id}
            disabled={@start.pending?}
            class={@quiet}
          >
            Start with this set
          </button>
          <button
            id={"input-set-delete-#{set.id}"}
            type="button"
            phx-click="delete_input_set"
            phx-value-id={set.id}
            data-confirm={"Delete the input set #{set.name}?"}
            disabled={@start.pending?}
            aria-label={"Delete #{set.name}"}
            class={@quiet}
          >
            Delete
          </button>
        </li>
      </ul>
      <p id="input-from-run" class="flex flex-wrap items-center gap-x-2 text-xs text-muted">
        <button type="button" disabled class={@quiet}>From a previous run</button> Not available yet
      </p>
    </section>
    """
  end

  @spec set_notice(notice :: tuple()) :: String.t()
  defp set_notice({:saved, name}), do: "Saved as #{name}."

  defp set_notice({:not_saved, :name_taken}),
    do: "A set with that name exists. Pick another name."

  defp set_notice({:not_saved, :invalid_name}), do: "Give the set a name to save it."
  defp set_notice({:not_saved, _reason}), do: "Couldn't save the set. Try again."

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
  Each node whose runner may change things outside Composer, confirmed before a start.
  Back to inputs returns to the form with its text and ids.
  """
  attr :start, :map, required: true

  def effects_confirmation(assigns) do
    assigns = assign(assigns, primary: @primary, secondary: @secondary)

    ~H"""
    <div id="start-effects" role="alertdialog" aria-labelledby="start-effects-title" class="space-y-2">
      <p id="start-effects-title" class="text-sm">
        These steps may change things outside Composer. Check them before you start.
      </p>
      <ul id="start-effects-list" class="list-disc space-y-0.5 pl-5 text-sm">
        <li :for={effect <- @start.effects} id={"start-effect-#{effect.stage}-#{effect.node}"}>
          {effect.stage} / {effect.node}: {effect.label}
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
        <button
          id="back-to-inputs"
          type="button"
          phx-click="back_to_inputs"
          disabled={@start.pending?}
          class={@secondary}
        >
          Back to inputs
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
  back to the draft. Notices about the run follow it. A run whose draft was deleted has
  no way back, and New run says why it can't start one.
  """
  attr :title, :string, required: true, doc: "the draft's title, else the run's workflow name"
  attr :draft_id, :string, default: nil, doc: "nil once the run's draft was deleted"
  attr :stage, :string, default: nil
  attr :run, :map, required: true
  attr :selected, :string, default: nil
  attr :outline_open?, :boolean, default: false
  attr :surface, :string, default: "canvas"
  attr :runs_enabled?, :boolean, default: false
  attr :launcher?, :boolean, default: false, doc: "a launcher is open, so it gets a surface"
  attr :document, :map, required: true, doc: "the run's snapshot"
  attr :attention_count, :integer, default: 0, doc: "the draft's runs that may need you"

  def run_header(assigns) do
    run = assigns.run
    controls = RunView.controls(if(run.state == :open, do: run.status))
    pending = if(controls == [:recover], do: [], else: pending(run.status, assigns.document))

    assigns =
      assign(assigns,
        primary: @primary,
        secondary: @secondary,
        controls: controls,
        busy: busy(run.op),
        sentence: sentence(run, assigns.document),
        pending: pending,
        failed_step: failed_step(run),
        more: Enum.filter(controls, &(&1 in [:pause, :unpause])),
        checked:
          if(:reconcile in controls,
            do: Enum.find(RunView.uncertainties(run.fold, run.status), & &1.node)
          ),
        # Review with nothing selected opens the first pending decision, so it shows something.
        review_patch:
          if(is_nil(assigns.selected) and pending != [],
            do: decision_path(assigns.draft_id, assigns.run.id, hd(pending))
          )
      )

    ~H"""
    <header
      id="run-header"
      data-modal-background
      class="soft-panel flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2"
    >
      <.outline_toggle open?={@outline_open?} label="Steps" />
      <nav id="breadcrumb" aria-label="Breadcrumb" class="min-w-0 text-sm">
        <.link navigate={~p"/composer"} class="soft-link">Drafts</.link>
        <span class="text-muted">/</span>
        <span id="draft-title" class="font-semibold">{@title}</span>
        <span class="text-muted">/</span>
        <span>Run <code id="run-id" class="text-xs">{String.slice(@run.id, 0, 8)}</code></span>
        <span class="text-muted">/</span>
        <.link
          :if={@stage}
          id="breadcrumb-workflow"
          patch={run_link(@draft_id, nil, @run.id, scope: if(is_integer(@run.scope), do: @run.scope))}
          class="soft-link"
        >
          Workflow
        </.link>
        <span :if={!@stage} id="breadcrumb-workflow">Workflow</span>
        <span :if={@stage} class="text-muted">/</span>
        <span :if={@stage} id="breadcrumb-stage">{@stage}</span>
      </nav>

      <span id="engine-target" class="soft-chip rounded-full px-2 py-0.5 text-xs">Core 0.3.4</span>

      <button
        :if={@runs_enabled? && @draft_id}
        id="run-switcher"
        type="button"
        phx-click="open_outline"
        aria-controls="outline-panel"
        class={@secondary}
      >
        <.icon name="hero-queue-list" class="size-4" /> Runs
        <span
          :if={@attention_count > 0}
          id="run-switcher-attention"
          class="soft-chip rounded-full px-1.5 text-xs text-warning"
        >
          {if @attention_count > 5, do: "5+", else: @attention_count}
        </span>
      </button>

      <p id="run-status" role="status" aria-live="polite" class="text-[15px] font-semibold">
        {@sentence}
      </p>

      <div class="ml-auto flex flex-wrap items-center gap-2">
        <.link
          :for={decision <- @pending}
          id={"run-pending-link-#{decision}"}
          patch={decision_path(@draft_id, @run.id, decision)}
          class={@secondary}
        >
          Answer {decision}
        </.link>
        <p :if={@run.op} id="run-op" role="status" aria-live="polite" class="text-sm text-muted">
          {op_text(@run.op)}
        </p>
        <button
          :if={:recover in @controls}
          id="recover-run"
          type="button"
          phx-click="recover_run"
          class={@primary}
        >
          Recover
        </button>
        <.link
          :if={@checked}
          id="review-uncertainty"
          patch={step_path(@draft_id, @run.id, {@checked.stage, @checked.node})}
          class={@primary}
        >
          Check {@checked.node}
        </.link>
        <button
          :if={:resume in @controls}
          id="resume-run"
          type="button"
          phx-click="resume_run"
          disabled={@busy == :resume}
          class={@primary}
        >
          Resume run
        </button>
        <button
          :if={:stop in @controls}
          id="stop-run"
          type="button"
          phx-click="stop_run"
          disabled={@busy == :stop}
          class={@secondary}
        >
          Stop run
        </button>
        <button
          :if={:cancel in @controls}
          id="cancel-run"
          type="button"
          phx-click={JS.push_focus() |> JS.push("open_cancel_run")}
          disabled={@busy == :cancel}
          class={@secondary}
        >
          Cancel run
        </button>
        <details
          :if={@more != []}
          id="run-more"
          phx-mounted={JS.ignore_attributes("open")}
          class="relative"
        >
          <summary class={["list-none cursor-pointer", @secondary]}>
            More <.icon name="hero-chevron-down" class="size-3.5" />
          </summary>
          <%!-- In flow on a narrow screen, so the wrapped header never pushes it off-screen. --%>
          <div class="soft-panel absolute right-0 z-40 mt-1 flex w-48 flex-col p-1 max-md:static max-md:w-auto">
            <button
              :if={:pause in @more}
              id="pause-run"
              type="button"
              phx-click={JS.remove_attribute("open", to: "#run-more") |> JS.push("pause_run")}
              disabled={@busy == :pause}
              class="soft-btn soft-btn-quiet justify-start px-3 py-1.5 text-sm"
            >
              Pause run
            </button>
            <button
              :if={:unpause in @more}
              id="unpause-run"
              type="button"
              phx-click={JS.remove_attribute("open", to: "#run-more") |> JS.push("unpause_run")}
              disabled={@busy == :unpause}
              class="soft-btn soft-btn-quiet justify-start px-3 py-1.5 text-sm"
            >
              Unpause run
            </button>
          </div>
        </details>
        <.link
          :if={@failed_step}
          id="view-failed-step"
          patch={step_path(@draft_id, @run.id, @failed_step)}
          class={@secondary}
        >
          View failed step
        </.link>
        <button id="open-results" type="button" phx-click="open_results" class={@secondary}>
          Results
        </button>
        <button
          :if={@runs_enabled?}
          id="new-run"
          type="button"
          phx-click="open_start"
          disabled={is_nil(@draft_id)}
          aria-describedby={if(is_nil(@draft_id), do: "new-run-reason")}
          class={@secondary}
        >
          New run
        </button>
        <p
          :if={@runs_enabled? && is_nil(@draft_id)}
          id="new-run-reason"
          class="text-xs text-muted"
        >
          This workflow's draft was deleted
        </p>
        <.canvas_only_toggle />
        <.link
          :if={@draft_id}
          id="back-to-draft"
          patch={composer_path(@draft_id, @stage, nil)}
          class={@secondary}
        >
          Back to draft
        </.link>
      </div>
      <.surface_switcher
        surface={@surface}
        labels={~w(Canvas Steps Review)}
        details_patch={@review_patch}
        results?
        launcher?={@launcher?}
      />
    </header>

    <.run_notices run={@run} draft_id={@draft_id} stage={@stage} />
    """
  end

  # Where a failed run failed: its first failed node, by name, and that node's stage.
  @spec failed_step(run :: map()) :: {String.t(), String.t()} | nil
  defp failed_step(%{
         state: :open,
         status: %{committed_phase: "finished", outcome: "failed"},
         fold: fold
       }) do
    case fold |> RunView.nodes_with("failed") |> Enum.sort() do
      [node | _later] -> {fold.stages[node], node}
      [] -> nil
    end
  end

  defp failed_step(_run), do: nil

  @spec step_path(
          draft_id :: String.t() | nil,
          run_id :: String.t(),
          step :: {String.t(), String.t()}
        ) :: String.t()
  defp step_path(draft_id, run_id, {stage, node}),
    do: run_link(draft_id, stage, run_id, node: node)

  # The command whose request is in flight or accepted, so its button can't be pressed
  # again.
  @spec busy(op :: map() | nil) :: atom() | nil
  defp busy(%{command: command, state: state}) when state in [:sending, :accepted], do: command
  defp busy(_op), do: nil

  @spec op_text(op :: map()) :: String.t()
  defp op_text(%{state: :sending}), do: "Sending…"

  defp op_text(%{state: :unconfirmed}),
    do: "Couldn't confirm the request. Press again to retry the same request."

  defp op_text(%{command: :stop}), do: "Stop accepted. Stopping active work and saving checkpoint"
  defp op_text(%{command: :resume}), do: "Resume accepted. Continuing this run"
  defp op_text(%{command: :cancel}), do: "Cancel accepted. Ending this run"

  defp op_text(%{command: :pause}),
    do: "Pause accepted. Finishing active work before pausing"

  defp op_text(%{command: :unpause}), do: "Unpause accepted. Continuing this run"
  defp op_text(%{command: :reconcile}), do: "Check recorded. The step runs again"

  attr :run, :map, required: true
  attr :draft_id, :string, default: nil
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
        navigate={run_link(@draft_id, @stage, @run.id)}
        class={@secondary}
      >
        Reload
      </.link>
    </div>
    <div
      :if={@run.fold_stale?}
      id="run-fold-stale"
      role="status"
      class="soft-panel px-4 py-2 text-sm text-warning"
    >
      Step badges may be out of date. Reload to refresh.
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
  The confirmation before a run is cancelled. Tab stays inside it and the page behind is
  inert while it is open, and however it closes, focus returns to Cancel run.
  """
  def cancel_dialog(assigns) do
    assigns = assign(assigns, secondary: @secondary, danger: @danger)

    ~H"""
    <.modal_scrim focus_id="cancel-run-focus">
      <div
        id="cancel-run-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="cancel-run-title"
        phx-window-keydown="close_cancel_run"
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
            phx-click="close_cancel_run"
            class={@secondary}
          >
            Keep running
          </button>
          <button
            id="confirm-cancel-run"
            type="button"
            phx-click="confirm_cancel_run"
            class={@danger}
          >
            Cancel run
          </button>
        </div>
      </div>
    </.modal_scrim>
    """
  end

  @doc """
  The confirmation before an uncertain effect is settled as safe to retry. Like the
  cancel dialog it traps focus and makes the page behind inert; however it closes, focus
  returns to the control that opened it.
  """
  attr :run, :map, required: true, doc: "an open run whose `reconcile` names the uncertainty"

  def reconcile_dialog(assigns) do
    %{run: run} = assigns

    uncertainty =
      Enum.find(RunView.uncertainties(run.fold, run.status), &(&1.id == run.reconcile))

    assigns =
      assign(assigns,
        secondary: @secondary,
        primary: @primary,
        uncertainty: uncertainty || %{id: run.reconcile, node: nil}
      )

    ~H"""
    <.modal_scrim focus_id="reconcile-focus">
      <div
        id="reconcile-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="reconcile-title"
        phx-window-keydown="close_reconcile"
        phx-key="escape"
        class="soft-panel w-96 max-w-[calc(100vw-2rem)] space-y-3 p-5"
      >
        <h2 id="reconcile-title" class="font-semibold">
          Run {@uncertainty.node || "this step"} again?
        </h2>
        <p class="text-sm text-muted">
          Only go on once you have checked outside Composer that running it again is safe:
          that its change didn't happen, or that repeating it does no harm. Composer
          can't check this for you.
        </p>
        <div class="flex justify-end gap-2">
          <button
            id="close-reconcile"
            type="button"
            phx-mounted={JS.focus()}
            phx-click="close_reconcile"
            class={@secondary}
          >
            Not yet
          </button>
          <button
            id="confirm-reconcile"
            type="button"
            phx-click="confirm_reconcile"
            phx-value-uncertainty={@uncertainty.id}
            class={@primary}
          >
            Checked: safe to retry
          </button>
        </div>
      </div>
    </.modal_scrim>
    """
  end

  @doc """
  The run's outline: its status, the generation the graph shows once the run has more
  than one, recent runs and the snapshot's inputs.
  """
  attr :draft_id, :string, default: nil
  attr :stage, :string, default: nil
  attr :run, :map, required: true
  attr :inputs, :list, required: true
  attr :recent, :list, required: true
  attr :attention_count, :integer, default: 0
  attr :document, :map, required: true, doc: "the run's snapshot"

  def run_outline(assigns) do
    status = assigns.run.status

    assigns =
      assign(assigns,
        section_title: @section_title,
        status: status,
        phase: status && RunView.phase(status),
        pending: pending(status, assigns.document),
        reached: reached(status)
      )

    ~H"""
    <section id="run-overview" aria-label="Run" class="space-y-3 p-3 text-sm">
      <h2 id="run-sentence" class="text-[15px] font-semibold">{sentence(@run, @document)}</h2>
      <dl :if={@status} class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <dt class="text-muted">Phase</dt>
        <dd id="run-phase">{if RunView.frozen?(@status), do: "frozen", else: @phase}</dd>
        <dt class="text-muted">Outcome</dt>
        <dd id="run-outcome">{@status.outcome || "not yet"}</dd>
        <dt class="text-muted">Availability</dt>
        <dd id="run-availability">{@status.availability || "unknown"}</dd>
      </dl>
      <div
        :if={@reached > 0}
        id="generation-scope"
        role="group"
        aria-labelledby="generation-scope-label"
        class="space-y-1"
      >
        <p id="generation-scope-label" class="text-xs text-muted">Graph shows</p>
        <div class="flex flex-wrap gap-1">
          <button
            id="generation-scope-latest"
            type="button"
            phx-click="set_run_scope"
            phx-value-scope="latest"
            aria-pressed={to_string(@run.scope == :latest)}
            class="soft-btn px-2 py-0.5 text-xs"
          >
            Latest
          </button>
          <button
            :for={generation <- 0..@reached}
            id={"generation-scope-#{generation}"}
            type="button"
            phx-click="set_run_scope"
            phx-value-scope={generation}
            aria-pressed={to_string(@run.scope == generation)}
            class="soft-btn px-2 py-0.5 text-xs"
          >
            Gen {generation}
          </button>
        </div>
      </div>
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
    <div class="border-t border-base-300">
      <.recent_runs
        runs={@recent}
        draft_id={@draft_id}
        stage={@stage}
        current={@run.id}
        attention_count={@attention_count}
      />
    </div>
    <section id="run-inputs" aria-label="Inputs" class="space-y-2 border-t border-base-300 p-3">
      <h2 class={@section_title}>Inputs</h2>
      <p :if={@inputs == []} class="text-xs text-muted">This workflow takes no inputs.</p>
      <ul class="space-y-1.5">
        <li
          :for={input <- @inputs}
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
    """
  end

  @doc """
  The selected card in a run: its status, a node's results, or a decision's outcome and
  form.
  """
  attr :run, :map, required: true
  attr :selected, :string, default: nil
  attr :statuses, :map, required: true
  attr :stage, :string, default: nil
  attr :document, :map, required: true
  attr :cards, :list, required: true
  attr :draft_id, :string, required: true

  def run_summary(assigns) do
    detail =
      assigns.stage && RunView.node_detail(assigns.run.fold, assigns.document, assigns.selected)

    generation = detail && RunView.shown_generation(detail, assigns.run.generation)

    assigns =
      assign(assigns,
        quiet: @quiet,
        detail: detail,
        generation: generation,
        reached: reached(assigns.run.status),
        selected_status: selected_status(assigns, detail, generation),
        card: !assigns.stage && Enum.find(assigns.cards, &(&1.name == assigns.selected)),
        uncertain: uncertain_here(assigns)
      )

    ~H"""
    <section id="run-summary" aria-label="Selected step" class="space-y-3 p-3 text-sm">
      <div id="run-selected" class="space-y-3">
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
          <p :if={@reached > 0} id="run-scope-label" class="text-xs text-muted">
            {scope_label(@selected, @generation, @run.scope)}
          </p>
        </div>
        <section
          :if={@uncertain != []}
          id="uncertainty-review"
          aria-labelledby="uncertainty-review-title"
          class="space-y-2 rounded-md border border-warning/40 p-3"
        >
          <h3 id="uncertainty-review-title" class="font-semibold text-warning">
            Check before this run goes on
          </h3>
          <p class="text-muted">
            The run stopped while this step may have been changing something outside
            Composer, so Composer can't tell whether the change happened. It won't run the
            step again until you check.
          </p>
          <div
            :for={{item, index} <- Enum.with_index(@uncertain)}
            id={"uncertainty-#{index}"}
            class="flex flex-wrap items-center gap-2"
          >
            <span class="flex-1">
              <span class="font-semibold">{item.node || "A step"}</span>
              <span :if={item.generation} class="text-xs text-muted">
                generation {item.generation}, attempt {item.ordinal}
              </span>
            </span>
            <button
              id={"open-reconcile-#{index}"}
              type="button"
              phx-click={JS.push_focus() |> JS.push("open_reconcile")}
              phx-value-uncertainty={item.id}
              class="soft-btn px-3 py-1.5 text-sm"
            >
              Checked: safe to retry
            </button>
          </div>
        </section>
        <.node_results
          :if={@detail}
          detail={@detail}
          generation={@generation}
          result={read_for(@run.reads, @selected, @generation)}
        />
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
    </section>
    """
  end

  # The uncertain effects to review beside this card: its own, or its stage's nodes', and
  # any the fold couldn't place. Only while the run offers reconciling them.
  @spec uncertain_here(assigns :: map()) :: [RunView.uncertainty()]
  defp uncertain_here(%{run: run, selected: selected, stage: stage}) do
    status = if(run.state == :open, do: run.status)

    if :reconcile in RunView.controls(status) do
      for item <- RunView.uncertainties(run.fold, status),
          is_nil(item.node) or item.node == selected or (is_nil(stage) and item.stage == selected),
          do: item
    else
      []
    end
  end

  # The generation a run has reached, or 0 while its status is unknown.
  @spec reached(status :: map() | nil) :: non_neg_integer()
  defp reached(%{generation: generation}) when is_integer(generation), do: generation
  defp reached(_status), do: 0

  # What each surface shows: the node's generation in the inspector, and the graph's.
  @spec scope_label(
          name :: String.t(),
          generation :: integer() | nil,
          scope :: integer() | :latest
        ) :: String.t()
  defp scope_label(name, generation, scope) do
    graph = if scope == :latest, do: "graph shows latest", else: "graph shows generation #{scope}"

    if is_integer(generation),
      do: "Showing #{name} from generation #{generation}; #{graph}",
      else: String.capitalize(graph)
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

      <.result_body
        result={@result}
        store?={@detail.store?}
        node={@detail.name}
        generation={@generation}
      />

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
  attr :node, :string, required: true
  attr :generation, :integer, default: nil
  attr :prefix, :string, default: "run", doc: "starts each id, unique per result on the page"
  attr :reload_id, :string, default: "reload-run-record"

  defp result_body(%{result: %{state: :stored, record: record}} = assigns) do
    assigns = assign(assigns, record: record)

    ~H"""
    <div id={"#{@prefix}-node-result"} class="space-y-1">
      <%= case @record do %>
        <% %{status: :ok, output: %{kind: :json} = output} -> %>
          <pre
            id={"#{@prefix}-output"}
            class="soft-tray max-h-96 overflow-auto bg-sunken p-3 font-mono text-[12.5px] leading-[1.55]"
          >{output.text}</pre>
          <p :if={output.truncated?} id={"#{@prefix}-output-cut"} class="text-xs text-muted">
            Showing the first {size(RunValues.preview_bytes())} of {size(output.bytes)}.
          </p>
        <% %{status: :ok, output: %{kind: :binary, bytes: bytes}} -> %>
          <p id={"#{@prefix}-output-binary"}>Binary output, {size(bytes)}. Not shown.</p>
        <% %{status: :ok, output: %{kind: :bytes, bytes: bytes}} -> %>
          <p id={"#{@prefix}-output-bytes"}>This output isn't text, {size(bytes)}. Not shown.</p>
        <% %{status: :ok, output: %{kind: :type, type: type}} -> %>
          <p id={"#{@prefix}-output-type"}>
            This output can't be shown here. Its type is <code class="font-mono text-xs">{type}</code>.
          </p>
        <% %{status: :error} = failure -> %>
          <p><code id={"#{@prefix}-error-type"} class="font-mono text-xs">{failure.type}</code></p>
          <p id={"#{@prefix}-error-text"} data-retryable={to_string(failure.retryable?)}>
            {failure.text}
          </p>
        <% %{status: :cancelled} -> %>
          <p id={"#{@prefix}-output-cancelled"}>
            Cancelled. This step was stopped before it finished.
          </p>
        <% %{status: :skipped} -> %>
          <p id={"#{@prefix}-output-skipped"}>Skipped. The run didn't need this step.</p>
        <% %{status: :degraded} -> %>
          <p id={"#{@prefix}-output-degraded"}>Could not be loaded.</p>
      <% end %>
    </div>
    """
  end

  # Each way a read can end without a result says which, and reading again only reads.
  defp result_body(%{result: %{state: state}} = assigns)
       when state in [:lag, :unavailable, :read_failed] do
    assigns = assign(assigns, secondary: @secondary, state: state, text: absence(state, true))

    ~H"""
    <div id={"#{@prefix}-node-result"} data-result={@state} class="flex items-center gap-3">
      <p id={"#{@prefix}-result-#{@state}"} class="flex-1">{@text}</p>
      <button
        id={@reload_id}
        type="button"
        phx-click="retry_run_record"
        phx-value-node={@node}
        phx-value-generation={@generation}
        class={@secondary}
      >
        Reload result
      </button>
    </div>
    """
  end

  defp result_body(%{result: %{state: state}} = assigns) do
    assigns = assign(assigns, text: absence(state, assigns.store?), state: state)

    ~H"""
    <p id={"#{@prefix}-node-result"} data-result={@state}>{@text}</p>
    """
  end

  defp result_body(assigns), do: ~H""

  @spec absence(state :: atom(), store? :: boolean()) :: String.t()
  defp absence(:not_run, _store?), do: "Not run. The run didn't reach this step."
  defp absence(:running, _store?), do: "Running. The output appears when this step ends."
  defp absence(:interrupted, _store?), do: "Interrupted. This step ended before it finished."
  defp absence(:loading, _store?), do: "Loading the output"
  defp absence(:lag, _store?), do: "Catching up. This result is still being written."
  defp absence(:unavailable, _store?), do: "Couldn't load this result."

  defp absence(:read_failed, _store?),
    do: "Reading this result stopped before it finished."

  defp absence(:miss, false),
    do: "Not stored by policy. This step ran, but its output isn't kept."

  defp absence(:miss, _store?),
    do: "Result not available. This step ended, but no output was recorded."

  # The read of a node's result at a generation, among those the page reads.
  @spec read_for(reads :: map(), node :: String.t(), generation :: integer() | nil) ::
          map() | nil
  defp read_for(reads, node, generation) do
    Enum.find_value(reads, fn
      {{_id, ^node, ^generation, _seq}, read} -> read
      _other -> nil
    end)
  end

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
  The Results panel: the workflow's declared outputs first, then every other node with
  a settled attempt, by stage. Expanding a row reads its result at its latest
  generation; nothing here runs anything. It shows while nothing is selected.
  """
  attr :run, :map, required: true
  attr :document, :map, required: true, doc: "the run's snapshot"
  attr :open?, :boolean, required: true

  def results_panel(assigns) do
    rows = RunView.results(assigns.run.fold, assigns.document)
    by_ref = Map.new(rows, &{{&1.stage, &1.node}, &1})

    declared =
      for %{"stage" => stage, "node" => node} <- Composer.outputs(assigns.document),
          do: {stage, node}

    assigns =
      assign(assigns,
        outputs:
          for({stage, node} = ref <- declared, do: by_ref[ref] || %{stage: stage, node: node}),
        stages:
          rows
          |> Enum.reject(&({&1.stage, &1.node} in declared))
          |> Enum.chunk_by(& &1.stage)
          |> Enum.map(&{hd(&1).stage, &1})
      )

    ~H"""
    <.panel id="results-panel" side="right" label="Results" open?={@open?} close="close_panel">
      <div class="space-y-4 p-3 text-sm">
        <section :if={@outputs != []} id="results-outputs" aria-label="Workflow outputs">
          <h3 class="mb-1 text-xs font-medium text-muted">Workflow outputs</h3>
          <ul class="space-y-1">
            <.result_row :for={row <- @outputs} row={row} run={@run} />
          </ul>
        </section>
        <section
          :for={{stage, rows} <- @stages}
          id={"results-stage-#{stage}"}
          aria-label={"Results of #{stage}"}
        >
          <h3 class="mb-1 text-xs font-medium text-muted">{stage}</h3>
          <ul class="space-y-1">
            <.result_row :for={row <- rows} row={row} run={@run} />
          </ul>
        </section>
        <p :if={@outputs == [] and @stages == []} id="results-empty" class="text-muted">
          No step has finished yet. Results appear here as steps end.
        </p>
      </div>
    </.panel>
    """
  end

  attr :row, :map, required: true
  attr :run, :map, required: true

  defp result_row(assigns) do
    %{row: row, run: run} = assigns
    id = "result-row-#{row.stage}-#{row.node}"

    assigns =
      assign(assigns,
        id: id,
        expanded?: MapSet.member?(run.expanded, {row.stage, row.node}),
        read: row[:generation] && read_for(run.reads, row.node, row.generation)
      )

    ~H"""
    <li id={@id} class="soft-row space-y-2 px-2 py-1.5">
      <button
        :if={@row[:status]}
        id={"#{@id}-toggle"}
        type="button"
        phx-click="toggle_result"
        phx-value-stage={@row.stage}
        phx-value-node={@row.node}
        aria-expanded={to_string(@expanded?)}
        class="flex w-full items-center gap-2 text-left"
      >
        <span class="min-w-0 flex-1 truncate font-medium">{@row.node}</span>
        <span :if={@row.generation > 0} class="text-xs text-muted">Gen {@row.generation}</span>
        <.run_pill id={"#{@id}-status"} status={@row.status} class="run-pill-inline" />
      </button>
      <div :if={!@row[:status]} class="flex items-center gap-2">
        <span class="min-w-0 flex-1 truncate font-medium">{@row.node}</span>
        <span class="text-xs text-muted">No result yet</span>
      </div>
      <.result_body
        :if={@expanded?}
        result={@read}
        store?={@row[:store?] != false}
        node={@row.node}
        generation={@row.generation}
        prefix={@id}
        reload_id={"#{@id}-reload"}
      />
    </li>
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
  A person's answer to a pending decision: the nodes it declares as evidence, each with
  the generation its result comes from, then one form per choice, each saying what it
  does. It shows only while Core awaits this decision and the run isn't frozen, which
  includes a stopped run: there a halt finishes the run at once, and a rerun waits for
  Resume.
  """
  attr :decision, :string, required: true
  attr :card, :map, required: true
  attr :document, :map, required: true
  attr :run, :map, required: true

  def decision_form(assigns) do
    %{run: run, document: document, decision: decision} = assigns
    status = run.status
    occurrence = RunView.awaited(status, decision)
    choices = get_in(document, ["vertices", decision, "choices"]) || []

    assigns =
      assign(assigns,
        occurrence: occurrence,
        show?:
          assigns.card.decider == @person and is_binary(occurrence) and is_map(status) and
            not RunView.frozen?(status),
        stopped?: is_map(status) and RunView.phase(status) == "stopped",
        history?: history?(run, status, decision),
        choices: choices,
        evidence: RunView.evidence(run.fold, document, status, decision),
        secondary: @secondary
      )

    ~H"""
    <div :if={@show? and @history?} id="decision-history-note" class="soft-row space-y-2 p-3">
      <p>
        The graph shows generation {@run.scope}, older than this decision. Show the latest
        generation to answer it.
      </p>
      <button
        id="decision-history-latest"
        type="button"
        phx-click="set_run_scope"
        phx-value-scope="latest"
        class={@secondary}
      >
        Show latest
      </button>
    </div>
    <section
      :if={@show? and not @history?}
      id={"decision-form-#{@decision}"}
      aria-label="Answer this decision"
      class="space-y-3"
    >
      <p :if={@stopped?} id="decision-stopped-note" class="text-warning">
        This run is stopped. {stopped_note(@choices)}
      </p>
      <section
        :if={@evidence != []}
        id="decision-evidence"
        aria-label="Evidence"
        class="space-y-2"
      >
        <div
          :for={item <- @evidence}
          id={"decision-evidence-#{item.node}"}
          class="space-y-1"
        >
          <p>
            <span class="font-medium">{item.node}</span>
            <span id={"decision-evidence-#{item.node}-generation"} class="text-xs text-muted">
              {evidence_label(item.shown)}
            </span>
          </p>
          <.result_body
            :if={item.shown}
            result={read_for(@run.reads, item.node, elem(item.shown, 1))}
            store?={evidence_stored?(@document, item)}
            node={item.node}
            generation={elem(item.shown, 1)}
            prefix={"decision-evidence-#{item.node}"}
            reload_id={"reload-evidence-#{item.node}"}
          />
        </div>
      </section>
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
            id_prefix={"decide-#{choice["name"]}-field"}
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

  # A graph scope older than the pending occurrence is history, which never answers it.
  @spec history?(run :: map(), status :: map() | nil, decision :: String.t()) :: boolean()
  defp history?(%{scope: scope} = run, status, decision) when is_integer(scope) do
    case RunView.pending_generation(run.fold, status, decision) do
      pending when is_integer(pending) -> scope < pending
      nil -> false
    end
  end

  defp history?(_run, _status, _decision), do: false

  @spec evidence_label(shown :: {:same | :from, integer()} | nil) :: String.t()
  defp evidence_label({:same, generation}), do: "Generation #{generation}"
  defp evidence_label({:from, generation}), do: "from generation #{generation}"
  defp evidence_label(nil), do: "Not run yet in this run."

  @spec evidence_stored?(document :: map(), item :: RunView.evidence()) :: boolean()
  defp evidence_stored?(document, item),
    do: Composer.nodes(document, item.stage)[item.node]["store"] != false

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
        else: "#{name} runs when you press Resume run."
    end)
  end

  @spec decider_label(id :: String.t() | nil) :: String.t()
  defp decider_label(id) do
    case Enum.find(Catalog.deciders(), &(&1.id == id)) do
      %{label: label} -> label
      nil -> "its decider"
    end
  end

  @spec decision_path(
          draft_id :: String.t() | nil,
          run_id :: String.t(),
          decision :: String.t()
        ) :: String.t()
  defp decision_path(draft_id, run_id, decision),
    do: run_link(draft_id, nil, run_id, node: decision)

  @doc """
  The run switcher: a draft's runs that may need attention first, then its newest, each
  with its summary's status and opening that run. A run with no summary yet shows as
  needing a check. Its links lead to the Runs view for this draft.
  """
  attr :runs, :list, required: true, doc: "runs with their summaries, attention first"
  attr :draft_id, :string, default: nil
  attr :stage, :string, default: nil
  attr :current, :string, default: nil
  attr :attention_count, :integer, default: 0

  def recent_runs(assigns) do
    assigns = assign(assigns, section_title: @section_title)

    ~H"""
    <section id="recent-runs" aria-label="Runs" class="space-y-2 p-3">
      <h2 class={@section_title}>Runs</h2>
      <p :if={@runs == []} id="recent-runs-empty" class="text-xs text-muted">No runs yet.</p>
      <.link
        :if={@attention_count > 0 && @draft_id}
        id="attention-runs-link"
        navigate={~p"/composer/runs?#{[draft: @draft_id, status: "attention"]}"}
        class="soft-link block text-xs text-warning"
      >
        {attention_label(@attention_count)}
      </.link>
      <ul class="space-y-1 text-sm">
        <li :for={row <- @runs} :key={row.id} id={"recent-run-#{row.id}"}>
          <.link
            patch={run_link(@draft_id, @stage, row.id)}
            aria-current={if(row.id == @current, do: "page")}
            class={[
              "soft-link flex items-center gap-2",
              row.id == @current && "font-semibold"
            ]}
          >
            <.summary_chip id={"recent-run-status-#{row.id}"} summary={row.summary} />
            <span class="min-w-0 flex-1 truncate">{start_time(row.inserted_at)}</span>
            <code class="text-xs text-muted">{String.slice(row.id, 0, 8)}</code>
          </.link>
        </li>
      </ul>
      <.link
        :if={@draft_id}
        id="all-runs-link"
        navigate={~p"/composer/runs?#{[draft: @draft_id]}"}
        class="soft-link block text-xs"
      >
        All runs of this draft
      </.link>
    </section>
    """
  end

  @doc """
  A run's status as its summary last saw it, as a word. With no summary yet it says the
  run needs a check, since it may be waiting.
  """
  attr :id, :string, required: true
  attr :summary, :map, default: nil, doc: "a `Domovoy.Composer.RunSummary`, or nil"

  def summary_chip(assigns) do
    {tone, word} = summary_state(assigns.summary)
    assigns = assign(assigns, tone: tone, word: word)

    ~H"""
    <span id={@id} data-run-pill={@tone} class="run-pill shrink-0">
      <span :if={@tone == "running"} aria-hidden="true" class="flex">
        <.icon name="hero-arrow-path" class="run-spin size-3" />
      </span>
      {@word}
    </span>
    """
  end

  @doc """
  When a run started, to the minute, labelled as UTC.
  """
  @spec start_time(at :: DateTime.t()) :: String.t()
  def start_time(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @spec attention_label(count :: pos_integer()) :: String.t()
  defp attention_label(1), do: "1 run may need you"
  defp attention_label(count) when count > 5, do: "5+ runs may need you"
  defp attention_label(count), do: "#{count} runs may need you"

  # The chip's tone, which picks its colour, and its word.
  @spec summary_state(summary :: map() | nil) :: {String.t(), String.t()}
  defp summary_state(nil), do: {"uncertain", "Needs a check"}

  defp summary_state(%{error_type: "never_started", terminal: true}),
    do: {"none", "Never started"}

  defp summary_state(%{error_type: "unreadable", terminal: true}), do: {"none", "Can't be read"}
  defp summary_state(%{error_type: "unreadable"}), do: {"uncertain", "Can't be read"}
  defp summary_state(%{error_type: "never_started"}), do: {"running", "Starting"}

  defp summary_state(%{committed_phase: "finished", outcome: "succeeded"}),
    do: {"succeeded", "Succeeded"}

  defp summary_state(%{committed_phase: "finished", outcome: "failed"}), do: {"failed", "Failed"}

  defp summary_state(%{committed_phase: "finished", outcome: "cancelled"}),
    do: {"none", "Cancelled"}

  defp summary_state(%{committed_phase: "finished"}), do: {"none", "Finished"}

  defp summary_state(%{committed_phase: "waiting", pending_decisions: [_ | _]}),
    do: {"needs_you", "Needs you"}

  defp summary_state(%{committed_phase: "waiting"}), do: {"needs_you", "Waiting"}
  defp summary_state(%{committed_phase: "stopped"}), do: {"none", "Stopped"}
  defp summary_state(%{committed_phase: "paused"}), do: {"none", "Paused"}

  defp summary_state(%{committed_phase: phase})
       when phase in ~w(starting resuming running pausing stopping cancelling finishing),
       do: {"running", "Running"}

  defp summary_state(_unknown), do: {"uncertain", "Needs a check"}

  # The decisions waiting for a person, which are the only ones a person can answer.
  @spec pending(status :: map() | nil, document :: map()) :: [String.t()]
  defp pending(%{awaiting: awaiting}, document) when is_list(awaiting) do
    for %{decision: decision} when is_binary(decision) <- awaiting,
        get_in(document, ["vertices", decision, "decider"]) == @person,
        uniq: true,
        do: decision
  end

  defp pending(_status, _document), do: []

  @doc """
  One sentence that says where the run is and what it needs next, from its status and
  its snapshot, `document`, which names who answers each decision.
  """
  @spec sentence(run :: map(), document :: map()) :: String.t()
  def sentence(%{state: :opening}, _document), do: "Opening this run"
  def sentence(%{state: :never_started}, _document), do: "This run never started"

  def sentence(%{state: :runner_unavailable}, _document),
    do: "This run's runners are no longer available"

  def sentence(%{state: :definition_mismatch}, _document), do: "This run can't continue"
  def sentence(%{state: :unavailable}, _document), do: "This run can't be read right now"

  def sentence(%{status: status, fold: fold}, document) do
    cond do
      RunView.frozen?(status) ->
        "This run lost its process and is doing nothing. Recover to continue"

      RunView.phase(status) == "waiting" ->
        case pending(status, document) do
          [] -> "Waiting"
          decisions -> "Waiting for your decision on #{Enum.join(decisions, ", ")}"
        end

      true ->
        phase_sentence(RunView.phase(status), status, fold)
    end
  end

  @spec phase_sentence(phase :: String.t(), status :: map(), fold :: RunView.t()) :: String.t()
  defp phase_sentence("starting", _status, _fold), do: "Starting this run"
  defp phase_sentence("resuming", _status, _fold), do: "Resuming this run"
  defp phase_sentence("running", _status, fold), do: named("Running", fold, "running")

  defp phase_sentence("pausing", _status, _fold), do: "Finishing active work before pausing"

  defp phase_sentence("paused", status, _fold) do
    case time(status[:pause_until]) do
      nil -> "Paused. Unpause run lets it go on"
      until -> "Paused until #{Calendar.strftime(until, "%Y-%m-%d %H:%M UTC")}"
    end
  end

  defp phase_sentence("stopping", _status, _fold),
    do: "Stopping active work and saving checkpoint"

  defp phase_sentence("stopped", _status, _fold),
    do: "Stopped. Resume run continues it from its checkpoint"

  defp phase_sentence("blocked", %{block_reason: "pause_timeout"}, _fold),
    do: "Blocked. Active work didn't finish in time to pause. Unpause run lets it go on"

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
end
