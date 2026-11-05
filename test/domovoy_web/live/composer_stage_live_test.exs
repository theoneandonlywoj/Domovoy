defmodule DomovoyWeb.ComposerStageLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Catalog
  alias Domovoy.Composer
  alias Domovoy.Composer.Document

  @string "DomovoyCore.Type.String"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @trust "DomovoyMisePlugin.Runner.Trust"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"

  defp open(conn, draft, stage \\ "prepare") do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/#{stage}")
    view
  end

  defp click(view, selector), do: view |> element(selector) |> render_click()
  defp undo_offered?(view), do: has_element?(view, "#undo:not([disabled])")

  # A stage `main` with these ops applied.
  defp main(conn, ops) do
    draft = draft!(edit_all(Document.new("w"), ops))
    {draft, open(conn, draft, "main")}
  end

  defp connect(view, source_selector, node, field) do
    click(view, source_selector)
    click(view, "#connect-#{node}-#{field}")
  end

  describe "routes" do
    test "an unknown or malformed id goes to the list with a flash", %{conn: conn} do
      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, {_kind, %{to: "/composer", flash: %{"error" => _message}}}} =
                 live(conn, ~p"/composer/#{id}")

        assert {:error, {_kind, %{to: "/composer"}}} = live(conn, ~p"/composer/#{id}/stages/main")
      end
    end

    test "an unknown stage or a Decision name patches to the workflow", %{conn: conn} do
      draft = draft!(scenario_a())
      workflow_path = ~p"/composer/#{draft.id}"

      for name <- ["nope", "review"] do
        view = open(conn, draft)
        render_patch(view, ~p"/composer/#{draft.id}/stages/#{name}")
        assert_patch(view, workflow_path)
        assert has_element?(view, "#flash-info")
        assert has_element?(view, "#vertex-prepare")
      end
    end

    test "a stage named at first load redirects through to the start stage", %{conn: conn} do
      draft = draft!(scenario_a())

      assert {:error, {_kind, %{to: to, flash: %{"info" => _notice}}}} =
               live(conn, ~p"/composer/#{draft.id}/stages/review")

      assert to == ~p"/composer/#{draft.id}"
    end

    test "a draft deleted while open redirects on the next save", %{conn: conn} do
      draft = draft!(scenario_a())
      view = open(conn, draft)
      {:ok, _deleted} = Composer.delete_draft(draft)

      click(view, "#node-ask_claude-select")
      click(view, "#remove-node")

      assert {"/composer", %{"error" => _message}} = assert_redirect(view)
    end
  end

  describe "cards" do
    test "WorktreeResolve reflects its contract by DOM id", %{conn: conn} do
      view = open(conn, draft!(scenario_a()))

      assert has_element?(view, "#node-resolve_worktree-runner", "Git WorktreeResolve")
      assert has_element?(view, "#node-resolve_worktree-output", "Git Worktree")

      assert has_element?(
               view,
               "#node-resolve_worktree-required #field-resolve_worktree-worktree_name"
             )

      assert has_element?(view, "#field-resolve_worktree-worktree_name-value", "worktree_name")
      assert has_element?(view, "#node-resolve_worktree-validators", "Git WorktreeNameIsSafe")
      assert has_element?(view, "#node-resolve_worktree-policy", "Max attempts 1")
      assert has_element?(view, "#node-resolve_worktree-policy", "pure effect")
      assert has_element?(view, "#node-resolve_worktree-policy", "stored")
      assert has_element?(view, "#node-resolve_worktree-optional-count", "1")
    end

    test "AskClaude reflects its contract by DOM id", %{conn: conn} do
      {:ok, ask} = Catalog.runner(@ask)
      view = open(conn, draft!(scenario_a()))

      output = Catalog.type_label(ask.output)
      inherited = Catalog.validators_for(@ask).inherited
      assert inherited != []

      assert has_element?(view, "#node-ask_claude-runner", ask.label)
      assert has_element?(view, "#node-ask_claude-output", output)
      assert has_element?(view, "#node-ask_claude-required #field-ask_claude-context")
      assert has_element?(view, "#field-ask_claude-options-value", "{}")

      for validator <- inherited do
        assert has_element?(view, "#node-ask_claude-validators", validator.label)
      end

      assert has_element?(
               view,
               "#node-ask_claude-policy",
               "Max attempts #{ask.retry.max_attempts}"
             )

      assert has_element?(view, "#node-ask_claude-policy", "#{ask.effect.class} effect")
    end

    test "a saved position renders there, and a remount offers no undo", %{conn: conn} do
      {:ok, document, :layout} =
        Composer.edit(scenario_a(), {:move, {:stage, "prepare"}, "ask_claude", 321, 654})

      draft = draft!(document)
      view = open(conn, draft)

      assert has_element?(view, "#node-ask_claude[style*='left:321px'][style*='top:654px']")
      refute undo_offered?(view)
    end

    test "a card stays between 280 and 340 px wide", %{conn: conn} do
      assert has_element?(open(conn, draft!(scenario_a())), "#node-ask_claude.w-\\[320px\\]")
    end
  end

  describe "names with hyphens" do
    # LiveViewTest raises on a duplicate DOM id, and this also names the expected ones.
    test "every DOM id and socket stays unambiguous", %{conn: conn} do
      {_draft, view} =
        main(conn, [
          {:put_input, "form", %{"type" => @string}},
          {:put_input, "rows", %{"type" => @string}},
          {:put_input, "rail", %{"type" => @string}},
          {:put_input, "bind-only", %{"type" => @string}},
          {:add_node, "main", @detect, "a"},
          {:add_node, "main", @detect, "a-select"},
          {:add_node, "main", @detect, "b-c"},
          {:add_node, "main", @detect, "a-b"},
          {:add_node, "main", @detect, "c"},
          {:add_node, "main", @detect, "validators"},
          {:add_node, "main", @trust, "only"},
          {:add_after, "main", "b-c", "a"},
          {:add_after, "main", "c", "a-b"}
        ])

      click(view, "#node-validators-select")
      document = LazyHTML.from_fragment(render(view))

      for attribute <- ["id", "data-socket"] do
        values = document |> LazyHTML.query("[#{attribute}]") |> LazyHTML.attribute(attribute)
        assert values != []
        assert values == Enum.uniq(values)
      end

      assert has_element?(view, "#inputs-form")
      assert has_element?(view, "#input-form")
      assert has_element?(view, "#node-a-select")
      assert has_element?(view, "#node-a‿select")
      assert has_element?(view, "#rel-after-b‿c-a")
      assert has_element?(view, "#rel-after-c-a‿b")
      assert has_element?(view, ~s([data-socket="out:a-select"]))
      assert has_element?(view, ~s([data-socket="in:only.worktree"]))
    end

    test "an issue link and a Connect-to row reach a hyphenated name", %{conn: conn} do
      {_draft, view} =
        main(conn, [{:add_node, "main", @resolve, "a-b"}, {:add_node, "main", @trust, "c-d"}])

      assert has_element?(view, ~s(a[href="#field-a‿b-worktree_name"]))
      click(view, "#node-a‿b-connect")
      click(view, "#connect-c‿d-worktree")
      assert has_element?(view, "#field-c‿d-worktree-value", "a-b")
    end
  end

  describe "keyboard path" do
    test "builds a stage by forms, validates, reloads, undoes and exports", %{conn: conn} do
      {:ok, draft} = Composer.create_draft(%{title: "By keyboard"})
      view = open(conn, draft, "main")
      refute undo_offered?(view)

      view
      |> form("#inputs-form", input: %{name: "tree", type: @string, required: "true"})
      |> render_submit()

      assert has_element?(view, "#input-tree-required", "required")

      view |> form("#catalog-search", catalog: %{text: "WorktreeResolve"}) |> render_change()
      refute has_element?(view, "#runner-DomovoyMisePlugin-Runner-Trust")
      click(view, "#pick-runner-DomovoyGitPlugin-Runner-WorktreeResolve")
      view |> form("#add-node-form", add_node: %{name: "resolve"}) |> render_submit()
      assert has_element?(view, "#node-resolve")

      assert has_element?(view, "#field-resolve-worktree_name-missing")
      refute has_element?(view, "#definition-valid")

      view
      |> form("#bind-form-resolve-worktree_name", bind: %{source: "tree"})
      |> render_submit()

      assert has_element?(view, "#issues-empty")
      click(view, "#validate")
      assert has_element?(view, "#definition-valid")
      assert has_element?(view, "#definition-fingerprint")
      assert has_element?(view, "#export[href='/composer/#{draft.id}/export']")

      reloaded = open(conn, draft, "main")
      assert has_element?(reloaded, "#field-resolve-worktree_name-value", "tree")
      refute undo_offered?(reloaded)
      refute has_element?(reloaded, "#definition-valid")

      assert conn |> get(~p"/composer/#{draft.id}/export") |> response(200)

      assert undo_offered?(view)
      click(reloaded, "#validate")
      assert has_element?(reloaded, "#definition-fingerprint")
    end

    test "the Connect-to form makes the same binding, and search narrows it", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @trust, "trust"}
        ])

      click(view, "#node-resolve-connect")
      view |> form("#connect-search", connect: %{query: "trust.work"}) |> render_change()
      assert has_element?(view, "#connect-trust-worktree")
      refute has_element?(view, "#connect-trust-mise")

      click(view, "#connect-trust-worktree")

      refute has_element?(view, "#connect-to")

      assert saved_document(draft)["vertices"]["main"]["nodes"]["trust"]["inputs"]["worktree"] ==
               %{"bind" => "resolve"}
    end

    test "text inputs commit on blur too, and the same value isn't a second edit", %{conn: conn} do
      {draft, view} = main(conn, [{:add_node, "main", @ask, "ask"}])
      click(view, "#node-ask-select")

      view |> element("#literal-ask-context_value") |> render_blur(%{"value" => "hi"})

      assert saved_document(draft)["vertices"]["main"]["nodes"]["ask"]["inputs"]["context"] == %{
               "literal" => "hi"
             }

      click(view, "#undo")
      view |> element("#literal-ask-context_value") |> render_blur(%{"value" => "hi"})
      view |> element("#literal-ask-context_value") |> render_blur(%{"value" => "hi"})
      click(view, "#undo")
      refute undo_offered?(view)
    end

    test "leaving an untouched empty editor sets nothing", %{conn: conn} do
      {draft, view} = main(conn, [{:add_node, "main", @ask, "ask"}])
      click(view, "#node-ask-select")

      view |> element("#literal-ask-context_value") |> render_blur(%{"value" => ""})

      assert saved_document(draft)["vertices"]["main"]["nodes"]["ask"]["inputs"] == %{}
      refute undo_offered?(view)
    end

    test "committing forms ignore auto-recover, so a reconnect can't re-apply them", %{conn: conn} do
      view = open(conn, draft!(scenario_a()))
      click(view, "#node-ask_claude-select")

      for id <-
            ~w(#rename-form #literal-form-ask_claude-options #execution-form #inputs-form #title-form) do
        assert has_element?(view, "#{id}[phx-auto-recover='ignore']")
      end
    end
  end

  describe "bindings" do
    test "an Any field's relationship says accepted by Any", %{conn: conn} do
      view = open(conn, draft!(scenario_a()))

      assert has_element?(
               view,
               "#rel-bind-trust_mise-worktree-name[aria-label='Bind resolve_worktree output to trust_mise.worktree; accepted by Any']"
             )

      refute has_element?(
               view,
               "#rel-bind-ask_claude-context-name[aria-label*='accepted by Any']"
             )
    end

    test "a mismatch names both types, offers the adapter and changes nothing", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @ask, "ask"}
        ])

      before = saved_document(draft)
      connect(view, "#node-resolve-connect", "ask", "working_directory")

      assert has_element?(view, "#rejection-message", "Git Worktree")
      assert has_element?(view, "#rejection-message", "Directory")
      assert has_element?(view, "#rejection-core-id", "binding_type_mismatch")
      assert saved_document(draft) == before
      refute undo_offered?(view)

      click(view, "#adapter-DomovoyGitPlugin-Runner-WorktreeDirectory")

      refute has_element?(view, "#rejection")
      assert has_element?(view, "#node-worktree_directory")
      assert has_element?(view, "#field-ask-working_directory-value", "worktree_directory")

      click(view, "#undo")
      assert saved_document(draft) == before
      refute has_element?(view, "#node-worktree_directory")
    end

    test "an adapter over a literal explains itself and changes nothing", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @ask, "ask"},
          {:set_literal, "main", "ask", "working_directory", "/tmp", replace_binding: false}
        ])

      before = saved_document(draft)
      connect(view, "#node-resolve-connect", "ask", "working_directory")
      assert has_element?(view, "#rejection-message", "Directory")

      click(view, "#adapter-DomovoyGitPlugin-Runner-WorktreeDirectory")

      assert has_element?(view, "#rejection-message", "working_directory holds a literal")
      assert has_element?(view, "#rejection-message", "Clear it")
      refute has_element?(view, "[id^='adapter-']")
      assert saved_document(draft) == before
      assert undo_offered?(view) == false
    end

    test "a mismatch with no real adapter explains the gap and offers nothing", %{conn: conn} do
      {_draft, view} =
        main(conn, [
          {:add_node, "main", @ask, "ask"},
          {:add_node, "main", @resolve, "resolve"}
        ])

      connect(view, "#node-ask-connect", "resolve", "worktree_name")

      assert has_element?(view, "#rejection-message", "No installed runner converts")
      refute has_element?(view, "[id^='adapter-']")
    end

    test "binding over a literal confirms, is one undo entry, and undo returns it", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:put_input, "prompt", %{"type" => @string}},
          {:add_node, "main", @ask, "ask"},
          {:set_literal, "main", "ask", "context", "Review this diff", replace_binding: false}
        ])

      connect(view, "#input-prompt-connect", "ask", "context")
      assert has_element?(view, "#confirm-replace-literal[role='alertdialog']")

      assert saved_document(draft)["vertices"]["main"]["nodes"]["ask"]["inputs"]["context"] == %{
               "literal" => "Review this diff"
             }

      click(view, "#confirm-replace-literal-button")

      refute has_element?(view, "#confirm-replace-literal")
      assert has_element?(view, "#field-ask-context-value", "prompt")

      click(view, "#undo")

      assert has_element?(view, "#field-ask-context-value", "Review this diff")
      refute undo_offered?(view)
    end

    test "Escape cancels the replacement: the literal stays and no undo exists", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:put_input, "prompt", %{"type" => @string}},
          {:add_node, "main", @ask, "ask"},
          {:set_literal, "main", "ask", "context", "Review this diff", replace_binding: false}
        ])

      connect(view, "#input-prompt-connect", "ask", "context")
      assert has_element?(view, "#confirm-replace-literal[phx-key='escape']")

      view |> element("#confirm-replace-literal") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#confirm-replace-literal")

      assert saved_document(draft)["vertices"]["main"]["nodes"]["ask"]["inputs"]["context"] == %{
               "literal" => "Review this diff"
             }

      refute undo_offered?(view)
    end

    test "the replacement dialog restores focus through JS commands", %{conn: conn} do
      {_draft, view} =
        main(conn, [
          {:put_input, "prompt", %{"type" => @string}},
          {:add_node, "main", @ask, "ask"},
          {:set_literal, "main", "ask", "context", "x", replace_binding: false}
        ])

      click(view, "#input-prompt-connect")
      assert has_element?(view, ~s(#connect-ask-context[phx-click*="push_focus"]))

      click(view, "#connect-ask-context")
      assert has_element?(view, ~s(#cancel-replace-literal[phx-click*="pop_focus"]))
    end

    test "a cycle names exactly its nodes and suggests a Decision", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:add_node, "main", @detect, "alpha"},
          {:add_node, "main", @detect, "beta"},
          {:add_node, "main", @detect, "omega"},
          {:add_after, "main", "beta", "alpha"},
          {:add_after, "main", "omega", "alpha"}
        ])

      before = saved_document(draft)
      click(view, "#node-alpha-select")
      view |> form("#add-after-form", after: %{source: "beta"}) |> render_submit()

      assert has_element?(view, "#rejection-core-id", "graph_has_cycle")
      assert has_element?(view, "#rejection-message", "alpha, beta wait on each other")
      refute has_element?(view, "#rejection-message", "omega")
      assert has_element?(view, "#rejection-message", "Decision with a Rerun choice")
      assert saved_document(draft) == before
    end

    test "a self-binding is a cycle of one", %{conn: conn} do
      {draft, view} = main(conn, [{:add_node, "main", @resolve, "resolve"}])
      before = saved_document(draft)

      connect(view, "#node-resolve-connect", "resolve", "worktree_name")

      assert has_element?(view, "#rejection-core-id", "graph_has_cycle")
      assert has_element?(view, "#rejection-message", "resolve wait on each other")
      assert saved_document(draft) == before
    end
  end

  describe "relationships" do
    test "After adds ordering only, and its reverse is a cycle", %{conn: conn} do
      {draft, view} =
        main(conn, [
          {:add_node, "main", @detect, "a"},
          {:add_node, "main", @detect, "b"}
        ])

      inputs = saved_document(draft)["vertices"]["main"]["nodes"]["b"]["inputs"]
      click(view, "#node-b-select")
      view |> form("#add-after-form", after: %{source: "a"}) |> render_submit()

      assert has_element?(view, "#rel-after-b-a-name", "b runs after a")
      assert saved_document(draft)["vertices"]["main"]["nodes"]["b"]["inputs"] == inputs

      click(view, "#node-a-select")
      view |> form("#add-after-form", after: %{source: "b"}) |> render_submit()

      assert has_element?(view, "#rejection-core-id", "graph_has_cycle")
      assert saved_document(draft)["vertices"]["main"]["nodes"]["a"]["after"] == []
    end

    test "each relationship has its own row and delete control", %{conn: conn} do
      {_draft, view} =
        main(conn, [
          {:add_node, "main", @detect, "detect"},
          {:add_node, "main", @trust, "trust"},
          {:bind, "main", "trust", "worktree", "detect", replace_literal: false},
          {:bind, "main", "trust", "mise", "detect", replace_literal: false},
          {:add_after, "main", "trust", "detect"}
        ])

      for id <- ~w(rel-bind-trust-worktree rel-bind-trust-mise rel-after-trust-detect) do
        assert has_element?(view, "##{id}-delete")
      end

      click(view, "#rel-bind-trust-worktree-delete")

      refute has_element?(view, "#rel-bind-trust-worktree")
      assert has_element?(view, "#rel-bind-trust-mise")
      assert has_element?(view, "#rel-after-trust-detect")
      assert has_element?(view, "#field-trust-worktree-missing", "missing input")

      click(view, "#rel-after-trust-detect-delete")
      refute has_element?(view, "#rel-after-trust-detect")
      assert has_element?(view, "#rel-bind-trust-mise")
    end

    test "a deleted producer stays visible as unresolved, and undo restores it", %{conn: conn} do
      draft = draft!(scenario_a())
      before = saved_document(draft)
      view = open(conn, draft)

      click(view, "#validate")
      assert has_element?(view, "#definition-valid")

      click(view, "#node-worktree_directory-select")
      click(view, "#remove-node")

      refute has_element?(view, "#node-worktree_directory")
      assert has_element?(view, "#field-ask_claude-working_directory-value", "worktree_directory")
      assert has_element?(view, "#field-ask_claude-working_directory-unresolved")
      refute has_element?(view, "#input-worktree_directory")
      refute has_element?(view, "#definition-valid")
      refute has_element?(view, "#export")

      click(view, "#undo")

      assert has_element?(view, "#node-worktree_directory")
      refute has_element?(view, "#field-ask_claude-working_directory-unresolved")
      assert saved_document(draft) == before
    end

    test "a binding to nothing can't export", %{conn: conn} do
      draft = draft!(edit_all(scenario_a(), [{:remove_node, "prepare", "worktree_directory"}]))
      view = open(conn, draft)

      click(view, "#validate")

      refute has_element?(view, "#definition-valid")
      refute has_element?(view, "#export")
    end
  end

  describe "editing a node" do
    test "renaming keeps consumers and selection, as one undo entry", %{conn: conn} do
      draft = draft!(scenario_a())
      view = open(conn, draft)

      click(view, "#node-resolve_worktree-select")
      view |> form("#rename-form", rename: %{name: "tree"}) |> render_submit()

      assert has_element?(view, "#node-tree[class*='ring-primary']")
      assert has_element?(view, "#field-trust_mise-worktree-value", "tree")
      assert has_element?(view, "#field-worktree_directory-worktree-value", "tree")

      click(view, "#undo")
      assert has_element?(view, "#node-resolve_worktree")
      assert has_element?(view, "#field-trust_mise-worktree-value", "resolve_worktree")
      refute undo_offered?(view)
    end

    test "replacing a runner previews the impact before one undo entry", %{conn: conn} do
      draft = draft!(scenario_a())
      before = saved_document(draft)
      view = open(conn, draft)

      click(view, "#node-resolve_worktree-select")

      view
      |> form("#replace-runner-form", replace: %{runner: @detect})
      |> render_submit()

      assert has_element?(view, "#replace-runner-preview")
      assert has_element?(view, "#replace-dropped", "worktree_name")
      assert has_element?(view, "#replace-consumers", "trust_mise.worktree")
      assert has_element?(view, "#replace-consumers", "worktree_directory.worktree")
      assert has_element?(view, "#replace-warnings")
      assert saved_document(draft) == before
      refute undo_offered?(view)

      click(view, "#cancel-replace-runner")
      refute has_element?(view, "#replace-runner-preview")
      assert saved_document(draft) == before

      view
      |> form("#replace-runner-form", replace: %{runner: @detect})
      |> render_submit()

      click(view, "#confirm-replace-runner")

      assert has_element?(view, "#node-resolve_worktree-runner", "Detect")
      assert has_element?(view, "#issues li")

      click(view, "#undo")
      assert saved_document(draft) == before
      refute undo_offered?(view)
    end

    test "inherited validators are read-only; node validators add, reorder, remove", %{conn: conn} do
      {draft, view} = main(conn, [{:add_node, "main", @ask, "ask"}])

      validators = fn ->
        saved_document(draft)["vertices"]["main"]["nodes"]["ask"]["validators"]
      end

      [first, second] = Enum.map(Catalog.validators_for(@ask).curated, & &1.id)

      click(view, "#node-ask-select")

      assert has_element?(view, "#execution-order li", "Cast the output")
      assert has_element?(view, "#inherited-validators", "inherited from")
      refute has_element?(view, "#inherited-validators button")

      view |> form("#add-validator-form", validator: %{validator: first}) |> render_submit()
      view |> form("#add-validator-form", validator: %{validator: second}) |> render_submit()
      assert validators.() == [first, second]

      render_hook(view, "move_validator", %{"node" => "ask", "id" => second, "direction" => "up"})
      assert validators.() == [second, first]
      assert has_element?(view, "#node-ask-validators", "Claude")

      render_hook(view, "remove_validator", %{"node" => "ask", "id" => second})
      assert validators.() == [first]
    end

    test "execution saves attempts and storing; a non-number explains itself", %{conn: conn} do
      {draft, view} = main(conn, [{:add_node, "main", @detect, "detect"}])
      node = fn -> saved_document(draft)["vertices"]["main"]["nodes"]["detect"] end

      click(view, "#node-detect-select")

      view
      |> form("#execution-form", execution: %{max_attempts: "3", store: "false"})
      |> render_submit()

      assert node.()["retry"] == %{"max_attempts" => 3}
      assert node.()["store"] == false
      assert has_element?(view, "#node-detect-policy", "Max attempts 3")
      assert has_element?(view, "#node-detect-policy", "not stored")

      view |> form("#execution-form", execution: %{max_attempts: "many"}) |> render_submit()

      assert has_element?(view, "#rejection-message", "whole number")
      assert node.()["retry"] == %{"max_attempts" => 3}
    end

    test "engine name and title commit, and a bad name is rejected", %{conn: conn} do
      {draft, view} = main(conn, [])

      view |> form("#workflow-name-form", workflow_name: %{value: "renamed"}) |> render_submit()
      assert saved_document(draft)["name"] == "renamed"

      view |> form("#workflow-name-form", workflow_name: %{value: "bad name"}) |> render_submit()
      assert has_element?(view, "#rejection-message", "A name holds")
      assert saved_document(draft)["name"] == "renamed"

      view |> form("#title-form", title: %{value: "New title"}) |> render_submit()
      assert has_element?(view, "#draft-title", "New title")
      assert {:ok, %{title: "New title"}} = Composer.get_draft(draft.id)

      view |> form("#title-form", title: %{value: "   "}) |> render_submit()
      assert has_element?(view, "#rejection-message", "A title holds")
      assert {:ok, %{title: "New title"}} = Composer.get_draft(draft.id)
    end
  end

  describe "validity" do
    test "any definition edit clears it", %{conn: conn} do
      view = open(conn, draft!(scenario_a()))

      click(view, "#validate")
      assert has_element?(view, "#definition-valid")

      click(view, "#rel-after-ask_claude-trust_mise-delete")

      refute has_element?(view, "#definition-valid")
      refute has_element?(view, "#definition-fingerprint")
      refute has_element?(view, "#export")
    end

    test "the header states the engine target", %{conn: conn} do
      assert has_element?(open(conn, draft!(scenario_a())), "#engine-target", "Core 0.3.2")
    end
  end

  describe "two tabs" do
    test "a stale tab sees the banner, and Load latest keeps the first tab's change", %{
      conn: conn
    } do
      draft = draft!(scenario_a())
      tab_a = open(conn, draft)
      tab_b = open(conn, draft)

      click(tab_a, "#rel-after-ask_claude-trust_mise-delete")
      kept = saved_document(draft)

      click(tab_b, "#rel-bind-ask_claude-context-delete")

      assert has_element?(tab_b, "#conflict-banner")
      assert saved_document(draft) == kept
      assert has_element?(tab_b, "#rel-bind-ask_claude-context")
      refute undo_offered?(tab_b)

      click(tab_b, "#load-latest")

      refute has_element?(tab_b, "#conflict-banner")
      refute undo_offered?(tab_b)
      refute has_element?(tab_b, "#rel-after-ask_claude-trust_mise")
      assert saved_document(draft) == kept
    end

    test "a conflicting undo keeps its stack and shows the banner", %{conn: conn} do
      draft = draft!(scenario_a())
      tab_a = open(conn, draft)
      tab_b = open(conn, draft)

      click(tab_b, "#rel-bind-ask_claude-context-delete")
      click(tab_a, "#rel-after-ask_claude-trust_mise-delete")
      assert has_element?(tab_a, "#conflict-banner")
      refute undo_offered?(tab_a)

      click(tab_b, "#rel-bind-trust_mise-mise-delete")
      assert undo_offered?(tab_b)

      click(tab_a, "#load-latest")
      click(tab_a, "#rel-after-ask_claude-trust_mise-delete")
      kept = saved_document(draft)

      click(tab_b, "#undo")

      assert has_element?(tab_b, "#conflict-banner")
      assert undo_offered?(tab_b)
      assert saved_document(draft) == kept
    end
  end

  describe "reconnect" do
    test "a remount shows the saved draft and offers no undo it no longer holds", %{conn: conn} do
      draft = draft!(scenario_a())
      view = open(conn, draft)

      click(view, "#rel-after-ask_claude-trust_mise-delete")
      assert undo_offered?(view)

      remounted = open(conn, draft)

      refute has_element?(remounted, "#rel-after-ask_claude-trust_mise")
      refute undo_offered?(remounted)
    end
  end
end
