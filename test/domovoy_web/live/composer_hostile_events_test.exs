defmodule DomovoyWeb.ComposerHostileEventsTest do
  # Not async: the log test changes the global Logger level.
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import ExUnit.CaptureLog

  import Domovoy.RunCase,
    only: [
      setup_runs: 1,
      start_attrs: 2,
      open!: 1,
      await_phase: 2,
      watch: 1,
      await_delivered: 1,
      entered: 1
    ]

  import Ecto.Query

  alias Domovoy.Composer
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs
  alias Domovoy.CoreCallTrace
  alias Domovoy.Examples.Definitions
  alias Domovoy.Repo

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
      {"put_evidence",
       %{
         "evidence" => %{"decision" => value, "refs" => %{"prepare" => %{"ask_claude" => "true"}}}
       }},
      {"put_evidence", %{"evidence" => %{"decision" => "review", "refs" => value}}},
      {"put_evidence",
       %{"evidence" => %{"decision" => "review", "refs" => %{"prepare" => value}}}},
      {"put_outputs", %{"outputs" => value}},
      {"put_outputs", %{"outputs" => %{"refs" => value}}},
      {"put_outputs", %{"outputs" => %{"refs" => %{"prepare" => %{"ask_claude" => value}}}}},
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
      {"remove_choice", %{"decision" => value, "name" => "approve"}},
      {"open_start", %{"start" => value}},
      {"submit_start", %{"start" => value}},
      {"submit_start", %{"start" => %{"worktree_name" => value, "prompt" => value}}},
      {"confirm_start", %{"start" => value}},
      {"close_start", %{"start" => value}},
      {"decide", %{"occurrence" => value, "choice" => value, "inputs" => value}},
      {"select_run_generation", %{"generation" => value}},
      {"retry_run_record", %{"anything" => value}}
    ]
  end

  # A review run waiting at its decision, opened on the workflow with it selected.
  defp waiting_review(conn) do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document

    {:ok, values} =
      RunInputs.parse(document, %{
        "rooms" => "3",
        "bathrooms" => "1",
        "area" => "58.5",
        "district" => "Krowodrza"
      })

    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    %{awaiting: [%{occurrence: occurrence}]} = await_phase(handle, "waiting")

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{run_id}&node=review")
    render_async(view, 5_000)
    %{view: view, handle: handle, occurrence: occurrence}
  end

  # Start fields that are no text a form could send.
  defp hostile_start_values, do: [%{"a" => 1}, ["x"], <<0xFF>>, "a\0b"]

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

  # The names of the Core run calls any process makes during `fun`, a start's task included.
  defp core_run_calls(fun), do: for({name, _args} <- CoreCallTrace.calls(fun), do: name)

  describe "with runs on" do
    setup :setup_runs

    test "start and lifecycle events make no Core call with runs off, and start does with them on",
         %{conn: conn} do
      draft = draft!(leak_run(), "Leak")
      Application.put_env(:domovoy, :composer_runs_enabled, false)
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

      off =
        core_run_calls(fn ->
          for value <- hostile_start_values() ++ ["fine"] do
            render_hook(view, "open_start", %{})

            render_hook(view, "submit_start", %{
              "start" => %{"secret" => value, "mode" => "succeed"}
            })

            render_hook(view, "confirm_start", %{})
            render_async(view, 5_000)
            assert has_element?(view, "#composer")
          end

          for event <- ~w(stop_run resume_run open_cancel_run confirm_cancel_run recover_run) do
            render_hook(view, event, %{})
          end
        end)

      assert off == []
      refute has_element?(view, "#start-form")
      assert Repo.all(from(row in Run, where: row.draft_id == ^draft.id)) == []

      # The control: the same start, with runs on, calls Core.
      Application.put_env(:domovoy, :composer_runs_enabled, true)
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

      on =
        core_run_calls(fn ->
          render_hook(view, "open_start", %{})
          render_hook(view, "submit_start", %{"start" => %{"secret" => "s", "mode" => "succeed"}})
          render_async(view, 5_000)
        end)

      assert :start in on
    end

    test "hostile decide and generation events change nothing in a run", %{conn: conn} do
      %{view: view, handle: handle, occurrence: occurrence} = waiting_review(conn)

      for value <- hostile_values() do
        # An undeclared input, under a hostile name or holding a hostile value.
        named = if is_binary(value), do: [%{value => "x"}], else: []

        for inputs <- [%{"x" => value} | named],
            params <- [
              %{"occurrence" => value, "choice" => "accept", "inputs" => %{}},
              %{"occurrence" => occurrence, "choice" => value, "inputs" => %{}},
              %{"occurrence" => occurrence, "choice" => "accept", "inputs" => value},
              %{"occurrence" => occurrence, "choice" => "revise", "inputs" => inputs}
            ] do
          render_hook(view, "decide", params)
          assert has_element?(view, "#composer")
        end

        render_hook(view, "select_run_generation", %{"generation" => value})
        render_hook(view, "retry_run_record", %{"generation" => value})
        render_hook(view, "retry_run_record", %{"node" => value, "generation" => "0"})

        render_hook(view, "retry_run_record", %{
          "node" => "join_price_terms",
          "generation" => value
        })

        render_hook(view, "toggle_result", %{"stage" => value, "node" => "join_price_terms"})
        render_hook(view, "toggle_result", %{"stage" => "estimate_price", "node" => value})
        render_hook(view, "open_results", %{"surface" => value})
        render_hook(view, "set_surface", %{"surface" => value})
        assert has_element?(view, "#composer")
      end

      # Only a node the Results panel lists is ever expanded.
      %{socket: %{assigns: %{run: run}}} = :sys.get_state(view.pid)
      assert run.expanded == MapSet.new()

      render_hook(view, "select_run_generation", %{"generation" => "7"})
      assert has_element?(view, "#run-phase", "waiting")
      assert {:ok, %{committed_phase: "waiting", generation: 0}} = Composer.run_view(handle)
    end

    test "on a run page start events open the launcher while edits stay refused", %{conn: conn} do
      %{view: view, handle: handle} = waiting_review(conn)
      %{socket: %{assigns: %{draft: draft}}} = :sys.get_state(view.pid)
      before = saved_document(draft)

      for value <- hostile_values() do
        render_hook(view, "open_start", %{"start" => value})
        render_hook(view, "submit_start", %{"start" => value})
        render_hook(view, "confirm_start", %{"start" => value})
        render_async(view, 5_000)
        assert has_element?(view, "#composer")
      end

      assert has_element?(view, "#launcher-panel #start-form")

      render_hook(view, "node_moved", %{
        "node" => "review",
        "x" => 1,
        "y" => 2,
        "level" => "workflow"
      })

      assert_reply(view, %{status: "rejected"})
      render_hook(view, "add_node", %{"add_node" => %{"runner" => @ask, "name" => "fresh"}})
      render_hook(view, "add_vertex", %{"vertex" => %{"name" => "extra", "kind" => "stage"}})
      estimate = %{"estimate_price" => %{"join_price_terms" => "true"}}

      render_hook(view, "put_evidence", %{
        "evidence" => %{"decision" => "review", "refs" => estimate}
      })

      render_hook(view, "put_outputs", %{"outputs" => %{"refs" => estimate}})

      assert saved_document(draft) == before
      assert Repo.all(from(row in Run, where: row.draft_id == ^draft.id)) |> length() == 1
      assert {:ok, %{committed_phase: "waiting"}} = Composer.run_view(handle)
    end

    test "hostile start fields are refused by name and start nothing", %{conn: conn} do
      draft = draft!(leak_run(), "Leak")
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      render_hook(view, "open_start", %{})

      for value <- hostile_start_values() do
        render_hook(view, "submit_start", %{"start" => %{"secret" => value, "mode" => "succeed"}})
        render_hook(view, "confirm_start", %{})
        render_async(view, 5_000)

        assert has_element?(view, "#start-field-secret .text-error")
        refute has_element?(view, "#start-form input[name='start[secret]'][value]")
        assert has_element?(view, "#start-form input[name='start[mode]'][value='succeed']")
      end

      render_hook(view, "submit_start", %{"start" => "not a map"})
      render_async(view, 5_000)

      assert has_element?(view, "#start-form")
      assert Repo.all(from(row in Run, where: row.draft_id == ^draft.id)) == []
    end
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

  test "save_input ignores a metadata param and keeps the stored description", %{conn: conn} do
    document =
      edit_all(scenario_a(), [
        {:put_input, "floor", %{"type" => "DomovoyCore.Type.String"}},
        {:set_description, {:input, "floor"}, "Stored."}
      ])

    draft = draft!(document)
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")

    render_hook(view, "save_input", %{
      "input" => %{
        "name" => "floor",
        "type" => "DomovoyCore.Type.String",
        "required" => "true",
        "metadata" => %{"description" => "Other."}
      }
    })

    refute has_element?(view, "#rejection")

    assert saved_document(draft)["inputs"]["floor"] == %{
             "type" => "DomovoyCore.Type.String",
             "required" => true,
             "metadata" => %{"description" => "Stored."}
           }
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

    test "a run input stays out of logs and flash, at success and at failure", %{conn: conn} do
      setup_runs(%{})

      for mode <- ["succeed", "fail"] do
        draft = draft!(leak_run(), "Leak #{mode}")

        {view, log} =
          with_log(fn ->
            {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
            render_async(view, 5_000)
            view |> element("#start-run") |> render_click()

            view
            |> form("#start-form", start: %{"secret" => @sentinel, "mode" => mode})
            |> render_submit()

            render_async(view, 5_000)
            assert_patch(view)
            watch(view.pid)
            render_async(view, 5_000)
            await_delivered(entered("finished"))
            Logger.debug("positive-control")
            view
          end)

        assert log =~ "positive-control"
        refute log =~ @sentinel

        assert has_element?(
                 view,
                 "#run-outcome",
                 if(mode == "succeed", do: "succeeded", else: "failed")
               )

        refute render(view) =~ @sentinel
      end
    end

    test "a decision input stays out of logs and flash, answered and refused", %{conn: conn} do
      setup_runs(%{})

      {view, log} =
        with_log(fn ->
          %{view: view, handle: handle, occurrence: occurrence} = waiting_review(conn)

          # Refused by the page: accept declares no input.
          render_hook(view, "decide", %{
            "occurrence" => occurrence,
            "choice" => "accept",
            "inputs" => %{"district" => @sentinel}
          })

          assert has_element?(view, "#rejection")
          render_hook(view, "dismiss_rejection", %{})

          view |> form("#decide-revise", inputs: %{district: @sentinel}) |> render_submit()
          refute has_element?(view, "#rejection")

          # Refused by Core: the occurrence was answered.
          render_hook(view, "decide", %{
            "occurrence" => occurrence,
            "choice" => "revise",
            "inputs" => %{"district" => @sentinel}
          })

          # No district has that name, so the rerun fails on a returned error.
          assert %{outcome: "failed"} = await_phase(handle, "finished")
          Logger.debug("positive-control")
          view
        end)

      assert log =~ "positive-control"
      refute log =~ @sentinel
      refute render(view) =~ @sentinel
    end
  end
end
