defmodule DomovoyWeb.ComposerLive.RunEvents do
  @moduledoc """
  The run side of `DomovoyWeb.ComposerLive`: starting a run, and showing one at
  `?run=<id>`, read-only, with live status, a selected node's result, answers to a
  person's decision, Cancel and Recover.

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

  import DomovoyWeb.ComposerComponents, only: [composer_path: 3]

  alias Domovoy.Composer
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.RunView
  alias Phoenix.LiveView.Socket

  @start_events ~w(open_start close_start submit_start confirm_start)
  @run_asyncs [:run_open, :run_start, :run_list, :run_record]

  # Facts after which the run's view is read again.
  @reread ~w(phase_entered outcome_fixed decision_pending decision_accepted
             uncertainty_recorded reconciled operation_completed)

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
  Leaves the composer for the draft list, saying the draft is gone.
  """
  @spec gone(socket :: Socket.t()) :: Socket.t()
  def gone(socket) do
    socket
    |> put_flash(:error, "That draft doesn't exist anymore.")
    |> push_navigate(to: ~p"/composer")
  end

  @doc """
  Reloads the draft's recent runs and its newest unfinished one, off the LiveView
  process, since each lookup can replay a run's history.
  """
  @spec load_runs(socket :: Socket.t()) :: Socket.t()
  def load_runs(%{assigns: %{runs_enabled?: true}} = socket) do
    if connected?(socket) do
      draft_id = socket.assigns.draft.id

      start_async(socket, :run_list, fn ->
        {Composer.recent_runs(draft_id), latest_id(draft_id)}
      end)
    else
      socket
    end
  end

  def load_runs(socket), do: socket

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

  # A result for another selection is dropped, so older data never shows as current.
  defp handle_async(:run_record, {:ok, {key, read}}, socket) do
    case socket.assigns.run do
      %{result: %{key: ^key}} = run -> {:halt, put_run(socket, %{run | result: read(key, read)})}
      _other -> {:halt, socket}
    end
  end

  defp handle_async(:run_record, {:exit, _reason}, socket) do
    case socket.assigns.run do
      %{result: %{state: :loading} = result} = run ->
        {:halt, put_run(socket, %{run | result: %{result | state: :lag}})}

      _other ->
        {:halt, socket}
    end
  end

  defp handle_async(:run_list, {:ok, {recent, latest}}, socket) when is_list(recent),
    do: {:halt, assign(socket, recent_runs: recent, latest_run: latest)}

  defp handle_async(key, _result, socket) when key in @run_asyncs, do: {:halt, socket}
  defp handle_async(_key, _result, socket), do: {:cont, socket}

  # In a run

  @spec run_event(event :: String.t(), params :: term(), socket :: Socket.t()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()} | {:halt, map(), Socket.t()}
  defp run_event("node_moved", _params, socket), do: {:halt, %{status: "rejected"}, socket}
  defp run_event("connect_preview", _params, socket), do: {:halt, %{targets: []}, socket}

  # A hook can't rewrite params, so `focus` and `tools` are never passed on.
  defp run_event("select_node", %{"node" => node}, socket) when is_binary(node) do
    if is_map_key(selectable(socket), node),
      do: {:halt, socket |> assign(:selected, node) |> sync_result()},
      else: {:halt, socket}
  end

  defp run_event("deselect_node", _params, socket),
    do: {:halt, socket |> assign(:selected, nil) |> sync_result()}

  # Only a generation the selected node has run at can be picked.
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
      {:halt, socket |> put_run(%{run | generation: {node, generation}}) |> sync_result()}
    else
      _other -> {:halt, socket}
    end
  end

  defp run_event(
         "retry_run_record",
         _params,
         %{assigns: %{run: %{result: %{state: state}} = run}} = socket
       )
       when state in [:lag, :unavailable],
       do: {:halt, socket |> put_run(%{run | result: nil}) |> sync_result()}

  defp run_event(
         "decide",
         %{"occurrence" => occurrence, "choice" => choice} = params,
         %{assigns: %{run: %{handle: handle}}} = socket
       )
       when is_binary(occurrence) and is_binary(choice) and not is_nil(handle),
       do: {:halt, decide(socket, occurrence, choice, Map.get(params, "inputs", %{}))}

  defp run_event("dismiss_rejection", _params, socket), do: {:cont, socket}

  defp run_event("open_cancel_run", _params, %{assigns: %{run: run}} = socket) do
    if :cancel in controls(run),
      do: {:halt, put_run(socket, %{run | cancel_open?: true})},
      else: {:halt, socket}
  end

  defp run_event("close_cancel_run", _params, %{assigns: %{run: run}} = socket),
    do: {:halt, put_run(socket, %{run | cancel_open?: false})}

  # Core decides whether a cancel fits the run's phase, so a crafted one still gets its
  # typed answer.
  defp run_event(
         "confirm_cancel_run",
         _params,
         %{assigns: %{run: %{handle: handle} = run}} = socket
       )
       when not is_nil(handle) do
    socket = put_run(socket, %{run | cancel_open?: false})

    case Composer.cancel_run(handle) do
      :ok -> {:halt, reread(socket)}
      {:error, reason} -> {:halt, socket |> refused(reason) |> reread()}
    end
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

  defp run_event(_event, _params, socket), do: {:halt, socket}

  @spec selectable(socket :: Socket.t()) :: map()
  defp selectable(%{assigns: %{document: document, stage: nil}}), do: document["vertices"]

  defp selectable(%{assigns: %{document: document, stage: stage}}),
    do: Composer.nodes(document, stage)

  @spec controls(run :: map()) :: [:recover | :cancel]
  defp controls(%{state: :open, status: %{} = status}), do: RunView.controls(status)
  defp controls(_run), do: []

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
      stale?: false,
      result: nil,
      generation: nil,
      decision: nil
    }

    socket =
      assign(socket,
        run: run,
        document: row.document,
        start: nil,
        selected: nil,
        conflict: false,
        rejection: nil
      )

    if connected?(socket) do
      draft_id = socket.assigns.draft.id
      start_async(socket, :run_open, fn -> open(row, draft_id) end)
    else
      socket
    end
  end

  @spec open(row :: Composer.Run.t(), draft_id :: String.t()) ::
          {String.t(), {:ok, map()} | {:error, atom()}, boolean()}
  defp open(row, draft_id) do
    opened =
      with {:ok, %{handle: handle, definition_changed?: changed?}} <- Composer.open_run(row),
           {:ok, status} <- Composer.run_view(handle) do
        {:ok, %{handle: handle, status: status, definition_changed?: changed?}}
      end

    draft_changed? =
      case Composer.get_draft(draft_id) do
        {:ok, draft} -> Composer.run_draft_changed?(row, draft) == true
        {:error, :not_found} -> false
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

    socket |> put_run(run) |> subscribe() |> sync_result()
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
    assign(socket, run: nil, selected: nil, rejection: nil)
  end

  # Live status

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
    run = %{run | fold: RunView.apply_event(run.fold, event), cursor: cursor, retries: 0}
    socket = put_run(socket, run)

    socket =
      if Enum.any?(List.wrap(event["facts"]), &(&1["type"] in @reread)),
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

  defp on_message(%{assigns: %{run: run}} = socket, {:closed, %{type: :resync_required}}) do
    run = closed(run)

    case Composer.resync_run(run.handle) do
      {:ok, %{view: status, cursor: cursor}} ->
        socket |> put_run(%{run | status: status, cursor: cursor}) |> subscribe()

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

  @spec reread(socket :: Socket.t()) :: Socket.t()
  defp reread(%{assigns: %{run: %{handle: handle} = run}} = socket) when not is_nil(handle) do
    case Composer.run_view(handle) do
      {:ok, status} -> put_run(socket, %{run | status: status})
      {:error, _unavailable} -> put_run(socket, %{run | stale?: true})
    end
  end

  defp reread(socket), do: socket

  # Results

  # The one place that decides what the sidebar says of a selected node's result: a
  # node that never ran, or whose attempt hasn't settled, makes no Core call.
  @spec sync_result(socket :: Socket.t()) :: Socket.t()
  defp sync_result(%{assigns: %{run: %{} = run}} = socket) do
    case wanted(socket.assigns, run) do
      nil ->
        put_run(socket, %{run | result: nil})

      {key, :fetch} ->
        if match?(%{key: ^key}, run.result), do: socket, else: fetch(socket, run, key)

      {key, state} ->
        put_run(socket, %{run | result: %{key: key, state: state}})
    end
  end

  defp sync_result(socket), do: socket

  @spec wanted(assigns :: map(), run :: map()) :: {tuple(), atom()} | nil
  defp wanted(%{stage: stage, selected: node, document: document}, %{state: :open} = run)
       when is_binary(stage) and is_binary(node) do
    with %{} = detail <- RunView.node_detail(run.fold, document, node) do
      generation = RunView.shown_generation(detail, run.generation)
      attempt = generation && List.last(detail.attempts[generation])
      key = {run.id, node, generation, attempt && attempt.settled_seq}

      cond do
        is_nil(attempt) -> {key, :not_run}
        is_integer(attempt.settled_seq) -> {key, :fetch}
        run.status[:owner_live?] == true -> {key, :running}
        true -> {key, :interrupted}
      end
    end
  end

  defp wanted(_assigns, _run), do: nil

  @spec fetch(socket :: Socket.t(), run :: map(), key :: tuple()) :: Socket.t()
  defp fetch(socket, %{handle: handle} = run, {_id, node, generation, seq} = key) do
    socket
    |> put_run(%{run | result: %{key: key, state: :loading}})
    |> start_async(:run_record, fn ->
      {key, Composer.run_record(handle, node, generation, seq)}
    end)
  end

  @spec read(key :: tuple(), read :: term()) :: map()
  defp read(key, %{status: _status} = rendered), do: %{key: key, state: :stored, record: rendered}
  defp read(key, :miss), do: %{key: key, state: :miss}
  defp read(key, :lag), do: %{key: key, state: :lag}
  defp read(key, _unavailable), do: %{key: key, state: :unavailable}

  # Decisions

  # The occurrence must be one this run asked, the choice one of its decision's in the
  # snapshot, and every input one that choice declares. Core then decides whether the
  # answer still fits, so a stale tab gets its typed refusal.
  @spec decide(
          socket :: Socket.t(),
          occurrence :: String.t(),
          choice :: String.t(),
          raw :: term()
        ) :: Socket.t()
  defp decide(%{assigns: %{run: run, document: document}} = socket, occurrence, choice, raw) do
    with true <- is_map(raw),
         decision when is_binary(decision) <- run.fold.occurrences[occurrence],
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
  defp refused(socket, :run_frozen),
    do: reject(socket, :run_frozen, nil, "This run lost its process. Recover it first.")

  defp refused(socket, {:refused, core_id}),
    do: reject(socket, :run_refused, core_id, "Core refused that for this run.")

  defp refused(socket, :runs_disabled),
    do: reject(socket, :runs_disabled, nil, "Runs are turned off on this host.")

  defp refused(socket, _unavailable),
    do: reject(socket, :run_unavailable, nil, "This run can't be reached right now.")

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

  @spec start_event(event :: String.t(), params :: term(), socket :: Socket.t()) :: Socket.t()
  defp start_event("open_start", _params, %{assigns: %{start: nil}} = socket) do
    fields = RunInputs.fields(socket.assigns.document)

    start = %{
      run_id: Ecto.UUID.generate(),
      command_id: Ecto.UUID.generate(),
      fields: fields,
      params: %{},
      form: start_form(%{}),
      errors: %{},
      values: nil,
      effects: nil,
      lock_version: nil,
      pending?: false
    }

    assign(socket, :start, start)
  end

  defp start_event("close_start", _params, %{assigns: %{start: %{pending?: false}}} = socket),
    do: assign(socket, :start, nil)

  defp start_event(
         "submit_start",
         params,
         %{assigns: %{start: %{pending?: false} = start}} = socket
       ) do
    raw = if is_map(params["start"]), do: params["start"], else: %{}
    kept = safe_params(start.fields, raw)
    start = %{start | params: kept, form: start_form(kept), values: nil, effects: nil}

    case RunInputs.parse(socket.assigns.document, raw) do
      {:ok, values} ->
        # The version whose runners the confirmation lists is the one that starts.
        start = %{
          start
          | errors: %{},
            values: values,
            lock_version: socket.assigns.draft.lock_version
        }

        case RunInputs.effects(socket.assigns.document) do
          [] -> launch(socket, start)
          effects -> assign(socket, :start, %{start | effects: effects})
        end

      {:error, errors} ->
        assign(socket, :start, %{start | errors: Map.new(errors, &{&1.name, &1.code})})
    end
  end

  # Acts only on the values the submit stored, never on anything this event carries.
  defp start_event("confirm_start", _params, %{assigns: %{start: start}} = socket)
       when is_map(start.values) and not start.pending? and is_list(start.effects),
       do: launch(socket, start)

  defp start_event(_event, _params, socket), do: socket

  # The same ids for the form's whole life, so a retry converges on one run. The draft
  # version is the one the submit saw, so a draft changed since then is a conflict.
  @spec launch(socket :: Socket.t(), start :: map()) :: Socket.t()
  defp launch(socket, start) do
    attrs = %{
      draft_id: socket.assigns.draft.id,
      lock_version: start.lock_version,
      run_id: start.run_id,
      command_id: start.command_id,
      values: start.values
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
        %{draft: draft, stage: stage} = socket.assigns

        socket
        |> assign(:start, nil)
        |> push_patch(to: composer_path(draft.id, stage, id))

      {:error, {:input_error, name}} ->
        assign(socket, :start, %{
          start
          | errors: %{name => :input_error},
            values: nil,
            effects: nil
        })

      # The draft moved on, so the form is submitted again against it.
      {:error, :conflict} ->
        assign(socket, start: %{start | values: nil, effects: nil}, conflict: true)

      {:error, :gone} ->
        gone(socket)

      {:error, {:invalid, issues}} ->
        assign(socket, start: nil, core_issues: issues, tools_open?: true)

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

  @spec latest_id(draft_id :: String.t()) :: String.t() | nil
  defp latest_id(draft_id) do
    case Composer.latest_unfinished_run(draft_id) do
      %{id: id} -> id
      _none -> nil
    end
  end
end
