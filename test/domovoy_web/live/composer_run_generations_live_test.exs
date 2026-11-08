defmodule DomovoyWeb.ComposerRunGenerationsLiveTest do
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
      watch: 1
    ]

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.RunView
  alias Domovoy.Examples.Definitions

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  @nodes ~w(normalize area_model layout_model location_model estimate)

  # A review run revised once, so generation 1 is asked; finished, it is accepted there.
  defp revised_run(finish? \\ false) do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
    {:ok, values} = RunInputs.parse(document, @review_form)
    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    %{awaiting: [%{occurrence: first}]} = await_phase(handle, "waiting")
    :ok = Composer.decide_run(handle, first, "revise", %{})
    %{awaiting: [%{occurrence: second}]} = await_fact(handle, asked(1))

    if finish? do
      :ok = Composer.decide_run(handle, second, "accept", %{})
      await_phase(handle, "finished")
    end

    %{draft: draft, run_id: run_id}
  end

  # Opens a page and waits until it has folded both generations' decisions.
  defp open_page(conn, path) do
    {:ok, view, _html} = live(conn, path)
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &(map_size(&1.occurrences) == 2))
    render(view)
    view
  end

  defp await_folded(view, fun) do
    %{socket: %{assigns: %{run: run}}} = :sys.get_state(view.pid)

    if fun.(run.fold) do
      :ok
    else
      assert_receive {:trace, _pid, :receive, {:domovoy_events, _subscription, _message}}, 5_000
      await_folded(view, fun)
    end
  end

  defp run_assign(view) do
    %{socket: %{assigns: %{run: run, selected: selected}}} = :sys.get_state(view.pid)
    {run, selected}
  end

  defp stage_path(run, query),
    do: ~p"/composer/#{run.draft.id}/stages/estimate_price?#{[run: run.run_id] ++ query}"

  test "a graph scope older than the pending occurrence shows no decision form",
       %{conn: conn} do
    run = revised_run()
    view = open_page(conn, ~p"/composer/#{run.draft.id}?#{[run: run.run_id, scope: 0]}")
    view |> element("#vertex-review-select") |> render_click()

    refute has_element?(view, "#decision-form-review")
    assert has_element?(view, "#decision-history-note", "generation 0")
    assert has_element?(view, "#generation-scope-0[aria-pressed='true']")

    view |> element("#decision-history-latest") |> render_click()
    assert_patch(view, ~p"/composer/#{run.draft.id}?#{[run: run.run_id, node: "review"]}")
    refute has_element?(view, "#decision-history-note")
    assert has_element?(view, "#decision-form-review #decide-accept")

    # The current generation's scope answers, as latest does.
    view |> element("#generation-scope-1") |> render_click()
    assert has_element?(view, "#decision-form-review #decide-accept")
  end

  test "the inspector's generation leaves the graph at latest", %{conn: conn} do
    run = revised_run()
    view = open_page(conn, stage_path(run, node: "estimate", gen: 0))

    assert has_element?(
             view,
             "#run-scope-label",
             "Showing estimate from generation 0; graph shows latest"
           )

    assert has_element?(view, "#run-generation-0[aria-pressed='true']")
    assert has_element?(view, "#generation-scope-latest[aria-pressed='true']")

    {run_state, _selected} = run_assign(view)
    latest = RunView.card_statuses(run_state.fold, "estimate_price")
    assert map_size(latest) == length(@nodes)

    for {node, status} <- latest do
      assert has_element?(view, "#node-#{node}[data-run-status='#{status}']")
    end
  end

  test "a graph scope marks each node in that generation", %{conn: conn} do
    run = revised_run()
    view = open_page(conn, stage_path(run, []))
    {run_state, _selected} = run_assign(view)

    # Generation 2 isn't reached, so only 0 and 1 are offered.
    refute has_element?(view, "#generation-scope-2")
    view |> element("#generation-scope-1") |> render_click()
    assert_patch(view, stage_path(run, scope: 1))

    for {node, status} <- RunView.scope_statuses(run_state.fold, "estimate_price", 1) do
      assert has_element?(view, "#node-#{node}[data-run-status='#{status}']")
    end
  end

  test "a stage's Open link and the Workflow breadcrumb keep the graph scope", %{conn: conn} do
    run = revised_run()
    view = open_page(conn, ~p"/composer/#{run.draft.id}?#{[run: run.run_id, scope: 0]}")

    view |> element("#vertex-estimate_price-open") |> render_click()
    assert_patch(view, stage_path(run, scope: 0))
    assert {%{scope: 0}, nil} = run_assign(view)

    view |> element("#breadcrumb-workflow") |> render_click()
    assert_patch(view, ~p"/composer/#{run.draft.id}?#{[run: run.run_id, scope: 0]}")
  end

  test "a scope on a run still at generation 0 is ignored, since it has no scope control",
       %{conn: conn} do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
    {:ok, values} = RunInputs.parse(document, @review_form)
    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "waiting")

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?#{[run: run_id, scope: 0]}")
    render_async(view, 5_000)

    refute has_element?(view, "#generation-scope-0")
    assert {%{scope: :latest}, nil} = run_assign(view)
  end

  test "a refresh keeps node, gen and scope", %{conn: conn} do
    run = revised_run()
    view = open_page(conn, stage_path(run, node: "estimate", gen: 1, scope: 1))

    assert {%{generation: {"estimate", 1}, scope: 1}, "estimate"} = run_assign(view)
    assert has_element?(view, "#run-generation-1[aria-pressed='true']")
    assert has_element?(view, "#generation-scope-1[aria-pressed='true']")

    assert has_element?(
             view,
             "#run-scope-label",
             "Showing estimate from generation 1; graph shows generation 1"
           )
  end

  test "on an open finished run a picked generation shows at once and keeps node",
       %{conn: conn} do
    run = revised_run(true)
    view = open_page(conn, stage_path(run, scope: 1))
    view |> element("#node-estimate-select") |> render_click()
    render_async(view, 5_000)

    view |> element("#run-generation-0") |> render_click()
    assert_patch(view, stage_path(run, node: "estimate", gen: 0, scope: 1))
    assert has_element?(view, "#run-generation-0[aria-pressed='true']")
    assert {%{generation: {"estimate", 0}, scope: 1}, "estimate"} = run_assign(view)
  end

  test "a hostile gen or scope is ignored and makes no atom", %{conn: conn} do
    run = revised_run()
    view = open_page(conn, stage_path(run, node: "estimate"))

    for value <- ["abc", "-1", "999", "1.0", " 1", "latest_#{System.unique_integer([:positive])}"] do
      render_patch(view, stage_path(run, node: "estimate", gen: value, scope: value))
      assert {%{generation: nil, scope: :latest}, "estimate"} = run_assign(view)

      render_hook(view, "set_run_scope", %{"scope" => value})
      render_hook(view, "select_run_generation", %{"generation" => value})
      assert {%{generation: nil, scope: :latest}, "estimate"} = run_assign(view)
    end

    for params <- [%{}, %{"scope" => 1}, %{"scope" => ["0"]}, %{"scope" => %{"a" => "0"}}] do
      render_hook(view, "set_run_scope", params)
      assert {%{scope: :latest}, _selected} = run_assign(view)
    end

    assert has_element?(view, "#composer")
  end
end
