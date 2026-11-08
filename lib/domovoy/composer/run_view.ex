defmodule Domovoy.Composer.RunView do
  @moduledoc """
  A run as the composer shows it, folded from its public events and its snapshot.

  Pure, and naming no Core module: events arrive string-keyed, as
  `Domovoy.Composer.Runs.encode_event/1` gives them. A replayed event is ignored by its
  `seq`, so a resubscription can't add an attempt twice. Every value read from an event
  stays a string, so an unknown phase or outcome makes no atom.

  `controls/1` is the one owner of which run buttons show, and `frozen?/1` of when a run
  has lost its process. `node_detail/3` and `vertex_detail/2` give what the sidebar
  shows of one card, `evidence/4` what a pending decision shows beside its choices,
  `results/2` what the Results panel lists, `uncertainties/2` which steps a blocked run
  needs a person to check, and `scope_statuses/3` each card's status in one generation,
  from events and the snapshot; none holds a value.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Document

  # A committed phase in which an owner must be doing work. Without one, nothing moves.
  @live_phases ~w(starting resuming running pausing stopping cancelling finishing)

  @known_phases ~w(starting resuming running waiting pausing paused stopping stopped
                   cancelling finishing finished blocked)

  # A committed phase whose run Core lets pause, and so stop.
  @pausable ~w(starting resuming running waiting)

  # Worst first: a stage card shows the worst of its nodes.
  @severity ~w(failed uncertain running needs_you interrupted cancelled skipped unknown
               not_executed succeeded)

  @settled %{
    "succeeded" => "succeeded",
    "failed" => "failed",
    "cancelled" => "cancelled",
    "interrupted" => "interrupted"
  }

  @typedoc "A card's run status: one of `@severity`, as a string."
  @type status :: String.t()

  @type attempt :: %{
          node: String.t(),
          generation: integer(),
          ordinal: integer(),
          admitted_seq: integer(),
          admitted_at: String.t() | nil,
          settled_seq: integer() | nil,
          settled_at: String.t() | nil,
          outcome: String.t() | nil,
          uncertain?: boolean()
        }

  @type t :: %__MODULE__{
          stages: %{String.t() => String.t()},
          last_seq: non_neg_integer(),
          attempts: %{{String.t(), integer(), integer()} => attempt()},
          skipped: MapSet.t({String.t(), integer()}),
          stage_runs: %{{String.t(), integer()} => :started | :finished},
          occurrences: %{String.t() => String.t()},
          pending: MapSet.t(String.t()),
          superseded: MapSet.t(String.t()),
          chosen: %{String.t() => String.t()},
          asked: %{String.t() => integer()},
          answers: %{String.t() => String.t()},
          uncertainties: %{String.t() => {String.t(), integer(), integer()}}
        }

  @type source :: %{field: String.t(), source: String.t() | nil}

  @type node_detail :: %{
          name: String.t(),
          stage: String.t(),
          runner: String.t(),
          store?: boolean(),
          generations: [integer()],
          attempts: %{integer() => [attempt()]},
          sources: [source()]
        }

  @type evidence :: %{
          stage: String.t(),
          node: String.t(),
          shown: {:same, integer()} | {:from, integer()} | nil
        }

  @type result_row :: %{
          stage: String.t(),
          node: String.t(),
          generation: integer(),
          status: status(),
          store?: boolean()
        }

  @type uncertainty :: %{
          id: String.t(),
          node: String.t() | nil,
          stage: String.t() | nil,
          generation: integer() | nil,
          ordinal: integer() | nil
        }

  @type occurrence :: %{
          occurrence: String.t(),
          generation: integer() | nil,
          choice: String.t() | nil,
          state: :pending | :answered | :superseded
        }

  defstruct stages: %{},
            last_seq: 0,
            attempts: %{},
            skipped: MapSet.new(),
            stage_runs: %{},
            occurrences: %{},
            pending: MapSet.new(),
            superseded: MapSet.new(),
            chosen: %{},
            asked: %{},
            answers: %{},
            uncertainties: %{}

  @doc """
  An empty fold for a run of this snapshot.
  """
  @spec new(document :: Document.t()) :: t()
  def new(document) do
    stages =
      for {stage, %{"kind" => "stage"}} <- document["vertices"],
          node <- Map.keys(Document.nodes(document, stage)),
          into: %{} do
        {node, stage}
      end

    %__MODULE__{stages: stages}
  end

  @doc """
  Folds one encoded event. An event at or before the last one folded changes nothing.
  """
  @spec apply_event(view :: t(), event :: map()) :: t()
  def apply_event(%__MODULE__{last_seq: last} = view, %{"seq" => seq} = event)
      when is_integer(seq) and seq > last do
    facts = if is_list(event["facts"]), do: event["facts"], else: []
    at = if is_binary(event["at"]), do: event["at"]

    facts
    |> Enum.reduce(view, &apply_fact(&2, &1, seq, at))
    |> Map.put(:last_seq, seq)
  end

  def apply_event(view, _event), do: view

  @doc """
  The node a subject names, or nil for any other subject.
  """
  @spec subject_node(subject :: term()) :: String.t() | nil
  def subject_node("node:" <> node) when node != "", do: node
  def subject_node(_subject), do: nil

  @doc """
  Each card's status at a level, by card name: a node's latest attempt on a stage; on
  the workflow, a stage's worst node and a decision's own state. A card the run hasn't
  reached has no entry.
  """
  @spec card_statuses(view :: t(), stage :: String.t() | nil) :: %{String.t() => status()}
  def card_statuses(view, nil) do
    by_stage =
      view
      |> node_statuses()
      |> Enum.group_by(fn {node, _status} -> view.stages[node] end, &elem(&1, 1))
      |> Map.new(fn {stage, statuses} -> {stage, worst(statuses)} end)

    decisions =
      Map.new(view.occurrences, fn {_occurrence, decision} ->
        {decision, decision_status(view, decision)}
      end)

    by_stage |> Map.delete(nil) |> Map.merge(decisions)
  end

  def card_statuses(view, stage) do
    view
    |> node_statuses()
    |> Map.filter(fn {node, _status} -> view.stages[node] == stage end)
  end

  @doc """
  Each card's status in one generation, by card name. On a stage, a node attempted at
  `generation` has its latest attempt's status there, one skipped there is
  `"skipped"`, and any other is `"not_executed"`, so an earlier generation's success is
  never reported for this one. On the workflow, a stage that ran there has the worst of
  the nodes it executed. A node that ran with a problem wins even while another still
  runs; otherwise a started stage reads `"running"` until it finishes; a decision asked there has its occurrence's state, and any
  other card is `"not_executed"`.
  """
  @spec scope_statuses(view :: t(), stage :: String.t() | nil, generation :: integer()) ::
          %{String.t() => status()}
  def scope_statuses(view, nil, generation) do
    stages =
      view.stages
      |> Map.keys()
      |> Enum.group_by(&view.stages[&1], &scope_status(view, &1, generation))
      |> Map.new(fn {stage, statuses} ->
        {stage, stage_scope_status(view.stage_runs[{stage, generation}], statuses)}
      end)

    decisions =
      view.occurrences
      |> Map.values()
      |> Map.new(&{&1, "not_executed"})

    asked =
      for {occurrence, decision} <- view.occurrences,
          view.asked[occurrence] == generation,
          into: %{} do
        {decision, occurrence_status(view, occurrence)}
      end

    decisions |> Map.merge(stages) |> Map.merge(asked)
  end

  def scope_statuses(view, stage, generation) do
    for {node, ^stage} <- view.stages, into: %{} do
      {node, scope_status(view, node, generation)}
    end
  end

  @doc """
  The generation a pending decision was asked at, or Core's current one once a resync
  lost that fact. Nil while Core awaits no occurrence of the decision.
  """
  @spec pending_generation(view :: t(), status :: map() | nil, decision :: String.t()) ::
          integer() | nil
  def pending_generation(view, status, decision) do
    with occurrence when is_binary(occurrence) <- awaited(status, decision),
         generation when is_integer(generation) <- view.asked[occurrence] || status[:generation] do
      generation
    else
      _not_pending -> nil
    end
  end

  @doc """
  The edges of a level, each with a `run` key once the run has travelled it: the card
  it leaves succeeded, and the card it reaches has a status. A decision's route counts
  only for the choice it took. Sockets are mapped through the level's cards, so the
  projection stays unaware of runs.
  """
  @spec wire_statuses(view :: t(), stage :: String.t() | nil, level :: map()) :: [map()]
  def wire_statuses(view, stage, %{cards: cards, edges: edges}) do
    statuses = card_statuses(view, stage)
    owners = socket_owners(cards)

    Enum.map(edges, fn edge ->
      case travelled(view, statuses, owners[edge.from], owners[edge.to]) do
        nil -> edge
        run -> Map.put(edge, :run, run)
      end
    end)
  end

  @doc """
  The nodes whose latest attempt has this status, sorted.
  """
  @spec nodes_with(view :: t(), status :: status()) :: [String.t()]
  def nodes_with(view, status) do
    for {node, ^status} <- node_statuses(view), do: node
  end

  @doc """
  The phase to show: the committed one, which an owner's observed phase lags, else the
  observed one. A phase this release doesn't know is `"unknown"`.
  """
  @spec phase(status :: map()) :: String.t()
  def phase(status) do
    shown = status[:committed_phase] || status[:phase]
    if shown in @known_phases, do: shown, else: "unknown"
  end

  @doc """
  Whether a run has lost its process mid-work: its committed phase needs an owner and it
  has none. Such a run executes nothing until a person recovers it.
  """
  @spec frozen?(status :: map() | nil) :: boolean()
  def frozen?(status) do
    status[:owner_live?] != true and status[:committed_phase] in @live_phases
  end

  @doc """
  The run's buttons, primary first; Pause is last, a secondary control. Committed phase
  decides, and a blocked run's block reason; an owner already observed cancelling or
  finishing shows none.
  """
  @spec controls(status :: map() | nil) ::
          [:recover | :resume | :unpause | :reconcile | :stop | :cancel | :pause]
  def controls(nil), do: []

  def controls(status) do
    cond do
      frozen?(status) -> [:recover]
      status[:phase] in ["cancelling", "finishing"] -> []
      true -> phase_controls(status[:committed_phase], status[:block_reason])
    end
  end

  # Core unblocks a run whose pause timed out, and reconciles an uncertain effect.
  @spec phase_controls(phase :: String.t() | nil, block_reason :: String.t() | nil) :: [atom()]
  defp phase_controls(phase, _reason) when phase in @pausable, do: [:stop, :cancel, :pause]
  defp phase_controls("pausing", _reason), do: [:stop, :cancel]
  defp phase_controls("paused", _reason), do: [:unpause, :stop, :cancel]
  defp phase_controls("stopping", _reason), do: [:cancel]
  defp phase_controls("stopped", _reason), do: [:resume, :cancel]
  defp phase_controls("blocked", "pause_timeout"), do: [:unpause, :stop, :cancel]
  defp phase_controls("blocked", "effect_uncertain"), do: [:reconcile, :stop, :cancel]
  defp phase_controls("blocked", _reason), do: [:stop, :cancel]
  defp phase_controls(_phase, _reason), do: []

  @doc """
  The effects Core couldn't tell happened, which a person must check before the run goes
  on: each unresolved uncertainty in `status`, with the attempt it was recorded on when
  the fold saw it, else with no node.
  """
  @spec uncertainties(view :: t(), status :: map() | nil) :: [uncertainty()]
  def uncertainties(view, %{uncertainties: ids}) when is_list(ids) do
    for id <- ids, is_binary(id) do
      case view.uncertainties[id] do
        {node, generation, ordinal} ->
          %{
            id: id,
            node: node,
            stage: view.stages[node],
            generation: generation,
            ordinal: ordinal
          }

        nil ->
          %{id: id, node: nil, stage: nil, generation: nil, ordinal: nil}
      end
    end
  end

  def uncertainties(_view, _status), do: []

  @doc """
  What the sidebar shows of a node: its runner's label from the snapshot, whether the
  snapshot stores its output, its attempts by generation from events, and where each
  input comes from, as reconstructed from the definition. Nil for a node the snapshot
  doesn't hold.
  """
  @spec node_detail(view :: t(), document :: Document.t(), node :: String.t()) ::
          node_detail() | nil
  def node_detail(view, document, node) do
    with stage when is_binary(stage) <- view.stages[node],
         %{} = definition <- Document.nodes(document, stage)[node] do
      attempts =
        for {{^node, _generation, _ordinal}, attempt} <- view.attempts do
          attempt
        end
        |> Enum.group_by(& &1.generation)
        |> Map.new(fn {generation, list} -> {generation, Enum.sort_by(list, & &1.ordinal)} end)

      %{
        name: node,
        stage: stage,
        runner: runner_label(definition["runner"]),
        store?: definition["store"] != false,
        generations: attempts |> Map.keys() |> Enum.sort(),
        attempts: attempts,
        sources: sources(definition["inputs"])
      }
    else
      _unknown -> nil
    end
  end

  @doc """
  What the sidebar shows of a workflow card: a decision's occurrences, oldest first,
  each with the choice it took, and a stage's node statuses.
  """
  @spec vertex_detail(view :: t(), vertex :: String.t()) :: %{
          occurrences: [occurrence()],
          nodes: %{String.t() => status()}
        }
  def vertex_detail(view, vertex) do
    occurrences =
      for {occurrence, ^vertex} <- view.occurrences do
        %{
          occurrence: occurrence,
          generation: view.asked[occurrence],
          choice: view.answers[occurrence],
          state: occurrence_state(view, occurrence)
        }
      end
      |> Enum.sort_by(&{&1.generation || 0, &1.occurrence})

    %{occurrences: occurrences, nodes: card_statuses(view, vertex)}
  end

  @doc """
  The generation a node's detail shows: the one picked for this node, while it has
  run there, else its latest. `picked` is `{node, generation}` or nil.
  """
  @spec shown_generation(detail :: node_detail(), picked :: {String.t(), integer()} | nil) ::
          integer() | nil
  def shown_generation(%{name: node} = detail, {node, generation}) when is_integer(generation) do
    if generation in detail.generations, do: generation, else: List.last(detail.generations)
  end

  def shown_generation(detail, _picked), do: List.last(detail.generations)

  @doc """
  The occurrence of a decision that Core's status awaits, or nil.
  """
  @spec awaited(status :: map() | nil, decision :: String.t()) :: String.t() | nil
  def awaited(%{awaiting: awaiting}, decision) when is_list(awaiting) do
    Enum.find_value(awaiting, fn
      %{decision: ^decision, occurrence: occurrence} when is_binary(occurrence) -> occurrence
      _other -> nil
    end)
  end

  def awaited(_status, _decision), do: nil

  @doc """
  The generation a node's result is shown at beside a decision asked at `generation`:
  `{:same, generation}` when the node succeeded there, `{:from, k}` for the newest
  earlier generation it succeeded at, as when its stage didn't rerun, else nil.
  """
  @spec evidence_generation(
          view :: t(),
          ref :: {String.t(), String.t()},
          generation :: integer()
        ) :: {:same, integer()} | {:from, integer()} | nil
  def evidence_generation(view, {stage, node}, generation) do
    succeeded =
      for {{^node, at, _ordinal}, %{outcome: "succeeded"}} <- view.attempts,
          view.stages[node] == stage,
          at <= generation,
          uniq: true,
          do: at

    cond do
      generation in succeeded -> {:same, generation}
      succeeded == [] -> nil
      true -> {:from, Enum.max(succeeded)}
    end
  end

  @doc """
  The evidence a pending decision declares in the snapshot, each node with where its
  result comes from, as `evidence_generation/3` says. The pending generation is the one
  its occurrence was asked at, or Core's current one once a resync lost that fact. None
  while Core awaits no occurrence of the decision.
  """
  @spec evidence(
          view :: t(),
          document :: Document.t(),
          status :: map() | nil,
          decision :: String.t()
        ) :: [evidence()]
  def evidence(view, document, status, decision) do
    with %{"kind" => "decision"} = vertex <- document["vertices"][decision],
         generation when is_integer(generation) <- pending_generation(view, status, decision) do
      for %{"stage" => stage, "node" => node} <- Document.evidence(vertex) do
        %{stage: stage, node: node, shown: evidence_generation(view, {stage, node}, generation)}
      end
    else
      _not_pending -> []
    end
  end

  @doc """
  What the Results panel lists: every node with a settled attempt, by stage then name,
  at its latest generation with that generation's status.
  """
  @spec results(view :: t(), document :: Document.t()) :: [result_row()]
  def results(view, document) do
    for {stage, node, _definition} <- Enum.sort(Document.all_nodes(document)),
        %{} = detail <- [node_detail(view, document, node)],
        detail.attempts |> Map.values() |> List.flatten() |> Enum.any?(& &1.settled_seq) do
      generation = List.last(detail.generations)
      latest = List.last(detail.attempts[generation])

      %{
        stage: stage,
        node: node,
        generation: generation,
        status: attempt_status(latest),
        store?: detail.store?
      }
    end
  end

  @doc """
  An attempt's status, as a card shows it.
  """
  @spec attempt_status(attempt :: attempt()) :: status()
  def attempt_status(%{uncertain?: true}), do: "uncertain"
  def attempt_status(%{outcome: nil}), do: "running"
  def attempt_status(%{outcome: outcome}), do: Map.get(@settled, outcome, "unknown")

  @spec occurrence_state(view :: t(), occurrence :: String.t()) ::
          :pending | :answered | :superseded
  defp occurrence_state(view, occurrence) do
    cond do
      MapSet.member?(view.pending, occurrence) -> :pending
      MapSet.member?(view.superseded, occurrence) -> :superseded
      true -> :answered
    end
  end

  @spec runner_label(id :: term()) :: String.t()
  defp runner_label(id) when is_binary(id) do
    case Catalog.runner(id) do
      {:ok, runner} -> runner.label
      :error -> id
    end
  end

  defp runner_label(_id), do: "unknown"

  # A literal's value is left out: only where each input comes from is shown.
  @spec sources(inputs :: term()) :: [source()]
  defp sources(inputs) when is_map(inputs) do
    for {field, input} <- Enum.sort(inputs) do
      case input do
        %{"bind" => source} when is_binary(source) -> %{field: field, source: source}
        _literal -> %{field: field, source: nil}
      end
    end
  end

  defp sources(_inputs), do: []

  @spec apply_fact(view :: t(), fact :: term(), seq :: integer(), at :: String.t() | nil) :: t()
  defp apply_fact(view, %{"type" => "attempt_admitted"} = fact, seq, at) do
    with node when is_binary(node) <- subject_node(fact["subject"]),
         {:ok, key} <- attempt_key(node, fact) do
      attempt = %{
        node: node,
        generation: elem(key, 1),
        ordinal: elem(key, 2),
        admitted_seq: seq,
        admitted_at: at,
        settled_seq: nil,
        settled_at: nil,
        outcome: nil,
        uncertain?: false
      }

      %{view | attempts: Map.put_new(view.attempts, key, attempt)}
    else
      _other -> view
    end
  end

  defp apply_fact(view, %{"type" => "attempt_settled"} = fact, seq, at) do
    update_attempt(view, fact, fn attempt ->
      outcome = if is_binary(fact["outcome"]), do: fact["outcome"], else: "unknown"
      %{attempt | settled_seq: seq, settled_at: at, outcome: outcome}
    end)
  end

  defp apply_fact(view, %{"type" => "uncertainty_recorded"} = fact, _seq, _at) do
    view =
      with id when is_binary(id) <- fact["uncertainty"],
           node when is_binary(node) <- subject_node(fact["subject"]),
           {:ok, key} <- attempt_key(node, fact) do
        %{view | uncertainties: Map.put(view.uncertainties, id, key)}
      else
        _other -> view
      end

    update_attempt(view, fact, &%{&1 | uncertain?: true})
  end

  defp apply_fact(view, %{"type" => "node_skipped"} = fact, _seq, _at) do
    case {subject_node(fact["subject"]), fact["generation"]} do
      {node, generation} when is_binary(node) and is_integer(generation) ->
        %{view | skipped: MapSet.put(view.skipped, {node, generation})}

      _other ->
        view
    end
  end

  # A stage that finished at a generation stays finished, whatever arrives after.
  defp apply_fact(
         view,
         %{"type" => type, "stage" => stage, "generation" => generation},
         _seq,
         _at
       )
       when type in ["stage_started", "stage_finished"] and is_binary(stage) and
              is_integer(generation) do
    key = {stage, generation}

    stage_runs =
      if type == "stage_finished",
        do: Map.put(view.stage_runs, key, :finished),
        else: Map.put_new(view.stage_runs, key, :started)

    %{view | stage_runs: stage_runs}
  end

  defp apply_fact(view, %{"type" => "decision_pending"} = fact, _seq, _at) do
    case fact do
      %{"occurrence" => occurrence, "decision" => decision}
      when is_binary(occurrence) and is_binary(decision) ->
        asked =
          if is_integer(fact["generation"]),
            do: Map.put(view.asked, occurrence, fact["generation"]),
            else: view.asked

        %{
          view
          | occurrences: Map.put(view.occurrences, occurrence, decision),
            pending: MapSet.put(view.pending, occurrence),
            asked: asked
        }

      _other ->
        view
    end
  end

  defp apply_fact(view, %{"type" => "decision_accepted"} = fact, _seq, _at) do
    case {fact["occurrence"], fact["choice"]} do
      {occurrence, choice} when is_binary(occurrence) and is_binary(choice) ->
        decision = view.occurrences[occurrence]

        chosen =
          if decision, do: Map.put(view.chosen, decision, choice), else: view.chosen

        %{
          view
          | pending: MapSet.delete(view.pending, occurrence),
            chosen: chosen,
            answers: Map.put(view.answers, occurrence, choice)
        }

      _other ->
        view
    end
  end

  # A run that ended with this occurrence open closed it unanswered; any choice it
  # carries was never accepted, so it routes nothing.
  defp apply_fact(view, %{"type" => "decision_superseded", "occurrence" => occurrence}, _seq, _at)
       when is_binary(occurrence) do
    %{
      view
      | pending: MapSet.delete(view.pending, occurrence),
        superseded: MapSet.put(view.superseded, occurrence)
    }
  end

  defp apply_fact(view, _fact, _seq, _at), do: view

  @spec attempt_key(node :: String.t(), fact :: map()) ::
          {:ok, {String.t(), integer(), integer()}} | :error
  defp attempt_key(node, %{"generation" => generation, "ordinal" => ordinal})
       when is_integer(generation) and is_integer(ordinal),
       do: {:ok, {node, generation, ordinal}}

  defp attempt_key(_node, _fact), do: :error

  @spec update_attempt(view :: t(), fact :: map(), fun :: (attempt() -> attempt())) :: t()
  defp update_attempt(view, fact, fun) do
    with node when is_binary(node) <- subject_node(fact["subject"]),
         {:ok, key} <- attempt_key(node, fact),
         %{} = attempt <- view.attempts[key] do
      %{view | attempts: Map.put(view.attempts, key, fun.(attempt))}
    else
      _other -> view
    end
  end

  # A node's latest attempt decides its status; a skip at a later generation wins.
  @spec node_statuses(view :: t()) :: %{String.t() => status()}
  defp node_statuses(view) do
    latest =
      view.attempts
      |> Map.values()
      |> Enum.group_by(& &1.node)
      |> Map.new(fn {node, attempts} ->
        {node, Enum.max_by(attempts, &{&1.generation, &1.ordinal})}
      end)

    from_attempts = Map.new(latest, fn {node, attempt} -> {node, attempt_status(attempt)} end)

    view.skipped
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(from_attempts, fn {node, generations}, acc ->
      generation = Enum.max(generations)

      case latest[node] do
        %{generation: attempted} when attempted >= generation -> acc
        _older -> Map.put(acc, node, "skipped")
      end
    end)
  end

  # A node's status in one generation: its latest attempt there, else a skip there.
  @spec scope_status(view :: t(), node :: String.t(), generation :: integer()) :: status()
  defp scope_status(view, node, generation) do
    attempts = for {{^node, ^generation, _ordinal}, attempt} <- view.attempts, do: attempt

    cond do
      attempts != [] -> attempts |> Enum.max_by(& &1.ordinal) |> attempt_status()
      MapSet.member?(view.skipped, {node, generation}) -> "skipped"
      true -> "not_executed"
    end
  end

  @spec occurrence_status(view :: t(), occurrence :: String.t()) :: status()
  defp occurrence_status(view, occurrence) do
    case occurrence_state(view, occurrence) do
      :pending -> "needs_you"
      :superseded -> "cancelled"
      :answered -> "succeeded"
    end
  end

  # A decision with no pending occurrence and no choice yet is still being decided. Core
  # supersedes only a pending occurrence of a run that is ending, so that is its last word.
  @spec decision_status(view :: t(), decision :: String.t()) :: status()
  defp decision_status(view, decision) do
    cond do
      Enum.any?(view.pending, &(view.occurrences[&1] == decision)) -> "needs_you"
      Enum.any?(view.superseded, &(view.occurrences[&1] == decision)) -> "cancelled"
      is_map_key(view.chosen, decision) -> "succeeded"
      true -> "running"
    end
  end

  # A stage's status in one generation, from whether it started or finished there and
  # its nodes' statuses there. Nodes it skipped or never reached don't count once one ran;
  # any node that ran with a problem wins, even over one still running, and a started
  # stage otherwise reads running.
  @spec stage_scope_status(run :: :started | :finished | nil, statuses :: [status()]) ::
          status()
  defp stage_scope_status(nil, statuses), do: worst(statuses)

  defp stage_scope_status(run, statuses) do
    ran = Enum.reject(statuses, &(&1 in ~w(not_executed skipped)))
    problems = Enum.reject(ran, &(&1 in ~w(succeeded running)))

    cond do
      problems != [] -> worst(problems)
      run == :started -> "running"
      ran != [] -> worst(ran)
      true -> worst(statuses)
    end
  end

  @spec worst(statuses :: [status()]) :: status()
  defp worst(statuses) do
    Enum.min_by(statuses, fn status -> Enum.find_index(@severity, &(&1 == status)) end)
  end

  # Which card, and which of a decision's choices, each socket belongs to.
  @spec socket_owners(cards :: [map()]) :: %{String.t() => {String.t(), String.t() | nil}}
  defp socket_owners(cards) do
    for card <- cards, {socket, choice} <- card_sockets(card), is_binary(socket), into: %{} do
      {socket, {card.name, choice}}
    end
  end

  @spec card_sockets(card :: map()) :: [{String.t() | nil, String.t() | nil}]
  defp card_sockets(%{kind: _kind} = card) do
    [{card.in_socket, nil}, {card.out_socket, nil}] ++
      Enum.map(card.choices, &{&1.socket, &1.name})
  end

  defp card_sockets(card) do
    rows = card.required ++ card.configured ++ card.unset

    [{card.output_socket, nil}, {card.after_out_socket, nil}, {card.after_in_socket, nil}] ++
      Enum.map(rows, &{&1.socket, nil})
  end

  @spec travelled(
          view :: t(),
          statuses :: %{String.t() => status()},
          from :: {String.t(), String.t() | nil} | nil,
          to :: {String.t(), String.t() | nil} | nil
        ) :: String.t() | nil
  defp travelled(view, statuses, {from, choice}, {to, _target_choice}) do
    left? =
      if choice,
        do: view.chosen[from] == choice,
        else: statuses[from] == "succeeded"

    case {left?, statuses[to]} do
      {false, _status} -> nil
      {true, nil} -> nil
      {true, "running"} -> "running"
      {true, "failed"} -> "failed"
      {true, _reached} -> "succeeded"
    end
  end

  defp travelled(_view, _statuses, _from, _to), do: nil
end
