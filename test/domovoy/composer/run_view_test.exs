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

      node_edges = Enum.filter(edges, &String.starts_with?(&1.from, "out:normalize"))
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
    assert :ok = Runs.cancel(handle)
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

  describe "subject_node/1" do
    test "normalises a node subject and nothing else" do
      assert RunView.subject_node("node:estimate") == "estimate"
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

    test "anything else shows Cancel, including a run waiting without an owner" do
      assert RunView.controls(status(%{phase: "running"})) == [:cancel]

      assert RunView.controls(status(%{committed_phase: "waiting", owner_live?: false})) == [
               :cancel
             ]

      assert RunView.controls(status(%{committed_phase: "stopped", owner_live?: false})) == [
               :cancel
             ]
    end

    test "the phase shown is the owner's, else the committed one, and an unknown one is unknown" do
      assert RunView.phase(status(%{phase: "waiting"})) == "waiting"
      assert RunView.phase(status(%{phase: nil, committed_phase: "stopped"})) == "stopped"
      assert RunView.phase(status(%{phase: "teleporting"})) == "unknown"
    end
  end
end
