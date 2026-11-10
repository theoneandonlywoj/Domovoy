defmodule DomovoyWeb.DashboardComposerRunLiveTest do
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
  alias Domovoy.Examples.Definitions

  @moduletag :capture_log

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp review_document,
    do: Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document

  # A review run waiting at its first decision.
  defp waiting_run do
    document = review_document()
    {:ok, values} = RunInputs.parse(document, @review_form)
    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    await_phase(handle, "waiting")
    %{draft: draft, run_id: run_id, handle: handle}
  end

  # A review run revised once, so generation 1 is asked.
  defp revised_run do
    %{handle: handle} = run = waiting_run()
    {:ok, view} = Composer.run_view(handle)
    [%{occurrence: first}] = view.awaiting
    :ok = Composer.decide_run(handle, first, "revise", %{})
    await_fact(handle, asked(1))
    run
  end

  # A leak run that has finished, succeeded or failed by its mode.
  defp finished_leak(mode) do
    draft = draft!(leak_run(), "Leak")
    {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => mode})
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "finished")
    %{draft: draft, run_id: run_id}
  end

  # Opens a page and waits until it has folded the run's events this far.
  defp open_page(conn, path, ready) do
    {:ok, view, _html} = live(conn, path)
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, ready)
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

  defp settled?(fold, node),
    do: Enum.any?(fold.attempts, &match?({{^node, _gen, _ordinal}, %{settled_seq: _}}, &1))

  defp base(draft), do: "/dashboard/workflows/#{draft.id}"

  defp href(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> LazyHTML.attribute("href")
    |> hd()
  end

  # Every `/composer` link inside the dashboard must be the export download, the only
  # exit the dashboard has.
  defp hrefs_leak?(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a[href]")
    |> LazyHTML.attribute("href")
    |> Enum.any?(fn href ->
      String.starts_with?(href, "/composer") and not String.ends_with?(href, "/export")
    end)
  end

  test "?launch=1 opens the launcher and patches within the dashboard", %{conn: conn} do
    draft = draft!(hold_run(), "Held")
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/#{draft.id}")

    # A patch made while mounting can't be asserted, so the param arrives by a patch.
    render_patch(view, ~p"/dashboard/workflows/#{draft.id}?launch=1")
    assert_patch(view, base(draft))
    assert has_element?(view, "#launcher-panel:not([hidden]) #start-form")
    refute hrefs_leak?(view)
  end

  test "starting a run from the launcher patches to it in the dashboard", %{conn: conn} do
    draft = draft!(leak_run(), "Leak")
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/#{draft.id}")

    view |> element("#start-run") |> render_click()

    view
    |> form("#start-form", start: %{"secret" => "t", "mode" => "succeed"})
    |> render_submit()

    render_async(view, 5_000)
    path = assert_patch(view)
    assert String.starts_with?(path, base(draft) <> "?run=")
  end

  test "a run's links stay in the dashboard, and All runs leads to the Runs view",
       %{conn: conn} do
    run = waiting_run()
    path = ~p"/dashboard/workflows/#{run.draft.id}/stages/estimate_price?run=#{run.run_id}"
    view = open_page(conn, path, &(map_size(&1.occurrences) > 0))

    assert has_element?(view, "#run-header #breadcrumb a[href='/dashboard/workflows']", "Drafts")
    assert String.starts_with?(href(view, "#run-header #breadcrumb"), "/dashboard/workflows")

    assert href(view, "#back-to-draft") == base(run.draft) <> "/stages/estimate_price"

    assert view |> element("#breadcrumb-workflow") |> render() =~
             ~s(href="#{base(run.draft)}?run=#{run.run_id})

    assert href(view, "#run-pending") =~ base(run.draft) <> "?"

    assert has_element?(
             view,
             "#all-runs-link[href='/dashboard/workflows/runs?draft=#{run.draft.id}']"
           )

    assert has_element?(
             view,
             "#attention-runs-link[href='/dashboard/workflows/runs?draft=#{run.draft.id}&status=attention']"
           )

    refute hrefs_leak?(view)

    view |> element("#run-pending-link-review") |> render_click()
    path = assert_patch(view)
    assert String.starts_with?(path, base(run.draft) <> "?")
    assert path =~ "node=review"
    refute hrefs_leak?(view)

    view |> element("#back-to-draft") |> render_click()
    assert_patch(view, base(run.draft))
    render_async(view, 5_000)

    {:ok, runs, _html} =
      view |> element("#all-runs-link") |> render_click() |> follow_redirect(conn)

    render_async(runs, 5_000)
    assert has_element?(runs, "#runs")
    assert has_element?(runs, "#dashboard-nav-workflows[aria-current='page']")
  end

  test "a failed run's step link stays in the dashboard", %{conn: conn} do
    run = finished_leak("fail")

    view =
      open_page(
        conn,
        ~p"/dashboard/workflows/#{run.draft.id}?run=#{run.run_id}",
        &settled?(&1, "leak")
      )

    view |> element("#view-failed-step") |> render_click()
    path = assert_patch(view)
    assert String.starts_with?(path, base(run.draft) <> "/stages/main?")
    assert path =~ "node=leak"
    refute hrefs_leak?(view)
  end

  test "Fix in editor on a run page leads to the draft's issues in the dashboard",
       %{conn: conn} do
    run = finished_leak("succeed")

    view =
      open_page(
        conn,
        ~p"/dashboard/workflows/#{run.draft.id}?run=#{run.run_id}",
        &settled?(&1, "leak")
      )

    {:ok, latest} = Composer.get_draft(run.draft.id)

    {:ok, _saved} =
      Composer.save_document(
        latest,
        edit_all(latest.document, [{:add_node, "main", "Domovoy.LeakRunner", "unbound"}])
      )

    view |> element("#new-run") |> render_click()

    view
    |> form("#start-form", start: %{"secret" => "t", "mode" => "succeed"})
    |> render_submit()

    render_async(view, 5_000)

    assert has_element?(
             view,
             "#launcher-fix[href='/dashboard/workflows/#{run.draft.id}?tools=1']"
           )

    refute hrefs_leak?(view)
  end

  test "picking a generation or a graph scope patches within the dashboard", %{conn: conn} do
    run = revised_run()
    stage = base(run.draft) <> "/stages/estimate_price"

    view =
      open_page(
        conn,
        ~p"/dashboard/workflows/#{run.draft.id}/stages/estimate_price?#{[run: run.run_id, node: "join_price_terms"]}",
        &(map_size(&1.occurrences) == 2)
      )

    view |> element("#generation-scope-1") |> render_click()
    path = assert_patch(view)
    assert String.starts_with?(path, stage <> "?")
    assert path =~ "scope=1"

    view |> element("#run-generation-0") |> render_click()
    path = assert_patch(view)
    assert String.starts_with?(path, stage <> "?")
    assert path =~ "gen=0"
    refute hrefs_leak?(view)
  end
end
