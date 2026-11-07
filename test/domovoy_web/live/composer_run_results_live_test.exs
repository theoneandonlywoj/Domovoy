defmodule DomovoyWeb.ComposerRunResultsLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  import Domovoy.RunCase,
    only: [setup_runs: 1, start_attrs: 2, open!: 1, await_phase: 2, open_gate: 0, watch: 1]

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Examples.Definitions
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
    await_folded(view, &settled?(&1, "estimate"))
    view |> element("#node-estimate-select") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#run-selected-status", "Done")
    assert has_element?(view, "#run-output")
    assert has_element?(view, "#run-attempt-1", "Done")
    assert has_element?(view, "#run-attempt-1", "took")
    assert has_element?(view, "#run-node-runner", "Estimate")
    assert has_element?(view, "#run-node-version")
    assert has_element?(view, "#run-node-source-features", "from normalize")
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
      refute has_element?(view, "#retry-run-record")
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
    refute has_element?(frozen, "#retry-run-record")
  end
end
