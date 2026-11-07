defmodule Domovoy.Composer.RunsTest do
  use Domovoy.RunCase

  import Domovoy.ComposerFixtures
  import Ecto.Query

  alias Domovoy.Composer
  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Examples.Definitions
  alias Domovoy.NoExecutionTrace
  alias Domovoy.SpyJournal
  alias Domovoy.UncertainHoldRunner
  alias Domovoy.UnknownCommitJournal
  alias DomovoyCore.Runs, as: CoreRuns

  @ungated [enabled?: 0, children: 0, runtime: 0, unfinished?: 1]
  @gated [
    ack: 2,
    activate: 1,
    cancel: 1,
    decide: 4,
    draft_changed?: 2,
    encode_event: 1,
    get: 2,
    latest_unfinished: 1,
    open: 1,
    recent: 1,
    recent: 2,
    record: 4,
    resync: 1,
    start: 1,
    subscribe: 2,
    unsubscribe: 1,
    view: 1
  ]

  # Every Core run module, by the name a call to it compiles to.
  @core_run_modules ~r/^DomovoyCore\.(Runs|Run|Events|Store|Journal)(\.|$)/

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp seed(title), do: Enum.find(Definitions.all(), &(&1.title == title)).document

  defp review_draft, do: draft!(seed("Cracow house price review"), "Review")

  defp review_values do
    {:ok, values} = RunInputs.parse(seed("Cracow house price review"), @review_form)
    values
  end

  defp start_review do
    draft = review_draft()
    attrs = start_attrs(draft, review_values())
    assert {:ok, run_id} = Runs.start(attrs)
    handle = open!(run_id)
    assert %{committed_phase: "waiting"} = await_phase(handle, "waiting")

    %{draft: draft, attrs: attrs, run_id: run_id, handle: handle}
  end

  defp start_held(document) do
    open_gate()
    draft = draft!(document, "Held")
    assert {:ok, run_id} = Runs.start(start_attrs(draft, %{"trap_exit" => true}))
    assert_receive {:entered, "hold", runner}, 5_000

    %{draft: draft, run_id: run_id, handle: open!(run_id), runner: runner}
  end

  defp row_count(run_id), do: Repo.aggregate(from(row in Run, where: row.id == ^run_id), :count)

  defp insert_row!(draft, fields) do
    Repo.insert!(
      struct!(
        %Run{
          id: Ecto.UUID.generate(),
          draft_id: draft.id,
          workflow_name: draft.document["name"],
          document: draft.document,
          fingerprint: "unstarted",
          start_command_id: "start"
        },
        fields
      )
    )
  end

  defp finish(%{handle: handle, runner: runner}) do
    send(runner, :release)
    await_phase(handle, "finished")
  end

  # The functions of Core's run API the calling process calls during `fun`.
  defp core_run_calls(fun) do
    for {_pid, {CoreRuns, name, _arity}} <- NoExecutionTrace.calls_to([CoreRuns], fun), do: name
  end

  describe "with the flag off" do
    setup do
      Application.put_env(:domovoy, :composer_runs_enabled, false)
    end

    test "every function but the ungated four refuses, and the table misses none" do
      assert Enum.sort(Runs.__info__(:functions) -- @ungated) == Enum.sort(@gated)

      for {name, arity} <- @gated do
        args = List.duplicate(:junk, arity)
        assert apply(Runs, name, args) == {:error, :runs_disabled}, "#{name}/#{arity}"
      end
    end

    test "no child is given, and the booted tree holds no Runtime" do
      assert Runs.children() == []
      refute Runs.enabled?()

      ids = Domovoy.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

      refute {DomovoyCore.Runtime, Runs.runtime()} in ids
    end

    test "unfinished?/1 makes no Core call and any row counts, so it fails closed" do
      draft = draft!(hold_run())
      assert core_run_calls(fn -> refute Runs.unfinished?(draft.id) end) == []

      insert_row!(draft, [])

      assert core_run_calls(fn -> assert Runs.unfinished?(draft.id) end) == []
      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}
    end

    test "the call trace sees a real call, so its silence means something" do
      assert :options_schema in core_run_calls(fn -> CoreRuns.options_schema(:start) end)
    end

    test "the composer's delegates refuse too" do
      assert Composer.start_run(:junk) == {:error, :runs_disabled}
      assert Composer.recent_runs(:junk) == {:error, :runs_disabled}
      assert Composer.recent_runs(:junk, 1) == {:error, :runs_disabled}
      refute Composer.runs_enabled?()
    end
  end

  describe "the gateway" do
    test "with the flag on gives the Runtime as the one child" do
      assert Runs.children() == [{DomovoyCore.Runtime, name: Runs.runtime()}]
    end

    test "in production config, Core's adapters use the host's repo" do
      config = Config.Reader.read!(Path.expand("config/config.exs"), env: :dev)
      adapters = config[:domovoy][:composer_run_adapters]

      assert {DomovoyCore.Journal.Canonical.Postgres, journal} = adapters[:journal]
      assert {DomovoyCore.Store.Postgres, store} = adapters[:store]
      assert journal[:repo] == Domovoy.Repo
      assert store[:repo] == Domovoy.Repo
    end

    test "is the only lib module that imports a Core run module" do
      {:ok, modules} = :application.get_key(:domovoy, :modules)

      importers =
        for module <- modules,
            beam = :code.which(module),
            {:ok, {^module, chunks}} <- [:beam_lib.chunks(beam, [:imports, :compile_info])],
            source = to_string(chunks[:compile_info][:source]),
            String.contains?(source, "/lib/"),
            not String.contains?(source, "/deps/"),
            {imported, _function, _arity} <- chunks[:imports],
            inspect(imported) =~ @core_run_modules,
            uniq: true do
          module
        end

      assert importers == [Runs]
    end
  end

  describe "a real run" do
    test "cracow_prices finishes succeeded from form text" do
      document = seed("Cracow house price")

      {:ok, values} =
        RunInputs.parse(
          document,
          Map.merge(@review_form, %{
            "floor" => "2",
            "balcony" => "true",
            "year_built" => "1995"
          })
        )

      draft = draft!(document, "Prices")
      assert {:ok, run_id} = Composer.start_run(start_attrs(draft, values))

      assert %{committed_phase: "finished", outcome: "succeeded"} =
               await_phase(open!(run_id), "finished")
    end

    test "cracow_review waits on review, with the choices named and no value in its view" do
      %{handle: handle} = start_review()

      assert {:ok,
              %{
                committed_phase: "waiting",
                owner_live?: true,
                error: nil,
                awaiting: [%{decision: "review", choices: ["accept", "revise"]}]
              } = view} = Composer.run_view(handle)

      refute inspect(view) =~ "Krowodrza"
    end

    test "a draft that became invalid starts nothing" do
      draft = draft!(edit_all(Document.new("no_node"), [{:add_decision, "lonely"}]), "Invalid")
      attrs = start_attrs(draft, %{})

      assert {:error, {:invalid, [_ | _]}} = Runs.start(attrs)
      assert row_count(attrs.run_id) == 0
    end

    test "a stale lock is a conflict and a missing draft is gone, and neither starts" do
      draft = review_draft()
      stale = start_attrs(%{draft | lock_version: draft.lock_version - 1}, review_values())
      missing = start_attrs(%{draft | id: Ecto.UUID.generate()}, review_values())
      malformed = start_attrs(%{draft | id: "nope"}, review_values())

      assert Runs.start(stale) == {:error, :conflict}
      assert Runs.start(missing) == {:error, :gone}
      assert Runs.start(malformed) == {:error, :gone}
      assert row_count(stale.run_id) + row_count(missing.run_id) == 0
    end
  end

  describe "a second and an interrupted start" do
    test "the same ids and values give one run and one row" do
      %{attrs: attrs, run_id: run_id, handle: handle} = start_review()
      {:ok, before} = Runs.view(handle)

      assert Runs.start(attrs) == {:ok, run_id}

      assert row_count(run_id) == 1
      assert {:ok, %{committed_phase: "waiting"} = later} = Runs.view(handle)
      assert later.committed_seq == before.committed_seq
    end

    test "after a commit, a changed value keeps the row and the run" do
      %{attrs: attrs, run_id: run_id, handle: handle} = start_review()
      changed = put_in(attrs.values["rooms"], 4)

      assert Runs.start(changed) == {:opened_uncertain, run_id}

      assert row_count(run_id) == 1
      assert {:ok, %{committed_phase: "waiting"}} = Runs.view(handle)
    end

    test "after a commit, an invalid value keeps the row and the run" do
      %{attrs: attrs, run_id: run_id, handle: handle} = start_review()
      invalid = put_in(attrs.values["area"], "58.5")

      assert Runs.start(invalid) == {:opened_uncertain, run_id}

      assert row_count(run_id) == 1
      assert {:ok, %{committed_phase: "waiting"}} = Runs.view(handle)
    end

    test "a never committed invalid input removes the row and names only the input" do
      draft = review_draft()
      attrs = start_attrs(draft, put_in(review_values()["area"], "58.5"))

      assert Runs.start(attrs) == {:error, {:input_error, "area"}}
      assert row_count(attrs.run_id) == 0
    end

    test "a never committed refusal removes the row and gives only the error type" do
      draft = review_draft()
      attrs = start_attrs(draft, Map.put(review_values(), "undeclared", "x"))

      assert Runs.start(attrs) == {:error, {:refused, :invalid_workflow_input}}
      assert row_count(attrs.run_id) == 0
    end

    test "ids these rows hold for another start are left alone" do
      %{attrs: attrs, run_id: run_id, handle: handle} = start_review()
      other_command = %{attrs | command_id: Ecto.UUID.generate()}
      other_draft = %{start_attrs(review_draft(), attrs.values) | run_id: run_id}

      assert Runs.start(other_command) == {:opened_uncertain, run_id}
      assert Runs.start(other_draft) == {:opened_uncertain, run_id}

      assert row_count(run_id) == 1
      assert {:ok, %{committed_phase: "waiting"}} = Runs.view(handle)
    end

    test "a row with no Core run opens as never started" do
      row = insert_row!(review_draft(), [])

      assert Runs.open(row) == {:error, :never_started}
    end

    test "a row with a runner since gone opens as unavailable to run" do
      document = put_in(hold_run()["vertices"]["main"]["nodes"]["hold"]["runner"], "Gone.Runner")
      row = insert_row!(draft!(hold_run()), document: document)

      assert Runs.open(row) == {:error, :runner_unavailable}
    end

    test "a retried commit that never landed keeps the row, after one identical retry" do
      with_unknown_commit_journal()
      draft = draft!(hold_run())
      attrs = start_attrs(draft, %{})

      assert Runs.start(attrs) == {:opened_uncertain, attrs.run_id}

      assert_received :start_attempt
      assert_received :start_attempt
      refute_received :start_attempt
      assert row_count(attrs.run_id) == 1
      assert Runs.open(Repo.get!(Run, attrs.run_id)) == {:error, :never_started}
    end

    test "a commit whose acknowledgement was lost is the same run after the retry" do
      with_unknown_commit_journal()
      Process.put(:unknown_commit, :landed)
      open_gate()
      draft = draft!(hold_run())
      attrs = start_attrs(draft, %{})

      assert Runs.start(attrs) == {:ok, attrs.run_id}

      assert_receive {:entered, "hold", runner}, 5_000
      send(runner, :release)
      assert row_count(attrs.run_id) == 1
      assert %{outcome: "succeeded"} = await_phase(open!(attrs.run_id), "finished")
    end
  end

  describe "deleting a draft" do
    test "is refused while a run waits, and works after it finishes, leaving the row" do
      %{draft: draft, run_id: run_id, handle: handle} = start_review()

      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}
      assert {:ok, _still} = Composer.get_draft(draft.id)

      {:ok, %{awaiting: [%{occurrence: occurrence}]}} = Runs.view(handle)

      {:ok, _receipt} =
        CoreRuns.command(handle, :decide,
          command_id: "answer",
          occurrence: occurrence,
          choice: "accept"
        )

      assert %{outcome: "succeeded"} = await_phase(handle, "finished")

      assert {:ok, _deleted} = Composer.delete_draft(draft)
      assert %Run{draft_id: nil} = Repo.get!(Run, run_id)
    end

    test "asks Core outside any transaction, as a control inside one shows" do
      %{draft: draft} = start_review()
      with_journal(SpyJournal)
      Process.put(:spy_journal, :report)

      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}

      seen = drain_in_transaction()
      assert seen != []
      assert Enum.all?(seen, &(&1 == false))

      assert {:ok, true} = Repo.transaction(fn -> Runs.unfinished?(draft.id) end)
      control = drain_in_transaction()
      assert control != []
      assert Enum.all?(control, & &1)
    end

    test "is refused when a row arrives while Core is asked, and that row keeps its draft" do
      %{draft: draft, run_id: run_id, handle: handle} = start_review()
      {:ok, %{awaiting: [%{occurrence: occurrence}]}} = Runs.view(handle)

      {:ok, _receipt} =
        CoreRuns.command(handle, :decide,
          command_id: "answer",
          occurrence: occurrence,
          choice: "accept"
        )

      assert %{outcome: "succeeded"} = await_phase(handle, "finished")
      refute Runs.unfinished?(draft.id)
      assert row_count(run_id) == 1

      arriving = %Run{
        id: Ecto.UUID.generate(),
        draft_id: draft.id,
        workflow_name: draft.document["name"],
        document: draft.document,
        fingerprint: "unstarted",
        start_command_id: "start"
      }

      with_journal(SpyJournal)
      Process.put(:spy_journal, {:insert, arriving})

      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}

      assert {:ok, _still} = Composer.get_draft(draft.id)
      assert %Run{draft_id: draft_id} = Repo.get!(Run, arriving.id)
      assert draft_id == draft.id
    end

    @tag :capture_log
    test "is refused for a frozen cancelling run" do
      %{draft: draft, handle: handle} = start_held(hold_run())
      {:ok, _receipt} = CoreRuns.command(handle, :cancel, command_id: "cancel")
      await_phase(handle, "cancelling")

      # A capsule is temporary, so killing it, unlike killing its owner, restarts nothing.
      owner = CoreRuns.whereis(handle)
      ref = Process.monitor(owner)

      for {_id, capsule, _type, _modules} <- DomovoyCore.Runtime.capsules(Runs.runtime()),
          do: Process.exit(capsule, :kill)

      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

      assert {:ok, %{committed_phase: "cancelling", owner_live?: false}} = Runs.view(handle)
      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}
    end

    test "is refused for a live run whose definition no longer matches" do
      %{draft: draft, run_id: run_id} = start_review()

      changed =
        edit_all(draft.document, [{:put_input, "extra", %{"type" => "DomovoyCore.Type.String"}}])

      Repo.update_all(from(row in Run, where: row.id == ^run_id), set: [document: changed])

      assert Runs.open(Repo.get!(Run, run_id)) == {:error, :definition_mismatch}
      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}
    end

    test "isn't blocked by a run whose runner is gone" do
      draft = draft!(hold_run())
      document = put_in(hold_run()["vertices"]["main"]["nodes"]["hold"]["runner"], "Gone.Runner")
      insert_row!(draft, document: document)

      refute Runs.unfinished?(draft.id)
      assert {:ok, _deleted} = Composer.delete_draft(draft)
    end

    test "is blocked by a new row with no run, since its start may be in flight, not an old one" do
      draft = draft!(hold_run())
      row = insert_row!(draft, [])
      assert Composer.delete_draft(draft) == {:error, :runs_unfinished}

      old = DateTime.add(DateTime.utc_now(:second), -61)
      Repo.update_all(from(run in Run, where: run.id == ^row.id), set: [inserted_at: old])

      refute Runs.unfinished?(draft.id)
      assert {:ok, _deleted} = Composer.delete_draft(draft)
    end
  end

  describe "reads" do
    test "get/2 needs the row to belong to the draft" do
      %{draft: draft, run_id: run_id} = start_review()
      other = draft!(hold_run())

      assert {:ok, %Run{id: ^run_id}} = Composer.get_run(draft.id, run_id)
      assert Runs.get(other.id, run_id) == {:error, :not_found}
      assert Runs.get(draft.id, "nope") == {:error, :not_found}
      assert Runs.get("nope", run_id) == {:error, :not_found}
      assert Runs.get(draft.id, Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "recent/2 and latest_unfinished/1 take a draft's rows, newest first" do
      %{draft: draft, run_id: waiting} = start_review()
      newer = insert_row!(draft, inserted_at: DateTime.add(DateTime.utc_now(:second), 30))
      older = insert_row!(draft, inserted_at: DateTime.add(DateTime.utc_now(:second), -300))
      insert_row!(draft!(hold_run()), [])

      assert Enum.map(Runs.recent(draft.id), & &1.id) == [newer.id, waiting, older.id]
      assert Enum.map(Composer.recent_runs(draft.id, 1), & &1.id) == [newer.id]

      # `newer` has no Core run but counts for now, as its start may be in flight.
      assert %Run{id: id} = Composer.latest_unfinished_run(draft.id)
      assert id == newer.id

      Repo.update_all(from(run in Run, where: run.id == ^newer.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -120)]
      )

      assert %Run{id: ^waiting} = Runs.latest_unfinished(draft.id)
    end
  end

  describe "the definition" do
    test "a finished run with a changed fingerprint opens, flagged" do
      held = start_held(hold_run())
      finish(held)

      assert {:ok, %{definition_changed?: false}} =
               Composer.open_run(Repo.get!(Run, held.run_id))

      Repo.update_all(from(row in Run, where: row.id == ^held.run_id),
        set: [fingerprint: "changed"]
      )

      assert {:ok, %{definition_changed?: true}} = Runs.open(Repo.get!(Run, held.run_id))
    end

    test "draft_changed?/2 counts a retry-only edit and not a moved card" do
      %{draft: draft, run_id: run_id} = start_review()
      row = Repo.get!(Run, run_id)

      moved = edit_all(draft.document, [{:move, :workflow, "review", 900, 900}])

      retried =
        edit_all(draft.document, [{:set_execution, "estimate_price", "estimate", 5, true}])

      refute Composer.run_draft_changed?(row, %{draft | document: moved})
      assert Runs.draft_changed?(row, %{draft | document: retried})
    end

    test "export bytes and root don't change with a run, and inputs export no metadata" do
      document = seed("Cracow house price review")
      assert {:valid, before} = Composer.validate(document)

      %{draft: draft} = start_review()

      assert {:valid, later} = Composer.validate(draft.document)
      assert later.json == before.json
      assert later.fingerprint == before.fingerprint
      assert {:ok, workflow} = CoreBridge.build(draft.document)
      assert Enum.all?(workflow.inputs, fn {_name, input} -> not is_map_key(input, :metadata) end)
    end

    test "an effectful hold runner can be used, for the phases that need one" do
      held = start_held(hold_run(UncertainHoldRunner))
      assert %{outcome: "succeeded"} = finish(held)
    end
  end

  defp with_unknown_commit_journal, do: with_journal(UnknownCommitJournal)

  defp with_journal(journal) do
    adapters = Application.fetch_env!(:domovoy, :composer_run_adapters)
    on_exit(fn -> Application.put_env(:domovoy, :composer_run_adapters, adapters) end)

    Application.put_env(
      :domovoy,
      :composer_run_adapters,
      Keyword.put(adapters, :journal, {journal, namespace: "composer"})
    )
  end

  # What the spy journal's reads have reported so far, in order.
  defp drain_in_transaction do
    receive do
      {:in_transaction, inside?} -> [inside? | drain_in_transaction()]
    after
      0 -> []
    end
  end
end
