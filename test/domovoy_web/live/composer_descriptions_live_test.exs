defmodule DomovoyWeb.ComposerDescriptionsLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer.Document

  @string "DomovoyCore.Type.String"
  @integer "DomovoyCore.Type.Integer"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @icon ".hero-information-circle"
  @sentinel "sentinel-secret-value"
  @malformed [1, %{"description" => "   "}, @sentinel]

  # Stage `first` makes `made`, which stage `second` reads. Input `name` shows on both.
  defp sourced do
    edit_all(Document.new("w"), [
      {:put_input, "name", %{"type" => @string, "required" => true}},
      {:add_stage, "first"},
      {:add_stage, "second"},
      {:set_start, "first"},
      {:remove_vertex, "main"},
      {:set_next, "first", "second"},
      {:add_node, "first", @resolve, "made"},
      {:bind, "first", "made", "worktree_name", "name", replace_literal: false},
      {:add_node, "second", @directory, "reader"},
      {:bind, "second", "reader", "worktree", "made", replace_literal: false}
    ])
  end

  # Stage `after_review` reads `note`, a choice input.
  defp from_choice do
    edit_all(scenario_a(), [
      {:add_stage, "after_review"},
      {:put_choice, "review",
       %{
         "name" => "go",
         "description" => "Go on",
         "target" => ["run", "after_review"],
         "inputs" => %{"note" => @string}
       }},
      {:add_node, "after_review", @resolve, "again"},
      {:bind, "after_review", "again", "worktree_name", "note", replace_literal: false}
    ])
  end

  @made_path ["vertices", "first", "nodes", "made"]
  @made {:node, "first", "made"}

  # One row per surface: where its item is, the page showing it and its icon.
  defp surfaces do
    [
      %{
        document: sourced(),
        target: @made,
        path: @made_path,
        stage: "first",
        icon: "#node-made-description"
      },
      %{
        document: sourced(),
        target: {:vertex, "first"},
        path: ["vertices", "first"],
        stage: nil,
        icon: "#vertex-first-description"
      },
      %{
        document: scenario_a(),
        target: {:vertex, "review"},
        path: ["vertices", "review"],
        stage: nil,
        icon: "#vertex-review-description"
      },
      %{
        document: sourced(),
        target: {:input, "name"},
        path: ["inputs", "name"],
        stage: "second",
        icon: "#input-name-description"
      },
      %{
        document: sourced(),
        target: {:input, "name"},
        path: ["inputs", "name"],
        stage: "second",
        icon: "#source-name-description"
      },
      %{
        document: sourced(),
        target: @made,
        path: @made_path,
        stage: "second",
        icon: "#source-made-description"
      }
    ]
  end

  defp open(conn, document, stage) do
    draft = draft!(document)
    {draft, view(conn, draft, stage)}
  end

  defp view(conn, draft, nil) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    view
  end

  defp view(conn, draft, stage) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/#{stage}")
    view
  end

  defp click(view, selector), do: view |> element(selector) |> render_click()
  defp undo_offered?(view), do: has_element?(view, "#undo:not([disabled])")

  defp put_metadata(document, path, metadata) do
    put_in(document, path ++ ["metadata"], metadata)
  end

  describe "a description" do
    test "shows as a native title on each surface", %{conn: conn} do
      for surface <- surfaces() do
        document = edit_all(surface.document, [{:set_description, surface.target, "Plain text."}])
        {_draft, view} = open(conn, document, surface.stage)

        assert has_element?(view, ~s(#{surface.icon}[title="Plain text."]))
        assert has_element?(view, ~s(#{surface.icon}[aria-label="Plain text."]))
        assert has_element?(view, "#{surface.icon} #{@icon}")
        refute has_element?(view, "#{surface.icon}.text-error")
      end
    end

    test "sits beside a card's grip, never inside it", %{conn: conn} do
      document =
        edit_all(sourced(), [
          {:set_description, @made, "Plain text."},
          {:set_description, {:vertex, "first"}, "Plain text."}
        ])

      {_draft, stage} = open(conn, document, "first")
      assert has_element?(stage, "#node-made > header > #node-made-description")
      refute has_element?(stage, "#node-made-select #node-made-description")

      {_draft, workflow} = open(conn, document, nil)
      assert has_element?(workflow, "#vertex-first > header > #vertex-first-description")
      refute has_element?(workflow, "#vertex-first-select #vertex-first-description")
    end

    test "on an earlier source is its origin node's", %{conn: conn} do
      document = edit_all(sourced(), [{:set_description, @made, "Origin text."}])
      {_draft, view} = open(conn, document, "second")

      assert has_element?(view, ~s(#source-made-description[title="Origin text."]))
    end

    test "is absent from an earlier source read from a choice input", %{conn: conn} do
      {_draft, view} = open(conn, from_choice(), "after_review")

      assert has_element?(view, "#source-note")
      refute has_element?(view, "#source-note-description")
    end

    test "on an input shown twice keeps every id on the page unique", %{conn: conn} do
      document = edit_all(sourced(), [{:set_description, {:input, "name"}, "Plain text."}])
      {_draft, view} = open(conn, document, "second")

      assert has_element?(view, "#input-name-description")
      assert has_element?(view, "#source-name-description")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[id]")
        |> LazyHTML.attribute("id")

      assert ids == Enum.uniq(ids)
    end
  end

  describe "absent metadata" do
    test "shows no icon on any surface", %{conn: conn} do
      for surface <- surfaces(), metadata <- [:none, %{}, %{"other" => 1}] do
        document =
          if metadata == :none,
            do: surface.document,
            else: put_metadata(surface.document, surface.path, metadata)

        {_draft, view} = open(conn, document, surface.stage)

        refute has_element?(view, surface.icon), inspect({surface.icon, metadata})
      end
    end
  end

  describe "malformed metadata" do
    test "shows a red icon that never echoes the value, and stays validatable", %{conn: conn} do
      for surface <- surfaces(), metadata <- @malformed do
        document = put_metadata(surface.document, surface.path, metadata)
        {_draft, view} = open(conn, document, surface.stage)
        label = inspect({surface.icon, metadata})

        assert has_element?(view, "#{surface.icon}.text-error #{@icon}"), label
        refute has_element?(view, ~s(#{surface.icon}[title*="#{@sentinel}"])), label
        refute has_element?(view, ~s(#{surface.icon}[aria-label*="#{@sentinel}"])), label
        refute render(view) =~ @sentinel, label

        click(view, "#validate")
        assert has_element?(view, "#definition-valid"), label
      end
    end

    test "on a description holding the sentinel doesn't reach the page", %{conn: conn} do
      document = put_metadata(sourced(), @made_path, %{"description" => %{"x" => @sentinel}})
      {_draft, view} = open(conn, document, "second")

      assert has_element?(view, "#source-made-description.text-error")
      refute render(view) =~ @sentinel
    end
  end

  describe "editing" do
    defp described_floor do
      edit_all(sourced(), [
        {:put_input, "floor", %{"type" => @string}},
        {:set_description, {:input, "floor"}, "Plain text."}
      ])
    end

    test "saving an input with a new type keeps it, and undo restores the input", %{conn: conn} do
      {draft, view} = open(conn, described_floor(), "second")
      before = saved_document(draft)["inputs"]["floor"]

      click(view, "#input-floor-edit")
      view |> form("#inputs-form", input: %{type: @integer}) |> render_submit()

      saved = saved_document(draft)["inputs"]["floor"]
      assert saved["type"] == @integer
      assert Document.description(saved) == {:ok, "Plain text."}
      assert has_element?(view, ~s(#input-floor-description[title="Plain text."]))

      click(view, "#undo")
      assert saved_document(draft)["inputs"]["floor"] == before
    end

    test "saving an unchanged input is no edit", %{conn: conn} do
      {draft, view} = open(conn, described_floor(), "second")
      before = saved_document(draft)

      click(view, "#input-floor-edit")
      view |> form("#inputs-form") |> render_submit()

      assert saved_document(draft) == before
      refute undo_offered?(view)
    end

    test "replacing a runner removes the icon, and undo restores both", %{conn: conn} do
      document = edit_all(sourced(), [{:set_description, @made, "Plain text."}])
      {draft, view} = open(conn, document, "first")

      click(view, "#node-made-select")
      view |> form("#replace-runner-form", replace: %{runner: @detect}) |> render_submit()
      click(view, "#confirm-replace-runner")

      refute has_element?(view, "#node-made-description")
      refute is_map_key(saved_document(draft)["vertices"]["first"]["nodes"]["made"], "metadata")

      click(view, "#undo")

      assert has_element?(view, ~s(#node-made-description[title="Plain text."]))
      assert saved_document(draft)["vertices"]["first"]["nodes"]["made"]["runner"] == @resolve
    end
  end
end
