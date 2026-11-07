defmodule DomovoyWeb.ComposerRunStartLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.RunCase, only: [setup_runs: 1, open!: 1, await_phase: 2, open_gate: 0]
  import Ecto.Query

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Run
  alias Domovoy.Examples.Definitions
  alias Domovoy.Repo

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp seed(title), do: Enum.find(Definitions.all(), &(&1.title == title)).document

  defp rows(draft), do: Repo.all(from(row in Run, where: row.draft_id == ^draft.id))

  defp open_form(conn, draft) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    render_async(view, 5_000)
    view |> element("#start-run") |> render_click()
    assert has_element?(view, "#start-form")
    view
  end

  defp run_id_of(path),
    do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("run")

  # The ids the open form holds, as a second tab sharing them would.
  defp form_ids(view) do
    %{socket: %{assigns: %{start: start}}} = :sys.get_state(view.pid)
    start
  end

  test "the review seed's four values and a confirmation start one run, then show it", %{
    conn: conn
  } do
    draft = draft!(seed("Cracow house price review"), "Review")
    view = open_form(conn, draft)

    view |> form("#start-form", start: @review_form) |> render_submit()

    # Cracow's runners declare no effect, so they count as able to change things.
    assert has_element?(view, "#start-effects")
    assert has_element?(view, "#start-effects-list li")
    assert rows(draft) == []

    view |> element("#confirm-start") |> render_click()
    render_async(view, 5_000)
    run_id = view |> assert_patch() |> run_id_of()

    assert [%Run{id: ^run_id}] = rows(draft)
    assert %{committed_phase: "waiting"} = await_phase(open!(run_id), "waiting")

    render_async(view, 5_000)
    assert has_element?(view, "#run-header")
    assert has_element?(view, "#stage-canvas[data-read-only]")
  end

  test "a double submit starts one run", %{conn: conn} do
    draft = draft!(seed("Cracow house price review"), "Review")
    view = open_form(conn, draft)

    view |> form("#start-form", start: @review_form) |> render_submit()
    view |> element("#confirm-start") |> render_click()
    render_hook(view, "confirm_start", %{})
    render_hook(view, "submit_start", %{"start" => @review_form})
    render_async(view, 5_000)

    assert [_one] = rows(draft)
  end

  describe "the confirmation matches what starts" do
    test "after Load latest, Confirm starts nothing until the form is submitted again", %{
      conn: conn
    } do
      draft = draft!(seed("Cracow house price review"), "Review")
      view = open_form(conn, draft)

      view |> form("#start-form", start: @review_form) |> render_submit()
      assert has_element?(view, "#start-effects")

      # Another tab saves, so this tab's next edit conflicts and offers Load latest.
      {:ok, _saved} = Composer.save_document(draft, draft.document)
      render_hook(view, "add_vertex", %{"vertex" => %{"name" => "extra", "kind" => "stage"}})
      view |> element("#load-latest") |> render_click()
      assert_patch(view, ~p"/composer/#{draft.id}")

      view |> element("#confirm-start") |> render_click()
      render_async(view, 5_000)

      assert rows(draft) == []
      assert has_element?(view, "#conflict-banner")
      refute has_element?(view, "#confirm-start")

      assert_fresh_submit_starts_one_run(view, draft)
    end

    test "after an Undo, Confirm starts nothing until the form is submitted again", %{
      conn: conn
    } do
      draft = draft!(seed("Cracow house price review"), "Review")
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      render_async(view, 5_000)

      render_hook(view, "add_vertex", %{"vertex" => %{"name" => "extra", "kind" => "stage"}})
      view |> element("#start-run") |> render_click()
      view |> form("#start-form", start: @review_form) |> render_submit()
      assert has_element?(view, "#start-effects")

      view |> element("#undo") |> render_click()
      view |> element("#confirm-start") |> render_click()
      render_async(view, 5_000)

      assert rows(draft) == []
      assert has_element?(view, "#conflict-banner")
      refute has_element?(view, "#confirm-start")

      assert_fresh_submit_starts_one_run(view, draft)
    end
  end

  defp assert_fresh_submit_starts_one_run(view, draft) do
    view |> form("#start-form", start: @review_form) |> render_submit()
    view |> element("#confirm-start") |> render_click()
    render_async(view, 5_000)
    run_id = view |> assert_patch() |> run_id_of()

    assert [%Run{id: ^run_id}] = rows(draft)
    assert %{committed_phase: "waiting"} = await_phase(open!(run_id), "waiting")
  end

  test "a stale tab shows the conflict banner and starts nothing", %{conn: conn} do
    draft = draft!(hold_run(), "Held")
    view = open_form(conn, draft)

    {:ok, _saved} = Composer.save_document(draft, draft.document)

    view |> form("#start-form", start: %{"trap_exit" => "false"}) |> render_submit()
    render_async(view, 5_000)

    assert has_element?(view, "#conflict-banner")
    assert rows(draft) == []
  end

  test "an invalid draft lists its issues and closes the form", %{conn: conn} do
    document =
      edit_all(Document.new("broken"), [{:add_node, "main", "Domovoy.LeakRunner", "leak"}])

    draft = draft!(document, "Broken")
    view = open_form(conn, draft)

    view |> form("#start-form") |> render_submit()
    render_async(view, 5_000)

    refute has_element?(view, "#start-form")
    assert has_element?(view, "#composer-tools #issues li")
    assert rows(draft) == []
  end

  test "a blank bound input marks that field and starts nothing", %{conn: conn} do
    draft = draft!(leak_run(), "Leak")
    view = open_form(conn, draft)

    view |> form("#start-form", start: %{"secret" => "", "mode" => "succeed"}) |> render_submit()

    assert has_element?(view, "#start-field-secret", "This run needs a value here.")
    refute has_element?(view, "#start-field-mode .text-error")
    assert has_element?(view, "#start-form input[name='start[mode]'][value='succeed']")
    assert rows(draft) == []
  end

  test "a required Date blocks Start with an explanation", %{conn: conn} do
    document =
      edit_all(hold_run(), [
        {:put_input, "day", %{"type" => "DomovoyCore.Type.Date", "required" => true}}
      ])

    draft = draft!(document, "Dated")
    view = open_form(conn, draft)

    assert has_element?(view, "#start-blocked", "day")
    assert has_element?(view, "#submit-start[disabled]")
  end

  test "a path is checked only on submit, and a refused one isn't echoed", %{conn: conn} do
    open_gate()

    document =
      edit_all(hold_run(), [{:put_input, "repo", %{"type" => "DomovoyCore.Type.Directory"}}])

    draft = draft!(document, "Paths")
    view = open_form(conn, draft)

    # The form has no change event, so typing reaches nothing on the server.
    refute has_element?(view, "#start-form[phx-change]")

    view |> form("#start-form", start: %{"repo" => "relative/dir"}) |> render_submit()
    assert has_element?(view, "#start-field-repo", "Use an absolute path")

    missing = "/nonexistent-#{System.unique_integer([:positive])}/dir"
    view |> form("#start-form", start: %{"repo" => missing}) |> render_submit()
    render_async(view, 5_000)

    assert has_element?(view, "#start-field-repo", "Core refused this value.")
    refute view |> element("#start-field-repo .text-error") |> render() =~ missing
    assert rows(draft) == []
  end

  test "an input error on a start that already committed still opens that run", %{conn: conn} do
    open_gate()

    document =
      edit_all(hold_run(), [{:put_input, "repo", %{"type" => "DomovoyCore.Type.Directory"}}])

    draft = draft!(document, "Paths")
    view = open_form(conn, draft)

    # Another tab committed these very ids first.
    ids = form_ids(view)

    {:ok, run_id} =
      Composer.start_run(%{
        draft_id: draft.id,
        lock_version: draft.lock_version,
        run_id: ids.run_id,
        command_id: ids.command_id,
        values: %{"trap_exit" => false}
      })

    assert_receive {:entered, "hold", _runner}, 5_000

    missing = "/nonexistent-#{System.unique_integer([:positive])}/dir"
    view |> form("#start-form", start: %{"repo" => missing}) |> render_submit()
    render_async(view, 5_000)

    assert view |> assert_patch() |> run_id_of() == run_id
    assert [%Run{id: ^run_id}] = rows(draft)
  end

  test "with runs off, no Start shows and crafted start events start nothing", %{conn: conn} do
    Application.put_env(:domovoy, :composer_runs_enabled, false)
    draft = draft!(hold_run(), "Held")
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    refute has_element?(view, "#start-run")
    refute has_element?(view, "#recent-runs")

    for {event, params} <- [
          {"open_start", %{}},
          {"submit_start", %{"start" => %{"trap_exit" => "false"}}},
          {"confirm_start", %{}}
        ] do
      render_hook(view, event, params)
    end

    refute has_element?(view, "#start-form")
    assert rows(draft) == []
  end
end
