defmodule DomovoyWeb.ComposerRunNewRunLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Ecto.Query

  import Domovoy.RunCase,
    only: [
      setup_runs: 1,
      start_attrs: 2,
      open!: 1,
      await_phase: 2,
      open_gate: 0,
      watch: 1,
      await_delivered: 1
    ]

  alias Domovoy.Composer
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs
  alias Domovoy.CoreCallTrace
  alias Domovoy.Repo

  setup :setup_runs

  @string "DomovoyCore.Type.String"

  defp rows(draft), do: Repo.all(from(row in Run, where: row.draft_id == ^draft.id))

  defp run_id_of(path),
    do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("run")

  defp start(view) do
    %{socket: %{assigns: %{start: start}}} = :sys.get_state(view.pid)
    start
  end

  # A leak run that has finished, and its page.
  defp finished_run(conn) do
    draft = draft!(leak_run(), "Leak")
    {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "finished")

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{run_id}")
    render_async(view, 5_000)
    assert has_element?(view, "#run-outcome", "succeeded")
    %{draft: draft, run_id: run_id, view: view}
  end

  # Saves the draft as it is now with these edits, as another tab would.
  defp save_edits!(draft, ops) do
    {:ok, latest} = Composer.get_draft(draft.id)
    {:ok, saved} = Composer.save_document(latest, edit_all(latest.document, ops))
    saved
  end

  # A held run of `hold_run/0` and its page, once its attempt has reached the page.
  defp held_run(conn) do
    open_gate()
    draft = draft!(hold_run(), "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", _runner}, 5_000

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{run_id}")
    watch(view.pid)
    render_async(view, 5_000)
    await_delivered(&(&1["type"] == "attempt_admitted"))
    render(view)
    %{draft: draft, run_id: run_id, view: view}
  end

  test "New run from a finished run uses the current saved draft", %{conn: conn} do
    %{draft: draft, run_id: source, view: view} = finished_run(conn)

    # The draft gains an input after the page mounted on the run's snapshot.
    saved = save_edits!(draft, [{:put_input, "rooms", %{"type" => @string}}])

    view |> element("#new-run") |> render_click()

    assert has_element?(view, "#launcher-panel:not([hidden])")
    assert has_element?(view, "#launcher-source", "the current saved draft")
    refute has_element?(view, "#launcher-source", "the current run continues")

    for name <- ~w(secret mode rooms),
        do: assert(has_element?(view, "#launcher-panel #start-field-#{name}"))

    view
    |> form("#start-form", start: %{"secret" => "t", "mode" => "succeed", "rooms" => "4"})
    |> render_submit()

    render_async(view, 5_000)
    run_id = view |> assert_patch() |> run_id_of()

    assert run_id != source
    assert %Run{document: document, source_run_id: ^source} = Repo.get!(Run, run_id)
    assert document == saved.document
    refute has_element?(view, "#launcher-panel")
  end

  test "New run from an active run leaves it running", %{conn: conn} do
    %{draft: draft, run_id: source, view: view} = held_run(conn)
    %{socket: %{assigns: %{run: before}}} = :sys.get_state(view.pid)
    assert before.sub && before.monitor

    view |> element("#new-run") |> render_click()
    assert has_element?(view, "#launcher-source", "the current run continues")
    view |> element("#launcher-panel #close-start") |> render_click()
    refute has_element?(view, "#launcher-panel")

    %{socket: %{assigns: %{run: after_close}}} = :sys.get_state(view.pid)

    assert {after_close.id, after_close.sub, after_close.monitor} ==
             {source, before.sub, before.monitor}

    view |> element("#new-run") |> render_click()
    view |> form("#start-form", start: %{"trap_exit" => "false"}) |> render_submit()
    render_async(view, 5_000)
    run_id = view |> assert_patch() |> run_id_of()
    assert_receive {:entered, "hold", _runner}, 5_000

    render_async(view, 5_000)
    assert has_element?(view, "#run-id", String.slice(run_id, 0, 8))

    {:ok, row} = Composer.get_run(draft.id, source)
    {:ok, %{handle: handle}} = Composer.open_run(row)
    assert {:ok, %{committed_phase: phase}} = Composer.run_view(handle)
    assert phase != "finished"
  end

  test "a draft saved after the launcher opened is a conflict that keeps text and ids", %{
    conn: conn
  } do
    %{draft: draft, view: view} = finished_run(conn)

    view |> element("#new-run") |> render_click()
    opened = start(view)

    saved = save_edits!(draft, [{:put_input, "rooms", %{"type" => @string}}])

    view
    |> form("#start-form", start: %{"secret" => "t", "mode" => "succeed"})
    |> render_submit()

    render_async(view, 5_000)

    assert has_element?(view, "#launcher-draft-changed")
    assert has_element?(view, "#launcher-panel #start-field-rooms")
    assert has_element?(view, "#start-form input[name='start[mode]'][value='succeed']")

    later = start(view)
    assert {later.run_id, later.command_id} == {opened.run_id, opened.command_id}
    assert later.params == %{"secret" => "t", "mode" => "succeed"}
    assert later.lock_version == saved.lock_version
    assert length(rows(draft)) == 1

    # Submitted again, it starts against the draft it now shows, with the same ids.
    view
    |> form("#start-form", start: %{"secret" => "t", "mode" => "succeed"})
    |> render_submit()

    render_async(view, 5_000)
    assert view |> assert_patch() |> run_id_of() == opened.run_id
    assert %Run{document: document} = Repo.get!(Run, opened.run_id)
    assert document == saved.document
  end

  test "an invalid saved draft keeps the launcher open with Fix in editor", %{conn: conn} do
    %{draft: draft, view: view} = finished_run(conn)
    save_edits!(draft, [{:add_node, "main", "Domovoy.LeakRunner", "unbound"}])

    view |> element("#new-run") |> render_click()

    view
    |> form("#start-form", start: %{"secret" => "t", "mode" => "succeed"})
    |> render_submit()

    render_async(view, 5_000)

    assert has_element?(view, "#launcher-panel:not([hidden]) #launcher-invalid")
    assert has_element?(view, "#launcher-fix[href='/composer/#{draft.id}?tools=1']")
    assert has_element?(view, "#start-form input[name='start[mode]'][value='succeed']")
    assert length(rows(draft)) == 1

    {:ok, editor, _html} = live(conn, ~p"/composer/#{draft.id}?tools=1")
    assert has_element?(editor, "#composer-tools #issues li")
  end

  test "?launch=1 opens the launcher once connected, and the param is patched away", %{
    conn: conn
  } do
    draft = draft!(hold_run(), "Held")
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?launch=1")

    assert has_element?(view, "#launcher-panel:not([hidden]) #start-form")
    assert has_element?(view, "#workspace[data-surface='launcher']")
    assert has_element?(view, "#surface-launcher", "New run")

    # A patch to the URL without the param, as the mount's own patch is, keeps it open.
    render_patch(view, ~p"/composer/#{draft.id}")
    assert has_element?(view, "#launcher-panel:not([hidden]) #start-form")
    assert has_element?(view, "#workspace[data-surface='launcher']")

    # Anything but "1" opens nothing.
    {:ok, other, _html} = live(conn, ~p"/composer/#{draft.id}?launch=yes")
    refute has_element?(other, "#launcher-panel")
  end

  test "the workflow list links each draft to its launcher", %{conn: conn} do
    draft = draft!(hold_run(), "Held")
    {:ok, view, _html} = live(conn, ~p"/composer")

    assert has_element?(view, "#new-run-#{draft.id}[href='/composer/#{draft.id}?launch=1']")
  end

  test "opening the launcher on a run page makes no Core call", %{conn: conn} do
    %{view: view} = finished_run(conn)

    assert CoreCallTrace.calls(fn -> view |> element("#new-run") |> render_click() end) == []
    assert has_element?(view, "#launcher-panel")
  end

  test "with runs off, no New run shows and a crafted open_start opens nothing", %{conn: conn} do
    Application.put_env(:domovoy, :composer_runs_enabled, false)
    draft = draft!(hold_run(), "Held")

    {:ok, list, _html} = live(conn, ~p"/composer")
    assert has_element?(list, "#open-#{draft.id}")
    refute has_element?(list, "#new-run-#{draft.id}")

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?launch=1")
    refute has_element?(view, "#start-run")

    calls =
      CoreCallTrace.calls(fn ->
        render_hook(view, "open_start", %{})
        render_hook(view, "submit_start", %{"start" => %{"trap_exit" => "false"}})
      end)

    assert calls == []
    refute has_element?(view, "#launcher-panel")
    assert rows(draft) == []
  end
end
