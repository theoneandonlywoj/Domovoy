defmodule Domovoy.Composer.RunViewTest do
  use Domovoy.RunCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Composer.RunView
  alias Domovoy.Examples.Definitions
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Events
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Run.Transition
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Stage
  alias DomovoyCore.Type
  alias DomovoyCore.Workflow

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp seed(title), do: Enum.find(Definitions.all(), &(&1.title == title)).document

  # Every event of a real run, encoded the way the composer receives them.
  defp events(handle, after_cursor \\ nil) do
    {:ok, page} = Events.read(handle, after: after_cursor)
    encoded = Enum.map(page.events, &Runs.encode_event/1)
    if page.more?, do: encoded ++ events(handle, page.cursor), else: encoded
  end

  defp fold(document, events),
    do: Enum.reduce(events, RunView.new(document), &RunView.apply_event(&2, &1))

  defp run_seed(title, form) do
    document = seed(title)
    {:ok, values} = RunInputs.parse(document, form)
    draft = draft!(document, title)
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    {document, open!(run_id)}
  end

  describe "a real Cracow run" do
    setup do
      form =
        Map.merge(@review_form, %{"floor" => "2", "balcony" => "true", "year_built" => "1995"})

      {document, handle} = run_seed("Cracow house price", form)
      await_phase(handle, "finished")
      %{document: document, events: events(handle)}
    end

    test "every node of the stage, and the stage itself, show succeeded", context do
      view = fold(context.document, context.events)
      nodes = Map.keys(Composer.nodes(context.document, "estimate_price"))

      assert RunView.card_statuses(view, "estimate_price") == Map.new(nodes, &{&1, "succeeded"})
      assert RunView.card_statuses(view, nil) == %{"estimate_price" => "succeeded"}
      assert Enum.sort(RunView.nodes_with(view, "succeeded")) == Enum.sort(nodes)
    end

    test "a replay of the same events adds no attempt", context do
      once = fold(context.document, context.events)
      twice = Enum.reduce(context.events, once, &RunView.apply_event(&2, &1))

      assert twice == once

      assert map_size(once.attempts) ==
               map_size(Composer.nodes(context.document, "estimate_price"))
    end

    test "each attempt keeps the seq and time of its admit and settle", context do
      view = fold(context.document, context.events)

      for {_key, attempt} <- view.attempts do
        assert is_integer(attempt.admitted_seq) and attempt.settled_seq > attempt.admitted_seq
        assert {:ok, _at, _offset} = DateTime.from_iso8601(attempt.admitted_at)
        assert {:ok, _at, _offset} = DateTime.from_iso8601(attempt.settled_at)
      end
    end

    test "a stage's value wires leaving a succeeded node are travelled", context do
      view = fold(context.document, context.events)
      level = Composer.stage_view(context.document, "estimate_price")
      edges = RunView.wire_statuses(view, "estimate_price", level)

      node_edges = Enum.filter(edges, &String.starts_with?(&1.from, "out:normalize_listing"))
      assert node_edges != []
      assert Enum.all?(node_edges, &(&1[:run] == "succeeded"))

      # An input isn't a card, so its wires carry no run status.
      assert Enum.any?(edges, &(not is_map_key(&1, :run)))
    end
  end

  test "a real review run waits on its decision, with the route into it travelled" do
    {document, handle} = run_seed("Cracow house price review", @review_form)
    await_phase(handle, "waiting")
    view = fold(document, events(handle))

    assert RunView.card_statuses(view, nil) == %{
             "estimate_price" => "succeeded",
             "review" => "needs_you"
           }

    edges = RunView.wire_statuses(view, nil, Composer.workflow_view(document))
    [into_review] = Enum.filter(edges, &(&1.to == "after-in:review"))
    assert into_review.run == "succeeded"

    # No choice was taken, so no route out of the decision is travelled.
    assert edges
           |> Enum.filter(&String.starts_with?(&1.from, "choice-out:"))
           |> Enum.all?(&(not is_map_key(&1, :run)))
  end

  test "a review run cancelled while waiting closes its decision unanswered" do
    {document, handle} = run_seed("Cracow house price review", @review_form)
    await_phase(handle, "waiting")
    assert {:ok, %{operation_id: _id}} = Runs.cancel(handle, Ecto.UUID.generate())
    await_phase(handle, "finished")

    events = events(handle)

    assert Enum.any?(events, fn event ->
             Enum.any?(event["facts"], &(&1["type"] == "decision_superseded"))
           end)

    view = fold(document, events)

    assert RunView.card_statuses(view, nil) == %{
             "estimate_price" => "succeeded",
             "review" => "cancelled"
           }

    assert MapSet.size(view.pending) == 0
    assert view.chosen == %{}
  end

  test "a held node is running, then succeeded once released" do
    open_gate()
    document = hold_run()
    draft = draft!(document, "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", runner}, 5_000
    handle = open!(run_id)

    held = fold(document, events(handle))
    assert RunView.card_statuses(held, "main") == %{"hold" => "running"}
    assert RunView.card_statuses(held, nil) == %{"main" => "running"}

    send(runner, :release)
    await_phase(handle, "finished")

    assert RunView.card_statuses(fold(document, events(handle)), "main") == %{
             "hold" => "succeeded"
           }
  end

  # A decider with an effect has attempts of its own, whose subject isn't a node.
  test "a decision's own attempts don't count as a node, and its choice routes on" do
    adapters = Application.fetch_env!(:domovoy, :composer_run_adapters)
    open_gate()

    hold =
      Node.new(%{
        name: "hold",
        runner: Domovoy.PureHoldRunner,
        type: Type.String,
        bind: %{trap_exit: {"trap_exit", Type.Boolean}}
      })

    review =
      Decision.new(%{
        name: "review",
        prompt: "Go on?",
        choices: [Choice.new(%{name: "accept", description: "Finish.", target: :halt})],
        decider: Domovoy.AcceptingDecider
      })

    workflow =
      Workflow.new!(%{
        name: "hand_built",
        vertices: %{
          "main" => Stage.new(%{name: "main", graph: Graph.new([hold]), next: "review"}),
          "review" => review
        },
        start: "main",
        inputs: %{"trap_exit" => %{type: Type.Boolean}},
        journal: adapters[:journal],
        store: adapters[:store]
      })

    {:ok, handle, _receipt} =
      CoreRuns.start(Runs.runtime(), workflow, %{"trap_exit" => false},
        run_id: Ecto.UUID.generate(),
        command_id: "start"
      )

    assert_receive {:entered, "hold", runner}, 5_000
    send(runner, :release)
    await_phase(handle, "finished")

    events = events(handle)

    subjects =
      for event <- events, fact <- event["facts"], is_binary(fact["subject"]), do: fact["subject"]

    assert Enum.any?(subjects, &String.starts_with?(&1, "decision:"))

    # The snapshot a composer would hold for this workflow.
    document =
      edit_all(Composer.Document.new("hand_built"), [
        {:put_input, "trap_exit", %{"type" => "DomovoyCore.Type.Boolean"}},
        {:add_node, "main", "Domovoy.PureHoldRunner", "hold"},
        {:add_decision, "review"},
        {:set_next, "main", "review"}
      ])

    view = fold(document, events)

    assert RunView.card_statuses(view, "main") == %{"hold" => "succeeded"}
    assert RunView.card_statuses(view, nil) == %{"main" => "succeeded", "review" => "succeeded"}
    assert view.chosen == %{"review" => "accept"}
    assert RunView.nodes_with(view, "succeeded") == ["hold"]
  end

  describe "evidence and results" do
    @stage "estimate_price"

    # One attempt of a node at a generation, admitted then settled.
    defp attempt(seq, node, generation, outcome) do
      fact = %{"subject" => "node:#{node}", "generation" => generation, "ordinal" => 1}

      [
        %{"seq" => seq, "facts" => [Map.put(fact, "type", "attempt_admitted")]},
        %{
          "seq" => seq + 1,
          "facts" => [Map.merge(fact, %{"type" => "attempt_settled", "outcome" => outcome})]
        }
      ]
    end

    # Generation 0 ran estimate and area_model; generation 1 reran estimate, and
    # area_model failed there; normalize never ran. Review was asked at generation 1.
    defp evidence_fold(document, asked? \\ true) do
      pending = %{
        "seq" => 20,
        "facts" => [
          %{
            "type" => "decision_pending",
            "occurrence" => "o1",
            "decision" => "review",
            "generation" => 1
          }
        ]
      }

      events =
        attempt(1, "join_price_terms", 0, "succeeded") ++
          attempt(3, "area_model", 0, "succeeded") ++
          attempt(5, "join_price_terms", 1, "succeeded") ++
          attempt(7, "area_model", 1, "failed") ++ if(asked?, do: [pending], else: [])

      fold(document, events)
    end

    defp evidence_document do
      refs =
        for node <- ~w(join_price_terms area_model normalize_listing),
            do: %{"stage" => @stage, "node" => node}

      edit_all(seed("Cracow house price review"), [{:put_evidence, "review", refs}])
    end

    test "evidence_generation/3 is the same generation, the newest earlier one, or none" do
      view = evidence_fold(evidence_document())

      assert RunView.evidence_generation(view, {@stage, "join_price_terms"}, 1) == {:same, 1}
      assert RunView.evidence_generation(view, {@stage, "area_model"}, 1) == {:from, 0}
      assert RunView.evidence_generation(view, {@stage, "area_model"}, 0) == {:same, 0}
      assert RunView.evidence_generation(view, {@stage, "normalize_listing"}, 1) == nil
      assert RunView.evidence_generation(view, {"other", "join_price_terms"}, 1) == nil
    end

    test "evidence/4 reads the occurrence's generation, else Core's after a resync" do
      document = evidence_document()
      status = %{awaiting: [%{occurrence: "o1", decision: "review"}], generation: 1}

      expected = [
        %{stage: @stage, node: "area_model", shown: {:from, 0}},
        %{stage: @stage, node: "join_price_terms", shown: {:same, 1}},
        %{stage: @stage, node: "normalize_listing", shown: nil}
      ]

      assert RunView.evidence(evidence_fold(document), document, status, "review") == expected

      assert RunView.evidence(evidence_fold(document, false), document, status, "review") ==
               expected

      assert RunView.evidence(evidence_fold(document), document, %{awaiting: []}, "review") == []
      assert RunView.evidence(evidence_fold(document), document, status, "estimate_price") == []
    end

    test "results/2 lists settled nodes at their latest generation" do
      document = evidence_document()

      assert [
               %{node: "area_model", generation: 1, status: "failed", store?: true},
               %{node: "join_price_terms", generation: 1, status: "succeeded"}
             ] = RunView.results(evidence_fold(document), document)
    end
  end

  describe "scope_statuses/3" do
    @stage "estimate_price"

    defp fact_event(seq, fact), do: %{"seq" => seq, "facts" => [fact]}

    defp settled(seq, node, generation, outcome) do
      fact = %{"subject" => "node:#{node}", "generation" => generation, "ordinal" => 1}

      [
        fact_event(seq, Map.put(fact, "type", "attempt_admitted")),
        fact_event(seq + 1, Map.merge(fact, %{"type" => "attempt_settled", "outcome" => outcome}))
      ]
    end

    defp stage_fact(seq, type, generation),
      do: fact_event(seq, %{"type" => type, "stage" => @stage, "generation" => generation})

    # Generation 0 ran every node; generation 1 reran estimate, skipped area_model and
    # left the rest unrun. Generation 2's stage has started with no attempt yet.
    defp scoped_fold do
      document = seed("Cracow house price review")
      gen0 = ~w(normalize_listing area_model layout_model location_model join_price_terms)

      events =
        [stage_fact(1, "stage_started", 0)] ++
          (gen0
           |> Enum.with_index()
           |> Enum.flat_map(fn {node, i} -> settled(10 + 2 * i, node, 0, "succeeded") end)) ++
          [
            stage_fact(30, "stage_finished", 0),
            fact_event(31, %{
              "type" => "decision_pending",
              "occurrence" => "o0",
              "decision" => "review",
              "generation" => 0
            }),
            fact_event(32, %{
              "type" => "decision_accepted",
              "occurrence" => "o0",
              "choice" => "revise"
            }),
            stage_fact(33, "stage_started", 1)
          ] ++
          settled(40, "join_price_terms", 1, "succeeded") ++
          [
            fact_event(42, %{
              "type" => "node_skipped",
              "subject" => "node:area_model",
              "generation" => 1
            }),
            stage_fact(43, "stage_finished", 1),
            stage_fact(44, "stage_started", 1),
            stage_fact(45, "stage_started", 2)
          ]

      fold(document, events)
    end

    test "nodes with no attempt in a generation are not executed there" do
      view = scoped_fold()

      assert RunView.scope_statuses(view, @stage, 1) == %{
               "join_price_terms" => "succeeded",
               "area_model" => "skipped",
               "normalize_listing" => "not_executed",
               "layout_model" => "not_executed",
               "location_model" => "not_executed"
             }

      assert RunView.scope_statuses(view, @stage, 0) ==
               Map.new(
                 ~w(normalize_listing area_model layout_model location_model join_price_terms),
                 &{&1, "succeeded"}
               )

      # The latest view still shows generation 0's successes, which scope 1 never reports.
      assert RunView.card_statuses(view, @stage)["normalize_listing"] == "succeeded"
    end

    test "the workflow shows each stage's worst node that ran, and each decision asked there" do
      view = scoped_fold()

      assert view.stage_runs == %{
               {@stage, 0} => :finished,
               {@stage, 1} => :finished,
               {@stage, 2} => :started
             }

      assert RunView.scope_statuses(view, nil, 0) == %{
               @stage => "succeeded",
               "review" => "succeeded"
             }

      # Generation 1 ran estimate and skipped area_model; the rest never ran there.
      assert RunView.scope_statuses(view, nil, 1) == %{
               @stage => "succeeded",
               "review" => "not_executed"
             }

      assert RunView.scope_statuses(view, nil, 2) == %{
               @stage => "running",
               "review" => "not_executed"
             }

      assert RunView.scope_statuses(view, nil, 3) == %{
               @stage => "not_executed",
               "review" => "not_executed"
             }

      # A stage still going reads running after a success, but not after a failure.
      succeeded =
        Enum.reduce(
          settled(50, "normalize_listing", 2, "succeeded"),
          view,
          &RunView.apply_event(&2, &1)
        )

      assert RunView.scope_statuses(succeeded, nil, 2)[@stage] == "running"

      failed =
        Enum.reduce(
          settled(50, "normalize_listing", 2, "failed"),
          view,
          &RunView.apply_event(&2, &1)
        )

      assert RunView.scope_statuses(failed, nil, 2)[@stage] == "failed"
    end

    test "a stage still going reads running only while its nodes succeed or run" do
      view = scoped_fold()
      apply_all = fn events, view -> Enum.reduce(events, view, &RunView.apply_event(&2, &1)) end

      # Nothing attempted yet at generation 2.
      assert RunView.scope_statuses(view, nil, 2)[@stage] == "running"

      for outcome <- ~w(interrupted cancelled) do
        settled_view = apply_all.(settled(50, "normalize_listing", 2, outcome), view)
        assert RunView.scope_statuses(settled_view, nil, 2)[@stage] == outcome
      end

      uncertain =
        apply_all.(
          [
            fact_event(50, %{
              "type" => "attempt_admitted",
              "subject" => "node:normalize_listing",
              "generation" => 2,
              "ordinal" => 1
            }),
            fact_event(51, %{
              "type" => "uncertainty_recorded",
              "uncertainty" => "u1",
              "subject" => "node:normalize_listing",
              "generation" => 2,
              "ordinal" => 1
            })
          ],
          view
        )

      assert RunView.scope_statuses(uncertain, nil, 2)[@stage] == "uncertain"

      running =
        apply_all.(
          settled(50, "normalize_listing", 2, "succeeded") ++
            [
              fact_event(52, %{
                "type" => "attempt_admitted",
                "subject" => "node:join_price_terms",
                "generation" => 2,
                "ordinal" => 1
              })
            ],
          view
        )

      assert RunView.scope_statuses(running, nil, 2)[@stage] == "running"
    end

    test "a stage still going never reads running while a node that ran has a problem" do
      view = scoped_fold()
      apply_all = fn events, view -> Enum.reduce(events, view, &RunView.apply_event(&2, &1)) end

      estimate_running =
        fact_event(60, %{
          "type" => "attempt_admitted",
          "subject" => "node:join_price_terms",
          "generation" => 2,
          "ordinal" => 1
        })

      # An outcome this release doesn't know folds to "unknown".
      for {outcome, status} <- [
            {"interrupted", "interrupted"},
            {"cancelled", "cancelled"},
            {"lost", "unknown"}
          ] do
        mixed =
          apply_all.(settled(50, "normalize_listing", 2, outcome) ++ [estimate_running], view)

        assert RunView.scope_statuses(mixed, nil, 2)[@stage] == status
      end

      uncertain =
        apply_all.(
          [
            fact_event(50, %{
              "type" => "attempt_admitted",
              "subject" => "node:normalize_listing",
              "generation" => 2,
              "ordinal" => 1
            }),
            fact_event(51, %{
              "type" => "uncertainty_recorded",
              "uncertainty" => "u1",
              "subject" => "node:normalize_listing",
              "generation" => 2,
              "ordinal" => 1
            }),
            estimate_running
          ],
          view
        )

      assert RunView.scope_statuses(uncertain, nil, 2)[@stage] == "uncertain"
    end

    test "a skip at an older generation no longer wins once the node runs again" do
      view = scoped_fold()
      assert RunView.card_statuses(view, @stage)["area_model"] == "skipped"

      view =
        Enum.reduce(settled(50, "area_model", 2, "succeeded"), view, &RunView.apply_event(&2, &1))

      assert RunView.card_statuses(view, @stage)["area_model"] == "succeeded"
      assert RunView.scope_statuses(view, @stage, 1)["area_model"] == "skipped"
    end
  end

  describe "subject_node/1" do
    test "normalises a node subject and nothing else" do
      assert RunView.subject_node("node:join_price_terms") == "join_price_terms"
      assert RunView.subject_node("decision:review@0#1") == nil
      assert RunView.subject_node("node:") == nil
      assert RunView.subject_node(nil) == nil
      assert RunView.subject_node(%{"a" => 1}) == nil
    end
  end

  describe "an event that doesn't fit" do
    test "changes nothing and makes no atom" do
      view = RunView.new(hold_run())
      name = "run_view_atom_#{System.unique_integer([:positive])}"

      for event <- [
            %{},
            %{"seq" => "1"},
            %{"seq" => 1, "facts" => "x"},
            %{"seq" => 1, "facts" => [%{"type" => name, "subject" => "node:hold"}]},
            %{"seq" => 1, "facts" => [%{"type" => "attempt_admitted", "subject" => 1}]},
            %{"seq" => 1, "facts" => [%{"type" => "attempt_settled", "subject" => "node:hold"}]}
          ] do
        assert %RunView{attempts: attempts} = RunView.apply_event(view, event)
        assert attempts == %{}
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "controls/1 and phase/1" do
    defp status(fields),
      do: Map.merge(%{phase: nil, committed_phase: "running", owner_live?: true}, fields)

    test "a frozen run shows only Recover" do
      for phase <- ~w(starting resuming running pausing stopping cancelling finishing) do
        frozen = status(%{committed_phase: phase, owner_live?: false})
        assert RunView.frozen?(frozen), phase
        assert RunView.controls(frozen) == [:recover], phase
      end
    end

    test "a finished run, and one already ending, show nothing" do
      assert RunView.controls(status(%{committed_phase: "finished", owner_live?: false})) == []
      assert RunView.controls(status(%{phase: "cancelling", committed_phase: "running"})) == []
      assert RunView.controls(status(%{phase: "finishing", committed_phase: "running"})) == []
    end

    test "a live run offers Stop, Cancel and Pause, a stopped one Resume first, a stopping one Cancel" do
      assert RunView.controls(status(%{phase: "running"})) == [:stop, :cancel, :pause]

      assert RunView.controls(status(%{committed_phase: "waiting", owner_live?: false})) == [
               :stop,
               :cancel,
               :pause
             ]

      assert RunView.controls(status(%{committed_phase: "stopped", owner_live?: false})) == [
               :resume,
               :cancel
             ]

      assert RunView.controls(status(%{committed_phase: "stopping"})) == [:cancel]
      assert RunView.controls(status(%{committed_phase: "teleporting"})) == []
      assert RunView.controls(nil) == []
    end

    test "a pausing run can't pause again, and a paused one offers Unpause first" do
      assert RunView.controls(status(%{committed_phase: "pausing"})) == [:stop, :cancel]

      assert RunView.controls(status(%{committed_phase: "paused", owner_live?: false})) == [
               :unpause,
               :stop,
               :cancel
             ]
    end

    # Core's `:unblock` and `:reconcile` cells depend on more than the phase.
    test "a blocked run offers Unpause after a pause timeout and Reconcile for an uncertain effect" do
      blocked = &status(%{committed_phase: "blocked", block_reason: &1, owner_live?: false})

      assert RunView.controls(blocked.("pause_timeout")) == [:unpause, :stop, :cancel]
      assert RunView.controls(blocked.("effect_uncertain")) == [:reconcile, :stop, :cancel]
      assert RunView.controls(blocked.(nil)) == [:stop, :cancel]
      refute :pause in RunView.controls(blocked.("effect_uncertain"))

      # Excluded: Core takes a reconcile in other phases too, but an unresolved effect
      # there blocks the run before it goes on, so it is offered once blocked only.
      for phase <- ~w(running waiting paused stopped finished) do
        uncertain = status(%{committed_phase: phase, uncertainties: ["u"]})
        refute :reconcile in RunView.controls(uncertain), phase
      end
    end

    test "uncertainties/2 places each one Core lists on the attempt the fold saw" do
      fold =
        RunView.apply_event(%RunView{stages: %{"hold" => "main"}}, %{
          "seq" => 3,
          "facts" => [
            %{
              "type" => "uncertainty_recorded",
              "uncertainty" => "node:hold@0#1",
              "subject" => "node:hold",
              "generation" => 0,
              "ordinal" => 1
            }
          ]
        })

      assert RunView.uncertainties(fold, %{uncertainties: ["node:hold@0#1", "unseen"]}) == [
               %{id: "node:hold@0#1", node: "hold", stage: "main", generation: 0, ordinal: 1},
               %{id: "unseen", node: nil, stage: nil, generation: nil, ordinal: nil}
             ]

      assert RunView.uncertainties(fold, %{uncertainties: []}) == []
      assert RunView.uncertainties(fold, nil) == []
    end

    # Core's command matrix is internal (CORE_CHANGES.md, gap K), so a change to it shows
    # here first.
    test "every command offered is one Core accepts, and every one it always accepts is offered" do
      offered = ~w(stop resume cancel pause unpause)a
      # Unconditional rules only: :unblock and :reconcile depend on more than the phase,
      # so they have their own tests above.
      accepting? = fn rule ->
        match?({kind, _} when kind in [:to, :to_superseding], rule) or rule == :same
      end

      for {phase, rules} <- Transition.matrix(), command <- offered do
        live = status(%{committed_phase: Atom.to_string(phase), owner_live?: true})
        shown? = command in RunView.controls(live)
        rule = rules[command]

        if shown?, do: assert(accepting?.(rule), "#{phase} offers #{command}: #{inspect(rule)}")
        if accepting?.(rule), do: assert(shown?, "#{phase} hides #{command}: #{inspect(rule)}")
      end
    end

    test "a committed wait for a person reads waiting while the owner still observes running" do
      status = %{
        phase: "running",
        committed_phase: "waiting",
        awaiting: [%{decision: "review", occurrence: "o1"}],
        owner_live?: true
      }

      assert RunView.phase(status) == "waiting"
    end

    test "the phase shown is the committed one, else the owner's, and an unknown one is unknown" do
      assert RunView.phase(status(%{phase: "running", committed_phase: "stopping"})) ==
               "stopping"

      assert RunView.phase(%{phase: "waiting", committed_phase: nil}) == "waiting"
      assert RunView.phase(status(%{committed_phase: "teleporting"})) == "unknown"
    end
  end
end
