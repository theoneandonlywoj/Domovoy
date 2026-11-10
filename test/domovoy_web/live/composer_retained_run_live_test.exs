defmodule DomovoyWeb.ComposerRetainedRunLiveTest do
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
  alias Domovoy.CoreCallTrace
  alias Domovoy.Examples.Definitions

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  # A finished leak run whose draft was then deleted.
  defp orphaned_run do
    draft = draft!(leak_run(), "Leak")
    {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "finished")
    {:ok, _deleted} = Composer.delete_draft(draft)
    run_id
  end

  # A review run revised once and accepted at generation 1, whose draft was then deleted.
  defp orphaned_revised_run do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
    {:ok, values} = RunInputs.parse(document, @review_form)
    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    %{awaiting: [%{occurrence: first}]} = await_phase(handle, "waiting")
    :ok = Composer.decide_run(handle, first, "revise", %{})
    %{awaiting: [%{occurrence: second}]} = await_fact(handle, asked(1))
    :ok = Composer.decide_run(handle, second, "accept", %{})
    await_phase(handle, "finished")
    {:ok, _deleted} = Composer.delete_draft(draft)
    run_id
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

  defp core_run_calls(fun), do: for({name, _args} <- CoreCallTrace.calls(fun), do: name)

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

  test "a run with a draft is titled by the draft, whatever the page title", %{conn: conn} do
    draft = draft!(leak_run(), "Leak")
    {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "finished")

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{run_id}")
    render_async(view, 5_000)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket, &Phoenix.Component.assign(&1, :page_title, "Another title"))
    end)

    render_click(element(view, "#open-outline"))
    assert has_element?(view, "#run-header #draft-title", draft.title)
  end

  test "an orphaned run is inspectable read-only", %{conn: conn} do
    run_id = orphaned_run()

    {:ok, view, _html} = live(conn, ~p"/composer/runs/#{run_id}")
    render_async(view, 5_000)

    assert has_element?(view, "#run-outcome", "succeeded")
    assert has_element?(view, "#draft-title", "leak_run")
    assert has_element?(view, "#stage-canvas #vertex-main")
    assert has_element?(view, "#new-run[disabled][aria-describedby='new-run-reason']")
    assert has_element?(view, "#new-run-reason", "This workflow's draft was deleted")
    refute has_element?(view, "#back-to-draft")

    for {event, params} <- [
          {"confirm_cancel_run", %{}},
          {"decide", %{"occurrence" => Ecto.UUID.generate(), "choice" => "accept"}},
          {"recover_run", %{}},
          {"open_start", %{}}
        ] do
      calls =
        core_run_calls(fn ->
          render_hook(view, event, params)
          render_async(view, 5_000)
        end)

      refute :command in calls
      refute :activate in calls
      refute :start in calls

      assert has_element?(
               view,
               "#rejection-message",
               "This workflow's draft was deleted, so this run is read-only."
             )

      view |> element("#dismiss-rejection") |> render_click()
    end

    refute has_element?(view, "#launcher-panel")
  end

  test "the run route of a run that still has its draft goes through that draft",
       %{conn: conn} do
    draft = draft!(leak_run(), "Leak")
    {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "finished")

    to = ~p"/composer/#{draft.id}?#{[run: run_id]}"
    assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, ~p"/composer/runs/#{run_id}")

    stage_to = ~p"/composer/#{draft.id}/stages/main?#{[run: run_id]}"

    assert {:error, {:live_redirect, %{to: ^stage_to}}} =
             live(conn, ~p"/composer/runs/#{run_id}/stages/main")
  end

  test "a malformed or unknown id, and runs off, go to the draft list with no Core call",
       %{conn: conn} do
    run_id = orphaned_run()

    calls =
      core_run_calls(fn ->
        for id <- ["not-a-uuid", Ecto.UUID.generate()] do
          assert {:error, {:live_redirect, %{to: "/composer", flash: flash}}} =
                   live(conn, ~p"/composer/runs/#{id}")

          assert flash["error"] == "That run doesn't exist."
        end

        Application.put_env(:domovoy, :composer_runs_enabled, false)

        assert {:error, {:live_redirect, %{to: "/composer", flash: flash}}} =
                 live(conn, ~p"/composer/runs/#{run_id}")

        assert flash["error"] == "Runs are turned off on this host."
      end)

    assert calls == []
  end

  test "the orphan route keeps a picked generation and graph scope", %{conn: conn} do
    run_id = orphaned_revised_run()
    path = fn query -> ~p"/composer/runs/#{run_id}/stages/estimate_price?#{query}" end

    {:ok, view, _html} = live(conn, ~p"/composer/runs/#{run_id}/stages/estimate_price")
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &(map_size(&1.occurrences) == 2))

    view |> element("#node-join_price_terms-select") |> render_click()
    render_async(view, 5_000)

    view |> element("#run-generation-0") |> render_click()
    assert_patch(view, path.(node: "join_price_terms", gen: 0))

    view |> element("#generation-scope-1") |> render_click()
    assert_patch(view, path.(node: "join_price_terms", gen: 0, scope: 1))

    assert {%{generation: {"join_price_terms", 0}, scope: 1}, "join_price_terms"} =
             run_assign(view)

    assert has_element?(view, "#run-generation-0[aria-pressed='true']")
    assert has_element?(view, "#generation-scope-1[aria-pressed='true']")

    # An unknown stage goes back to the run's workflow on the same route.
    render_patch(view, ~p"/composer/runs/#{run_id}/stages/nope")
    assert_patch(view, ~p"/composer/runs/#{run_id}")
  end

  describe "in the dashboard" do
    test "a run with a draft goes through that draft", %{conn: conn} do
      draft = draft!(leak_run(), "Leak")
      {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
      {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
      await_phase(open!(run_id), "finished")

      to = ~p"/dashboard/workflows/#{draft.id}?#{[run: run_id]}"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, ~p"/dashboard/workflows/runs/#{run_id}")

      stage_to = ~p"/dashboard/workflows/#{draft.id}/stages/main?#{[run: run_id]}"

      assert {:error, {:live_redirect, %{to: ^stage_to}}} =
               live(conn, ~p"/dashboard/workflows/runs/#{run_id}/stages/main")
    end

    test "a malformed or unknown id, and runs off, go to dashboard workflows with no Core call",
         %{conn: conn} do
      run_id = orphaned_run()

      calls =
        core_run_calls(fn ->
          for id <- ["not-a-uuid", Ecto.UUID.generate()] do
            assert {:error, {:live_redirect, %{to: "/dashboard/workflows", flash: flash}}} =
                     live(conn, ~p"/dashboard/workflows/runs/#{id}")

            assert flash["error"] == "That run doesn't exist."
          end

          Application.put_env(:domovoy, :composer_runs_enabled, false)

          assert {:error, {:live_redirect, %{to: "/dashboard/workflows", flash: flash}}} =
                   live(conn, ~p"/dashboard/workflows/runs/#{run_id}")

          assert flash["error"] == "Runs are turned off on this host."
        end)

      assert calls == []
    end

    test "an orphaned run keeps its stage links in the dashboard", %{conn: conn} do
      run_id = orphaned_run()

      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/runs/#{run_id}")
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#vertex-main-open[href^='/dashboard/workflows/runs/#{run_id}/stages/main']"
             )

      view |> element("#vertex-main-open") |> render_click()
      path = assert_patch(view)
      assert String.starts_with?(path, "/dashboard/workflows/runs/#{run_id}/stages/main")
      refute hrefs_leak?(view)
    end
  end
end
