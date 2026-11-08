defmodule DomovoyWeb.ComposerLauncherLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Ecto.Query

  import Domovoy.RunCase, only: [setup_runs: 1, start_attrs: 2, open!: 1, await_phase: 2]

  alias Domovoy.Composer
  alias Domovoy.Composer.InputSet
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Examples.Definitions
  alias Domovoy.Repo

  setup :setup_runs

  @string "DomovoyCore.Type.String"
  @integer "DomovoyCore.Type.Integer"
  @directory "DomovoyCore.Type.Directory"
  @secret "/secret/path"

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  defp seed(title), do: Enum.find(Definitions.all(), &(&1.title == title)).document

  # Cracow's runners declare no effect, so its start has an effect review.
  defp review_draft(ops \\ []), do: draft!(edit_all(seed("Cracow house price review"), ops))

  defp rows(draft), do: Repo.all(from(row in Run, where: row.draft_id == ^draft.id))

  defp start(view) do
    %{socket: %{assigns: %{start: start}}} = :sys.get_state(view.pid)
    start
  end

  defp run_id_of(path),
    do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("run")

  defp save_set!(draft, name, params, opt_ins \\ []) do
    {:ok, latest} = Composer.get_draft(draft.id)
    fields = RunInputs.fields(latest.document)
    {:ok, set} = Composer.save_input_set(draft.id, name, fields, params, opt_ins)
    set
  end

  defp save_edits!(draft, ops) do
    {:ok, latest} = Composer.get_draft(draft.id)
    {:ok, saved} = Composer.save_document(latest, edit_all(latest.document, ops))
    saved
  end

  # The draft's page with the launcher open and its sets loaded.
  defp open_launcher(conn, draft) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    render_async(view, 5_000)
    view |> element("#start-run", "New run") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#launcher-panel:not([hidden]) #start-form")
    view
  end

  test "Back to inputs from the effects review keeps the text and the ids", %{conn: conn} do
    view = open_launcher(conn, review_draft())

    view |> form("#start-form", start: @review_form) |> render_submit()
    assert has_element?(view, "#start-effects")
    before = start(view)

    view |> element("#back-to-inputs") |> render_click()

    refute has_element?(view, "#start-effects")
    assert has_element?(view, "#start-form input[name='start[area]'][value='58.5']")
    back = start(view)

    assert {back.params, back.run_id, back.command_id} ==
             {before.params, before.run_id, before.command_id}
  end

  test "the effects review lists each node by stage and node", %{conn: conn} do
    view = open_launcher(conn, review_draft())
    view |> form("#start-form", start: @review_form) |> render_submit()

    assert has_element?(
             view,
             "#start-effect-estimate_price-normalize",
             "estimate_price / normalize:"
           )

    assert has_element?(view, "#start-effects-title", "may change things outside Composer")
  end

  test "a described bound input shows its description and Required to run", %{conn: conn} do
    view = open_launcher(conn, review_draft())

    assert has_element?(view, "#start-field-area-description", "Floor area")
    assert has_element?(view, "#start-field-area-required", "Required to run")
    assert has_element?(view, "#input-from-run button[disabled]", "From a previous run")
  end

  describe "a saved set" do
    test "fills eligible fields, marks the rest, and starts in two clicks from a run page", %{
      conn: conn
    } do
      draft = draft!(edit_all(leak_run(), [{:put_input, "repo", %{"type" => @directory}}]))
      {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
      {:ok, source} = Composer.start_run(start_attrs(draft, values))
      await_phase(open!(source), "finished")

      # The path wasn't opted in, so it isn't kept.
      set = save_set!(draft, "Sample", %{"secret" => "t", "mode" => "succeed", "repo" => @secret})

      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{source}")
      render_async(view, 5_000)

      view |> element("#new-run") |> render_click()
      render_async(view, 5_000)
      view |> element("#input-set-use-#{set.id}") |> render_click()

      assert has_element?(view, "#start-form input[name='start[mode]'][value='succeed']")
      assert has_element?(view, "#start-form input[name='start[secret]'][value='t']")
      refute has_element?(view, "#start-form input[name='start[repo]'][value]")
      assert has_element?(view, "#start-field-repo-unset", "Not saved in Sample")
      view |> element("#close-start") |> render_click()

      # New run, then Start with this set.
      view |> element("#new-run") |> render_click()
      render_async(view, 5_000)
      view |> element("#input-set-start-#{set.id}") |> render_click()
      render_async(view, 5_000)

      run_id = view |> assert_patch() |> run_id_of()
      assert run_id != source
      set_id = set.id
      assert %Run{source_run_id: ^source, input_set_id: ^set_id} = Repo.get!(Run, run_id)
    end

    test "a field another tab retypes drifts after the conflict and blocks Start", %{
      conn: conn
    } do
      draft = draft!(edit_all(leak_run(), [{:put_input, "rooms", %{"type" => @string}}]))
      set = save_set!(draft, "Old", %{"rooms" => "3", "mode" => "succeed"})

      view = open_launcher(conn, draft)
      view |> element("#input-set-use-#{set.id}") |> render_click()
      assert start(view).drift == []

      save_edits!(draft, [{:put_input, "rooms", %{"type" => @integer}}])
      view |> form("#start-form", start: %{"secret" => "s"}) |> render_submit()
      render_async(view, 5_000)

      assert has_element?(view, "#launcher-draft-changed")
      assert has_element?(view, "#start-drift-rooms", "changed type")
      assert has_element?(view, "#submit-start[disabled]")
      render_hook(view, "submit_start", %{"start" => %{"secret" => "s", "mode" => "succeed"}})
      render_async(view, 5_000)
      assert rows(draft) == []

      view |> element("#ack-drift") |> render_click()
      refute has_element?(view, "#submit-start[disabled]")
    end

    test "one that drifted lists what changed and blocks Start until acknowledged", %{
      conn: conn
    } do
      draft =
        draft!(
          edit_all(leak_run(), [
            {:put_input, "note", %{"type" => @string}},
            {:put_input, "rooms", %{"type" => @string}}
          ])
        )

      set = save_set!(draft, "Old", %{"note" => "n", "rooms" => "3", "mode" => "succeed"})
      save_edits!(draft, [{:remove_input, "note"}, {:put_input, "rooms", %{"type" => @integer}}])

      view = open_launcher(conn, draft)
      view |> element("#input-set-use-#{set.id}") |> render_click()

      assert has_element?(view, "#start-drift-note", "was removed")
      assert has_element?(view, "#start-drift-rooms", "changed type")
      assert has_element?(view, "#submit-start[disabled]")

      # A submit before the acknowledgement starts nothing.
      render_hook(view, "submit_start", %{"start" => %{"secret" => "s", "mode" => "succeed"}})
      assert rows(draft) == []

      view |> element("#ack-drift") |> render_click()
      refute has_element?(view, "#submit-start[disabled]")
      refute has_element?(view, "#ack-drift")
    end

    test "Save keeps the text typed into the same submit, and Use fills it in", %{conn: conn} do
      draft = review_draft()
      view = open_launcher(conn, draft)

      view
      |> form("#start-form", start: %{"area" => "58.5"}, set_name: "Sample flat")
      |> render_submit(%{"intent" => "save"})

      assert has_element?(view, "#input-set-notice", "Saved as Sample flat")
      assert rows(draft) == []

      assert [%InputSet{id: id, values: %{"area" => %{"text" => "58.5"}}}] =
               Composer.list_input_sets(draft.id)

      view |> element("#close-start") |> render_click()
      view |> element("#start-run", "New run") |> render_click()
      render_async(view, 5_000)
      refute has_element?(view, "#start-form input[name='start[area]'][value='58.5']")

      view |> element("#input-set-use-#{id}") |> render_click()
      assert has_element?(view, "#start-form input[name='start[area]'][value='58.5']")

      # The same name again saves nothing.
      view
      |> form("#start-form", start: %{"area" => "60"}, set_name: "Sample flat")
      |> render_submit(%{"intent" => "save"})

      assert has_element?(view, "#input-set-notice", "exists")
      assert [_one] = Composer.list_input_sets(draft.id)
    end

    test "Enter in the set name is handled by its hook, and a save starts nothing", %{
      conn: conn
    } do
      draft = review_draft()
      view = open_launcher(conn, draft)
      assert has_element?(view, "#start-form #save-input-set-name[phx-hook]")

      calls =
        Domovoy.CoreCallTrace.calls(fn ->
          view
          |> form("#start-form", start: @review_form, set_name: "Sample flat")
          |> render_submit(%{"intent" => "save"})

          render_async(view, 5_000)
        end)

      assert has_element?(view, "#input-set-notice", "Saved as Sample flat")
      refute has_element?(view, "#start-effects")
      refute Enum.any?(calls, &match?({:start, _args}, &1))
      assert rows(draft) == []
    end

    test "an opted-in value is used but never shown", %{conn: conn} do
      draft = review_draft([{:put_input, "repo", %{"type" => @directory}}])
      set = save_set!(draft, "Secret", Map.put(@review_form, "repo", @secret), ["repo"])
      assert set.values["repo"]["text"] == @secret

      view = open_launcher(conn, draft)
      view |> element("#input-set-use-#{set.id}") |> render_click()

      assert has_element?(view, "#start-field-repo-reused", "Using the saved value from Secret")
      refute has_element?(view, "#start-form input[name='start[repo]'][value]")
      refute render(view) =~ @secret

      # A submit refused on another field.
      view |> form("#start-form", start: Map.put(@review_form, "rooms", "x")) |> render_submit()
      assert has_element?(view, "#start-field-rooms .text-error")
      refute render(view) =~ @secret
      assert start(view).params["repo"] in [nil, ""]

      # The effect review holds it in the values only, and Back keeps it out of the form.
      view |> form("#start-form", start: @review_form) |> render_submit()
      assert start(view).values["repo"] == @secret
      refute render(view) =~ @secret
      view |> element("#back-to-inputs") |> render_click()
      refute render(view) =~ @secret
      assert start(view).params["repo"] in [nil, ""]

      # A draft saved meanwhile re-sources the launcher.
      view |> form("#start-form", start: @review_form) |> render_submit()
      save_edits!(draft, [{:put_input, "extra", %{"type" => @string}}])
      view |> element("#confirm-start") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#launcher-draft-changed")
      refute render(view) =~ @secret
      assert rows(draft) == []
    end

    test "Clear drops a reused value from the start", %{conn: conn} do
      draft = review_draft([{:put_input, "repo", %{"type" => @directory}}])
      set = save_set!(draft, "Secret", Map.put(@review_form, "repo", @secret), ["repo"])

      view = open_launcher(conn, draft)
      view |> element("#input-set-use-#{set.id}") |> render_click()
      view |> element("#start-field-repo-clear") |> render_click()

      refute has_element?(view, "#start-field-repo-reused")
      view |> form("#start-form", start: @review_form) |> render_submit()
      refute Map.has_key?(start(view).values, "repo")
    end
  end

  test "malformed and other drafts' set ids are refused and start nothing", %{conn: conn} do
    draft = draft!(leak_run())
    other = draft!(leak_run())
    foreign = save_set!(other, "Foreign", %{"secret" => "f", "mode" => "succeed"})
    view = open_launcher(conn, draft)

    for event <- ~w(choose_input_set start_with_input_set delete_input_set),
        id <- [foreign.id, "not-a-uuid", 7, %{"a" => 1}] do
      render_hook(view, event, %{"id" => id})
      assert has_element?(view, "#rejection", "doesn't exist anymore")
      refute has_element?(view, "#start-form input[name='start[secret]'][value='f']")
    end

    assert rows(draft) == []
    assert {:ok, _still_there} = Composer.fetch_input_set(other.id, foreign.id)
    assert start(view).input_set_id == nil
  end
end
