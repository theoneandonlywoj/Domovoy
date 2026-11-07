defmodule DomovoyWeb.ComposerScenarioALiveTest do
  # Not async: the no-execution trace is global.
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  alias Domovoy.NoExecutionTrace
  alias DomovoyCore.Definition
  alias DomovoyCore.Workflow

  @string "DomovoyCore.Type.String"
  @resolve "runner-DomovoyGitPlugin-Runner-WorktreeResolve"
  @directory "runner-DomovoyGitPlugin-Runner-WorktreeDirectory"
  @detect "runner-DomovoyMisePlugin-Runner-Detect"
  @trust "runner-DomovoyMisePlugin-Runner-Trust"
  @ask "runner-DomovoyClaudeCodePlugin-Runner-AskClaude"

  defp click(view, selector), do: view |> element(selector) |> render_click()

  defp input(view, name) do
    view
    |> form("#inputs-form", input: %{name: name, type: @string, required: "true"})
    |> render_submit()
  end

  defp vertex(view, name, kind) do
    view |> form("#add-vertex-form", vertex: %{name: name, kind: kind}) |> render_submit()
  end

  defp node(view, runner, name) do
    click(view, "#pick-#{runner}")
    view |> form("#add-node-form", add_node: %{name: name}) |> render_submit()
  end

  defp connect(view, source_button, node, field) do
    click(view, source_button)
    click(view, "#connect-#{node}-#{field}")
  end

  defp build(view, draft) do
    view
    |> form("#workflow-name-form", workflow_name: %{value: "scenario_a"})
    |> render_submit()

    input(view, "worktree_name")
    input(view, "prompt")

    # The vertices
    vertex(view, "prepare", "stage")
    click(view, "#vertex-prepare-select")
    click(view, "#set-start")
    click(view, "#vertex-main-select")
    click(view, "#remove-vertex")

    # The stage
    click(view, "#vertex-prepare-open")
    assert_patch(view, ~p"/composer/#{draft.id}/stages/prepare")

    node(view, @resolve, "resolve_worktree")
    node(view, @directory, "worktree_directory")
    node(view, @detect, "detect_mise")
    node(view, @trust, "trust_mise")
    node(view, @ask, "ask_claude")

    connect(view, "#input-worktree_name-connect", "resolve_worktree", "worktree_name")
    connect(view, "#node-resolve_worktree-connect", "worktree_directory", "worktree")
    connect(view, "#node-resolve_worktree-connect", "trust_mise", "worktree")
    connect(view, "#node-detect_mise-connect", "trust_mise", "mise")
    connect(view, "#input-prompt-connect", "ask_claude", "context")
    connect(view, "#node-worktree_directory-connect", "ask_claude", "working_directory")

    click(view, "#node-ask_claude-select")

    view
    |> form("#literal-form-ask_claude-options", literal: %{value: "{}"})
    |> render_submit()

    view |> form("#add-after-form", after: %{source: "trust_mise"}) |> render_submit()

    # The workflow
    click(view, "#breadcrumb-workflow")
    assert_patch(view, ~p"/composer/#{draft.id}")

    vertex(view, "review", "decision")
    click(view, "#vertex-prepare-select")
    view |> form("#next-form", next: %{vertex: "review"}) |> render_change()

    click(view, "#vertex-review-select")
    view |> form("#decision-form", decision: %{prompt: "Approve the answer?"}) |> render_submit()

    view
    |> form("#choice-form", choice: %{name: "approve", description: "Accept", kind: "halt"})
    |> render_submit()

    view |> form("#choice-form", choice: %{kind: "rerun", vertex: "prepare"}) |> render_change()

    view
    |> form("#choice-form",
      choice: %{
        name: "revise",
        description: "Ask again",
        kind: "rerun",
        vertex: "prepare",
        input_name: "prompt",
        input_type: @string
      }
    )
    |> render_submit()

    render_hook(view, "node_moved", %{
      "node" => "review",
      "x" => 640,
      "y" => 200,
      "level" => "workflow"
    })

    click(view, "#validate")

    has_element?(view, "#definition-valid")
  end

  test "builds A from a new draft through events alone, validates and exports", %{conn: conn} do
    {:ok, list, _html} = live(conn, ~p"/composer")
    list |> form("#draft-form", draft: %{title: "Scenario A"}) |> render_submit()
    {path, _flash} = assert_redirect(list)
    {:ok, view, _html} = live(conn, path)
    "/composer/" <> id = path
    draft = %{id: id}

    report = NoExecutionTrace.run(fn -> build(view, draft) end)

    assert report.result == true
    assert report.traced != []
    assert report.forbidden_calls == []
    assert Enum.all?(report.controls_expected, &(&1 in report.control_calls))

    {:ok, remounted, _html} = live(conn, path)
    assert has_element?(remounted, "#vertex-review[data-x='640'][data-y='200']")

    saved = saved_document(%{id: id})
    fixture = scenario_a()

    assert Map.take(saved, ~w(name start inputs vertices)) ==
             Map.take(fixture, ~w(name start inputs vertices))

    json = conn |> get(~p"/composer/#{id}/export") |> response(200)
    {:ok, workflow} = Workflow.from_json(json)

    assert Jason.decode!(json)["metadata"]["domovoy_editor"] == saved["layout"]
    assert workflow.metadata["domovoy_editor"] == saved["layout"]
    assert {:ok, ^json} = Workflow.to_json(workflow, pretty: true)
    assert Definition.fingerprint(workflow).root =~ "v1:"
  end
end
