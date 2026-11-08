defmodule DomovoyWeb.ComposerIssuesLiveTest do
  # Not async: the Core rejection test swaps a global application env.
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer.Document

  @string "DomovoyCore.Type.String"
  @date "DomovoyCore.Type.Date"
  @any "DomovoyCore.Type.Any"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @list "DomovoyClaudeCodePlugin.Runner.ListSessions"
  @detect "DomovoyMisePlugin.Runner.Detect"

  defp open(conn, document) do
    draft = draft!(document)
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/main")
    render_click(element(view, "#open-tools"))
    {draft, view}
  end

  defp doc(ops), do: edit_all(Document.new("w"), ops)
  defp click(view, selector), do: view |> element(selector) |> render_click()

  defp issue_link?(view, target) do
    has_element?(view, "#issues li a[href='##{target}']")
  end

  describe "the issue list" do
    test "lists node, graph and workflow problems at once, each linked", %{conn: conn} do
      document =
        doc([
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @detect, "detect"},
          {:put_input, "both", %{"type" => @string, "required" => true, "default" => "x"}},
          {:set_next, "main", nil}
        ])
        |> put_in(["vertices", "main", "nodes", "detect", "after"], ["gone"])
        |> put_in(["start"], "nowhere")

      {_draft, view} = open(conn, document)

      assert issue_link?(view, "field-resolve-worktree_name")
      assert issue_link?(view, "rel-after-detect-gone")
      assert issue_link?(view, "input-both")
      assert issue_link?(view, "workflow-settings")
      assert has_element?(view, "#issues li code", "invalid_node")
      assert has_element?(view, "#field-resolve-worktree_name[tabindex='-1']")
      assert has_element?(view, "#rel-after-detect-gone[tabindex='-1']")

      click(view, "#issues a[href='#rel-after-detect-gone']")
      assert has_element?(view, "#composer-tools #rel-after-detect-gone")
      assert has_element?(view, "#inspector-panel")
      assert_push_event(view, "composer:focus", %{id: "rel-after-detect-gone"})
      click(view, "#validate")
      refute has_element?(view, "#definition-valid")
    end

    test "following a node's issue selects that node", %{conn: conn} do
      {_draft, view} = open(conn, doc([{:add_node, "main", @resolve, "resolve"}]))

      view |> element("#issue-0 a") |> render_click()

      assert has_element?(view, "#inspector-runner-label", "Git WorktreeResolve")
      refute has_element?(view, "#composer-tools")
      assert_push_event(view, "composer:focus", %{id: "field-resolve-worktree_name"})
    end

    test "a blank default bound to a required field shows on that field", %{conn: conn} do
      document =
        doc([
          {:put_input, "name", %{"type" => @string, "default" => " "}},
          {:add_node, "main", @resolve, "resolve"},
          {:bind, "main", "resolve", "worktree_name", "name", replace_literal: false}
        ])

      {_draft, view} = open(conn, document)

      assert issue_link?(view, "field-resolve-worktree_name")
      assert has_element?(view, "#field-resolve-worktree_name p", "a run omitting name fails")

      click(view, "#validate")
      refute has_element?(view, "#definition-valid")
    end
  end

  describe "when Core rejects what the analyzer missed" do
    setup do
      previous = Application.fetch_env(:domovoy, :composer_export_steps)

      on_exit(fn ->
        case previous do
          {:ok, steps} -> Application.put_env(:domovoy, :composer_export_steps, steps)
          :error -> Application.delete_env(:domovoy, :composer_export_steps)
        end
      end)
    end

    test "the issue shows its core id and the view stays alive", %{conn: conn} do
      Application.put_env(:domovoy, :composer_export_steps, %{
        build: fn _document -> raise ArgumentError, "invalid_node: hidden detail" end
      })

      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")
      render_click(element(view, "#open-tools"))

      assert has_element?(view, "#issues-empty")
      click(view, "#validate")

      assert has_element?(view, "#issues li code", "invalid_node")
      refute has_element?(view, "#issues", "hidden detail")
      refute has_element?(view, "#definition-valid")
      refute has_element?(view, "#definition-fingerprint")
      refute has_element?(view, "#export")

      assert has_element?(view, "#composer")
      click(view, "#rel-after-ask_claude-trust_mise-delete")
      refute has_element?(view, "#issues li code", "invalid_node")
    end

    test "the export route answers 422", %{conn: conn} do
      Application.put_env(:domovoy, :composer_export_steps, %{
        build: fn _document -> raise ArgumentError, "invalid_node: hidden detail" end
      })

      draft = draft!(scenario_a())

      assert conn |> get(~p"/composer/#{draft.id}/export") |> response(422)
    end
  end

  test "an incomplete draft saves, shows its issue and gives no fingerprint", %{conn: conn} do
    {draft, view} = open(conn, doc([{:add_node, "main", @resolve, "resolve"}]))

    assert has_element?(view, "#field-resolve-worktree_name-missing")
    click(view, "#validate")

    refute has_element?(view, "#definition-fingerprint")
    assert saved_document(draft)["vertices"]["main"]["nodes"]["resolve"]

    {:ok, reloaded, _html} = live(conn, ~p"/composer/#{draft.id}/stages/main")
    render_click(element(reloaded, "#open-tools"))
    assert has_element?(reloaded, "#node-resolve")
    assert has_element?(reloaded, "#issues li")
  end

  describe "literals" do
    test "a bad Integer is an inline issue and export isn't offered", %{conn: conn} do
      {draft, view} = open(conn, doc([{:add_node, "main", @list, "list"}]))
      click(view, "#node-list-select")

      view
      |> form("#literal-form-list-limit", literal: %{value: "not an int"})
      |> render_submit()

      assert saved_document(draft)["vertices"]["main"]["nodes"]["list"]["inputs"]["limit"] ==
               %{"literal" => "not an int"}

      assert has_element?(view, "#field-list-limit p", "isn't a valid")
      assert issue_link?(view, "field-list-limit")

      click(view, "#validate")
      refute has_element?(view, "#export")
    end

    test "a bind-only field offers no literal editor", %{conn: conn} do
      {_draft, view} =
        open(conn, doc([{:add_node, "main", "DomovoyMisePlugin.Runner.Trust", "trust"}]))

      click(view, "#node-trust-select")

      assert has_element?(view, "#bind-only-trust-mise")
      refute has_element?(view, "#literal-form-trust-mise")
      assert has_element?(view, "#literal-form-trust-worktree")
    end
  end

  describe "workflow input defaults" do
    test "a calendar type offers no default control and stays usable", %{conn: conn} do
      {draft, view} = open(conn, doc([]))

      view |> form("#inputs-form", input: %{type: @date}) |> render_change()
      assert has_element?(view, "#inputs-bind-only")
      refute has_element?(view, "#inputs-form select[name='input[default_state]']")

      view |> form("#inputs-form", input: %{name: "day", type: @date}) |> render_submit()
      assert saved_document(draft)["inputs"]["day"] == %{"type" => @date, "required" => false}
      assert has_element?(view, "#input-day")
    end

    test "absent and null defaults stay distinct", %{conn: conn} do
      {draft, view} = open(conn, doc([]))

      view
      |> form("#inputs-form", input: %{name: "absent", type: @any, default_state: "absent"})
      |> render_submit()

      view
      |> form("#inputs-form", input: %{name: "null", type: @any, default_state: "null"})
      |> render_submit()

      inputs = saved_document(draft)["inputs"]
      refute is_map_key(inputs["absent"], "default")
      assert %{"default" => nil} = inputs["null"]
      assert has_element?(view, "#input-absent-default", "no default")
      assert has_element?(view, "#input-null-default", "null default")
    end

    test "null on a type refusing it, and required plus default, are issues", %{conn: conn} do
      {_draft, view} = open(conn, doc([]))

      view
      |> form("#inputs-form", input: %{name: "nothing", type: @string, default_state: "null"})
      |> render_submit()

      assert has_element?(view, "#issues li", "null")

      view
      |> form("#inputs-form", input: %{type: @string, default_state: "value"})
      |> render_change()

      view
      |> form("#inputs-form",
        input: %{
          name: "both",
          type: @string,
          required: "true",
          default_state: "value",
          default: "x"
        }
      )
      |> render_submit()

      assert has_element?(view, "#issues li", "required and has a default")
      assert has_element?(view, "#issues li code", "invalid_workflow_input")
    end

    test "edit fills the form, and remove takes the input away", %{conn: conn} do
      {draft, view} =
        open(conn, doc([{:put_input, "x", %{"type" => @string, "default" => "y"}}]))

      click(view, "#input-x-edit")
      assert has_element?(view, "#inputs-form input[name='input[name]'][value='x']")
      assert has_element?(view, "#inputs-form input[name='input[default]'][value='y']")

      click(view, "#input-x-remove")
      refute has_element?(view, "#input-x")
      refute is_map_key(saved_document(draft)["inputs"], "x")
    end
  end
end
