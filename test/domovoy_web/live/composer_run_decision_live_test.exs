defmodule DomovoyWeb.ComposerRunDecisionLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  import Domovoy.RunCase,
    only: [
      setup_runs: 1,
      start_attrs: 2,
      open!: 1,
      await_phase: 2,
      await_fact: 2,
      asked: 1,
      watch: 1,
      await_delivered: 1,
      entered: 1
    ]

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Examples.Definitions
  alias DomovoyCore.Events

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp seed(title), do: Enum.find(Definitions.all(), &(&1.title == title)).document

  # A review run waiting at its decision, with the occurrence it awaits.
  defp start_review(document \\ seed("Cracow house price review")) do
    {:ok, values} = RunInputs.parse(document, @review_form)
    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    view = await_phase(handle, "waiting")
    [%{occurrence: occurrence, decision: "review"}] = view.awaiting
    %{draft: draft, run_id: run_id, handle: handle, occurrence: occurrence}
  end

  defp open_run(conn, path) do
    {:ok, view, _html} = live(conn, path)
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &(map_size(&1.occurrences) > 0))
    render(view)
    view
  end

  # The page may have folded its replay before the watch began, so its state is read
  # first, and only then is a later delivery awaited.
  defp await_folded(view, fun) do
    %{socket: %{assigns: %{run: run}}} = :sys.get_state(view.pid)

    if fun.(run.fold) do
      :ok
    else
      assert_receive {:trace, _pid, :receive, {:domovoy_events, _subscription, _message}}, 5_000
      await_folded(view, fun)
    end
  end

  defp open_review(conn, run) do
    view = open_run(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
    view |> element("#vertex-review-select") |> render_click()
    view
  end

  # Every event of a run, as Core's public history holds it.
  defp facts(handle, type) do
    {:ok, page} = Events.read(handle, limit: 1_000)
    for envelope <- page.events, %{"type" => ^type} = fact <- envelope.facts, do: fact
  end

  defp estimate_output(view, generation) do
    view |> element("#run-generation-#{generation}") |> render_click()
    render_async(view, 5_000)
    view |> element("#run-output") |> render()
  end

  defp open_estimate(view, run) do
    render_patch(view, ~p"/composer/#{run.draft.id}/stages/estimate_price?run=#{run.run_id}")
    view |> element("#node-estimate-select") |> render_click()
    render_async(view, 5_000)
    view
  end

  describe "answering" do
    test "accept finishes the run succeeded and shows the choice", %{conn: conn} do
      run = start_review()
      view = open_review(conn, run)

      assert has_element?(view, "#decision-form-review #decide-accept")
      assert has_element?(view, "#decide-choice-accept", "Finishes the run")
      assert has_element?(view, "#decide-choice-revise", "Runs estimate_price again")
      assert has_element?(view, "#decide-choice-revise", "Leave blank to keep the earlier value")
      refute has_element?(view, "#decision-stopped-note")

      view |> form("#decide-accept") |> render_submit()
      await_delivered(entered("finished"))

      assert has_element?(view, "#run-outcome", "succeeded")
      assert has_element?(view, "#run-occurrence-0-choice", "accept")
      refute has_element?(view, "#decision-form-review")
      assert [%{"choice" => "accept"}] = facts(run.handle, "decision_accepted")
    end

    test "revise with Kazimierz reruns estimate_price, and both generations stay readable",
         %{conn: conn} do
      run = start_review()
      view = open_review(conn, run)

      view |> form("#decide-revise", inputs: %{district: "Kazimierz"}) |> render_submit()
      assert %{generation: 1} = await_fact(run.handle, asked(1))
      await_delivered(asked(1))

      open_estimate(view, run)
      assert has_element?(view, "#run-generation-0")
      assert has_element?(view, "#run-generation-1[aria-pressed='true']")

      revised = estimate_output(view, 1)
      first = estimate_output(view, 0)
      assert has_element?(view, "#run-generation-0[aria-pressed='true']")
      assert revised != first
    end

    test "a blank rerun input isn't sent, so the rerun keeps the earlier district",
         %{conn: conn} do
      run = start_review()
      view = open_review(conn, run)

      view |> form("#decide-revise", inputs: %{district: ""}) |> render_submit()
      await_fact(run.handle, asked(1))
      await_delivered(asked(1))

      open_estimate(view, run)
      assert estimate_output(view, 1) == estimate_output(view, 0)
    end
  end

  describe "a stopped run" do
    # Stop is pressed on the page, as a person would, and the page waits for it to land.
    defp stop(conn, run) do
      view = open_review(conn, run)
      view |> element("#stop-run") |> render_click()
      render_async(view, 5_000)
      await_phase(run.handle, "stopped")
      await_delivered(entered("stopped"))
      render(view)
      view
    end

    test "shows the form with what follows, and accept finishes it with no Resume",
         %{conn: conn} do
      run = start_review()
      view = stop(conn, run)

      assert has_element?(view, "#resume-run")
      assert has_element?(view, "#decision-form-review")

      assert has_element?(
               view,
               "#decision-stopped-note",
               "Accept finishes it now. Revise runs when you press Resume run."
             )

      view |> form("#decide-accept") |> render_submit()

      assert %{committed_phase: "finished", outcome: "succeeded"} =
               await_phase(run.handle, "finished")

      await_delivered(entered("finished"))
      refute has_element?(view, "#resume-run")

      assert facts(run.handle, "operation_accepted")
             |> Enum.map(& &1["command"])
             |> Enum.reject(&(&1 in ["stop", "decide", "start"])) == []
    end

    test "revise is recorded and the run stays stopped until Resume run", %{conn: conn} do
      run = start_review()
      view = stop(conn, run)

      view |> form("#decide-revise", inputs: %{district: "Kazimierz"}) |> render_submit()

      assert has_element?(view, "#run-phase", "stopped")
      assert has_element?(view, "#resume-run")
      assert has_element?(view, "#run-status", "Resume run continues it from its checkpoint")
      assert [%{"choice" => "revise"}] = facts(run.handle, "decision_accepted")
      assert {:ok, %{committed_phase: "stopped"}} = Composer.run_view(run.handle)

      view |> element("#resume-run") |> render_click()
      render_async(view, 5_000)
      assert %{committed_phase: "waiting", generation: 1} = await_fact(run.handle, asked(1))
    end
  end

  describe "refusals" do
    test "a doubled and a stale answer commit one answer and refresh the view",
         %{conn: conn} do
      run = start_review()
      first = open_review(conn, run)
      second = open_review(conn, run)

      params = %{"occurrence" => run.occurrence, "choice" => "accept", "inputs" => %{}}
      render_hook(first, "decide", params)
      render_hook(first, "decide", params)
      await_phase(run.handle, "finished")

      # The other tab still answers the occurrence it was shown.
      render_hook(second, "decide", %{params | "choice" => "revise"})

      assert has_element?(second, "#rejection-core-id")
      assert has_element?(second, "#run-phase", "finished")
      assert [%{"choice" => "accept"}] = facts(run.handle, "decision_accepted")
    end

    test "forged choices, occurrences and inputs change nothing, and the run keeps waiting",
         %{conn: conn} do
      run = start_review()
      view = open_review(conn, run)

      for params <- [
            %{"occurrence" => run.occurrence, "choice" => "nope", "inputs" => %{}},
            %{"occurrence" => "forged", "choice" => "accept", "inputs" => %{}},
            %{"occurrence" => run.occurrence, "choice" => "accept", "inputs" => %{"x" => "1"}},
            %{"occurrence" => run.occurrence, "choice" => "accept", "inputs" => "text"}
          ] do
        render_hook(view, "decide", params)
        assert has_element?(view, "#rejection-message", "doesn't fit")
        assert has_element?(view, "#run-phase", "waiting")
      end

      # Core itself refuses an input the choice doesn't declare.
      assert {:error, {:refused, _type}} =
               Composer.decide_run(run.handle, run.occurrence, "accept", %{"district" => "x"})

      assert {:ok, %{committed_phase: "waiting"}} = Composer.run_view(run.handle)
      assert facts(run.handle, "decision_accepted") == []
    end

    test "a rerun past max_generations is refused", %{conn: conn} do
      run = start_review()

      last =
        Enum.reduce(1..10, run.occurrence, fn generation, occurrence ->
          :ok = Composer.decide_run(run.handle, occurrence, "revise", %{})
          %{awaiting: [%{occurrence: next}]} = await_fact(run.handle, asked(generation))
          next
        end)

      view = open_review(conn, run)
      render_hook(view, "decide", %{"occurrence" => last, "choice" => "revise", "inputs" => %{}})
      assert has_element?(view, "#rejection-core-id", "rerun_limit")

      assert has_element?(
               view,
               "#rejection-message",
               "This run can't create another generation. Start a new run instead."
             )

      assert has_element?(view, "#new-run")
      assert {:ok, %{committed_phase: "waiting", generation: 10}} = Composer.run_view(run.handle)
    end
  end

  describe "evidence" do
    # The review seed after an `intake` stage, which a revise doesn't rerun, with
    # intake's `note` and estimate_price's `estimate` as review's evidence.
    defp evidence_review do
      refs = [
        %{"stage" => "intake", "node" => "note"},
        %{"stage" => "estimate_price", "node" => "estimate"}
      ]

      edit_all(seed("Cracow house price review"), [
        {:add_stage, "intake"},
        {:add_node, "intake", "Domovoy.LeakRunner", "note"},
        {:set_literal, "intake", "note", "secret", "intake note", replace_binding: false},
        {:set_literal, "intake", "note", "mode", "succeed", replace_binding: false},
        {:set_next, "intake", "estimate_price"},
        {:set_start, "intake"},
        {:put_evidence, "review", refs}
      ])
    end

    test "shows beside the choices at the pending generation, or the one it last ran at",
         %{conn: conn} do
      run = start_review(evidence_review())
      view = open_review(conn, run)
      render_async(view, 5_000)

      assert has_element?(view, "#decision-evidence-estimate-generation", "Generation 0")
      assert has_element?(view, "#decision-evidence-note-generation", "Generation 0")

      view |> form("#decide-revise", inputs: %{district: "Kazimierz"}) |> render_submit()
      await_fact(run.handle, asked(1))
      await_delivered(asked(1))
      render_async(view, 5_000)

      assert has_element?(view, "#decision-form-review #decision-evidence")
      assert has_element?(view, "#decision-evidence-estimate-generation", "Generation 1")
      assert has_element?(view, "#decision-evidence-estimate #decision-evidence-estimate-output")
      assert has_element?(view, "#decision-evidence-note-generation", "from generation 0")
      assert has_element?(view, "#decision-evidence-note-output", "intake note")

      # The estimate shown is generation 1's, which the revise changed.
      seq = settled_seq(view, "estimate", 1)
      assert %{output: %{text: revised}} = Composer.run_record(run.handle, "estimate", 1, seq)
      shown = revised |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      assert view |> element("#decision-evidence-estimate-output") |> render() =~ shown
    end

    test "is read again after a resync brings the decision back", %{conn: conn} do
      run = start_review(evidence_review())
      view = open_review(conn, run)
      render_async(view, 5_000)
      assert has_element?(view, "#decision-evidence-estimate-output")

      # A status from before the decision was pending, so nothing of its evidence is held.
      :sys.replace_state(view.pid, fn state ->
        update_in(
          state.socket.assigns.run,
          &%{&1 | reads: %{}, status: %{&1.status | awaiting: []}}
        )
      end)

      %{socket: %{assigns: %{run: %{sub: sub}}}} = :sys.get_state(view.pid)
      send(view.pid, {:domovoy_events, sub, {:closed, %{type: :resync_required}}})
      render_async(view, 5_000)

      # Both evidence results are read again, not left to the next run event.
      %{socket: %{assigns: %{run: %{reads: reads}}}} = :sys.get_state(view.pid)
      assert [_estimate, _note] = Enum.filter(Map.values(reads), &(&1.state == :stored))
      assert has_element?(view, "#run-fold-stale")
      assert has_element?(view, "#decision-evidence-estimate-output")
      assert has_element?(view, "#decision-evidence-note-output", "intake note")
    end
  end

  defp settled_seq(view, node, generation) do
    %{socket: %{assigns: %{run: %{fold: fold}}}} = :sys.get_state(view.pid)

    Enum.find_value(fold.attempts, fn
      {{^node, ^generation, _ordinal}, %{settled_seq: seq}} -> seq
      _other -> nil
    end)
  end

  test "a decision pending inside a stage links to the workflow level with it open",
       %{conn: conn} do
    run = start_review()
    view = open_run(conn, ~p"/composer/#{run.draft.id}/stages/estimate_price?run=#{run.run_id}")

    view |> element("#run-pending-link-review") |> render_click()
    path = assert_patch(view)

    assert path =~ "node=review"
    assert has_element?(view, "#run-selected-name", "review")
    assert has_element?(view, "#decision-form-review")
  end

  test "an automatic decider's choice shows read-only, with no form", %{conn: conn} do
    draft = draft!(route_run(), "Route")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"branch_name" => "feature/x"}))
    assert %{outcome: "succeeded"} = await_phase(open!(run_id), "finished")

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{run_id}&node=route")
    watch(view.pid)
    render_async(view, 5_000)
    await_delivered(&(&1["type"] == "decision_accepted"))

    assert has_element?(view, "#run-decision-automatic")
    assert has_element?(view, "#run-occurrence-0-choice", "create")
    refute has_element?(view, "#decision-form-route")
    refute has_element?(view, "form[phx-submit='decide']")
  end

  test "an automatic decider reads the node its options name, whatever it's called" do
    draft = draft!(route_run("look_up_worktree"), "Route")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"branch_name" => "feature/x"}))
    assert %{outcome: "succeeded"} = await_phase(open!(run_id), "finished")
  end
end
