defmodule Domovoy.Composer.RunsPostgresTest do
  use Domovoy.RunCase

  import Domovoy.ComposerFixtures, only: [draft!: 2, leak_run: 0, leak_run: 1]
  import ExUnit.CaptureLog

  alias Domovoy.Composer
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Examples.Definitions
  alias Domovoy.RaisingDecider
  alias Domovoy.RaisingValidator
  alias Domovoy.RunTestRepo
  alias Domovoy.UncertainLeakRunner
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Record
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Runtime
  alias DomovoyCore.Stage
  alias DomovoyCore.Type
  alias DomovoyCore.Value
  alias DomovoyCore.Workflow

  require Logger

  @sentinel "sentinel-run-input-value"

  # What each crash path ends as on Core v0.3.4.
  @crash_states [
    raise: %{committed_phase: "finished", outcome: "failed"},
    exit: %{committed_phase: "finished", outcome: "failed"},
    throw: %{committed_phase: "finished", outcome: "failed"},
    uncertain: %{committed_phase: "finished", outcome: "failed"},
    validator: %{committed_phase: "finished", outcome: "failed"},
    decider: %{committed_phase: "finished", outcome: "failed"}
  ]

  # The crash paths whose log holds the sentinel on Core v0.3.4.
  @leaking [:raise, :exit, :throw, :uncertain, :decider]

  @form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  setup do
    adapters = Application.fetch_env!(:domovoy, :composer_run_adapters)
    on_exit(fn -> Application.put_env(:domovoy, :composer_run_adapters, adapters) end)

    Application.put_env(:domovoy, :composer_run_adapters,
      journal: {DomovoyCore.Journal.Canonical.Postgres, repo: RunTestRepo, namespace: "composer"},
      store: {DomovoyCore.Store.Postgres, repo: RunTestRepo}
    )

    start_supervised!(RunTestRepo)
    truncate_core_tables()

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  # RunTestRepo isn't sandboxed, so what a run writes here commits.
  defp truncate_core_tables do
    %{rows: rows} =
      RunTestRepo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' " <>
          "AND (tablename LIKE 'domovoy_canonical_%' OR tablename = 'domovoy_records')"
      )

    tables = rows |> List.flatten() |> Enum.join(", ")
    RunTestRepo.query!("TRUNCATE #{tables}")
  end

  defp restart_runtime do
    :ok = stop_supervised!({Runtime, Runs.runtime()})
    start_supervised!({Runtime, name: Runs.runtime()})
  end

  defp start_leak(mode, runner \\ Domovoy.LeakRunner) do
    draft = draft!(leak_run(runner), "Leak")
    {:ok, values} = RunInputs.parse(draft.document, %{"secret" => @sentinel, "mode" => mode})
    assert {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    {handle, await_phase(handle, "finished")}
  end

  # A Core workflow built by hand, since the catalog names neither raising module: the
  # `leak` node gives back the sentinel, checked by `validators`, then `decider` decides.
  defp start_core(validators, decider) do
    open_gate()
    adapters = Application.fetch_env!(:domovoy, :composer_run_adapters)

    leak =
      Node.new(%{
        name: "leak",
        runner: Domovoy.LeakRunner,
        type: Type.String,
        validators: validators,
        bind: %{secret: {"secret", Type.String}, mode: {"mode", Type.String}}
      })

    review =
      Decision.new(%{
        name: "review",
        prompt: "Go on?",
        choices: [Choice.new(%{name: "accept", description: "Finish.", target: :halt})],
        decider: decider
      })

    workflow =
      Workflow.new!(%{
        name: "hand_built",
        vertices: %{
          "main" => Stage.new(%{name: "main", graph: Graph.new([leak]), next: "review"}),
          "review" => review
        },
        start: "main",
        inputs: %{"secret" => %{type: Type.String}, "mode" => %{type: Type.String}},
        journal: adapters[:journal],
        store: adapters[:store]
      })

    {:ok, handle, _receipt} =
      CoreRuns.start(Runs.runtime(), workflow, %{"secret" => @sentinel, "mode" => "succeed"},
        run_id: Ecto.UUID.generate(),
        command_id: "start"
      )

    view = await_phase(handle, "finished")
    {:ok, plain} = Runs.view(handle)
    {handle, %{view | owner_live?: plain.owner_live?}}
  end

  # Each crash path, run to its end, giving the handle and the view.
  defp crash(:raise), do: start_leak("raise")
  defp crash(:exit), do: start_leak("exit")
  defp crash(:throw), do: start_leak("throw")
  defp crash(:uncertain), do: start_leak("raise", UncertainLeakRunner)

  defp crash(:validator) do
    result = start_core([RaisingValidator], {RaisingDecider, node: "leak"})
    assert_received {:validated, "leak"}
    result
  end

  defp crash(:decider) do
    result = start_core([], {RaisingDecider, node: "leak"})
    assert_received {:decided, "review"}
    result
  end

  # Logs what `fun` does, with controls that prove a value would have shown.
  defp capture_with_controls(fun) do
    log =
      capture_log(fn ->
        Logger.debug("positive-control")
        Repo.all(Draft)
        fun.()
      end)

    assert log =~ "positive-control"
    assert log =~ "composer_drafts"
    log
  end

  test "a real run reopens after a Runtime restart, with its state and records" do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
    {:ok, values} = RunInputs.parse(document, @form)
    draft = draft!(document, "Review")

    assert {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    assert %{committed_phase: "waiting"} = await_phase(handle, "waiting")

    assert {:ok, %Record{status: :ok, result: %Value{value: estimate}}} =
             CoreRuns.get(handle, "join_price_terms", 0)

    restart_runtime()

    reopened = open!(run_id)

    assert {:ok, %{owner_live?: false, committed_phase: phase, awaiting: awaiting}} =
             Runs.view(reopened)

    assert phase in ["waiting", "stopped"]
    assert [%{decision: "review"}] = awaiting

    assert {:ok, %Record{result: %Value{value: ^estimate}}} =
             CoreRuns.get(reopened, "join_price_terms", 0)
  end

  test "a sentinel in a run input stays out of the logs through success" do
    log =
      capture_with_controls(fn ->
        # A query's parameters would show, so a clean log means Core's `log: false` held.
        RunTestRepo.query!("SELECT $1::text", ["param-control"])
        {handle, view} = start_leak("succeed")

        assert view.outcome == "succeeded"

        # The sentinel was really there to log.
        assert {:ok, %Record{result: %Value{value: @sentinel}}} =
                 CoreRuns.get(handle, "leak", 0)
      end)

    assert log =~ "param-control"
    refute log =~ @sentinel
  end

  test "a sentinel stays out of the logs when the runner returns an error" do
    log =
      capture_with_controls(fn ->
        {handle, view} = start_leak("fail")

        assert view.outcome == "failed"
        refute inspect(view) =~ @sentinel
        assert {:ok, %Record{status: :error}} = CoreRuns.get(handle, "leak", 0)
      end)

    refute log =~ @sentinel
  end

  describe "a crash path" do
    @describetag :capture_log

    for {path, state} <- @crash_states do
      test "#{path} ends as v0.3.4 gives it, with no sentinel in its view" do
        {_handle, view} = crash(unquote(path))

        assert Map.take(view, Map.keys(unquote(Macro.escape(state)))) ==
                 unquote(Macro.escape(state))

        refute inspect(view) =~ @sentinel
      end
    end
  end

  # Core v0.3.4 lets these crash reports carry the sentinel; LEAK.md explains.
  describe "a crash path's log" do
    for path <- @leaking do
      @tag :pending_core_crash_redaction
      test "#{path} holds no sentinel" do
        log = capture_with_controls(fn -> crash(unquote(path)) end)
        refute log =~ @sentinel
      end
    end

    for {path, _state} <- @crash_states, path not in @leaking do
      test "#{path} holds no sentinel" do
        log = capture_with_controls(fn -> crash(unquote(path)) end)
        refute log =~ @sentinel
      end
    end
  end

  describe "a decision on the real adapters" do
    defp waiting_review do
      document =
        Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document

      {:ok, values} = RunInputs.parse(document, @form)
      draft = draft!(document, "Review")
      {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
      handle = open!(run_id)
      %{awaiting: [%{occurrence: occurrence}]} = await_phase(handle, "waiting")
      {handle, occurrence}
    end

    defp stopped_review do
      {handle, occurrence} = waiting_review()
      {:ok, _receipt} = CoreRuns.command(handle, :stop, command_id: "stop-test")
      assert %{committed_phase: "stopped"} = await_phase(handle, "stopped")
      {handle, occurrence}
    end

    test "accept on a stopped run finishes it with no Resume" do
      {handle, occurrence} = stopped_review()

      assert :ok = Composer.decide_run(handle, occurrence, "accept", %{})

      assert %{committed_phase: "finished", outcome: "succeeded"} =
               await_phase(handle, "finished")
    end

    test "revise on a stopped run is recorded, and the run stays stopped until Resume" do
      {handle, occurrence} = stopped_review()

      assert :ok = Composer.decide_run(handle, occurrence, "revise", %{"district" => "Kazimierz"})
      assert {:ok, %{committed_phase: "stopped", awaiting: []}} = Runs.view(handle)

      {:ok, _receipt} = CoreRuns.command(handle, :resume, command_id: "resume-test")
      assert %{committed_phase: "waiting", generation: 1} = await_fact(handle, asked(1))
      assert {:ok, %Record{status: :ok}} = CoreRuns.get(handle, "join_price_terms", 1)
    end

    test "a sentinel in a decision input stays out of the logs, answered and refused" do
      log =
        capture_with_controls(fn ->
          {handle, occurrence} = waiting_review()

          # Refused: accept declares no input.
          assert {:error, {:refused, _type}} =
                   Composer.decide_run(handle, occurrence, "accept", %{"district" => @sentinel})

          assert :ok =
                   Composer.decide_run(handle, occurrence, "revise", %{"district" => @sentinel})

          # No district has that name, so the rerun's normalize refuses it and the run
          # fails on a returned error, not a crash.
          assert %{outcome: "failed"} = await_phase(handle, "finished")
          # The sentinel was really there to log: Core keeps the answer's input.
          assert {:ok, %Record{result: %Value{value: @sentinel}}} =
                   CoreRuns.get(handle, "district", 1)

          assert {:ok, %Record{status: :error}} = CoreRuns.get(handle, "normalize_listing", 1)
        end)

      refute log =~ @sentinel
    end
  end

  describe "a second start, on the real adapters" do
    test "with the same ids and values is the one run and one row" do
      draft = draft!(leak_run(), "Leak")
      attrs = start_attrs(draft, %{"secret" => "s", "mode" => "succeed"})

      assert {:ok, run_id} = Composer.start_run(attrs)
      assert %{outcome: "succeeded"} = await_phase(open!(run_id), "finished")

      assert Composer.start_run(attrs) == {:ok, run_id}

      assert Composer.start_run(put_in(attrs.values["secret"], "t")) ==
               {:opened_uncertain, run_id}

      assert {:ok, %Run{}} = Composer.get_run(draft.id, run_id)
    end

    test "that never committed removes the row" do
      draft = draft!(leak_run(), "Leak")
      attrs = start_attrs(draft, %{"secret" => "s"})
      attrs = put_in(attrs.values["mode"], %{"not" => "text"})

      assert Composer.start_run(attrs) == {:error, {:input_error, "mode"}}
      assert Composer.get_run(draft.id, attrs.run_id) == {:error, :not_found}
    end
  end

  describe "history from run summaries" do
    defp row!(draft, inserted_at, id \\ Ecto.UUID.generate()) do
      Repo.insert!(
        %Run{
          id: id,
          draft_id: draft.id,
          workflow_name: draft.document["name"],
          document: draft.document,
          fingerprint: "unstarted",
          start_command_id: "start",
          inserted_at: inserted_at
        },
        log: false
      )
    end

    defp ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds)

    defp summarize!(row, phase) do
      view = %{
        committed_phase: phase,
        outcome: if(phase == "finished", do: "succeeded"),
        generation: 0,
        committed_seq: 5,
        awaiting:
          if(phase == "waiting",
            do: [%{occurrence: "o", decision: "review", choices: ["accept"]}],
            else: []
          ),
        error: nil
      }

      :ok = Runs.summarize(row.id, view)
    end

    defp ids(rows), do: Enum.map(rows, & &1.id)

    test "latest gives each draft's newest run, ties broken by the larger id" do
      [d, g, h] = for name <- ~w(D G H), do: draft!(leak_run(), name)
      e = draft!(leak_run(), "E")
      f = draft!(leak_run(), "F")
      at = ago(10)
      row!(d, ago(3_600))

      # Four rows per draft in the same second, inserted ascending, descending and
      # shuffled, so a query without `desc: id` is very unlikely to pick the largest
      # id for all three drafts, whatever order the join and scan return them in.
      orders = [{d, &Enum.sort/1}, {g, &Enum.sort(&1, :desc)}, {h, &Enum.shuffle/1}]

      winners =
        for {draft, order} <- orders, into: %{} do
          ids = for _ <- 1..4, do: Ecto.UUID.generate()
          for id <- order.(ids), do: row!(draft, at, id)
          {draft.id, Enum.max(ids)}
        end

      summarize!(Repo.get!(Run, winners[d.id], log: false), "finished")
      only = row!(e, ago(5))

      latest = Runs.latest([d.id, g.id, h.id, e.id, f.id, "not-a-uuid"])

      assert Enum.sort(Map.keys(latest)) == Enum.sort([d.id, g.id, h.id, e.id])
      for {draft_id, id} <- winners, do: assert(latest[draft_id].id == id)
      assert %Run{summary: %{committed_phase: "finished"}} = latest[d.id]
      assert %Run{summary: nil} = latest[e.id]
      assert latest[e.id].id == only.id
      assert Runs.latest([]) == %{}
    end

    test "an old waiting run is found past 11 newer finished ones" do
      draft = draft!(leak_run(), "Leak")
      waiting = row!(draft, ago(3_600))
      summarize!(waiting, "waiting")
      for seconds <- 1..11, do: draft |> row!(ago(seconds)) |> summarize!("finished")

      assert ids(Composer.attention_runs(draft.id, 5)) == [waiting.id]
      assert [%Run{summary: %{committed_phase: "waiting"}}] = Runs.attention(draft.id, 5)
    end

    test "a known waiting run ranks before newer runs with no summary yet" do
      draft = draft!(leak_run(), "Leak")
      waiting = row!(draft, ago(3_600))
      summarize!(waiting, "waiting")
      unsummarised = for seconds <- 1..6, do: row!(draft, ago(seconds))

      assert [first | rest] = Runs.attention(draft.id, 5)
      assert first.id == waiting.id
      # Then the newest with no summary, while there is room.
      assert ids(rest) == unsummarised |> Enum.take(4) |> ids()
      assert Enum.all?(rest, &is_nil(&1.summary))

      assert Runs.attention(nil, 5) == []
      assert Runs.attention("junk", 5) == []
    end

    test "120 rows from one second page 25 at a time, each once, opening nothing" do
      draft = draft!(leak_run(), "Leak")
      at = ago(10)
      all = for _ <- 1..120, do: row!(draft, at).id

      {pages, calls} =
        trace(fn -> page_all(%{draft_id: draft.id}, nil, []) end)

      assert Enum.map(pages, &length/1) == [25, 25, 25, 25, 20]
      seen = List.flatten(pages)
      assert Enum.sort(seen) == Enum.sort(all)
      assert length(Enum.uniq(seen)) == 120
      refute Enum.any?(calls, &(&1 in [:open, :view]))
    end

    test "filters by status, by a deleted draft and by a cast draft id" do
      draft = draft!(leak_run(), "Leak")
      waiting = row!(draft, ago(330))
      summarize!(waiting, "waiting")
      finished = row!(draft, ago(320))
      summarize!(finished, "finished")
      # Past the start grace, so the draft can be deleted below.
      missing = row!(draft, ago(310))

      page = &ids(Runs.page(Map.put(&1, :draft_id, draft.id), nil, 25).runs)

      assert page.(%{status: "attention"}) == [missing.id, waiting.id]
      assert page.(%{status: "waiting"}) == [waiting.id]
      assert page.(%{status: "succeeded"}) == [finished.id]
      assert page.(%{status: "failed"}) == []
      assert page.(%{status: "nonsense"}) == [missing.id, finished.id, waiting.id]

      assert Runs.page(%{draft_id: "not-a-uuid"}, nil, 25).runs == []
      assert Runs.page(%{draft_id: "deleted"}, nil, 25).runs == []

      {:ok, _deleted} =
        draft.id |> Composer.get_draft() |> elem(1) |> Composer.delete_draft()

      assert ids(Runs.page(%{draft_id: "deleted"}, nil, 25).runs) ==
               [missing.id, finished.id, waiting.id]
    end

    defp page_all(filters, cursor, pages) do
      %{runs: runs, next: next} = Composer.run_page(filters, cursor, 25)
      pages = [ids(runs) | pages]
      if next, do: page_all(filters, next, pages), else: Enum.reverse(pages)
    end

    defp trace(fun) do
      parent = self()
      calls = Domovoy.CoreCallTrace.calls(fn -> send(parent, {:traced, fun.()}) end)
      assert_received {:traced, result}
      {result, for({name, _args} <- calls, do: name)}
    end
  end
end
