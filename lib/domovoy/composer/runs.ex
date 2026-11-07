defmodule Domovoy.Composer.Runs do
  @moduledoc """
  The gateway to Core's runs, and the only module that may name Core's run modules.

  Runs are local dev only. With `composer_runs_enabled` off, every function but
  `enabled?/0`, `children/0`, `runtime/0` and `unfinished?/1` gives
  `{:error, :runs_disabled}`, and no Core run function is called.

  Core's failures go through `CoreBridge.guarded/2`, which keeps only an error's type,
  because a reason or a cause can hold an input's value or an expanded path. Run-table
  queries pass `log: false`, because a snapshot's literals may hold secrets. A view has
  fixed atom keys and holds no input or output value.
  """

  import Ecto.Query

  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Export
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunValues
  alias Domovoy.Composer.RunView
  alias Domovoy.Repo
  alias DomovoyCore.Definition
  alias DomovoyCore.Error
  alias DomovoyCore.Events
  alias DomovoyCore.Events.Envelope
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Runs.Ref
  alias DomovoyCore.Workflow

  @recent_limit 10

  # A start may be in flight this long after its row was written.
  @start_grace_seconds 60

  @type disabled :: {:error, :runs_disabled}

  @type start_attrs :: %{
          draft_id: String.t(),
          lock_version: integer(),
          run_id: String.t(),
          command_id: String.t(),
          values: map()
        }

  @type view :: %{
          phase: String.t() | nil,
          committed_phase: String.t(),
          committed_seq: non_neg_integer(),
          outcome: String.t() | nil,
          block_reason: String.t() | nil,
          availability: String.t(),
          pending_operation: String.t() | nil,
          cursor: String.t() | nil,
          generation: non_neg_integer(),
          pause_until: String.t() | nil,
          awaiting: [%{occurrence: String.t(), decision: String.t(), choices: [String.t()]}],
          uncertainties: [String.t()],
          error: String.t() | nil,
          owner_live?: boolean()
        }

  @doc """
  Whether this host may run workflows.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:domovoy, :composer_runs_enabled, false) == true

  @doc """
  The name of the host's Core runtime.
  """
  @spec runtime() :: module()
  def runtime, do: Domovoy.Composer.Runtime

  @doc """
  The supervised children runs need, none with the flag off.
  """
  @spec children() :: [Supervisor.child_spec() | module() | {module(), keyword()}]
  def children do
    if enabled?(), do: [{DomovoyCore.Runtime, name: runtime()}], else: []
  end

  @doc """
  Starts a run from a freshly read draft, snapshotting its document first.

  No error from Core proves that nothing committed: a start can fail after its commit.
  So the row is removed only when Core answers that this start isn't there and no
  attempt of this call had an unknown outcome. Otherwise the row stays and the answer
  is `{:opened_uncertain, run_id}`, since that row still reaches whatever committed.
  """
  @spec start(attrs :: start_attrs()) ::
          {:ok, String.t()}
          | {:opened_uncertain, String.t()}
          | {:error,
             :conflict
             | :gone
             | :runs_disabled
             | {:invalid, [Issue.t()]}
             | {:input_error, String.t()}
             | {:refused, atom() | nil}}
  def start(attrs) do
    gated(fn ->
      %{draft_id: draft_id, lock_version: lock_version} = attrs

      with {:ok, draft} <- fresh_draft(draft_id, lock_version),
           {:ok, valid} <- valid_document(draft),
           :ok <- insert_row(draft, valid.fingerprint, attrs) do
        commit(draft.document, attach(valid.workflow), attrs)
      end
    end)
  end

  @doc """
  Finds a run of a draft. A malformed id, and another draft's run, are the same as an
  unknown one.
  """
  @spec get(draft_id :: term(), run_id :: term()) ::
          {:ok, Run.t()} | {:error, :not_found} | disabled()
  def get(draft_id, run_id) do
    gated(fn ->
      with {:ok, draft_uuid} <- Ecto.UUID.cast(draft_id),
           {:ok, run_uuid} <- Ecto.UUID.cast(run_id),
           %Run{} = row <- Repo.get_by(Run, [id: run_uuid, draft_id: draft_uuid], log: false) do
        {:ok, row}
      else
        _missing -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Opens a run from its snapshot. Opening starts no owner and executes nothing.

  `definition_changed?` says a runner's contract has changed since a finished run; Core
  itself refuses a live run in that state, which gives `:definition_mismatch`.
  """
  @spec open(row :: Run.t()) ::
          {:ok, %{handle: Ref.t(), definition_changed?: boolean()}}
          | {:error,
             :runner_unavailable
             | :definition_mismatch
             | :never_started
             | :unavailable
             | :runs_disabled}
  def open(row) do
    gated(fn ->
      case CoreBridge.build(row.document) do
        {:ok, workflow} -> reopen(workflow, row)
        {:error, _issues} -> {:error, :runner_unavailable}
      end
    end)
  end

  @doc """
  The current view of an opened run.
  """
  @spec view(handle :: Ref.t()) :: {:ok, view()} | {:error, :unavailable | :runs_disabled}
  def view(handle), do: gated(fn -> guarded_view(handle) end)

  @doc """
  Subscribes the calling process to an opened run's events after a cursor, `nil` for
  the first one. It must run in the process that consumes them, since Core delivers to
  the caller. Subscribing starts no owner.
  """
  @spec subscribe(handle :: Ref.t(), after_cursor :: String.t() | nil) ::
          {:ok, Events.Subscription.t()} | {:error, :unavailable | :runs_disabled}
  def subscribe(handle, after_cursor) do
    gated(fn -> reach(fn -> Events.subscribe(handle, after: after_cursor) end) end)
  end

  @doc """
  Gives a subscription its credit back, up to a cursor.
  """
  @spec ack(subscription :: Events.Subscription.t(), cursor :: String.t()) ::
          :ok | {:error, :unavailable | :runs_disabled}
  def ack(subscription, cursor) do
    gated(fn -> ok(reach(fn -> Events.ack(subscription, cursor) end)) end)
  end

  @doc """
  Ends a subscription. Ending one that already ended is `:ok`.
  """
  @spec unsubscribe(subscription :: Events.Subscription.t()) :: :ok | disabled()
  def unsubscribe(subscription) do
    gated(fn ->
      _ended = reach(fn -> Events.unsubscribe(subscription) end)
      :ok
    end)
  end

  @doc """
  The run's view and the cursor it stands at, for a subscription whose history after
  its cursor can no longer be read.
  """
  @spec resync(handle :: Ref.t()) ::
          {:ok, %{view: view(), cursor: String.t()}} | {:error, :unavailable | :runs_disabled}
  def resync(handle), do: gated(fn -> reach(fn -> resynced(handle) end) end)

  @doc """
  An event as a string-keyed document, which holds no value and no error reason.
  """
  @spec encode_event(envelope :: Envelope.t()) :: map() | disabled()
  def encode_event(envelope), do: gated(fn -> Envelope.encode(envelope) end)

  @doc """
  Cancels a run. A frozen run gives `:run_frozen`, because a command would start its
  owner; a command the run's phase refuses gives its type.
  """
  @spec cancel(handle :: Ref.t()) ::
          :ok | {:error, :run_frozen | :unavailable | :runs_disabled | {:refused, atom() | nil}}
  def cancel(handle) do
    gated(fn -> command(handle, :cancel, &"cancel:#{&1.committed_seq}", []) end)
  end

  @doc """
  Answers a pending decision occurrence. The command id comes from the answer itself,
  so a second submit of the same answer reads its receipt, and a different answer to
  an occurrence already answered is refused as `decision_not_pending`. Core casts the
  inputs by the types the choice declares. A frozen run gives `:run_frozen`.
  """
  @spec decide(
          handle :: Ref.t(),
          occurrence :: String.t(),
          choice :: String.t(),
          inputs :: map()
        ) ::
          :ok | {:error, :run_frozen | :unavailable | :runs_disabled | {:refused, atom() | nil}}
  def decide(handle, occurrence, choice, inputs) do
    gated(fn ->
      # A command id has a length limit, so the answer is hashed.
      digest =
        {occurrence, choice, inputs}
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      opts = [occurrence: occurrence, choice: choice, inputs: inputs]
      command(handle, :decide, fn _view -> "decide:" <> digest end, opts)
    end)
  end

  @doc """
  A node's stored result at a generation, read once the projection holds the commit at
  `seq`, its `attempt_settled`. Gives the rendered record, `:miss` when the Store holds
  none, or `:lag` when the projection hasn't caught up in time. Reading starts no owner.
  """
  @spec record(
          handle :: Ref.t(),
          node :: String.t(),
          generation :: non_neg_integer(),
          seq :: non_neg_integer()
        ) :: RunValues.rendered() | :miss | :lag | {:error, :unavailable | :runs_disabled}
  def record(handle, node, generation, seq) do
    gated(fn ->
      reached(fn -> stored(handle, node, generation, seq) end)
    end)
  end

  @doc """
  Starts a frozen run's owner, which recovers it. Adds no command.
  """
  @spec activate(handle :: Ref.t()) :: :ok | {:error, :unavailable | :runs_disabled}
  def activate(handle) do
    gated(fn -> ok(reach(fn -> CoreRuns.activate(handle) end)) end)
  end

  @doc """
  A draft's latest rows, newest first. Reads rows only, so nothing is opened.
  """
  @spec recent(draft_id :: String.t(), limit :: pos_integer()) :: [Run.t()] | disabled()
  def recent(draft_id, limit \\ @recent_limit) do
    gated(fn -> Repo.all(limit(rows_query(draft_id), ^limit), log: false) end)
  end

  @doc """
  The newest of a draft's recent rows that isn't finished, or nil.
  """
  @spec latest_unfinished(draft_id :: String.t()) :: Run.t() | nil | disabled()
  def latest_unfinished(draft_id) do
    gated(fn -> draft_id |> recent() |> Enum.find(&unfinished_row?/1) end)
  end

  @doc """
  Whether a draft's definition differs from a run's snapshot. Moving a card doesn't
  count; a retry-only edit does.
  """
  @spec draft_changed?(row :: Run.t(), draft :: Draft.t()) :: boolean() | disabled()
  def draft_changed?(row, draft) do
    gated(fn -> Map.drop(row.document, ["layout"]) != Map.drop(draft.document, ["layout"]) end)
  end

  @doc """
  Whether any run of a draft could still need a person. With the flag off this makes
  no Core call and any row counts, so it fails closed.
  """
  @spec unfinished?(draft_id :: String.t()) :: boolean()
  def unfinished?(draft_id) do
    rows = Repo.all(rows_query(draft_id), log: false)
    if enabled?(), do: Enum.any?(rows, &unfinished_row?/1), else: rows != []
  end

  @spec gated(fun :: (-> result)) :: result | disabled() when result: term()
  defp gated(fun), do: if(enabled?(), do: fun.(), else: {:error, :runs_disabled})

  @spec rows_query(draft_id :: String.t()) :: Ecto.Query.t()
  defp rows_query(draft_id) do
    from(row in Run,
      where: row.draft_id == ^draft_id,
      order_by: [desc: row.inserted_at, desc: row.id]
    )
  end

  # An outcome is fixed before `finished`, so only `finished` lets a draft go.
  @spec unfinished_row?(row :: Run.t()) :: boolean()
  defp unfinished_row?(row) do
    case open(row) do
      {:ok, %{handle: handle}} -> not match?({:ok, %{committed_phase: "finished"}}, view(handle))
      {:error, :runner_unavailable} -> false
      {:error, :never_started} -> start_in_flight?(row)
      {:error, _definition_mismatch_or_unavailable} -> true
    end
  end

  @spec start_in_flight?(row :: Run.t()) :: boolean()
  defp start_in_flight?(row),
    do: DateTime.diff(DateTime.utc_now(), row.inserted_at) < @start_grace_seconds

  @spec fresh_draft(draft_id :: term(), lock_version :: term()) ::
          {:ok, Draft.t()} | {:error, :conflict | :gone}
  defp fresh_draft(draft_id, lock_version) do
    with {:ok, uuid} <- Ecto.UUID.cast(draft_id),
         %Draft{} = draft <- Repo.get(Draft, uuid, log: false) do
      if draft.lock_version == lock_version, do: {:ok, draft}, else: {:error, :conflict}
    else
      _missing -> {:error, :gone}
    end
  end

  @spec valid_document(draft :: Draft.t()) :: {:ok, map()} | {:error, {:invalid, [Issue.t()]}}
  defp valid_document(draft) do
    case Export.validate(draft.document, Export.configured_steps()) do
      {:valid, valid} -> {:ok, valid}
      {:invalid, issues} -> {:error, {:invalid, issues}}
    end
  end

  # A repeat of the same start applies nothing. A row these ids already hold for anything
  # else may have committed, so it's kept as it is and no Core call can remove it.
  @spec insert_row(draft :: Draft.t(), fingerprint :: String.t(), attrs :: start_attrs()) ::
          :ok | {:opened_uncertain, String.t()} | {:error, :gone}
  defp insert_row(draft, fingerprint, %{run_id: run_id, command_id: command_id}) do
    changeset =
      Run.changeset(%Run{
        id: run_id,
        draft_id: draft.id,
        workflow_name: draft.document["name"],
        document: draft.document,
        fingerprint: fingerprint,
        start_command_id: command_id
      })

    case Repo.insert(changeset, on_conflict: :nothing, log: false) do
      {:ok, _row} ->
        case Repo.get(Run, run_id, log: false) do
          %Run{draft_id: draft_id, document: document, start_command_id: ^command_id}
          when draft_id == draft.id and document == draft.document ->
            :ok

          _another_start ->
            {:opened_uncertain, run_id}
        end

      {:error, _changeset} ->
        {:error, :gone}
    end
  end

  # The one place adapters join a workflow, so `Export.validate/2` never sees them.
  @spec attach(workflow :: Workflow.t()) :: Workflow.t()
  defp attach(%Workflow{} = workflow) do
    adapters = Application.fetch_env!(:domovoy, :composer_run_adapters)
    %Workflow{workflow | journal: adapters[:journal], store: adapters[:store]}
  end

  # Core 0.3.3 persists no limits, and a ref opened without them starts the owner on the
  # defaults, which can fail a run for good. So `start/4` and `open/4` share these, and
  # they name no limits.
  @spec run_opts() :: keyword()
  defp run_opts, do: []

  @spec commit(document :: map(), workflow :: Workflow.t(), attrs :: start_attrs()) ::
          {:ok, String.t()} | {:opened_uncertain, String.t()} | {:error, tuple()}
  defp commit(document, workflow, %{run_id: run_id} = attrs) do
    case core_start(document, workflow, attrs) do
      {:error, [%Issue{core_id: :commit_outcome_unknown} | _rest]} ->
        case core_start(document, workflow, attrs) do
          {:ok, %Ref{}} -> {:ok, run_id}
          _still_unknown -> {:opened_uncertain, run_id}
        end

      {:ok, %Ref{}} ->
        {:ok, run_id}

      failure ->
        settle_failure(failure, workflow, attrs)
    end
  end

  # Never reads an error's `cause`, which can hold the rejected value or an expanded path.
  @spec core_start(document :: map(), workflow :: Workflow.t(), attrs :: start_attrs()) ::
          {:ok, Ref.t() | {:input_error, String.t()}} | {:error, [Issue.t()]}
  defp core_start(document, workflow, %{run_id: run_id, command_id: command_id, values: values}) do
    inputs = document["inputs"]
    opts = [run_id: run_id, command_id: command_id] ++ run_opts()

    CoreBridge.guarded(:workflow, fn ->
      case CoreRuns.start(runtime(), workflow, values, opts) do
        {:ok, ref, _receipt} ->
          {:ok, ref}

        {:error, %Error{type: :invalid_workflow_input, reason: %{input_name: name}}}
        when is_map_key(inputs, name) ->
          {:ok, {:input_error, name}}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  @spec settle_failure(
          failure :: {:ok, {:input_error, String.t()}} | {:error, [Issue.t()]},
          workflow :: Workflow.t(),
          attrs :: start_attrs()
        ) :: {:opened_uncertain, String.t()} | {:error, tuple()}
  defp settle_failure(failure, workflow, %{run_id: run_id, command_id: command_id}) do
    receipt =
      CoreBridge.guarded(:workflow, fn ->
        with {:ok, _receipt} <- CoreRuns.start_receipt(runtime(), workflow, run_id, command_id) do
          {:ok, :committed}
        end
      end)

    case receipt do
      {:error, [%Issue{core_id: :start_not_found} | _rest]} ->
        Repo.delete_all(from(row in Run, where: row.id == ^run_id), log: false)
        {:error, refusal(failure)}

      _committed_or_unknown ->
        {:opened_uncertain, run_id}
    end
  end

  @spec refusal(failure :: {:ok, {:input_error, String.t()}} | {:error, [Issue.t()]}) :: tuple()
  defp refusal({:ok, {:input_error, name}}), do: {:input_error, name}
  defp refusal({:error, [%Issue{core_id: core_id} | _rest]}), do: {:refused, core_id}

  @spec reopen(workflow :: Workflow.t(), row :: Run.t()) ::
          {:ok, %{handle: Ref.t(), definition_changed?: boolean()}}
          | {:error, :definition_mismatch | :never_started | :unavailable}
  defp reopen(workflow, row) do
    opened =
      CoreBridge.guarded(:workflow, fn ->
        with {:ok, handle} <- CoreRuns.open(runtime(), attach(workflow), row.id, run_opts()) do
          changed? = Definition.fingerprint(workflow).root != row.fingerprint
          {:ok, %{handle: handle, definition_changed?: changed?}}
        end
      end)

    case opened do
      {:ok, result} ->
        {:ok, result}

      {:error, [%Issue{core_id: :workflow_definition_mismatch} | _]} ->
        {:error, :definition_mismatch}

      {:error, [%Issue{core_id: :run_not_found} | _]} ->
        {:error, :never_started}

      {:error, _issues} ->
        {:error, :unavailable}
    end
  end

  # Re-reads the view first: a command starts the owner, which a frozen run must not get
  # without a person's Recover. The id comes from that committed state, or from the
  # command's own content, so a repeat of the same intent reads its receipt.
  @spec command(
          handle :: Ref.t(),
          name :: CoreRuns.command(),
          id :: (view() -> String.t()),
          opts :: keyword()
        ) :: :ok | {:error, :run_frozen | :unavailable | {:refused, atom() | nil}}
  defp command(handle, name, id, opts) do
    with {:ok, view} <- guarded_view(handle),
         false <- RunView.frozen?(view) do
      submit(handle, name, [command_id: id.(view)] ++ opts)
    else
      true -> {:error, :run_frozen}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @spec submit(handle :: Ref.t(), name :: CoreRuns.command(), opts :: keyword()) ::
          :ok | {:error, {:refused, atom() | nil}}
  defp submit(handle, name, opts) do
    case CoreBridge.guarded(:workflow, fn -> CoreRuns.command(handle, name, opts) end) do
      {:ok, _receipt} -> :ok
      {:error, [%Issue{core_id: core_id} | _rest]} -> {:error, {:refused, core_id}}
    end
  end

  @spec stored(
          handle :: Ref.t(),
          node :: String.t(),
          generation :: non_neg_integer(),
          seq :: non_neg_integer()
        ) :: {:ok, RunValues.rendered() | :miss | :lag} | {:error, Error.t()}
  defp stored(handle, node, generation, seq) do
    case CoreRuns.get(handle, node, generation, at_least_seq: seq, timeout: 2_000) do
      {:ok, record} -> {:ok, RunValues.render_record(record)}
      :miss -> {:ok, :miss}
      {:error, %Error{type: :projection_lag}} -> {:ok, :lag}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec resynced(handle :: Ref.t()) :: {:ok, map()} | {:error, Error.t()}
  defp resynced(handle) do
    with {:ok, %{view: view, cursor: cursor}} <- Events.resync(handle) do
      {:ok, %{view: view_map(view, CoreRuns.whereis(handle)), cursor: cursor}}
    end
  end

  # A Core call whose failure, of any kind, only says the run can't be reached now.
  @spec reach(fun :: (-> term())) :: {:ok, term()} | {:error, :unavailable}
  defp reach(fun) do
    case CoreBridge.guarded(:workflow, fun) do
      {:ok, value} -> {:ok, value}
      {:error, _issues} -> {:error, :unavailable}
    end
  end

  @spec reached(fun :: (-> term())) :: term() | {:error, :unavailable}
  defp reached(fun) do
    case reach(fun) do
      {:ok, result} -> result
      {:error, :unavailable} = error -> error
    end
  end

  @spec ok(result :: {:ok, :ok} | {:error, :unavailable}) :: :ok | {:error, :unavailable}
  defp ok({:ok, :ok}), do: :ok
  defp ok({:error, :unavailable} = error), do: error

  @spec guarded_view(handle :: Ref.t()) :: {:ok, view()} | {:error, :unavailable}
  defp guarded_view(handle), do: reach(fn -> reduced_view(handle) end)

  # After an event, a committed read is never older than that event.
  @spec reduced_view(handle :: Ref.t()) :: {:ok, view()} | {:error, Error.t()}
  defp reduced_view(handle) do
    with {:ok, view} <- CoreRuns.view(handle, consistency: :committed) do
      {:ok, view_map(view, CoreRuns.whereis(handle))}
    end
  end

  @spec view_map(view :: map(), owner :: pid() | nil) :: view()
  defp view_map(view, owner) do
    %{
      phase: text(view.phase),
      committed_phase: text(view.committed_phase),
      committed_seq: view.committed_seq,
      outcome: text(view.outcome),
      block_reason: text(view.block_reason),
      availability: text(view.availability),
      pending_operation: view.pending_operation,
      cursor: view.cursor,
      generation: view.generation,
      pause_until: view.pause_until,
      awaiting: view.awaiting,
      uncertainties: view.uncertainties,
      error: error_type(view.error),
      owner_live?: is_pid(owner)
    }
  end

  @spec text(value :: atom() | nil) :: String.t() | nil
  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)

  @spec error_type(error :: Error.t() | nil) :: String.t() | nil
  defp error_type(%Error{type: type}), do: Atom.to_string(type)
  defp error_type(nil), do: nil
end
