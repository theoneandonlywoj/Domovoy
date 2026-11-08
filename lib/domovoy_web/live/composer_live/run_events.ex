defmodule DomovoyWeb.ComposerLive.RunEvents do
  @moduledoc """
  The run side of `DomovoyWeb.ComposerLive`: starting a run, and showing one at
  `?run=<id>`, read-only, with live status, the results it reads (a selected node's,
  a pending decision's evidence and each expanded Results row), answers to a person's
  decision, Stop, Resume, Pause, Unpause, Cancel, reconciling an uncertain effect and
  Recover.

  It attaches hooks at mount. In a run every event is denied unless it is listed here,
  so an edit, `undo` and `save_title`, which bypass `commit/2`, and any future event
  change nothing; selection stays, checked against the snapshot. Every run message and
  async result halts here in both modes, and one for another run is dropped. All
  blocking start work runs in `start_async`.

  Rules stay in `Domovoy.Composer`: a refusal becomes the composer's rejection, and no
  value from a form or a run reaches a log, a flash or the page beyond the form's own
  text.
  """

  use DomovoyWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView

  import DomovoyWeb.ComposerComponents, only: [composer_path: 3, run_link: 4]

  alias Domovoy.Composer
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.RunView
  alias Phoenix.LiveView.Socket

  @start_events ~w(open_start close_start submit_start confirm_start back_to_inputs
                   choose_input_set start_with_input_set delete_input_set ack_drift
                   clear_reused)
  # What a run whose draft was deleted refuses: anything that starts or changes a run.
  @run_commands ~w(stop_run resume_run pause_run unpause_run open_cancel_run
                   confirm_cancel_run open_reconcile confirm_reconcile decide
                   recover_run) ++ @start_events

  # A result read runs as `{:run_record, key}`, one task per key.
  @run_asyncs [:run_open, :run_start, :run_list, :run_command, :run_input_sets]

  # A read that ended without a result, which Reload result reads again.
  @reloadable [:lag, :unavailable, :read_failed]

  @commands %{
    stop: &Composer.stop_run/2,
    resume: &Composer.resume_run/2,
    pause: &Composer.pause_run/2,
    unpause: &Composer.unpause_run/2,
    cancel: &Composer.cancel_run/2,
    reconcile: &Composer.reconcile_run/3
  }

  @core_refusals %{
    transition_in_progress: "Another change to this run is still in progress.",
    not_applicable: "That doesn't apply to this run right now.",
    already_terminal: "This run has already finished.",
    nothing_to_reconcile: "That step has already been checked.",
    commit_outcome_unknown: "Couldn't confirm that was saved. Check the run before trying again.",
    busy: "Core is busy. Try again in a moment.",
    rerun_limit: "This run can't create another generation. Start a new run instead."
  }

  # Facts after which the run's view is read again.
  @reread ~w(phase_entered outcome_fixed decision_pending decision_accepted
             uncertainty_recorded reconciled operation_completed)

  # The switcher lists this many runs needing attention, and one more says there are more.
  @attention_shown 5
  @recent_shown 10

  @resubscribe_attempts 3
  @resubscribe_ms 250

  @doc """
  Attaches the run hooks and their assigns. With runs off nothing is read.
  """
  @spec attach(socket :: Socket.t()) :: Socket.t()
  def attach(socket) do
    socket
    |> assign(
      run: nil,
      start: nil,
      runs_enabled?: Composer.runs_enabled?(),
      recent_runs: [],
      attention_count: 0,
      latest_run: nil
    )
    |> attach_hook(:runs, :handle_event, &handle_event/3)
    |> attach_hook(:runs, :handle_info, &handle_info/2)
    |> attach_hook(:runs, :handle_async, &handle_async/3)
  end

  @doc """
  Reads `?run=` before a level is entered: `:none` when it doesn't change, `{:enter,
  socket}` on a run of this draft, `{:leave, socket}` when it was removed, and `{:bad,
  socket}` for anything else. With runs off any `?run=` is `:bad`, with no gateway call.
  """
  @spec sync_param(params :: map(), socket :: Socket.t()) ::
          :none | {:enter | :leave | :bad, Socket.t()}
  def sync_param(params, socket) do
    case {params["run"], socket.assigns.run} do
      {nil, nil} -> :none
      {nil, _run} -> {:leave, leave(socket)}
      {id, %{id: id}} -> :none
      {id, _run} -> enter_param(socket, id)
    end
  end

  @doc """
  Opens the New run launcher on the current saved draft, as the `open_start` event does.
  With runs off, or a launcher already open, nothing changes.
  """
  @spec open_launcher(socket :: Socket.t()) :: Socket.t()
  def open_launcher(%{assigns: %{runs_enabled?: true}} = socket),
    do: start_event("open_start", %{}, socket)

  def open_launcher(socket), do: socket

  @doc """
  Shows a run whose draft was deleted, read-only, as `?run=` shows one of a draft's.
  """
  @spec enter_retained(socket :: Socket.t(), row :: Composer.Run.t()) :: Socket.t()
  def enter_retained(socket, row), do: enter(socket, row)

  @doc """
  Leaves the composer for the draft list, saying the draft is gone.
  """
  @spec gone(socket :: Socket.t()) :: Socket.t()
  def gone(socket) do
    socket
    |> put_flash(:error, "That draft doesn't exist anymore.")
    |> push_navigate(to: ~p"/composer")
  end

  @doc """
  Reloads the draft's run switcher from run summaries, off the LiveView process: runs
  that may need attention first, then the newest. It opens no run. Without a draft there
  are none.
  """
  @spec load_runs(socket :: Socket.t()) :: Socket.t()
  def load_runs(%{assigns: %{draft: nil}} = socket), do: socket

  def load_runs(%{assigns: %{runs_enabled?: true}} = socket) do
    if connected?(socket) do
      draft_id = socket.assigns.draft.id

      start_async(socket, :run_list, fn ->
        {Composer.run_page(%{draft_id: draft_id}, nil, @recent_shown),
         Composer.attention_runs(draft_id, @attention_shown + 1)}
      end)
    else
      socket
    end
  end

  def load_runs(socket), do: socket

  @doc """
  The plain words for why a run refused a request. A Core refusal is named by its type
  only, so no reason reaches the page.
  """
  @spec refusal_text(reason :: term()) :: String.t()
  def refusal_text(:run_frozen), do: "This run lost its process. Recover it first."
  def refusal_text(:command_in_flight), do: "Another check is still being sent."
  def refusal_text(:runs_disabled), do: "Runs are turned off on this host."

  def refusal_text(:draft_deleted),
    do: "This workflow's draft was deleted, so this run is read-only."

  def refusal_text({:not_offered, _name}), do: "That isn't available for this run right now."

  def refusal_text({:refused, core_id}),
    do: Map.get(@core_refusals, core_id, "Core refused that for this run.")

  def refusal_text(_unavailable), do: "This run can't be reached right now."

  # Hooks

  @spec handle_event(event :: String.t(), params :: term(), socket :: Socket.t()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, map(), Socket.t()}
  defp handle_event(event, params, %{assigns: %{run: %{}}} = socket),
    do: run_event(event, params, socket)

  defp handle_event(event, params, %{assigns: %{runs_enabled?: true}} = socket)
       when event in @start_events,
       do: {:halt, start_event(event, params, socket)}

  defp handle_event(event, _params, socket) when event in @start_events, do: {:halt, socket}
  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @spec handle_info(message :: term(), socket :: Socket.t()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()}
  defp handle_info({:domovoy_events, subscription, message}, socket) do
    case socket.assigns.run do
      %{sub: ^subscription} -> {:halt, on_message(socket, message)}
      _other_run -> {:halt, socket}
    end
  end

  defp handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case socket.assigns.run do
      %{monitor: ^ref} = run -> {:halt, retry(put_run(socket, %{run | sub: nil, monitor: nil}))}
      _other -> {:halt, socket}
    end
  end

  defp handle_info({:run_resubscribe, id}, socket) do
    case socket.assigns.run do
      %{id: ^id, sub: nil, handle: handle} when not is_nil(handle) -> {:halt, subscribe(socket)}
      _other -> {:halt, socket}
    end
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  @spec handle_async(key :: term(), result :: term(), socket :: Socket.t()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()}
  defp handle_async(:run_open, {:ok, {id, opened, draft_changed?}}, socket) do
    case socket.assigns.run do
      %{id: ^id} = run -> {:halt, opened(socket, run, opened, draft_changed?)}
      _other_run -> {:halt, socket}
    end
  end

  defp handle_async(:run_open, {:exit, _reason}, socket) do
    case socket.assigns.run do
      %{} = run -> {:halt, put_run(socket, %{run | state: :unavailable})}
      nil -> {:halt, socket}
    end
  end

  defp handle_async(:run_start, result, socket), do: {:halt, started(socket, result)}

  # A read no longer wanted is dropped, so older data never shows as current.
  defp handle_async({:run_record, key}, {:ok, read}, socket) do
    case socket.assigns.run do
      %{reads: %{^key => _wanted} = reads} = run ->
        {:halt, put_run(socket, %{run | reads: Map.put(reads, key, read(key, read))})}

      _other ->
        {:halt, socket}
    end
  end

  defp handle_async({:run_record, key}, {:exit, _reason}, socket) do
    case socket.assigns.run do
      %{reads: %{^key => %{state: :loading} = loading} = reads} = run ->
        reads = Map.put(reads, key, %{loading | state: :read_failed})
        {:halt, put_run(socket, %{run | reads: reads})}

      _other ->
        {:halt, socket}
    end
  end

  # Every lifecycle command shares one key, so a later press replaces the task and its
  # result is the one that lands; a result for an op no longer shown is dropped.
  defp handle_async(:run_command, {:ok, {id, result}}, socket) do
    case socket.assigns.run do
      %{op: %{command_id: ^id} = op} = run -> {:halt, commanded(socket, run, op, result)}
      _other -> {:halt, socket}
    end
  end

  defp handle_async(:run_command, {:exit, _reason}, socket) do
    case socket.assigns.run do
      %{op: %{state: :sending} = op} = run ->
        {:halt, put_run(socket, %{run | op: %{op | state: :unconfirmed}})}

      _other ->
        {:halt, socket}
    end
  end

  # Sets for a launcher since closed or reopened are dropped.
  defp handle_async(:run_input_sets, {:ok, {id, sets}}, socket) when is_list(sets) do
    case socket.assigns.start do
      %{run_id: ^id} = start -> {:halt, assign(socket, :start, %{start | sets: sets})}
      _other -> {:halt, socket}
    end
  end

  # Unfinished run links only to a run whose written summary says so, never to one with
  # no summary yet, which the switcher shows as needing a check.
  defp handle_async(:run_list, {:ok, {%{runs: recent}, attention}}, socket)
       when is_list(attention) do
    shown = Enum.take(attention, @attention_shown)
    ids = MapSet.new(shown, & &1.id)

    {:halt,
     assign(socket,
       recent_runs: shown ++ Enum.reject(recent, &MapSet.member?(ids, &1.id)),
       attention_count: length(attention),
       latest_run: Enum.find_value(attention, &(&1.summary && &1.id))
     )}
  end

  defp handle_async(key, _result, socket) when key in @run_asyncs, do: {:halt, socket}
  defp handle_async({:run_record, _key}, _result, socket), do: {:halt, socket}
  defp handle_async(_key, _result, socket), do: {:cont, socket}

  # In a run

  @spec run_event(event :: String.t(), params :: term(), socket :: Socket.t()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, map(), Socket.t()}
  # A run whose draft was deleted is read-only, whatever its controls show.
  defp run_event(event, _params, %{assigns: %{draft: nil}} = socket)
       when event in @run_commands,
       do: {:halt, refused(socket, :draft_deleted)}

  defp run_event("node_moved", _params, socket), do: {:halt, %{status: "rejected"}, socket}
  defp run_event("connect_preview", _params, socket), do: {:halt, %{targets: []}, socket}

  # A hook can't rewrite params, so `focus` and `tools` are never passed on.
  defp run_event("select_node", %{"node" => node}, socket) when is_binary(node) do
    if is_map_key(selectable(socket), node),
      do: {:halt, socket |> assign(selected: node, surface: "details") |> sync_result()},
      else: {:halt, socket}
  end

  defp run_event("deselect_node", _params, socket),
    do: {:halt, socket |> assign(selected: nil, surface: "canvas") |> sync_result()}

  # Only a generation the selected node has run at can be picked. It goes into the URL,
  # so a refresh keeps it.
  defp run_event(
         "select_run_generation",
         %{"generation" => text},
         %{assigns: %{run: run, selected: node}} = socket
       )
       when is_binary(text) and is_binary(node) do
    with {generation, ""} <- Integer.parse(text),
         %{generations: generations} <-
           RunView.node_detail(run.fold, socket.assigns.document, node),
         true <- generation in generations do
      {:halt, push_patch(socket, to: run_page_path(socket, gen: generation))}
    else
      _other -> {:halt, socket}
    end
  end

  # The graph's generation: latest, or one the run has reached.
  defp run_event("set_run_scope", %{"scope" => "latest"}, socket),
    do: {:halt, push_patch(socket, to: run_page_path(socket, scope: nil))}

  defp run_event("set_run_scope", %{"scope" => text}, %{assigns: %{run: run}} = socket) do
    case reached_generation(run, text) do
      nil -> {:halt, socket}
      generation -> {:halt, push_patch(socket, to: run_page_path(socket, scope: generation))}
    end
  end

  # Reading again is only a read: nothing runs, and only a read that ended without a
  # result, of a generation this node has run at, is dropped and read again.
  defp run_event(
         "retry_run_record",
         %{"node" => node, "generation" => text},
         %{assigns: %{run: run}} = socket
       )
       when is_binary(node) and is_binary(text) do
    with {generation, ""} <- Integer.parse(text),
         %{generations: generations} <-
           RunView.node_detail(run.fold, socket.assigns.document, node),
         true <- generation in generations do
      reads =
        Map.reject(run.reads, fn
          {{_id, ^node, ^generation, _seq}, %{state: state}} -> state in @reloadable
          _other -> false
        end)

      {:halt, socket |> put_run(%{run | reads: reads}) |> sync_result()}
    else
      _other -> {:halt, socket}
    end
  end

  # Only a node the Results panel lists can be expanded or collapsed.
  defp run_event("toggle_result", %{"stage" => stage, "node" => node}, socket)
       when is_binary(stage) and is_binary(node) do
    %{run: run, document: document} = socket.assigns

    if Enum.any?(RunView.results(run.fold, document), &(&1.stage == stage and &1.node == node)) do
      ref = {stage, node}

      expanded =
        if MapSet.member?(run.expanded, ref),
          do: MapSet.delete(run.expanded, ref),
          else: MapSet.put(run.expanded, ref)

      {:halt, socket |> put_run(%{run | expanded: expanded}) |> sync_result()}
    else
      {:halt, socket}
    end
  end

  # Results shows while nothing is selected, so opening it lets the selection go. A
  # button sends its `value` too, so the surface is matched, not the whole params.
  defp run_event("set_surface", %{"surface" => "results"}, socket),
    do: run_event("open_results", %{}, socket)

  defp run_event("open_results", _params, socket),
    do:
      {:halt,
       socket |> assign(panel: "results", surface: "results", selected: nil) |> sync_result()}

  defp run_event(
         "decide",
         %{"occurrence" => occurrence, "choice" => choice} = params,
         %{assigns: %{run: %{handle: handle}}} = socket
       )
       when is_binary(occurrence) and is_binary(choice) and not is_nil(handle),
       do: {:halt, decide(socket, occurrence, choice, Map.get(params, "inputs", %{}))}

  defp run_event("dismiss_rejection", _params, socket), do: {:cont, socket}

  # Panels only change what is shown, and their handlers accept allowlisted names only.
  defp run_event(event, _params, socket)
       when event in ~w(open_outline close_panel set_surface toggle_canvas_only),
       do: {:cont, socket}

  defp run_event("open_cancel_run", _params, %{assigns: %{run: run}} = socket) do
    if :cancel in RunView.controls(open_status(run)),
      do: {:halt, put_run(socket, %{run | cancel_open?: true})},
      else: {:halt, socket}
  end

  defp run_event("close_cancel_run", _params, %{assigns: %{run: run}} = socket),
    do: {:halt, put_run(socket, %{run | cancel_open?: false})}

  # Only an uncertainty Core's status still lists can be checked, and only while the run
  # offers that.
  defp run_event("open_reconcile", %{"uncertainty" => id}, %{assigns: %{run: run}} = socket) do
    if reconcilable?(run, id),
      do: {:halt, put_run(socket, %{run | reconcile: id})},
      else: {:halt, refused(socket, {:not_offered, :reconcile})}
  end

  defp run_event("close_reconcile", _params, %{assigns: %{run: run}} = socket),
    do: {:halt, put_run(socket, %{run | reconcile: nil})}

  defp run_event(
         "confirm_reconcile",
         %{"uncertainty" => id},
         %{assigns: %{run: %{handle: handle} = run}} = socket
       )
       when not is_nil(handle) do
    if reconcilable?(run, id),
      do: {:halt, lifecycle(socket, :reconcile, [id])},
      else:
        {:halt, socket |> put_run(%{run | reconcile: nil}) |> refused({:not_offered, :reconcile})}
  end

  # A lifecycle command the run's controls don't offer is refused here, before any Core
  # call. One they do offer from a stale status still reaches Core, which re-reads the
  # run and gives its typed refusal.
  defp run_event(event, _params, %{assigns: %{run: %{handle: handle}}} = socket)
       when event in ~w(stop_run resume_run pause_run unpause_run confirm_cancel_run) and
              not is_nil(handle) do
    name =
      case event do
        "stop_run" -> :stop
        "resume_run" -> :resume
        "pause_run" -> :pause
        "unpause_run" -> :unpause
        "confirm_cancel_run" -> :cancel
      end

    {:halt, lifecycle(socket, name)}
  end

  defp run_event("recover_run", _params, %{assigns: %{run: %{handle: handle} = run}} = socket)
       when not is_nil(handle) do
    if RunView.frozen?(run.status) do
      case Composer.activate_run(handle) do
        :ok -> {:halt, reread(socket)}
        {:error, reason} -> {:halt, socket |> refused(reason) |> reread()}
      end
    else
      {:halt, socket}
    end
  end

  # New run starts a separate run from the current saved draft; this one is left as it is.
  defp run_event(event, params, %{assigns: %{runs_enabled?: true}} = socket)
       when event in @start_events,
       do: {:halt, start_event(event, params, socket)}

  defp run_event(_event, _params, socket), do: {:halt, socket}

  # Every run-page patch keeps the page's stage, run, node, `gen` and `scope`, but for
  # what `query` sets, so no patch drops another param.
  @spec run_page_path(socket :: Socket.t(), query :: keyword()) :: String.t()
  defp run_page_path(%{assigns: %{draft: draft, stage: stage, selected: node, run: run}}, query) do
    draft_id = draft && draft.id

    generation =
      case run.generation do
        {^node, generation} -> generation
        _other -> nil
      end

    current = [node: node, gen: generation, scope: if(is_integer(run.scope), do: run.scope)]
    run_link(draft_id, stage, run.id, Keyword.merge(current, query))
  end

  # A graph scope needs a run past generation 0, which is when it offers the control.
  @spec scoped(run :: map(), text :: term()) :: integer() | :latest
  defp scoped(run, text) do
    case open_status(run) do
      %{generation: reached} when is_integer(reached) and reached > 0 ->
        reached_generation(run, text) || :latest

      _first_generation ->
        :latest
    end
  end

  # A generation from the page, as an integer the open run has reached, else nil.
  @spec reached_generation(run :: map(), text :: term()) :: integer() | nil
  defp reached_generation(run, text) when is_binary(text) do
    with {generation, ""} <- Integer.parse(text),
         %{generation: reached} when is_integer(reached) <- open_status(run),
         true <- generation in 0..reached//1 do
      generation
    else
      _other -> nil
    end
  end

  defp reached_generation(_run, _text), do: nil

  @spec selectable(socket :: Socket.t()) :: map()
  defp selectable(%{assigns: %{document: document, stage: nil}}), do: document["vertices"]

  defp selectable(%{assigns: %{document: document, stage: stage}}),
    do: Composer.nodes(document, stage)

  # What `RunView.controls/1` decides from: the status of an open run only.
  @spec open_status(run :: map()) :: map() | nil
  defp open_status(run), do: if(run.state == :open, do: run.status)

  @spec reconcilable?(run :: map(), id :: term()) :: boolean()
  defp reconcilable?(run, id) do
    status = open_status(run)

    is_binary(id) and :reconcile in RunView.controls(status) and
      id in Map.get(status, :uncertainties, [])
  end

  # `args` follow the handle and the command id: the uncertainty, for a reconcile.
  @spec lifecycle(
          socket :: Socket.t(),
          name :: :stop | :resume | :pause | :unpause | :cancel | :reconcile,
          args :: [String.t()]
        ) :: Socket.t()
  defp lifecycle(%{assigns: %{run: run}} = socket, name, args \\ []) do
    status = open_status(run)

    cond do
      match?(%{command: ^name, state: state} when state in [:sending, :accepted], run.op) and
          Map.get(run.op, :args, []) == args ->
        socket

      # One check at a time: another uncertainty waits for the one being sent.
      match?(%{command: ^name, state: state} when state in [:sending, :accepted], run.op) ->
        socket
        |> put_run(%{run | reconcile: nil})
        |> refused(:command_in_flight)

      name not in RunView.controls(status) ->
        socket
        |> put_run(%{run | cancel_open?: false, reconcile: nil})
        |> refused(if(RunView.frozen?(status), do: :run_frozen, else: {:not_offered, name}))

      true ->
        # The same intent keeps its id, so a retry after an unconfirmed send converges.
        id =
          if match?(%{command: ^name}, run.op) and Map.get(run.op, :args, []) == args,
            do: run.op.command_id,
            else: Ecto.UUID.generate()

        op = %{command: name, command_id: id, operation_id: nil, state: :sending, args: args}
        call = Map.fetch!(@commands, name)
        handle = run.handle

        socket
        |> put_run(%{run | op: op, cancel_open?: false, reconcile: nil})
        |> start_async(:run_command, fn -> {id, apply(call, [handle, id | args])} end)
    end
  end

  @spec commanded(socket :: Socket.t(), run :: map(), op :: map(), result :: term()) ::
          Socket.t()
  defp commanded(socket, run, op, {:ok, %{operation_id: operation_id}}) do
    socket
    |> put_run(%{run | op: %{op | state: :accepted, operation_id: operation_id}})
    |> reread()
  end

  defp commanded(socket, run, _op, {:error, reason}),
    do: socket |> put_run(%{run | op: nil}) |> refused(reason) |> reread()

  # Entering and leaving

  @spec enter_param(socket :: Socket.t(), id :: term()) :: {:enter | :bad, Socket.t()}
  defp enter_param(%{assigns: %{runs_enabled?: false}} = socket, _id), do: {:bad, socket}

  defp enter_param(socket, id) do
    case Composer.get_run(socket.assigns.draft.id, id) do
      {:ok, row} -> {:enter, socket |> leave() |> enter(row)}
      {:error, _not_found} -> {:bad, socket}
    end
  end

  @spec enter(socket :: Socket.t(), row :: Composer.Run.t()) :: Socket.t()
  defp enter(socket, row) do
    run = %{
      id: row.id,
      state: :opening,
      handle: nil,
      sub: nil,
      monitor: nil,
      cursor: nil,
      retries: 0,
      status: nil,
      fold: RunView.new(row.document),
      draft_changed?: false,
      definition_changed?: false,
      cancel_open?: false,
      reconcile: nil,
      stale?: false,
      fold_stale?: false,
      op: nil,
      reads: %{},
      expanded: MapSet.new(),
      generation: nil,
      scope: :latest,
      wanted: %{gen: nil, scope: nil},
      decision: nil
    }

    socket =
      assign(socket,
        run: run,
        document: row.document,
        start: kept_start(socket.assigns.start),
        selected: nil,
        conflict: false,
        rejection: nil
      )

    if connected?(socket),
      do: start_async(socket, :run_open, fn -> open(row) end),
      else: socket
  end

  # A submitted start keeps its launcher, so its answer still lands.
  @spec kept_start(start :: map() | nil) :: map() | nil
  defp kept_start(%{pending?: true} = start), do: start
  defp kept_start(_start), do: nil

  # A run whose draft was deleted has no draft to have changed.
  @spec open(row :: Composer.Run.t()) ::
          {String.t(), {:ok, map()} | {:error, atom()}, boolean()}
  defp open(row) do
    opened =
      with {:ok, %{handle: handle, definition_changed?: changed?}} <- Composer.open_run(row),
           {:ok, status} <- Composer.run_view(handle) do
        {:ok, %{handle: handle, status: status, definition_changed?: changed?}}
      end

    draft_changed? =
      with id when is_binary(id) <- row.draft_id,
           {:ok, draft} <- Composer.get_draft(id) do
        Composer.run_draft_changed?(row, draft) == true
      else
        _no_draft -> false
      end

    {row.id, opened, draft_changed?}
  end

  @spec opened(
          socket :: Socket.t(),
          run :: map(),
          opened :: {:ok, map()} | {:error, atom()},
          draft_changed? :: boolean()
        ) :: Socket.t()
  defp opened(socket, run, {:ok, opened}, draft_changed?) do
    run = %{
      run
      | state: :open,
        handle: opened.handle,
        status: opened.status,
        definition_changed?: opened.definition_changed?,
        draft_changed?: draft_changed?
    }

    _summarized = Composer.summarize_run(run.id, opened.status)
    socket |> put_run(run) |> apply_wanted() |> subscribe() |> sync_result()
  end

  defp opened(socket, run, {:error, reason}, draft_changed?)
       when reason in [:never_started, :runner_unavailable, :definition_mismatch] do
    put_run(socket, %{run | state: reason, draft_changed?: draft_changed?})
  end

  defp opened(socket, run, {:error, _unavailable}, draft_changed?),
    do: put_run(socket, %{run | state: :unavailable, draft_changed?: draft_changed?})

  @spec leave(socket :: Socket.t()) :: Socket.t()
  defp leave(%{assigns: %{run: nil}} = socket), do: socket

  defp leave(%{assigns: %{run: run}} = socket) do
    if run.monitor, do: Process.demonitor(run.monitor, [:flush])
    if run.sub, do: Composer.unsubscribe_run(run.sub)

    assign(socket,
      run: nil,
      selected: nil,
      rejection: nil,
      start: kept_start(socket.assigns.start)
    )
  end

  # Live status

  # An accepted op ends with the `operation_completed` fact of its operation.
  @spec completed?(op :: map() | nil, facts :: [map()]) :: boolean()
  defp completed?(%{operation_id: id}, facts) when is_binary(id),
    do: Enum.any?(facts, &(&1["type"] == "operation_completed" and &1["operation_id"] == id))

  defp completed?(_op, _facts), do: false

  # A subscription can end without saying so, so its process is watched.
  @spec subscribe(socket :: Socket.t()) :: Socket.t()
  defp subscribe(%{assigns: %{run: run}} = socket) do
    case Composer.subscribe_run(run.handle, run.cursor) do
      {:ok, subscription} ->
        monitor = Process.monitor(subscription.pid)
        put_run(socket, %{run | sub: subscription, monitor: monitor})

      {:error, _unavailable} ->
        retry(socket)
    end
  end

  @spec retry(socket :: Socket.t()) :: Socket.t()
  defp retry(%{assigns: %{run: %{retries: retries} = run}} = socket)
       when retries < @resubscribe_attempts do
    Process.send_after(self(), {:run_resubscribe, run.id}, @resubscribe_ms * (retries + 1))
    put_run(socket, %{run | retries: retries + 1})
  end

  defp retry(%{assigns: %{run: run}} = socket), do: put_run(socket, %{run | stale?: true})

  @spec on_message(socket :: Socket.t(), message :: term()) :: Socket.t()
  defp on_message(%{assigns: %{run: run}} = socket, {:event, envelope, cursor}) do
    event = Composer.encode_run_event(envelope)
    _acked = Composer.ack_run_event(run.sub, cursor)
    facts = List.wrap(event["facts"])

    run = %{
      run
      | fold: RunView.apply_event(run.fold, event),
        cursor: cursor,
        retries: 0,
        op: if(completed?(run.op, facts), do: nil, else: run.op)
    }

    socket = put_run(socket, run)

    socket =
      if Enum.any?(facts, &(&1["type"] in @reread)),
        do: reread(socket),
        else: socket

    sync_result(socket)
  end

  defp on_message(%{assigns: %{run: run}} = socket, {:watermark, cursor}) do
    _acked = Composer.ack_run_event(run.sub, cursor)
    put_run(socket, %{run | cursor: cursor})
  end

  defp on_message(%{assigns: %{run: run}} = socket, {:closed, %{type: :run_deleted}}),
    do: put_run(socket, %{closed(run) | stale?: true})

  # The history between the fold and the resync can't be read, so the fold is marked
  # stale rather than replayed. The new status may await a decision, so its evidence is
  # read again.
  defp on_message(%{assigns: %{run: run}} = socket, {:closed, %{type: :resync_required}}) do
    run = closed(run)

    case Composer.resync_run(run.handle) do
      {:ok, %{view: status, cursor: cursor}} ->
        socket
        |> put_run(%{run | status: status, cursor: cursor, fold_stale?: true})
        |> subscribe()
        |> sync_result()

      {:error, _unavailable} ->
        put_run(socket, %{run | stale?: true})
    end
  end

  defp on_message(%{assigns: %{run: run}} = socket, {:closed, _error}),
    do: socket |> put_run(closed(run)) |> retry()

  defp on_message(socket, _message), do: socket

  @spec closed(run :: map()) :: map()
  defp closed(run) do
    if run.monitor, do: Process.demonitor(run.monitor, [:flush])
    %{run | sub: nil, monitor: nil}
  end

  # An accepted op whose command is no longer pending has completed, even when its
  # `operation_completed` arrived before its operation id was known.
  @spec reread(socket :: Socket.t()) :: Socket.t()
  defp reread(%{assigns: %{run: %{handle: handle} = run}} = socket) when not is_nil(handle) do
    case Composer.run_view(handle) do
      {:ok, status} ->
        _summarized = Composer.summarize_run(run.id, status)
        put_run(socket, %{run | status: status, op: still_pending(run.op, status)})

      {:error, _unavailable} ->
        put_run(socket, %{run | stale?: true})
    end
  end

  defp reread(socket), do: socket

  @spec still_pending(op :: map() | nil, status :: map()) :: map() | nil
  defp still_pending(%{state: :accepted, command_id: id}, %{pending_operation: pending})
       when pending != id,
       do: nil

  defp still_pending(op, _status), do: op

  # Results

  @doc """
  Reads `gen` and `scope` from the URL: `gen` is the selected node's generation in the
  inspector, and `scope` the generation the graph shows, else its latest. An open run
  shows them at once; one still opening shows them once it opens. A value that isn't a
  generation the run has reached is ignored.
  """
  @spec generation_params(socket :: Socket.t(), params :: map()) :: Socket.t()
  def generation_params(%{assigns: %{run: %{} = run}} = socket, params) do
    wanted = %{gen: params["gen"], scope: params["scope"]}
    socket |> put_run(%{run | wanted: wanted}) |> apply_wanted()
  end

  def generation_params(socket, _params), do: socket

  @spec apply_wanted(socket :: Socket.t()) :: Socket.t()
  defp apply_wanted(%{assigns: %{run: %{state: :open, wanted: wanted} = run}} = socket) do
    node = socket.assigns.selected

    generation =
      case reached_generation(run, wanted.gen) do
        generation when is_integer(generation) and is_binary(node) -> {node, generation}
        _latest -> nil
      end

    put_run(socket, %{
      run
      | generation: generation,
        scope: scoped(run, wanted.scope)
    })
  end

  defp apply_wanted(socket), do: socket

  @doc """
  Reads the results the page now shows, as after any run event; a patch that selects a
  node calls this. Outside a run nothing changes.
  """
  @spec sync_reads(socket :: Socket.t()) :: Socket.t()
  def sync_reads(socket), do: sync_result(socket)

  # The one place that decides which results are read: the selected node's, the pending
  # decision's evidence and each expanded Results row. A node that never ran, or whose
  # attempt hasn't settled, makes no Core call, and a read no longer shown is dropped.
  @spec sync_result(socket :: Socket.t()) :: Socket.t()
  defp sync_result(%{assigns: %{run: %{} = run}} = socket) do
    wanted = wanted(socket.assigns, run)
    kept = Map.filter(run.reads, fn {key, _read} -> is_map_key(wanted, key) end)

    {reads, missing} =
      Enum.reduce(wanted, {kept, []}, fn
        {key, :fetch}, {reads, missing} when is_map_key(reads, key) ->
          {reads, missing}

        {key, :fetch}, {reads, missing} ->
          {Map.put(reads, key, %{key: key, state: :loading}), [key | missing]}

        {key, state}, {reads, missing} ->
          {Map.put(reads, key, %{key: key, state: state}), missing}
      end)

    socket = put_run(socket, %{run | reads: reads})
    Enum.reduce(missing, socket, &fetch(&2, run.handle, &1))
  end

  defp sync_result(socket), do: socket

  @spec wanted(assigns :: map(), run :: map()) :: %{tuple() => atom()}
  defp wanted(assigns, %{state: :open} = run) do
    [selected_key(assigns, run) | evidence_keys(assigns, run) ++ row_keys(assigns, run)]
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp wanted(_assigns, _run), do: %{}

  @spec selected_key(assigns :: map(), run :: map()) :: {tuple(), atom()} | nil
  defp selected_key(%{stage: stage, selected: node, document: document}, run)
       when is_binary(stage) and is_binary(node) do
    with %{} = detail <- RunView.node_detail(run.fold, document, node) do
      read_key(run, detail, RunView.shown_generation(detail, run.generation))
    end
  end

  defp selected_key(_assigns, _run), do: nil

  # A decision is a workflow card, so its evidence is read by each ref's own node, at the
  # generation its result is shown at.
  @spec evidence_keys(assigns :: map(), run :: map()) :: [{tuple(), atom()}]
  defp evidence_keys(%{stage: nil, selected: decision, document: document}, run)
       when is_binary(decision) do
    for %{node: node, shown: {_same_or_from, generation}} <-
          RunView.evidence(run.fold, document, run.status, decision),
        %{} = detail <- [RunView.node_detail(run.fold, document, node)] do
      read_key(run, detail, generation)
    end
  end

  defp evidence_keys(_assigns, _run), do: []

  @spec row_keys(assigns :: map(), run :: map()) :: [{tuple(), atom()}]
  defp row_keys(%{document: document}, run) do
    for row <- RunView.results(run.fold, document),
        MapSet.member?(run.expanded, {row.stage, row.node}),
        %{} = detail <- [RunView.node_detail(run.fold, document, row.node)] do
      read_key(run, detail, row.generation)
    end
  end

  # A result is keyed by run, node, generation and the seq its attempt settled at, so a
  # later attempt is a new read.
  @spec read_key(run :: map(), detail :: map(), generation :: integer() | nil) ::
          {tuple(), atom()}
  defp read_key(run, detail, generation) do
    attempt = generation && List.last(detail.attempts[generation])
    key = {run.id, detail.name, generation, attempt && attempt.settled_seq}

    cond do
      is_nil(attempt) -> {key, :not_run}
      is_integer(attempt.settled_seq) -> {key, :fetch}
      run.status[:owner_live?] == true -> {key, :running}
      true -> {key, :interrupted}
    end
  end

  @spec fetch(socket :: Socket.t(), handle :: term(), key :: tuple()) :: Socket.t()
  defp fetch(socket, handle, {_id, node, generation, seq} = key) do
    start_async(socket, {:run_record, key}, fn ->
      Composer.run_record(handle, node, generation, seq)
    end)
  end

  @spec read(key :: tuple(), read :: term()) :: map()
  defp read(key, %{status: _status} = rendered), do: %{key: key, state: :stored, record: rendered}
  defp read(key, :miss), do: %{key: key, state: :miss}
  defp read(key, :lag), do: %{key: key, state: :lag}
  defp read(key, _unavailable), do: %{key: key, state: :unavailable}

  # Decisions

  # The occurrence must be one this run asked, as folded or as Core awaits it after a
  # resync, the choice one of its decision's in the snapshot, and every input one that
  # choice declares. Core then decides whether the answer still fits, so a stale tab
  # gets its typed refusal.
  @spec decide(
          socket :: Socket.t(),
          occurrence :: String.t(),
          choice :: String.t(),
          raw :: term()
        ) :: Socket.t()
  defp decide(%{assigns: %{run: run, document: document}} = socket, occurrence, choice, raw) do
    with true <- is_map(raw),
         decision when is_binary(decision) <-
           run.fold.occurrences[occurrence] || awaited(run.status, occurrence),
         %{} = offered <- offered_choice(document, decision, choice),
         [] <- Map.keys(raw) -- Map.keys(offered["inputs"]) do
      answer(socket, occurrence, offered, raw)
    else
      _forged ->
        socket
        |> reject(:decision_refused, nil, "That answer doesn't fit a decision of this run.")
        |> reread()
    end
  end

  @spec answer(socket :: Socket.t(), occurrence :: String.t(), offered :: map(), raw :: map()) ::
          Socket.t()
  defp answer(%{assigns: %{run: run}} = socket, occurrence, offered, raw) do
    case RunInputs.parse_choice(offered, raw) do
      {:ok, values} ->
        socket = put_run(socket, %{run | decision: nil})

        case Composer.decide_run(run.handle, occurrence, offered["name"], values) do
          :ok -> reread(socket)
          {:error, reason} -> socket |> refused(reason) |> reread()
        end

      {:error, errors} ->
        decision = %{
          choice: offered["name"],
          params: safe_params(RunInputs.choice_fields(offered), raw),
          errors: Map.new(errors, &{&1.name, &1.code})
        }

        put_run(socket, %{run | decision: decision})
    end
  end

  @spec awaited(status :: map() | nil, occurrence :: String.t()) :: String.t() | nil
  defp awaited(%{awaiting: awaiting}, occurrence) when is_list(awaiting) do
    Enum.find_value(awaiting, fn
      %{occurrence: ^occurrence, decision: decision} when is_binary(decision) -> decision
      _other -> nil
    end)
  end

  defp awaited(_status, _occurrence), do: nil

  @spec offered_choice(document :: map(), decision :: String.t(), choice :: String.t()) ::
          map() | nil
  defp offered_choice(document, decision, choice) do
    case get_in(document, ["vertices", decision]) do
      %{"kind" => "decision", "choices" => choices} -> Enum.find(choices, &(&1["name"] == choice))
      _other -> nil
    end
  end

  @spec put_run(socket :: Socket.t(), run :: map()) :: Socket.t()
  defp put_run(socket, run), do: assign(socket, :run, run)

  @spec refused(socket :: Socket.t(), reason :: term()) :: Socket.t()
  defp refused(socket, reason) do
    {code, core_id} =
      case reason do
        {:refused, core_id} ->
          {:run_refused, core_id}

        {:not_offered, _name} ->
          {:run_not_offered, nil}

        code when code in [:run_frozen, :runs_disabled, :draft_deleted, :command_in_flight] ->
          {code, nil}

        _unavailable ->
          {:run_unavailable, nil}
      end

    reject(socket, code, core_id, refusal_text(reason))
  end

  @spec reject(
          socket :: Socket.t(),
          code :: atom(),
          core_id :: atom() | nil,
          message :: String.t()
        ) :: Socket.t()
  defp reject(socket, code, core_id, message) do
    issue = %Issue{code: code, target: :workflow, core_id: core_id, message: message}
    assign(socket, :rejection, %{issue: issue, connect: nil})
  end

  # Starting

  # The launcher reads the saved draft afresh, never the page's document, which on a run
  # page is that run's snapshot. Opening it leaves the run on screen subscribed.
  @spec start_event(event :: String.t(), params :: term(), socket :: Socket.t()) :: Socket.t()
  defp start_event("open_start", _params, %{assigns: %{start: nil}} = socket) do
    case Composer.get_draft(socket.assigns.draft.id) do
      {:ok, draft} ->
        start =
          %{
            run_id: Ecto.UUID.generate(),
            command_id: Ecto.UUID.generate(),
            params: %{},
            form: start_form(%{}),
            errors: %{},
            values: nil,
            effects: nil,
            source_run_id: socket.assigns.run && socket.assigns.run.id,
            notice: nil,
            issues: nil,
            pending?: false,
            sets: [],
            input_set_id: nil,
            reused: %{},
            drift: [],
            drift_acked?: false,
            blank: [],
            set_notice: nil
          }
          |> sourced(draft)

        socket
        |> assign(start: start, panel: "launcher", surface: "launcher")
        |> load_input_sets(start)

      {:error, :not_found} ->
        gone(socket)
    end
  end

  # A launcher hidden behind another panel is shown again, as it was.
  defp start_event("open_start", _params, socket),
    do: assign(socket, panel: "launcher", surface: "launcher")

  defp start_event("close_start", _params, %{assigns: %{start: %{pending?: false}}} = socket),
    do: assign(socket, start: nil, panel: nil, surface: "canvas")

  # Save keeps the text this same submit carries, since the form sends nothing before it.
  defp start_event(
         "submit_start",
         %{"intent" => "save"} = params,
         %{assigns: %{start: %{pending?: false} = start}} = socket
       ) do
    raw = if is_map(params["start"]), do: params["start"], else: %{}
    kept = safe_params(start.fields, raw)
    start = %{start | params: kept, form: start_form(kept)}
    draft_id = socket.assigns.draft.id

    case Composer.save_input_set(draft_id, params["set_name"], start.fields, raw, opt_ins(params)) do
      {:ok, set} ->
        sets = Enum.sort_by([set | start.sets], & &1.name)
        assign(socket, :start, %{start | sets: sets, set_notice: {:saved, set.name}})

      {:error, reason} ->
        assign(socket, :start, %{start | set_notice: {:not_saved, reason}})
    end
  end

  defp start_event(
         "submit_start",
         params,
         %{assigns: %{start: %{pending?: false} = start}} = socket
       ) do
    if start.drift != [] and not start.drift_acked?,
      do: socket,
      else: submit(socket, start, if(is_map(params["start"]), do: params["start"], else: %{}))
  end

  # The values stay as stored, so a confirm after Back starts what was confirmed only
  # after another submit.
  defp start_event("back_to_inputs", _params, %{assigns: %{start: start}} = socket)
       when is_list(start.effects) and not start.pending?,
       do: assign(socket, :start, %{start | effects: nil, values: nil})

  defp start_event("choose_input_set", %{"id" => id}, %{assigns: %{start: start}} = socket)
       when is_map(start) and not start.pending?,
       do: choose(socket, start, id)

  # Choose, then start as a submit of the set's text would; a set that drifted waits
  # for the person to acknowledge it.
  defp start_event("start_with_input_set", %{"id" => id}, %{assigns: %{start: start}} = socket)
       when is_map(start) and not start.pending? do
    socket = choose(socket, start, id)

    case socket.assigns.start do
      %{input_set_id: set_id, drift: []} = chosen when is_binary(set_id) ->
        submit(socket, chosen, chosen.params)

      _drifted_or_refused ->
        socket
    end
  end

  defp start_event("delete_input_set", %{"id" => id}, %{assigns: %{start: start}} = socket)
       when is_map(start) and not start.pending? do
    case Composer.delete_input_set(socket.assigns.draft.id, id) do
      :ok ->
        start = %{start | sets: Enum.reject(start.sets, &(&1.id == id))}
        start = if start.input_set_id == id, do: unchosen(start), else: start
        assign(socket, :start, start)

      {:error, _not_found} ->
        socket |> missing_set() |> load_input_sets(start)
    end
  end

  defp start_event(
         "ack_drift",
         _params,
         %{assigns: %{start: %{drift: [_ | _]} = start}} = socket
       ),
       do: assign(socket, :start, %{start | drift_acked?: true})

  defp start_event("clear_reused", %{"name" => name}, %{assigns: %{start: start}} = socket)
       when is_map(start) and is_binary(name),
       do: assign(socket, :start, %{start | reused: Map.delete(start.reused, name)})

  # Acts only on the values the submit stored, never on anything this event carries.
  defp start_event("confirm_start", _params, %{assigns: %{start: start}} = socket)
       when is_map(start.values) and not start.pending? and is_list(start.effects),
       do: launch(socket, start)

  defp start_event(_event, _params, socket), do: socket

  @spec submit(socket :: Socket.t(), start :: map(), raw :: map()) :: Socket.t()
  defp submit(socket, start, raw) do
    kept = safe_params(start.fields, raw)

    start = %{
      start
      | params: kept,
        form: start_form(kept),
        values: nil,
        effects: nil,
        notice: nil,
        issues: nil,
        set_notice: nil
    }

    # The document the launcher showed is the one parsed, confirmed and started, at the
    # version it was read at. A reused value joins only the term parsed, so it never
    # reaches the form; text typed into its field wins.
    case RunInputs.parse(start.document, Map.merge(start.reused, typed(raw))) do
      {:ok, values} ->
        start = %{start | errors: %{}, values: values}

        case RunInputs.effects(start.document) do
          [] -> launch(socket, start)
          effects -> assign(socket, :start, %{start | effects: effects})
        end

      {:error, errors} ->
        assign(socket, :start, %{start | errors: Map.new(errors, &{&1.name, &1.code})})
    end
  end

  @spec typed(raw :: map()) :: map()
  defp typed(raw),
    do: Map.reject(raw, fn {_name, text} -> is_binary(text) and String.trim(text) == "" end)

  @spec opt_ins(params :: map()) :: [String.t()]
  defp opt_ins(%{"opt_in" => opt_in}) when is_map(opt_in),
    do: for({name, "true"} <- opt_in, is_binary(name), do: name)

  defp opt_ins(_params), do: []

  # A set of this draft fills the form with its eligible text; its opt-in text is held
  # here only. Anything else is refused, the same as a set deleted since.
  @spec choose(socket :: Socket.t(), start :: map(), id :: term()) :: Socket.t()
  defp choose(socket, start, id) do
    with {:ok, set} <- Composer.fetch_input_set(socket.assigns.draft.id, id),
         %{} = loaded <- Composer.load_input_set(set, start.fields) do
      start = %{
        start
        | params: loaded.params,
          form: start_form(loaded.params),
          errors: %{},
          values: nil,
          effects: nil,
          input_set_id: set.id,
          reused: loaded.reused,
          drift: loaded.drift,
          drift_acked?: false,
          blank: loaded.blank,
          set_notice: nil
      }

      assign(socket, :start, start)
    else
      _missing ->
        socket |> assign(:start, unchosen(start)) |> missing_set() |> load_input_sets(start)
    end
  end

  @spec unchosen(start :: map()) :: map()
  defp unchosen(start),
    do: %{start | input_set_id: nil, reused: %{}, drift: [], drift_acked?: false, blank: []}

  @spec missing_set(socket :: Socket.t()) :: Socket.t()
  defp missing_set(socket),
    do: reject(socket, :input_set_missing, nil, "That input set doesn't exist anymore.")

  # Off the LiveView process, keyed by the launcher's run id so a late list is dropped.
  @spec load_input_sets(socket :: Socket.t(), start :: map()) :: Socket.t()
  defp load_input_sets(socket, %{run_id: id}) do
    if connected?(socket) do
      draft_id = socket.assigns.draft.id
      start_async(socket, :run_input_sets, fn -> {id, Composer.list_input_sets(draft_id)} end)
    else
      socket
    end
  end

  # The draft as the launcher shows it: its document, the version it was read at, and the
  # fields it asks for.
  @spec sourced(start :: map(), draft :: Composer.Draft.t()) :: map()
  defp sourced(start, draft) do
    Map.merge(start, %{
      document: draft.document,
      lock_version: draft.lock_version,
      fields: RunInputs.fields(draft.document)
    })
  end

  # The same ids for the form's whole life, so a retry converges on one run. The draft
  # version is the one the launcher read, so a draft changed since then is a conflict.
  @spec launch(socket :: Socket.t(), start :: map()) :: Socket.t()
  defp launch(socket, start) do
    attrs = %{
      draft_id: socket.assigns.draft.id,
      lock_version: start.lock_version,
      run_id: start.run_id,
      command_id: start.command_id,
      values: start.values,
      source_run_id: start.source_run_id,
      input_set_id: start.input_set_id
    }

    socket
    |> assign(:start, %{start | pending?: true})
    |> start_async(:run_start, fn -> Composer.start_run(attrs) end)
  end

  @spec started(socket :: Socket.t(), result :: term()) :: Socket.t()
  defp started(%{assigns: %{start: %{} = start}} = socket, {:ok, result}) do
    start = %{start | pending?: false}

    case result do
      {status, id} when status in [:ok, :opened_uncertain] ->
        stage = kept_stage(start.document, socket.assigns.stage)

        socket
        |> assign(start: nil, panel: nil, surface: "canvas")
        |> push_patch(to: composer_path(socket.assigns.draft.id, stage, id))

      {:error, {:input_error, name}} ->
        assign(socket, :start, %{
          start
          | errors: %{name => :input_error},
            values: nil,
            effects: nil
        })

      # The draft moved on, so the launcher shows it as it is now, keeping what was typed
      # and its ids, and is submitted again against it.
      {:error, :conflict} ->
        conflicted(socket, start)

      {:error, :gone} ->
        gone(socket)

      # The launcher stays open with what was typed, and Fix in editor leads to the issues.
      {:error, {:invalid, issues}} ->
        assign(socket,
          start: %{start | values: nil, effects: nil, issues: length(issues)},
          core_issues: issues
        )

      {:error, reason} ->
        socket |> assign(:start, start) |> refused(reason)
    end
  end

  # The task died: the ids stay, so a retry reaches whatever it may have started.
  defp started(%{assigns: %{start: %{} = start}} = socket, {:exit, _reason}) do
    socket
    |> assign(:start, %{start | pending?: false})
    |> reject(:run_not_started, nil, "Starting the run didn't finish. Try again.")
  end

  defp started(socket, _result), do: socket

  @spec conflicted(socket :: Socket.t(), start :: map()) :: Socket.t()
  defp conflicted(socket, start) do
    case Composer.get_draft(socket.assigns.draft.id) do
      {:ok, draft} ->
        start =
          %{start | values: nil, effects: nil, notice: :draft_changed}
          |> sourced(draft)
          |> rechecked(socket.assigns.draft.id)

        # On the draft the stale-tab banner says so too, since its edits would conflict.
        socket = assign(socket, :start, start)
        if socket.assigns.run, do: socket, else: assign(socket, :conflict, true)

      {:error, :not_found} ->
        gone(socket)
    end
  end

  # A chosen set is read again against the re-sourced fields, so a field another tab
  # removed or retyped drifts and blocks Start until acknowledged. Typed text stays, but
  # a field that drifts since loses it, as on a fresh choice; a cleared reuse stays clear.
  @spec rechecked(start :: map(), draft_id :: Ecto.UUID.t()) :: map()
  defp rechecked(%{input_set_id: id} = start, draft_id) when is_binary(id) do
    with {:ok, set} <- Composer.fetch_input_set(draft_id, id),
         %{} = loaded <- Composer.load_input_set(set, start.fields) do
      drifted = Enum.map(loaded.drift, & &1.name)
      params = Map.drop(start.params, drifted)

      %{
        start
        | params: params,
          form: start_form(params),
          reused: Map.take(loaded.reused, Map.keys(start.reused)),
          drift: loaded.drift,
          drift_acked?: start.drift_acked? and loaded.drift == start.drift,
          blank: loaded.blank
      }
    else
      _missing -> unchosen(start)
    end
  end

  defp rechecked(start, _draft_id), do: start

  # The stage on screen, while the started document still has it.
  @spec kept_stage(document :: map(), stage :: String.t() | nil) :: String.t() | nil
  defp kept_stage(document, stage) when is_binary(stage) do
    if match?(%{"kind" => "stage"}, document["vertices"][stage]), do: stage
  end

  defp kept_stage(_document, _stage), do: nil

  # Only safe text goes back into a form, since a form renders what it holds.
  @spec safe_params(fields :: [map()], raw :: map()) :: map()
  defp safe_params(fields, raw) do
    for %{name: name} <- fields,
        value = raw[name],
        is_binary(value) and Composer.text_safe?(value),
        into: %{} do
      {name, value}
    end
  end

  @spec start_form(params :: map()) :: Phoenix.HTML.Form.t()
  defp start_form(params), do: to_form(params, as: :start, id: "start")
end
