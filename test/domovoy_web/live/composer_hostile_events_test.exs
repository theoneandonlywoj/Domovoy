defmodule DomovoyWeb.ComposerHostileEventsTest do
  # Not async: the log test changes the global Logger level.
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import ExUnit.CaptureLog

  alias Domovoy.Composer

  require Logger

  @sentinel "sentinel-secret-value"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"

  defp open(conn) do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")
    {draft, view}
  end

  defp hostile_values do
    [
      "File",
      "Elixir.File",
      "System",
      "Elixir.DomovoyCore.Type.Choice",
      "DomovoyCore.Type.Choice",
      "not_a_real_name_#{System.unique_integer([:positive])}",
      "a\0b",
      <<0xFF>>,
      "",
      nil,
      1,
      %{"a" => 1},
      ["x"]
    ]
  end

  defp events_with(value) do
    [
      {"nope", %{"anything" => value}},
      {"node_moved", %{"node" => value, "x" => 1, "y" => 2, "level" => "stage:prepare"}},
      {"node_moved", %{"node" => "ask_claude", "x" => 1, "y" => 2, "level" => value}},
      {"connect_preview", %{"source" => value, "kind" => value}},
      {"open_picker", %{"source" => value}},
      {"preview_input", %{"input" => value}},
      {"save_input", %{"input" => %{"name" => "x", "type" => value}}},
      {"save_input", %{"input" => value}},
      {"edit_input", %{"name" => value}},
      {"remove_input", %{"name" => value}},
      {"catalog_search", %{"catalog" => %{"text" => value}}},
      {"pick_runner", %{"runner" => value}},
      {"add_node", %{"add_node" => %{"runner" => value, "name" => "fresh"}}},
      {"select_node", %{"node" => value}},
      {"open_connect", %{"source" => value}},
      {"connect_search", %{"connect" => %{"query" => value}}},
      {"connect", %{"source" => value, "node" => "ask_claude", "field" => "context"}},
      {"connect", %{"source" => "prompt", "node" => value, "field" => "context"}},
      {"connect", %{"source" => "prompt", "node" => "ask_claude", "field" => value}},
      {"bind_field", %{"bind" => value}},
      {"bind_field", %{"bind" => %{"source" => value, "node" => "ask_claude", "field" => "x"}}},
      {"insert_adapter", %{"runner" => value}},
      {"commit_literal", %{"literal" => value}},
      {"commit_literal", %{"node" => value, "field" => "context", "value" => "x"}},
      {"commit_literal", %{"node" => "ask_claude", "field" => value, "value" => "x"}},
      {"clear_input", %{"node" => value, "field" => "context"}},
      {"clear_input", %{"node" => "ask_claude", "field" => value}},
      {"add_after", %{"after" => %{"node" => value, "source" => "trust_mise"}}},
      {"add_after", %{"after" => %{"node" => "ask_claude", "source" => value}}},
      {"remove_after", %{"node" => value, "source" => "trust_mise"}},
      {"rename_node", %{"rename" => %{"node" => value, "name" => "fresh"}}},
      {"remove_node", %{"node" => value}},
      {"preview_replace_runner", %{"replace" => %{"node" => "ask_claude", "runner" => value}}},
      {"preview_replace_runner", %{"replace" => %{"node" => value, "runner" => @ask}}},
      {"add_validator", %{"validator" => %{"node" => "ask_claude", "validator" => value}}},
      {"add_validator", %{"validator" => %{"node" => value, "validator" => "x"}}},
      {"remove_validator", %{"node" => value, "id" => value}},
      {"move_validator", %{"node" => "ask_claude", "id" => value, "direction" => value}},
      {"set_execution", %{"execution" => value}},
      {"set_execution", %{"execution" => %{"node" => value, "max_attempts" => "1"}}},
      {"set_execution", %{"execution" => %{"node" => value, "store" => "true"}}},
      {"set_execution", %{"execution" => %{"node" => "ask_claude", "store" => value}}},
      {"set_execution",
       %{"execution" => %{"node" => "ask_claude", "max_attempts" => value, "store" => "true"}}},
      {"add_vertex", %{"vertex" => value}},
      {"add_vertex", %{"vertex" => %{"name" => "fresh", "kind" => value}}},
      {"set_start", %{"vertex" => value}},
      {"remove_vertex", %{"vertex" => value}},
      {"set_next", %{"next" => value}},
      {"set_next", %{"next" => %{"stage" => value, "vertex" => "review"}}},
      {"save_decision", %{"decision" => value}},
      {"save_decision",
       %{
         "decision" => %{
           "name" => value,
           "prompt" => "p",
           "decider" => "DomovoyCore.Decider.Person"
         }
       }},
      {"save_decision",
       %{"decision" => %{"name" => "review", "prompt" => "p", "decider" => value}}},
      {"preview_choice", %{"choice" => value}},
      {"save_choice", %{"choice" => value}},
      {"save_choice",
       %{
         "choice" => %{"decision" => value, "name" => "c", "description" => "d", "kind" => "halt"}
       }},
      {"save_choice",
       %{
         "choice" => %{
           "decision" => "review",
           "name" => "c",
           "description" => "d",
           "kind" => value
         }
       }},
      {"save_choice",
       %{
         "choice" => %{
           "decision" => "review",
           "name" => "c",
           "description" => "d",
           "kind" => "run",
           "vertex" => value
         }
       }},
      {"save_choice",
       %{
         "choice" => %{
           "decision" => "review",
           "name" => "c",
           "description" => "d",
           "kind" => "rerun",
           "vertex" => "prepare",
           "input_name" => "typed",
           "input_type" => value
         }
       }},
      {"edit_choice", %{"decision" => value, "name" => value}},
      {"remove_choice", %{"decision" => "review", "name" => value}},
      {"remove_choice", %{"decision" => value, "name" => "approve"}}
    ]
  end

  test "on the workflow, a hostile route or a hostile drag leaves the draft alone", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    before = saved_document(draft)

    for value <- hostile_values(),
        {name, params} <- [
          {"node_moved", %{"node" => value, "x" => 1, "y" => 2, "level" => "workflow"}},
          {"node_moved", %{"node" => "review", "x" => 1, "y" => 2, "level" => value}},
          {"connect_preview", %{"source" => value, "kind" => "after"}},
          {"select_node", %{"node" => value}},
          {"add_after", %{"after" => %{"node" => value, "source" => "prepare"}}},
          {"add_after", %{"after" => %{"node" => "review", "source" => value}}},
          {"set_next", %{"next" => %{"stage" => "prepare", "vertex" => value}}}
        ],
        # An empty vertex is the form's own way to say Finish.
        value != "" or name != "set_next" do
      render_hook(view, name, params)

      assert has_element?(view, "#composer"), "view died on #{name}"
      assert saved_document(draft) == before, "#{name} changed the draft"
    end
  end

  test "wrong shapes, unknown names and non-catalog modules leave the draft alone", %{conn: conn} do
    {draft, view} = open(conn)
    before = saved_document(draft)
    {:ok, %{lock_version: lock}} = Composer.get_draft(draft.id)

    for value <- hostile_values(), {name, params} <- events_with(value) do
      render_hook(view, name, params)

      assert has_element?(view, "#composer"), "view died on #{name}"
      assert saved_document(draft) == before, "#{name} changed the draft"
    end

    assert {:ok, %{lock_version: ^lock}} = Composer.get_draft(draft.id)
    refute has_element?(view, "#undo:not([disabled])")
  end

  test "NUL, broken text and wrong shapes never reach a name or the title", %{conn: conn} do
    {draft, view} = open(conn)
    before = saved_document(draft)

    for value <- ["a\0b", <<0xFF>>, nil, 1, %{"a" => 1}, ["x"]] do
      render_hook(view, "set_workflow_name", %{"workflow_name" => %{"value" => value}})
      render_hook(view, "rename_node", %{"node" => "ask_claude", "value" => value})
      render_hook(view, "add_node", %{"add_node" => %{"runner" => @ask, "name" => value}})
      render_hook(view, "save_title", %{"title" => %{"value" => value}})
      render_hook(view, "add_vertex", %{"vertex" => %{"name" => value, "kind" => "stage"}})
      render_hook(view, "add_vertex", %{"vertex" => %{"name" => value, "kind" => "decision"}})

      render_hook(view, "save_choice", %{
        "choice" => %{
          "decision" => "review",
          "name" => value,
          "description" => "d",
          "kind" => "halt"
        }
      })

      render_hook(view, "save_choice", %{
        "choice" => %{
          "decision" => "review",
          "name" => "c",
          "description" => value,
          "kind" => "halt"
        }
      })

      assert has_element?(view, "#composer")
      assert saved_document(draft) == before
      assert {:ok, %{title: "Draft"}} = Composer.get_draft(draft.id)
    end
  end

  test "an existing module that isn't in the catalog is an unknown runner", %{conn: conn} do
    {draft, view} = open(conn)
    before = saved_document(draft)

    for runner <- ["File", "Elixir.File", "DomovoyCore.Type.Choice"] do
      render_hook(view, "add_node", %{"add_node" => %{"runner" => runner, "name" => "fresh"}})
      assert has_element?(view, "#rejection-message", "That runner does not exist")
      assert saved_document(draft) == before
    end
  end

  test "an unknown name creates no atom", %{conn: conn} do
    {_draft, view} = open(conn)
    name = "composer_hostile_atom_#{System.unique_integer([:positive])}"

    render_hook(view, "add_node", %{"add_node" => %{"runner" => name, "name" => "fresh"}})
    render_hook(view, "pick_runner", %{"runner" => name})
    render_hook(view, "connect", %{"source" => name, "node" => name, "field" => name})

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "panel events with nothing open do nothing", %{conn: conn} do
    {draft, view} = open(conn)
    before = saved_document(draft)

    for event <- ~w(confirm_replace_literal cancel_replace_literal confirm_replace_runner
                    cancel_replace_runner close_connect undo dismiss_rejection) do
      render_hook(view, event, %{})
      assert has_element?(view, "#composer")
    end

    assert saved_document(draft) == before
  end

  describe "logs" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "debug logs around events show the control and not a literal", %{conn: conn} do
      {_draft, view} = open(conn)
      render_click(element(view, "#node-ask_claude-select"))

      log =
        capture_log(fn ->
          view
          |> form("#literal-form-ask_claude-options", literal: %{value: @sentinel})
          |> render_submit()

          render_hook(view, "commit_literal", %{
            "node" => "ask_claude",
            "field" => "options",
            "value" => @sentinel
          })

          render_hook(view, "node_moved", %{
            "node" => "ask_claude",
            "x" => 5,
            "y" => 6,
            "level" => "stage:prepare"
          })

          render_hook(view, "connect", %{
            "source" => "prompt",
            "node" => "ask_claude",
            "field" => "options"
          })

          render_hook(view, "save_decision", %{
            "decision" => %{
              "name" => "review",
              "prompt" => @sentinel,
              "decider" => "DomovoyCore.Decider.Person"
            }
          })

          render_hook(view, "save_choice", %{
            "choice" => %{
              "decision" => "review",
              "name" => "logged",
              "description" => @sentinel,
              "kind" => "halt"
            }
          })

          render_hook(view, "unknown_event", %{"value" => @sentinel})
          render_click(element(view, "#validate"))
          Logger.debug("positive-control")
        end)

      assert log =~ "positive-control"
      refute log =~ @sentinel
    end
  end
end
