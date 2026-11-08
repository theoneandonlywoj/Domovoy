defmodule DomovoyWeb.ComposerRunResultsLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  import Domovoy.RunCase,
    only: [setup_runs: 1, start_attrs: 2, open!: 1, await_phase: 2, open_gate: 0, watch: 1]

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Examples.Definitions
  alias Domovoy.CoreCallTrace
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Runtime

  # Killing a capsule makes its processes report their end.
  @moduletag :capture_log

  setup :setup_runs

  @sentinel "sentinel-result-value"

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp start(document, values) do
    draft = draft!(document, "Results")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    %{draft: draft, run_id: run_id, handle: open!(run_id)}
  end

  # Opens a stage of a run with a node selected, once the page has folded the run's
  # events this far: its state is read first, so a replay folded before the watch
  # began still counts.
  defp open_node(conn, run, node, ready \\ &settled?/2) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{run.draft.id}/stages/main?run=#{run.run_id}")
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &ready.(&1, node))
    view |> element("#node-#{node}-select") |> render_click()
    render_async(view, 5_000)
    view
  end

  defp settled?(fold, node),
    do: Enum.any?(fold.attempts, fn {{name, _g, _o}, a} -> name == node and a.settled_seq end)

  defp admitted?(fold, node),
    do: Enum.any?(fold.attempts, fn {{name, _g, _o}, _a} -> name == node end)

  defp await_folded(view, fun) do
    %{socket: %{assigns: %{run: run}}} = :sys.get_state(view.pid)

    if fun.(run.fold) do
      :ok
    else
      assert_receive {:trace, _pid, :receive, {:domovoy_events, _subscription, _message}}, 5_000
      await_folded(view, fun)
    end
  end

  defp file_run(tmp_dir, name, content) do
    path = Path.join(tmp_dir, name)
    File.write!(path, content)
    run = start(read_file_run(), %{"path" => path})
    Map.put(run, :view, await_phase(run.handle, "finished"))
  end

  test "a real node shows its status, output, attempts, timing, runner and sources",
       %{conn: conn} do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
    {:ok, values} = RunInputs.parse(document, @review_form)
    run = start(document, values)
    await_phase(run.handle, "waiting")

    {:ok, view, _html} =
      live(conn, ~p"/composer/#{run.draft.id}/stages/estimate_price?run=#{run.run_id}")

    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &settled?(&1, "join_price_terms"))
    view |> element("#node-join_price_terms-select") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#run-selected-status", "Done")
    assert has_element?(view, "#run-output")
    assert has_element?(view, "#run-attempt-1", "Done")
    assert has_element?(view, "#run-attempt-1", "took")
    assert has_element?(view, "#run-node-runner", "Estimate")
    assert has_element?(view, "#run-node-version")
    assert has_element?(view, "#run-node-source-features", "from normalize_listing")
    assert has_element?(view, "#run-node-source-base", "from area_model")
    refute has_element?(view, "#run-generations")
  end

  describe "Core 0.3.3's file outputs" do
    @describetag :tmp_dir

    test "ReadFile shows binary output and its size, never base64 or the file",
         %{conn: conn, tmp_dir: tmp_dir} do
      content = String.duplicate(@sentinel, 10)
      run = file_run(tmp_dir, "small.txt", content)
      assert run.view.outcome == "succeeded"

      view = open_node(conn, run, "read")

      assert has_element?(
               view,
               "#run-output-binary",
               "Binary output, #{byte_size(content)} bytes"
             )

      html = render(view)
      refute html =~ @sentinel
      refute html =~ Base.encode64(content)
      refute has_element?(view, "#run-output")
    end

    test "text past the preview shows a cut preview and its full size, up to the value limit",
         %{conn: conn, tmp_dir: tmp_dir} do
      for {name, size} <- [{"medium.txt", 20 * 1_024}, {"large.txt", 600 * 1_024}] do
        run = file_run(tmp_dir, name, String.duplicate("a", size))
        assert run.view.outcome == "succeeded"

        view = open_node(conn, run, "text")

        assert has_element?(view, "#run-output")
        assert has_element?(view, "#run-output-cut", "Showing the first 16 KB of")
        assert view |> element("#run-output") |> render() |> byte_size() < 20_000
      end
    end

    test "a file over the limit fails the node with canonical_too_large and no retry",
         %{conn: conn, tmp_dir: tmp_dir} do
      run = file_run(tmp_dir, "huge.txt", String.duplicate("a", 900 * 1_024))
      assert %{committed_phase: "finished", outcome: "failed"} = run.view

      view = open_node(conn, run, "read")

      assert has_element?(view, "#run-error-type", "canonical_too_large")
      assert has_element?(view, "#run-error-text[data-retryable='false']", "Retrying won't help")
      assert has_element?(view, "#run-outcome", "failed")
      refute has_element?(view, "#reload-run-record")
    end
  end

  test "a failed node shows its type and retryability, and nothing of its reason",
       %{conn: conn} do
    run = start(leak_run(), %{"secret" => @sentinel, "mode" => "fail"})
    assert %{outcome: "failed"} = await_phase(run.handle, "finished")

    view = open_node(conn, run, "leak")

    assert has_element?(view, "#run-error-type", "leak_failed")
    assert has_element?(view, "#run-error-text[data-retryable='false']")
    refute render(view) =~ @sentinel
  end

  test "a node kept out of the Store says so", %{conn: conn} do
    document = edit_all(leak_run(), [{:set_execution, "main", "leak", nil, false}])
    run = start(document, %{"secret" => "kept out", "mode" => "succeed"})
    assert %{outcome: "succeeded"} = await_phase(run.handle, "finished")

    view = open_node(conn, run, "leak")

    assert has_element?(view, "#run-node-result", "Not stored by policy")
    refute has_element?(view, "#run-output")
  end

  test "a node that never ran says Not run, a held one Running, and a frozen one Interrupted",
       %{conn: conn} do
    open_gate()
    run = start(hold_pair(), %{"trap_exit" => false})
    assert_receive {:entered, "hold", _runner}, 5_000

    view = open_node(conn, run, "after_hold", fn fold, _node -> admitted?(fold, "hold") end)
    assert has_element?(view, "#run-node-result[data-result='not_run']", "Not run")

    view |> element("#node-hold-select") |> render_click()
    assert has_element?(view, "#run-node-result[data-result='running']", "Running")

    # A killed capsule leaves the attempt unsettled with no owner.
    owner = CoreRuns.whereis(run.handle)
    ref = Process.monitor(owner)
    [{_id, capsule, :supervisor, _modules}] = Runtime.capsules(Runs.runtime())
    Process.exit(capsule, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000

    frozen = open_node(conn, run, "hold", fn fold, _node -> admitted?(fold, "hold") end)
    assert has_element?(frozen, "#run-node-result[data-result='interrupted']", "Interrupted")
    refute has_element?(frozen, "#reload-run-record")
  end

  # Sets every read the page holds to `state`, as a read that ended so would, and has
  # the page render it.
  defp put_reads(view, state) do
    :sys.replace_state(view.pid, fn %{socket: socket} = live ->
      run = socket.assigns.run
      reads = Map.new(run.reads, fn {key, _read} -> {key, %{key: key, state: state}} end)

      assigns = %{
        socket.assigns
        | run: %{run | reads: reads},
          __changed__: Map.put(socket.assigns.__changed__, :run, true)
      }

      %{live | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :render)
    _state = :sys.get_state(view.pid)
    render(view)
  end

  defp review_run(document \\ Definitions.cracow_review()) do
    {:ok, values} = RunInputs.parse(document, @review_form)
    run = start(document, values)
    await_phase(run.handle, "waiting")
    run
  end

  test "Reload result only reads, and lag, unavailable and a stopped read say which",
       %{conn: conn} do
    run = start(leak_run(), %{"secret" => "kept", "mode" => "succeed"})
    assert %{outcome: "succeeded"} = await_phase(run.handle, "finished")
    view = open_node(conn, run, "leak")

    for {state, text} <- [
          {"unavailable", "Couldn't load this result."},
          {"read_failed", "Reading this result stopped before it finished."},
          {"lag", "Catching up. This result is still being written."}
        ] do
      put_reads(view, String.to_existing_atom(state))
      assert has_element?(view, "#run-node-result[data-result='#{state}']")
      assert has_element?(view, "#run-result-#{state}", text)
      assert has_element?(view, "#reload-run-record", "Reload result")
      refute has_element?(view, "#run-output")
    end

    # A process has one tracer, so the page's own calls are traced only unwatched.
    :erlang.trace(view.pid, false, [:receive])
    %{socket: %{assigns: %{run: %{fold: before}}}} = :sys.get_state(view.pid)

    calls =
      CoreCallTrace.calls(fn ->
        view |> element("#reload-run-record") |> render_click()
        render_async(view, 5_000)
      end)

    refute Enum.any?(calls, fn {name, _args} -> name in [:command, :activate, :start] end)
    %{socket: %{assigns: %{run: %{fold: after_reload}}}} = :sys.get_state(view.pid)
    assert after_reload.attempts == before.attempts
    assert has_element?(view, "#run-output", "kept")
  end

  test "a read for a node no longer selected is dropped, so only the selected one shows",
       %{conn: conn} do
    run = review_run()

    {:ok, view, _html} =
      live(conn, ~p"/composer/#{run.draft.id}/stages/estimate_price?run=#{run.run_id}")

    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &settled?(&1, "join_price_terms"))

    # The second selection lands before the first read can, which is then dropped.
    view |> element("#node-join_price_terms-select") |> render_click()
    view |> element("#node-normalize_listing-select") |> render_click()
    render_async(view, 5_000)

    %{socket: %{assigns: %{run: page}}} = :sys.get_state(view.pid)
    assert [{_id, "normalize_listing", 0, _seq}] = Map.keys(page.reads)
    assert has_element?(view, "#run-selected-name", "normalize_listing")
    assert has_element?(view, "#run-output")
  end

  test "Results lists the declared outputs first, then the rest by stage, each read on expand",
       %{conn: conn} do
    estimate = %{"stage" => "estimate_price", "node" => "join_price_terms"}
    run = review_run(edit_all(Definitions.cracow_review(), [{:put_outputs, [estimate]}]))

    {:ok, view, _html} = live(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &settled?(&1, "join_price_terms"))
    view |> element("#open-results") |> render_click()

    assert has_element?(view, "#results-panel:not([hidden])")
    assert has_element?(view, "#results-outputs #result-row-estimate_price-join_price_terms")

    assert has_element?(
             view,
             "#results-stage-estimate_price #result-row-estimate_price-normalize_listing"
           )

    refute has_element?(
             view,
             "#results-stage-estimate_price #result-row-estimate_price-join_price_terms"
           )

    refute has_element?(view, "#result-row-estimate_price-normalize_listing-output")

    view |> element("#result-row-estimate_price-normalize_listing-toggle") |> render_click()
    render_async(view, 5_000)

    assert has_element?(
             view,
             "#result-row-estimate_price-normalize_listing-toggle[aria-expanded='true']"
           )

    assert has_element?(view, "#result-row-estimate_price-normalize_listing-output")

    view |> element("#result-row-estimate_price-normalize_listing-toggle") |> render_click()
    refute has_element?(view, "#result-row-estimate_price-normalize_listing-output")
  end

  test "the Results surface opens from its switcher button, and with a browser's value",
       %{conn: conn} do
    run = review_run()

    for send <- [
          &render_click(element(&1, "#surface-results")),
          &render_hook(&1, "set_surface", %{"surface" => "results", "value" => ""})
        ] do
      {:ok, view, _html} = live(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
      render_async(view, 5_000)
      assert has_element?(view, "#results-panel[hidden]")

      send.(view)
      assert has_element?(view, "#workspace[data-surface='results'] #results-panel:not([hidden])")
    end
  end

  test "a failed run leads to its failed step in one action, and offers a new run",
       %{conn: conn} do
    run = start(leak_run(), %{"secret" => @sentinel, "mode" => "fail"})
    assert %{outcome: "failed"} = await_phase(run.handle, "finished")

    {:ok, view, _html} = live(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
    watch(view.pid)
    render_async(view, 5_000)
    await_folded(view, &settled?(&1, "leak"))
    render(view)

    assert has_element?(view, "#new-run")
    view |> element("#view-failed-step") |> render_click()
    assert_patch(view) =~ "node=leak"
    render_async(view, 5_000)

    assert has_element?(view, "#breadcrumb-stage", "main")
    assert has_element?(view, "#run-selected-name", "leak")
    assert has_element?(view, "#run-error-type", "leak_failed")
    refute render(view) =~ @sentinel
  end
end
