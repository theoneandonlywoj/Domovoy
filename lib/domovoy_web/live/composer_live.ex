defmodule DomovoyWeb.ComposerLive do
  @moduledoc """
  Edits one draft by forms, keyboard and canvas gestures. Every edit goes through
  `commit/2`, and every rule lives in `Domovoy.Composer`, so a hostile event gets the
  same answer as a bad form: an explained rejection and an unchanged draft.

  Cards, relationships and issues are plain assigns with `:for :key`, an exception to
  the streams rule in `AGENTS.md`: undo and validation need the whole set, at about
  30-50 nodes. History lives in this process, so it starts empty on every mount.

  `?run=<id>` shows one run of the draft, read-only, through
  `DomovoyWeb.ComposerLive.RunEvents`, whose hooks deny every edit there.
  `/composer/runs/<id>` and `/dashboard/workflows/runs/<id>` open a run by its id alone: one with a draft goes to that
  draft's `?run=`, and one whose draft was deleted shows its snapshot with no draft.
  """

  use DomovoyWeb, :live_view

  @surfaces ~w(canvas outline details launcher)

  import DomovoyWeb.ComposerComponents
  import DomovoyWeb.ComposerRunComponents

  alias Domovoy.Catalog
  alias Domovoy.Composer
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.RunView
  alias DomovoyWeb.ComposerLive.RunEvents

  @impl true
  def mount(%{"run_id" => id} = params, _session, socket) do
    case Composer.get_run_by_id(id) do
      {:ok, %{draft_id: nil} = row} ->
        {:ok,
         socket
         |> base_assigns(row.workflow_name || "Run")
         |> reset_view(nil, row.document)
         |> RunEvents.enter_retained(row)}

      {:ok, row} ->
        {:ok,
         push_navigate(socket,
           to: composer_path(socket.assigns.shell, row.draft_id, params["stage"], row.id, [])
         )}

      {:error, reason} ->
        message =
          if reason == :runs_disabled,
            do: RunEvents.refusal_text(:runs_disabled),
            else: "That run doesn't exist."

        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: drafts_path(socket.assigns.shell))}
    end
  end

  def mount(%{"id" => id}, _session, socket) do
    case load_draft(id) do
      {:ok, draft} ->
        {:ok,
         socket
         |> base_assigns(draft.title)
         |> reset_draft(draft)
         |> RunEvents.load_runs()}

      :error ->
        {:ok, RunEvents.gone(socket)}
    end
  end

  @spec base_assigns(socket :: Phoenix.LiveView.Socket.t(), title :: String.t()) ::
          Phoenix.LiveView.Socket.t()
  defp base_assigns(socket, title) do
    socket
    |> stream_configure(:runners, dom_id: &runner_dom_id/1)
    |> assign(
      page_title: title,
      plugins: Catalog.plugins(),
      types: Catalog.types(),
      deciders: Catalog.deciders(),
      runner_options: Enum.map(Catalog.search(%{}), &{&1.label, &1.id}),
      stage: nil,
      shown: nil,
      panel: nil,
      surface: "canvas",
      canvas_only?: false,
      query: "",
      picked: nil,
      picker_source: nil,
      node_form: node_form("", ""),
      input_form: input_form(%{}),
      vertex_form: vertex_form(%{}),
      choice_form: choice_form(%{})
    )
    |> RunEvents.attach()
  end

  # `?run=` is read first, so the level below is checked against what is on screen: a
  # run's snapshot, or the draft. A run route's run was entered at mount.
  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:run, :run_stage],
      do: socket |> level(params) |> sync_reads()

  def handle_params(params, _uri, socket) do
    case RunEvents.sync_param(params, socket) do
      :none ->
        socket |> level(params) |> link_params(params) |> sync_reads()

      {:enter, socket} ->
        socket |> RunEvents.load_runs() |> level(params) |> link_params(params) |> sync_reads()

      {:leave, socket} ->
        case load_draft(socket.assigns.draft.id) do
          {:ok, latest} ->
            socket
            |> back_to_draft(latest)
            |> RunEvents.load_runs()
            |> level(params)
            |> link_params(params)

          :error ->
            {:noreply, RunEvents.gone(socket)}
        end

      {:bad, socket} ->
        stage = if socket.assigns.live_action == :stage, do: params["stage"]

        {:noreply,
         socket
         |> put_flash(:info, "That run isn't one of this draft's.")
         |> push_patch(
           to: composer_path(socket.assigns.shell, socket.assigns.draft.id, stage, nil, [])
         )}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # A link can select a node in a run, whose result is then read.
  @spec sync_reads(result :: {:noreply, Phoenix.LiveView.Socket.t()}) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp sync_reads({:noreply, socket}), do: {:noreply, RunEvents.sync_reads(socket)}

  @spec level(socket :: Phoenix.LiveView.Socket.t(), params :: map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp level(%{assigns: %{live_action: action}} = socket, %{"stage" => stage} = params)
       when action in [:stage, :run_stage] do
    if stage?(socket.assigns.document, stage) do
      # The catalog's stream isn't rendered above a stage, so entering one fills it.
      {:noreply,
       socket
       |> enter(stage)
       |> select_param(params)
       |> RunEvents.generation_params(params)
       |> stream(:runners, Catalog.search(%{}), reset: true)}
    else
      {:noreply,
       socket
       |> put_flash(:info, "That isn't a stage of this draft.")
       |> push_patch(
         to: run_link(socket.assigns.shell, draft_id(socket), nil, run_id(socket), [])
       )}
    end
  end

  defp level(socket, params),
    do:
      {:noreply,
       socket |> enter(nil) |> select_param(params) |> RunEvents.generation_params(params)}

  # A link can open the draft with its New run launcher or its issues shown. `launch` acts
  # once connected and is then patched away, so a reload doesn't open it again.
  @spec link_params(
          result :: {:noreply, Phoenix.LiveView.Socket.t()},
          params :: map()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp link_params({:noreply, %{assigns: %{run: nil}} = socket}, %{"launch" => "1"} = params) do
    if connected?(socket) do
      stage = if socket.assigns.live_action == :stage, do: socket.assigns.stage
      path = composer_path(socket.assigns.shell, socket.assigns.draft.id, stage, nil, [])
      {:noreply, socket |> RunEvents.open_launcher() |> push_patch(to: path, replace: true)}
    else
      link_params({:noreply, socket}, Map.delete(params, "launch"))
    end
  end

  defp link_params({:noreply, %{assigns: %{run: nil}} = socket}, %{"tools" => "1"}),
    do: {:noreply, socket |> validate() |> open_tools()}

  defp link_params(result, _params), do: result

  # A link can open a level with a card selected; in a run, `gen` and `scope` then pick
  # the generations shown, as `RunEvents.generation_params/2` reads them.
  @spec select_param(socket :: Phoenix.LiveView.Socket.t(), params :: map()) ::
          Phoenix.LiveView.Socket.t()
  defp select_param(socket, %{"node" => node}) when is_binary(node) do
    %{document: document, stage: stage} = socket.assigns
    selectable = if stage, do: Composer.nodes(document, stage), else: document["vertices"]

    if is_map_key(selectable, node),
      do: assign(socket, selected: node, surface: "details"),
      else: socket
  end

  defp select_param(socket, _params), do: socket

  # Back from a run: Undo stays only while nothing saved the draft in between.
  @spec back_to_draft(socket :: Phoenix.LiveView.Socket.t(), latest :: Draft.t()) ::
          Phoenix.LiveView.Socket.t()
  defp back_to_draft(socket, latest) do
    if latest.lock_version == socket.assigns.draft.lock_version,
      do: assign(socket, draft: latest, document: latest.document),
      else: reset_draft(socket, latest)
  end

  # The graph shows one generation's statuses once a scope is picked, else the latest.
  @spec run_statuses(run :: map() | nil, stage :: String.t() | nil) :: map()
  defp run_statuses(nil, _stage), do: %{}

  defp run_statuses(%{scope: scope} = run, stage) when is_integer(scope),
    do: RunView.scope_statuses(run.fold, stage, scope)

  defp run_statuses(run, stage), do: RunView.card_statuses(run.fold, stage)

  @spec run_active?(run :: map() | nil) :: boolean()
  defp run_active?(%{status: %{committed_phase: phase}}), do: phase != "finished"
  defp run_active?(_run), do: false

  @spec run_id(socket :: Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defp run_id(%{assigns: %{run: %{id: id}}}), do: id
  defp run_id(_socket), do: nil

  # Nil on a run whose draft was deleted.
  @spec draft_id(socket :: Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defp draft_id(%{assigns: %{draft: %{id: id}}}), do: id
  defp draft_id(_socket), do: nil

  @impl true
  def render(assigns) do
    %{run: run, stage: stage, view: view} = assigns

    assigns =
      assign(assigns,
        draft_id: assigns.draft && assigns.draft.id,
        selected_card: Enum.find(view.cards, &(&1.name == assigns.selected)),
        issue_rows:
          Composer.issue_rows(
            assigns.document,
            view.issues ++ assigns.core_issues,
            stage
          ),
        statuses: run_statuses(run, stage),
        scope: if(run && is_integer(run.scope), do: run.scope),
        edges: if(run, do: RunView.wire_statuses(run.fold, stage, view), else: view.edges)
      )

    ~H"""
    <Layouts.app flash={@flash} variant={layout_variant(@shell)} active="workflows">
      <div
        id="composer"
        data-canvas-only={@canvas_only?}
        class="relative flex h-full flex-col gap-4 p-4 max-md:gap-2 max-md:p-2"
      >
        <.run_header
          :if={@run}
          shell={@shell}
          title={if(@draft, do: @draft.title, else: @page_title)}
          draft_id={@draft_id}
          stage={@stage}
          run={@run}
          selected={@selected}
          outline_open?={@panel == "outline"}
          surface={@surface}
          runs_enabled?={@runs_enabled?}
          launcher?={not is_nil(@start)}
          document={@document}
          attention_count={@attention_count}
        />
        <.composer_header
          :if={!@run}
          shell={@shell}
          draft={@draft}
          stage={@stage}
          validity={@validity}
          undo?={not Composer.history_empty?(@history)}
          tools_open?={@tools_open?}
          issue_count={length(@issue_rows)}
          runs_enabled?={@runs_enabled?}
          latest_run={@latest_run}
          outline_open?={@panel == "outline"}
          surface={@surface}
          launcher?={not is_nil(@start)}
        />
        <.notices conflict={@conflict} rejection={@rejection} />
        <.input_strip
          :if={!@run}
          inputs={@view.inputs}
          prior={if @stage, do: @view.prior_sources, else: []}
          form={@input_form}
          types={@types}
        />

        <div
          id="workspace"
          data-modal-background
          data-surface={@surface}
          class="relative min-h-0 flex-1"
        >
          <.workflow_canvas
            :if={!@stage}
            shell={@shell}
            cards={@view.cards}
            edges={@edges}
            selected={@selected}
            draft_id={@draft_id}
            run_statuses={@statuses}
            read_only?={not is_nil(@run)}
            run_id={@run && @run.id}
            scope={@scope}
          />
          <.stage_canvas
            :if={@stage}
            cards={@view.cards}
            sources={@view.source_nodes}
            edges={@edges}
            selected={@selected}
            stage={@stage}
            run_statuses={@statuses}
            read_only?={not is_nil(@run)}
          />

          <.panel
            id="outline-panel"
            side="left"
            label={if @run, do: "Steps", else: "Outline"}
            open?={@panel == "outline"}
            close="close_panel"
          >
            <.run_outline
              :if={@run}
              shell={@shell}
              draft_id={@draft_id}
              stage={@stage}
              run={@run}
              inputs={@view.inputs}
              recent={@recent_runs}
              attention_count={@attention_count}
              document={@document}
            />
            <div :if={!@run}>
              <.workflow_settings draft={@draft} document={@document} />
              <.add_vertex :if={!@stage} form={@vertex_form} />
              <.catalog_picker
                :if={@stage}
                runners={@streams.runners}
                plugins={@plugins}
                query={@query}
                picked={@picked}
                source={@picker_source}
                form={@node_form}
              />
              <.recent_runs
                :if={@runs_enabled?}
                shell={@shell}
                runs={@recent_runs}
                draft_id={@draft.id}
                stage={@stage}
                attention_count={@attention_count}
              />
            </div>
          </.panel>

          <div
            :if={@canvas_only?}
            id="canvas-only-bar"
            data-canvas-control
            class="soft-panel absolute left-3 top-3 z-30 flex max-w-[calc(100%-1.5rem)] items-center gap-3 px-3 py-1.5 text-sm"
          >
            <p id="canvas-only-status" class="min-w-0 truncate">
              <%= if @run do %>
                {sentence(@run, @document)}
              <% else %>
                {@draft.title}<span :if={@stage} class="text-muted"> / {@stage}</span>
              <% end %>
            </p>
            <button
              id="exit-canvas-only"
              type="button"
              phx-click="toggle_canvas_only"
              phx-mounted={JS.focus()}
              class="soft-btn soft-btn-quiet whitespace-nowrap px-2 py-1 text-sm"
            >
              Exit canvas only
            </button>
          </div>

          <.start_form
            :if={@start}
            shell={@shell}
            start={@start}
            open?={@panel == "launcher"}
            draft_id={@draft_id}
            run_page?={not is_nil(@run)}
            run_active?={run_active?(@run)}
          />

          <.results_panel
            :if={@run}
            run={@run}
            document={@document}
            open?={@panel == "results" and is_nil(@selected)}
          />

          <.panel
            :if={@selected_card}
            id="inspector-panel"
            side="right"
            label="Inspector"
            open?={is_nil(@start) or @panel != "launcher"}
            pinnable?
          >
            <.run_summary
              :if={@run}
              run={@run}
              selected={@selected}
              statuses={@statuses}
              stage={@stage}
              document={@document}
              cards={@view.cards}
              draft_id={@draft_id}
            />
            <.vertex_inspector
              :if={!@run && !@stage}
              card={@selected_card}
              cards={@view.cards}
              document={@document}
              deciders={@deciders}
              types={@types}
              choice_form={@choice_form}
            />
            <.inspector
              :if={!@run && @stage}
              card={@selected_card}
              replace={@replace}
              runner_options={@runner_options}
            />
          </.panel>

          <aside
            :if={!@run && @tools_open?}
            id="composer-tools"
            data-canvas-control
            aria-label="Issues and tools"
            class="soft-panel workspace-panel absolute right-3 top-3 z-40 max-h-[calc(100%-1.5rem)] w-96 max-w-[calc(100%-1.5rem)] overflow-y-auto"
          >
            <div class="flex items-center justify-between border-b border-base-300 p-3">
              <h2 class="font-semibold">Issues / Tools</h2>
              <button
                id="close-tools"
                type="button"
                phx-click="close_tools"
                disabled={not is_nil(@confirm)}
                class="soft-btn soft-btn-quiet px-2 py-1 text-sm"
              >Close</button>
            </div>
            <.issue_list shell={@shell} rows={@issue_rows} draft_id={@draft.id} />
            <.loop_limits :if={!@stage && @view.loop?} />
            <.connect_to :if={@stage} connect={@connect} />
            <.clear_input_preview :if={@stage} clear={@clear} />
            <.relationship_list :if={@stage} relationships={@view.relationships} />
          </aside>
        </div>
        <.confirm_replace_literal confirm={@confirm} />
        <.cancel_dialog :if={@run && @run.cancel_open?} />
        <.reconcile_dialog :if={@run && @run.reconcile} run={@run} />
      </div>
    </Layouts.app>
    """
  end

  # Header

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, validate(socket)}

  def handle_event("undo", _params, socket) do
    %{history: history, draft: draft} = socket.assigns

    case Composer.undo(history) do
      :empty ->
        {:noreply, socket}

      {document, kind, rest} ->
        {:noreply,
         case Composer.save_document(draft, document) do
           {:ok, saved} -> saved(socket, saved, document, kind, rest)
           {:error, reason} -> save_failed(socket, reason)
         end}
    end
  end

  def handle_event("load_latest", _params, socket) do
    %{draft: draft, stage: stage} = socket.assigns

    case load_draft(draft.id) do
      {:ok, latest} ->
        {:noreply,
         socket
         |> reset_draft(latest)
         |> push_patch(to: composer_path(socket.assigns.shell, latest.id, stage, nil, []))}

      :error ->
        {:noreply, RunEvents.gone(socket)}
    end
  end

  def handle_event("dismiss_rejection", _params, socket) do
    {:noreply, assign(socket, :rejection, nil)}
  end

  # Workflow settings

  def handle_event("save_title", params, socket) do
    case form_value(params, "title") do
      title when is_binary(title) -> {:noreply, save_title(socket, title)}
      _wrong_shape -> {:noreply, socket}
    end
  end

  def handle_event("set_workflow_name", params, socket) do
    {:noreply, commit(socket, {:set_workflow_name, form_value(params, "workflow_name")})}
  end

  # Inputs

  def handle_event("preview_input", %{"input" => params}, socket) do
    {:noreply, assign(socket, :input_form, input_form(params))}
  end

  def handle_event("save_input", %{"input" => params}, socket) when is_map(params) do
    socket = commit(socket, {:put_input, params["name"], input_attrs(params)})

    kept? = socket.assigns.rejection || socket.assigns.conflict
    form = if kept?, do: input_form(params), else: input_form(%{})
    {:noreply, assign(socket, :input_form, form)}
  end

  def handle_event("new_input", _params, socket) do
    {:noreply, assign(socket, :input_form, input_form(%{}))}
  end

  def handle_event("edit_input", %{"name" => name}, socket) do
    case socket.assigns.document["inputs"] do
      %{^name => input} ->
        {:noreply, assign(socket, :input_form, input_form(input_params(name, input)))}

      _unknown ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_input", %{"name" => name}, socket) do
    {:noreply, commit(socket, {:remove_input, name})}
  end

  # Vertices

  def handle_event(
        "add_vertex",
        %{"vertex" => %{"name" => name, "kind" => kind} = params},
        socket
      )
      when kind in ["stage", "decision"] do
    op = if kind == "stage", do: {:add_stage, name}, else: {:add_decision, name}
    socket = commit(socket, op)

    form = if edit_stands?(socket), do: vertex_form(%{}), else: vertex_form(params)
    {:noreply, assign(socket, :vertex_form, form)}
  end

  def handle_event("preview_vertex", %{"vertex" => params}, socket) do
    {:noreply, assign(socket, :vertex_form, vertex_form(params))}
  end

  def handle_event("set_start", %{"vertex" => vertex}, socket) do
    {:noreply, commit(socket, {:set_start, vertex})}
  end

  def handle_event("remove_vertex", %{"vertex" => vertex}, socket) do
    {:noreply, commit(socket, {:remove_vertex, vertex})}
  end

  def handle_event("set_next", %{"next" => %{"stage" => stage, "vertex" => vertex}}, socket)
      when is_binary(vertex) do
    {:noreply, commit(socket, {:set_next, stage, if(vertex != "", do: vertex)})}
  end

  def handle_event(
        "save_decision",
        %{"decision" => %{"name" => name, "prompt" => prompt, "decider" => decider} = params},
        socket
      ) do
    options =
      case params["node"] do
        node when is_binary(node) and node != "" -> %{"node" => node}
        _none -> %{}
      end

    attrs = %{"prompt" => prompt, "decider" => decider, "decider_options" => options}
    {:noreply, commit(socket, {:put_decision, name, attrs})}
  end

  # Evidence and outputs are checkboxes per node, `refs[stage][node]`, so a ref is never
  # parsed out of one string; the op checks each names a node.
  def handle_event("put_evidence", %{"evidence" => %{"decision" => decision} = params}, socket)
      when is_binary(decision) do
    {:noreply, commit(socket, {:put_evidence, decision, checked_refs(params["refs"])})}
  end

  def handle_event("put_outputs", %{"outputs" => params}, socket) when is_map(params) do
    {:noreply, commit(socket, {:put_outputs, checked_refs(params["refs"])})}
  end

  # Choices

  def handle_event("preview_choice", %{"choice" => params}, socket) do
    {:noreply, assign(socket, :choice_form, choice_form(params))}
  end

  def handle_event("save_choice", %{"choice" => %{"decision" => decision} = params}, socket) do
    attrs = choice_attrs(socket.assigns.document, decision, params)
    socket = commit(socket, {:put_choice, decision, attrs})

    form = if edit_stands?(socket), do: choice_form(%{}), else: choice_form(params)
    {:noreply, assign(socket, :choice_form, form)}
  end

  def handle_event("edit_choice", %{"decision" => decision, "name" => name}, socket) do
    case find_choice(socket.assigns.document, decision, name) do
      %{"target" => target, "description" => description} ->
        params = %{
          "name" => name,
          "description" => description,
          "kind" => hd(target),
          "vertex" => List.last(target)
        }

        {:noreply, assign(socket, :choice_form, choice_form(params))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_choice", %{"decision" => decision, "name" => name}, socket) do
    {:noreply, commit(socket, {:remove_choice, decision, name})}
  end

  # Catalog

  def handle_event("catalog_search", %{"catalog" => %{"text" => text}}, socket)
      when is_binary(text) do
    if Composer.text_safe?(text) do
      {:noreply,
       socket
       |> assign(query: text, picker_source: nil)
       |> stream(:runners, Catalog.search(%{text: text}), reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_runner", %{"runner" => id}, socket) do
    case Catalog.runner(id) do
      {:ok, runner} ->
        name = suggest_name(socket.assigns.document, runner)
        {:noreply, assign(socket, picked: runner, node_form: node_form(runner.id, name))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("add_node", %{"add_node" => %{"runner" => runner, "name" => name}}, socket) do
    socket = commit(socket, {:add_node, socket.assigns.stage, runner, name})

    {:noreply,
     if socket.assigns.rejection || socket.assigns.conflict do
       socket
     else
       socket |> close_picker() |> assign(:selected, name)
     end}
  end

  def handle_event("open_picker", %{"source" => source}, socket) when is_binary(source) do
    %{document: document, stage: stage} = socket.assigns

    if source?(socket, source) do
      {:noreply,
       socket
       |> assign(picked: nil, query: "", picker_source: source)
       |> stream(:runners, Composer.runners_reading(document, stage, source), reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, close_picker(socket)}

  def handle_event("open_tools", _params, socket), do: {:noreply, open_tools(socket)}

  def handle_event("close_tools", _params, socket) do
    {:noreply, if(socket.assigns.confirm, do: socket, else: assign(socket, :tools_open?, false))}
  end

  # Panels. Below `md` one surface fills the screen; only these names are accepted.
  def handle_event("open_outline", _params, socket),
    do: {:noreply, assign(socket, panel: "outline", surface: "outline")}

  def handle_event("close_panel", _params, socket),
    do: {:noreply, assign(socket, panel: nil, surface: "canvas")}

  # The launcher is a surface only while one is open. Details hides it, since one right
  # panel shows at a time; New run in the switcher brings it back.
  def handle_event("set_surface", %{"surface" => surface}, socket) when surface in @surfaces do
    %{panel: panel, start: start} = socket.assigns

    panel =
      cond do
        surface == "outline" -> "outline"
        surface == "launcher" and not is_nil(start) -> "launcher"
        surface == "details" and panel == "launcher" -> nil
        true -> panel
      end

    if surface == "launcher" and is_nil(start),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, surface: surface, panel: panel)}
  end

  def handle_event("set_surface", _params, socket), do: {:noreply, socket}

  # Canvas only takes no params, so nothing a client sends can set anything else.
  def handle_event("toggle_canvas_only", _params, socket),
    do: {:noreply, update(socket, :canvas_only?, &(not &1))}

  # Selection

  def handle_event("select_node", %{"node" => node} = params, socket) do
    %{document: document, stage: stage} = socket.assigns
    selectable = if stage, do: Composer.nodes(document, stage), else: document["vertices"]

    if is_map_key(selectable, node) do
      socket =
        assign(socket,
          selected: node,
          surface: "details",
          replace: nil,
          choice_form: choice_form(%{})
        )

      {:noreply, focus_issue(socket, params)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("deselect_node", _params, socket) do
    {:noreply, assign(socket, selected: nil, replace: nil, surface: "canvas")}
  end

  # Canvas

  def handle_event("node_moved", %{"node" => node, "x" => x, "y" => y, "level" => level}, socket) do
    %{draft: before, stage: stage} = socket.assigns

    # A release can race a navigation, and names are only unique within a level.
    if level == canvas_level(stage) do
      socket =
        commit(socket, {:move, if(stage, do: {:stage, stage}, else: :workflow), node, x, y})

      {:reply, %{status: move_status(before, socket.assigns)}, socket}
    else
      {:reply, %{status: "rejected"}, socket}
    end
  end

  # Fits for a connection being dragged, from the same projection as the Connect-to list.
  def handle_event("connect_preview", %{"source" => source} = params, socket)
      when is_binary(source) do
    %{document: document, stage: stage} = socket.assigns

    targets =
      cond do
        is_nil(stage) -> Composer.route_targets(document, source)
        not source?(socket, source) -> []
        params["kind"] == "after" -> Composer.after_targets(document, stage, source)
        true -> Composer.connect_targets(document, stage, source)
      end

    {:reply, %{targets: Enum.map(targets, &Map.take(&1, [:socket, :fit, :label]))}, socket}
  end

  # Connecting

  def handle_event("open_connect", %{"source" => source}, socket) when is_binary(source) do
    %{document: document, stage: stage} = socket.assigns

    if source?(socket, source) do
      targets = Composer.connect_targets(document, stage, source)

      {:noreply,
       socket |> assign(:connect, %{source: source, query: "", targets: targets}) |> open_tools()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_connect", _params, socket) do
    {:noreply, if(socket.assigns.confirm, do: socket, else: assign(socket, :connect, nil))}
  end

  def handle_event("connect_search", %{"connect" => %{"query" => query}}, socket)
      when is_binary(query) do
    connect = socket.assigns.connect

    if connect && Composer.text_safe?(query) do
      {:noreply, assign(socket, :connect, %{connect | query: query})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("connect", %{"source" => source, "node" => node, "field" => field}, socket) do
    {:noreply, connect(socket, source, node, field)}
  end

  def handle_event("bind_field", %{"bind" => %{"source" => ""}}, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "bind_field",
        %{"bind" => %{"source" => source, "node" => node, "field" => field}},
        socket
      ) do
    {:noreply, connect(socket, source, node, field)}
  end

  def handle_event("confirm_replace_literal", _params, socket) do
    case socket.assigns.confirm do
      %{source: source, node: node, field: field} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> commit({:bind, socket.assigns.stage, node, field, source, replace_literal: true})
         |> close_connect()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_replace_literal", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("insert_adapter", %{"runner" => runner}, socket) do
    case socket.assigns.rejection do
      %{connect: %{source: source, node: node, field: field}} ->
        op = {:insert_adapter, socket.assigns.stage, source, node, field, runner}
        {:noreply, socket |> commit(op) |> close_connect()}

      _none ->
        {:noreply, socket}
    end
  end

  # Fields

  def handle_event("commit_literal", %{"literal" => params}, socket) when is_map(params) do
    {:noreply, commit_literal(socket, params["node"], params["field"], params["value"])}
  end

  def handle_event("commit_literal", %{"node" => node, "field" => field, "value" => raw}, socket) do
    {:noreply, commit_literal(socket, node, field, raw)}
  end

  # Clearing a binding another field depends on asks first.
  def handle_event("clear_input", %{"node" => node, "field" => field}, socket) do
    %{document: document, stage: stage} = socket.assigns
    op = {:clear_input, stage, node, field}

    case Composer.preview(document, op) do
      %{warnings: [_ | _] = warnings} ->
        {:noreply,
         socket |> assign(:clear, %{node: node, field: field, warnings: warnings}) |> open_tools()}

      _no_warning ->
        {:noreply, commit(socket, op)}
    end
  end

  def handle_event("confirm_clear_input", _params, socket) do
    case socket.assigns.clear do
      %{node: node, field: field} ->
        {:noreply,
         socket
         |> assign(:clear, nil)
         |> commit({:clear_input, socket.assigns.stage, node, field})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_clear_input", _params, socket) do
    {:noreply, assign(socket, :clear, nil)}
  end

  def handle_event("add_after", %{"after" => %{"source" => ""}}, socket) do
    {:noreply, socket}
  end

  # On the workflow, a card's After handle sets what a stage runs next.
  def handle_event(
        "add_after",
        %{"after" => %{"node" => node, "source" => source}},
        %{assigns: %{stage: nil}} = socket
      )
      when is_binary(node) do
    {:noreply, commit(socket, {:set_next, source, node})}
  end

  def handle_event("add_after", %{"after" => %{"node" => node, "source" => source}}, socket) do
    {:noreply, commit(socket, {:add_after, socket.assigns.stage, node, source})}
  end

  def handle_event("remove_after", %{"node" => node, "source" => source}, socket) do
    {:noreply, commit(socket, {:remove_after, socket.assigns.stage, node, source})}
  end

  # Nodes

  def handle_event("rename_node", %{"rename" => %{"node" => old, "name" => new}}, socket) do
    {:noreply, rename_node(socket, old, new)}
  end

  def handle_event("rename_node", %{"node" => old, "value" => new}, socket) do
    {:noreply, rename_node(socket, old, new)}
  end

  def handle_event("remove_node", %{"node" => node}, socket) do
    {:noreply, commit(socket, {:remove_node, socket.assigns.stage, node})}
  end

  def handle_event(
        "preview_replace_runner",
        %{"replace" => %{"node" => node, "runner" => runner}},
        socket
      ) do
    %{document: document, stage: stage} = socket.assigns

    case Composer.preview(document, {:replace_runner, stage, node, runner}) do
      %{} = preview ->
        {:ok, %{label: label}} = Catalog.runner(runner)

        replace = %{
          node: node,
          runner: runner,
          label: label,
          preview: preview,
          consumers: Composer.consumers(document, node)
        }

        {:noreply, assign(socket, replace: replace, rejection: nil)}

      {:error, %Issue{} = issue} ->
        {:noreply, reject(socket, issue, nil)}
    end
  end

  def handle_event("confirm_replace_runner", _params, socket) do
    case socket.assigns.replace do
      %{node: node, runner: runner} ->
        {:noreply,
         socket
         |> assign(:replace, nil)
         |> commit({:replace_runner, socket.assigns.stage, node, runner})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_replace_runner", _params, socket) do
    {:noreply, assign(socket, :replace, nil)}
  end

  # Validators

  def handle_event("add_validator", %{"validator" => %{"validator" => ""}}, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "add_validator",
        %{"validator" => %{"node" => node, "validator" => id}},
        socket
      ) do
    ids = validators(socket, node) ++ [id]
    {:noreply, commit(socket, {:set_validators, socket.assigns.stage, node, ids})}
  end

  def handle_event("remove_validator", %{"node" => node, "id" => id}, socket) do
    ids = List.delete(validators(socket, node), id)
    {:noreply, commit(socket, {:set_validators, socket.assigns.stage, node, ids})}
  end

  def handle_event(
        "move_validator",
        %{"node" => node, "id" => id, "direction" => direction},
        socket
      ) do
    ids = move(validators(socket, node), id, direction)
    {:noreply, commit(socket, {:set_validators, socket.assigns.stage, node, ids})}
  end

  # Execution

  def handle_event("set_execution", %{"execution" => %{"store" => store} = params}, socket)
      when store in ["true", "false"] do
    %{stage: stage} = socket.assigns

    case attempts(params["max_attempts"]) do
      {:ok, attempts} ->
        {:noreply,
         commit(socket, {:set_execution, stage, params["node"], attempts, store == "true"})}

      :error ->
        issue = %Issue{
          code: :invalid_max_attempts,
          target: {:node, stage, params["node"]},
          message: "Max attempts must be a whole number."
        }

        {:noreply, reject(socket, issue, nil)}
    end
  end

  # An unknown event, or a known one with the wrong shape, changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Writing

  # The one write path of this view. History grows only after the save succeeds.
  @spec commit(socket :: Phoenix.LiveView.Socket.t(), op :: tuple()) ::
          Phoenix.LiveView.Socket.t()
  defp commit(socket, op) do
    %{document: before, draft: draft, history: history} = socket.assigns

    with {:ok, document, kind} when kind != :none <- Composer.edit(before, op),
         {:ok, saved} <- Composer.save_document(draft, document) do
      saved(socket, saved, document, kind, Composer.push_history(history, before, kind))
    else
      {:ok, _document, :none} -> assign(socket, :rejection, nil)
      {:error, %Issue{code: :literal_present}} -> ask_to_replace(socket, op)
      {:error, %Issue{} = issue} -> reject(socket, issue, connect_context(op))
      {:error, reason} -> save_failed(socket, reason)
    end
  end

  @spec saved(
          socket :: Phoenix.LiveView.Socket.t(),
          draft :: Draft.t(),
          document :: map(),
          kind :: atom(),
          history :: term()
        ) :: Phoenix.LiveView.Socket.t()
  defp saved(socket, draft, document, kind, history) do
    socket
    |> assign(
      draft: draft,
      document: document,
      history: history,
      rejection: nil,
      replace: nil,
      clear: nil
    )
    |> clear_validity(kind)
    |> refresh()
    |> leave_removed_stage()
  end

  @spec layout_variant(shell :: DomovoyWeb.Shell.t()) :: String.t()
  defp layout_variant(:composer), do: "canvas"
  defp layout_variant(:dashboard), do: "dashboard"

  # Undo can remove the stage on screen.
  @spec leave_removed_stage(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp leave_removed_stage(%{assigns: %{stage: stage, document: document, draft: draft}} = socket) do
    if stage && !stage?(document, stage) do
      push_patch(socket, to: composer_path(socket.assigns.shell, draft.id, nil, nil, []))
    else
      socket
    end
  end

  @spec edit_stands?(socket :: Phoenix.LiveView.Socket.t()) :: boolean()
  defp edit_stands?(%{assigns: %{rejection: rejection, conflict: conflict}}) do
    is_nil(rejection) and not conflict
  end

  @spec clear_validity(socket :: Phoenix.LiveView.Socket.t(), kind :: atom()) ::
          Phoenix.LiveView.Socket.t()
  defp clear_validity(socket, :layout), do: socket
  defp clear_validity(socket, _kind), do: assign(socket, validity: nil, core_issues: [])

  @spec save_failed(socket :: Phoenix.LiveView.Socket.t(), reason :: term()) ::
          Phoenix.LiveView.Socket.t()
  defp save_failed(socket, :conflict), do: assign(socket, :conflict, true)
  defp save_failed(socket, :gone), do: RunEvents.gone(socket)

  defp save_failed(socket, %Ecto.Changeset{}) do
    issue = %Issue{code: :not_saved, target: :workflow, message: "That couldn't be saved."}
    reject(socket, issue, nil)
  end

  @spec reject(
          socket :: Phoenix.LiveView.Socket.t(),
          issue :: Issue.t(),
          connect :: map() | nil
        ) :: Phoenix.LiveView.Socket.t()
  defp reject(socket, issue, connect) do
    assign(socket, :rejection, %{issue: issue, connect: connect})
  end

  # Only a bind can meet a literal it may replace.
  @spec ask_to_replace(socket :: Phoenix.LiveView.Socket.t(), op :: tuple()) ::
          Phoenix.LiveView.Socket.t()
  defp ask_to_replace(socket, op) do
    assign(socket, confirm: connect_context(op), rejection: nil)
  end

  @spec connect_context(op :: tuple()) :: map() | nil
  defp connect_context({:bind, _stage, node, field, source, _opts}) do
    %{source: source, node: node, field: field}
  end

  defp connect_context(_op), do: nil

  @spec move_status(before :: Draft.t(), assigns :: map()) :: String.t()
  defp move_status(before, %{draft: draft, conflict: conflict, rejection: rejection}) do
    cond do
      draft.lock_version != before.lock_version -> "ok"
      conflict -> "conflict"
      rejection -> "rejected"
      true -> "noop"
    end
  end

  # An issue link selects its node and focuses its row, in Tools when the row lives there.
  @spec focus_issue(socket :: Phoenix.LiveView.Socket.t(), params :: map()) ::
          Phoenix.LiveView.Socket.t()
  defp focus_issue(socket, %{"focus" => focus} = params) when is_binary(focus) do
    socket =
      if params["tools"] == true or not is_nil(socket.assigns.confirm),
        do: open_tools(socket),
        else: assign(socket, :tools_open?, false)

    push_event(socket, "composer:focus", %{id: focus})
  end

  defp focus_issue(socket, _params), do: socket

  # Tools lives on the canvas surface, so below `md` opening it also shows the canvas.
  @spec open_tools(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp open_tools(socket), do: assign(socket, tools_open?: true, surface: "canvas")

  @spec close_picker(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp close_picker(%{assigns: %{picker_source: nil}} = socket) do
    assign(socket, picked: nil, node_form: node_form("", ""))
  end

  defp close_picker(socket) do
    socket
    |> assign(picked: nil, picker_source: nil, node_form: node_form("", ""))
    |> stream(:runners, Catalog.search(%{}), reset: true)
  end

  @spec connect(
          socket :: Phoenix.LiveView.Socket.t(),
          source :: term(),
          node :: term(),
          field :: term()
        ) :: Phoenix.LiveView.Socket.t()
  defp connect(socket, source, node, field) do
    socket
    |> commit({:bind, socket.assigns.stage, node, field, source, replace_literal: false})
    |> close_connect()
  end

  # The panel stays while a rejection, a confirmation or a conflict still needs it.
  @spec close_connect(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp close_connect(%{assigns: %{rejection: nil, confirm: nil, conflict: false}} = socket) do
    assign(socket, :connect, nil)
  end

  defp close_connect(socket), do: socket

  # Blur fires on every field left, so an untouched empty editor must stay empty.
  @spec commit_literal(
          socket :: Phoenix.LiveView.Socket.t(),
          node :: term(),
          field :: term(),
          raw :: term()
        ) :: Phoenix.LiveView.Socket.t()
  defp commit_literal(socket, node, field, raw) do
    %{document: document, stage: stage} = socket.assigns

    empty? =
      case Composer.nodes(document, stage) do
        %{^node => %{"inputs" => inputs}} -> not is_map_key(inputs, field)
        _unknown -> false
      end

    if raw == "" and empty? do
      socket
    else
      commit(socket, {:set_literal, stage, node, field, raw, replace_binding: false})
    end
  end

  @spec rename_node(socket :: Phoenix.LiveView.Socket.t(), old :: term(), new :: term()) ::
          Phoenix.LiveView.Socket.t()
  defp rename_node(socket, old, new) do
    socket = commit(socket, {:rename_node, socket.assigns.stage, old, new})

    if socket.assigns.selected == old and socket.assigns.rejection == nil and
         not socket.assigns.conflict do
      assign(socket, :selected, new)
    else
      socket
    end
  end

  @spec save_title(socket :: Phoenix.LiveView.Socket.t(), title :: String.t()) ::
          Phoenix.LiveView.Socket.t()
  defp save_title(%{assigns: %{draft: %{title: title}}} = socket, title), do: socket

  defp save_title(socket, title) do
    case Composer.save_title(socket.assigns.draft, title) do
      {:ok, draft} -> assign(socket, draft: draft, page_title: draft.title, rejection: nil)
      {:error, %Ecto.Changeset{}} -> reject(socket, title_issue(), nil)
      {:error, reason} -> save_failed(socket, reason)
    end
  end

  @spec title_issue() :: Issue.t()
  defp title_issue do
    %Issue{
      code: :invalid_title,
      target: :workflow,
      message: "A title holds 1 to 255 characters, without NUL."
    }
  end

  @spec validate(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp validate(socket) do
    %{document: document, view: view} = socket.assigns

    case Composer.validate(document) do
      {:valid, %{fingerprint: fingerprint}} ->
        assign(socket, validity: %{fingerprint: fingerprint}, core_issues: [])

      {:invalid, issues} ->
        assign(socket, validity: nil, core_issues: issues -- view.issues)
    end
  end

  # Reading

  @spec load_draft(id :: term()) :: {:ok, Draft.t()} | :error
  defp load_draft(id) do
    with {:ok, draft} <- Composer.get_draft(id),
         [] <- Composer.shape_issues(draft.document) do
      {:ok, draft}
    else
      _unusable -> :error
    end
  end

  @spec reset_draft(socket :: Phoenix.LiveView.Socket.t(), draft :: Draft.t()) ::
          Phoenix.LiveView.Socket.t()
  defp reset_draft(socket, draft), do: reset_view(socket, draft, draft.document)

  # A run whose draft was deleted has no draft, only its snapshot.
  @spec reset_view(
          socket :: Phoenix.LiveView.Socket.t(),
          draft :: Draft.t() | nil,
          document :: map()
        ) :: Phoenix.LiveView.Socket.t()
  defp reset_view(socket, draft, document) do
    socket
    |> assign(
      draft: draft,
      document: document,
      history: Composer.reset_history(),
      validity: nil,
      core_issues: [],
      conflict: false,
      rejection: nil,
      confirm: nil,
      replace: nil,
      connect: nil,
      clear: nil,
      selected: nil,
      tools_open?: false
    )
    |> refresh()
  end

  # Moving between the workflow and a stage leaves behind what belonged to the last one.
  # Every patch comes here, so the surface goes back to the canvas only when the level or
  # the run on screen changed; `?run=` is already read, so `run_id/1` is the new one.
  @spec enter(socket :: Phoenix.LiveView.Socket.t(), stage :: String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp enter(socket, stage) do
    shown = {stage, run_id(socket)}
    surface = if shown == socket.assigns.shown, do: socket.assigns.surface, else: "canvas"

    socket
    |> assign(
      stage: stage,
      shown: shown,
      surface: surface,
      tools_open?: false,
      selected: nil,
      rejection: nil,
      confirm: nil,
      replace: nil,
      connect: nil,
      clear: nil,
      picked: nil,
      picker_source: nil,
      query: "",
      node_form: node_form("", ""),
      choice_form: choice_form(%{})
    )
    |> refresh()
  end

  @spec refresh(socket :: Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh(socket) do
    %{document: document, stage: stage, connect: connect} = socket.assigns

    connect =
      connect && %{connect | targets: Composer.connect_targets(document, stage, connect.source)}

    view =
      if stage, do: Composer.stage_view(document, stage), else: Composer.workflow_view(document)

    assign(socket, view: view, connect: connect)
  end

  @spec stage?(document :: map(), name :: String.t()) :: boolean()
  defp stage?(document, name), do: match?(%{"kind" => "stage"}, document["vertices"][name])

  # The sources of the stage on screen: its nodes, workflow inputs, and what precedes it.
  @spec source?(socket :: Phoenix.LiveView.Socket.t(), name :: String.t()) :: boolean()
  defp source?(%{assigns: %{document: document, stage: stage, view: view}}, name) do
    is_map_key(Composer.nodes(document, stage), name) or
      is_map_key(document["inputs"], name) or
      Enum.any?(view.prior_sources, &(&1.name == name))
  end

  @spec find_choice(document :: map(), decision :: term(), name :: term()) :: map() | nil
  defp find_choice(document, decision, name) do
    case document["vertices"] do
      %{^decision => %{"choices" => choices}} -> Enum.find(choices, &(&1["name"] == name))
      _other -> nil
    end
  end

  # Only a Rerun on a Stage holds typed inputs, so changing the target drops them.
  @spec choice_attrs(document :: map(), decision :: term(), params :: map()) :: map()
  defp choice_attrs(document, decision, params) do
    target =
      case params["kind"] do
        "halt" -> ["halt"]
        kind -> [kind, params["vertex"]]
      end

    inputs =
      with ["rerun", vertex] <- target,
           true <- stage?(document, vertex),
           %{"inputs" => held} <-
             find_choice(document, decision, params["name"]) || %{"inputs" => %{}} do
        add_choice_input(held, params["input_name"], params["input_type"])
      else
        _other -> %{}
      end

    %{
      "name" => params["name"],
      "description" => params["description"],
      "target" => target,
      "inputs" => inputs
    }
  end

  @spec add_choice_input(inputs :: map(), key :: term(), type :: term()) :: map()
  defp add_choice_input(inputs, key, type) when is_binary(key) and key != "" do
    Map.put(inputs, key, type)
  end

  defp add_choice_input(inputs, _key, _type), do: inputs

  @spec validators(socket :: Phoenix.LiveView.Socket.t(), node :: term()) :: [String.t()]
  defp validators(socket, node) do
    case Composer.nodes(socket.assigns.document, socket.assigns.stage) do
      %{^node => %{"validators" => ids}} -> ids
      _unknown -> []
    end
  end

  @spec move(ids :: [String.t()], id :: term(), direction :: term()) :: [String.t()]
  defp move(ids, id, direction) do
    case {Enum.find_index(ids, &(&1 == id)), direction} do
      {nil, _direction} -> ids
      {0, "up"} -> ids
      {index, "up"} -> ids |> List.delete_at(index) |> List.insert_at(index - 1, id)
      {index, "down"} -> ids |> List.delete_at(index) |> List.insert_at(index + 1, id)
      _other -> ids
    end
  end

  @spec attempts(value :: term()) :: {:ok, integer() | nil} | :error
  defp attempts(""), do: {:ok, nil}

  defp attempts(value) when is_binary(value) do
    case Integer.parse(value) do
      {attempts, ""} -> {:ok, attempts}
      _other -> :error
    end
  end

  defp attempts(_value), do: :error

  # Forms

  # Nil for anything but a map of maps, which the op then refuses.
  @spec checked_refs(refs :: term()) :: [map()] | nil
  defp checked_refs(refs) when is_map(refs) do
    if Enum.all?(refs, fn {_stage, nodes} -> is_map(nodes) end) do
      for {stage, nodes} <- refs, {node, "true"} <- nodes, do: %{"stage" => stage, "node" => node}
    end
  end

  defp checked_refs(_refs), do: nil

  @spec form_value(params :: map(), name :: String.t()) :: term()
  defp form_value(params, name) do
    case params do
      %{^name => %{"value" => value}} -> value
      %{"value" => value} -> value
      _other -> nil
    end
  end

  @spec node_form(runner :: String.t(), name :: String.t()) :: Phoenix.HTML.Form.t()
  defp node_form(runner, name) do
    to_form(%{"runner" => runner, "name" => name}, as: :add_node, id: "add-node")
  end

  @spec vertex_form(params :: term()) :: Phoenix.HTML.Form.t()
  defp vertex_form(params) do
    to_form(
      %{"name" => safe_text(params, "name", ""), "kind" => safe_text(params, "kind", "stage")},
      as: :vertex,
      id: "vertex"
    )
  end

  @spec choice_form(params :: term()) :: Phoenix.HTML.Form.t()
  defp choice_form(params) do
    text = fn key, fallback -> safe_text(params, key, fallback) end

    to_form(
      %{
        "name" => text.("name", ""),
        "description" => text.("description", ""),
        "kind" => text.("kind", "run"),
        "vertex" => text.("vertex", ""),
        "input_name" => text.("input_name", ""),
        "input_type" => text.("input_type", "DomovoyCore.Type.String")
      },
      as: :choice,
      id: "choice"
    )
  end

  @spec suggest_name(document :: map(), runner :: map()) :: String.t()
  defp suggest_name(document, runner) do
    base = runner.module |> Module.split() |> List.last() |> Macro.underscore()
    taken = Enum.flat_map(Map.keys(document["vertices"]), &Map.keys(Composer.nodes(document, &1)))

    [base]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base}_#{&1}"))
    |> Enum.find(&(&1 not in taken))
  end

  # Holds only safe text, since a form renders back what it holds.
  @spec input_form(params :: term()) :: Phoenix.HTML.Form.t()
  defp input_form(params) do
    text = fn key, fallback -> safe_text(params, key, fallback) end

    to_form(
      %{
        "name" => text.("name", ""),
        "type" => text.("type", "DomovoyCore.Type.String"),
        "required" => text.("required", "false"),
        "default_state" => text.("default_state", "absent"),
        "default" => text.("default", "")
      },
      as: :input,
      id: "input"
    )
  end

  @spec safe_text(params :: term(), key :: String.t(), fallback :: String.t()) :: String.t()
  defp safe_text(%{} = params, key, fallback) do
    case params[key] do
      value when is_binary(value) -> if Composer.text_safe?(value), do: value, else: fallback
      _other -> fallback
    end
  end

  defp safe_text(_params, _key, fallback), do: fallback

  @spec input_attrs(params :: map()) :: map()
  defp input_attrs(params) do
    base = %{"type" => params["type"], "required" => params["required"] == "true"}

    case params["default_state"] do
      "null" -> Map.put(base, "default", nil)
      "value" -> Map.put(base, "default", params["default"])
      _absent -> base
    end
  end

  @spec input_params(name :: String.t(), input :: map()) :: map()
  defp input_params(name, input) do
    base = %{
      "name" => name,
      "type" => input["type"],
      "required" => to_string(Map.get(input, "required", false))
    }

    case input do
      %{"default" => nil} ->
        Map.put(base, "default_state", "null")

      %{"default" => default} ->
        Map.merge(base, %{"default_state" => "value", "default" => default})

      _absent ->
        Map.put(base, "default_state", "absent")
    end
  end

  @spec runner_dom_id(runner :: map()) :: String.t()
  defp runner_dom_id(runner), do: "runner-" <> String.replace(runner.id, ".", "-")
end
