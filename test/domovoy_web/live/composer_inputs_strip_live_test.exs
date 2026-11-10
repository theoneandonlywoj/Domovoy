defmodule DomovoyWeb.ComposerInputsStripLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer.Document

  @string "DomovoyCore.Type.String"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"

  # Stage `second` can read `made` and `spare`, both made by the earlier stage `first`.
  defp staged do
    edit_all(Document.new("w"), [
      {:put_input, "name", %{"type" => @string, "required" => true}},
      {:add_stage, "first"},
      {:add_stage, "second"},
      {:set_start, "first"},
      {:remove_vertex, "main"},
      {:set_next, "first", "second"},
      {:add_node, "first", @resolve, "made"},
      {:add_node, "first", @resolve, "spare"},
      {:bind, "first", "made", "worktree_name", "name", replace_literal: false},
      {:bind, "first", "spare", "worktree_name", "name", replace_literal: false},
      {:add_node, "second", @directory, "reader"},
      {:bind, "second", "reader", "worktree", "made", replace_literal: false}
    ])
  end

  defp composer_children(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#composer > *")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
  end

  defp assert_strip_above_graph(view) do
    ids = composer_children(view)
    strip = Enum.find_index(ids, &(&1 == "inputs-rail"))
    workspace = Enum.find_index(ids, &(&1 == "workspace"))
    assert strip && workspace && strip < workspace
  end

  defp js_ops(view, selector, attr) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attr)
    |> List.first()
    |> Jason.decode!()
  end

  defp shows_popover?(ops) do
    Enum.any?(ops, &match?(["show", %{"to" => "#inputs-popover"}], &1)) and
      Enum.any?(
        ops,
        &match?(["remove_attr", %{"attr" => "hidden", "to" => "#inputs-popover"}], &1)
      )
  end

  defp hides_popover?(ops) do
    Enum.any?(ops, &match?(["hide", %{"to" => "#inputs-popover"}], &1)) and
      Enum.any?(
        ops,
        &match?(["set_attr", %{"attr" => ["hidden", ""], "to" => "#inputs-popover"}], &1)
      )
  end

  defp assert_popover_outside_scroller(view) do
    assert has_element?(view, "#inputs-rail > #inputs-popover")
    assert has_element?(view, "#inputs-rail > #add-input")
    assert has_element?(view, "#inputs-rail > #inputs-scroller #inputs-rows")
    refute has_element?(view, "#inputs-scroller #inputs-popover")
    refute has_element?(view, "#inputs-rail[class*='overflow']")
    refute has_element?(view, "#inputs-rail [class*='overflow'] #inputs-popover")
  end

  test "the strip sits above the graph, out of the side panel, with every input", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    assert has_element?(view, "#inputs-rail[data-modal-background]")
    refute has_element?(view, "#outline-panel #inputs-rail")
    refute has_element?(view, "#workspace #inputs-rail")
    assert_strip_above_graph(view)

    for name <- Map.keys(draft.document["inputs"]) do
      assert has_element?(view, "#inputs-rows #input-#{name}")
    end
  end

  test "a stage shows the sources from earlier in the strip", %{conn: conn} do
    draft = draft!(staged())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/second")

    assert has_element?(view, "#inputs-rail #prior-sources")
    assert has_element?(view, "#inputs-rail #inputs-rows #input-name")
    assert_strip_above_graph(view)
  end

  test "Edit fills the form in the popover", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    view |> element("#input-prompt-edit") |> render_click()

    assert has_element?(
             view,
             ~s(#inputs-rail #inputs-popover #inputs-form input[name="input[name]"][value="prompt"])
           )
  end

  test "saving a new input adds its chip", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    refute has_element?(view, "#inputs-rows #input-floor")

    view
    |> form("#inputs-form", input: %{name: "floor", type: @string})
    |> render_submit()

    assert has_element?(view, "#inputs-rows #input-floor")
    assert saved_document(draft)["inputs"]["floor"]
  end

  test "the dashboard composer has the strip above the graph too", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/#{draft.id}")

    assert has_element?(view, "#inputs-rail #inputs-rows")
    refute has_element?(view, "#outline-panel #inputs-rail")
    assert_strip_above_graph(view)
  end

  test "every opener drops hidden and every closer restores it", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    add = js_ops(view, "#add-input", "phx-click")
    edit = js_ops(view, "#input-prompt-edit", "phx-click")

    for ops <- [add, edit] do
      assert shows_popover?(ops)
      refute Enum.any?(ops, &match?(["focus_first", _], &1))
      assert Enum.any?(ops, &match?(["focus", %{"to" => "#inputs-popover"}], &1))
    end

    assert ["push", %{"event" => "new_input"}] = List.first(add)

    assert Enum.any?(
             edit,
             &match?(["push", %{"event" => "edit_input", "value" => %{"name" => "prompt"}}], &1)
           )

    assert hides_popover?(js_ops(view, "#close-inputs-popover", "phx-click"))
    assert hides_popover?(js_ops(view, "#inputs-popover", "phx-click-away"))
    assert hides_popover?(js_ops(view, "#inputs-popover", "phx-window-keydown"))
    assert has_element?(view, ~s(#inputs-popover[phx-key="Escape"]))
    assert has_element?(view, ~s(#inputs-popover[role="dialog"][tabindex="-1"]))

    # Closed is the server's default, whatever was clicked last.
    assert has_element?(view, "#inputs-popover[hidden]")
    view |> element("#input-prompt-edit") |> render_click()
    assert has_element?(view, "#inputs-popover[hidden]")
    view |> element("#add-input") |> render_click()
    assert has_element?(view, "#inputs-popover[hidden]")
  end

  test "the popover sits outside the scrolling chips", %{conn: conn} do
    draft = draft!(scenario_a())

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    assert_popover_outside_scroller(view)

    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/#{draft.id}")
    assert_popover_outside_scroller(view)
  end

  @name_field ~s(#inputs-form input[name="input[name]"])
  @required_checked ~s(#inputs-form input[name="input[required]"][checked])

  test "Add input after Edit gives a blank form", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    view |> element("#input-prompt-edit") |> render_click()
    assert has_element?(view, ~s(#{@name_field}[value="prompt"]))
    assert has_element?(view, @required_checked)

    view |> element("#add-input") |> render_click()
    refute has_element?(view, ~s(#{@name_field}[value="prompt"]))
    assert has_element?(view, ~s"#{@name_field}[value=''], #{@name_field}:not([value])")
    refute has_element?(view, @required_checked)
  end

  test "Add input also resets Type and Default", %{conn: conn} do
    document =
      edit_all(Document.new("w"), [
        {:put_input, "floor", %{"type" => "DomovoyCore.Type.Integer", "default" => "1"}}
      ])

    draft = draft!(document)
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    type = ~s(#inputs-form select[name="input[type]"])
    default = ~s(#inputs-form select[name="input[default_state]"])

    view |> element("#input-floor-edit") |> render_click()
    assert has_element?(view, ~s(#{type} option[value="DomovoyCore.Type.Integer"][selected]))
    assert has_element?(view, ~s(#{default} option[value="value"][selected]))

    view |> element("#add-input") |> render_click()
    assert has_element?(view, ~s(#{type} option[value="#{@string}"][selected]))
    assert has_element?(view, ~s(#{default} option[value="absent"][selected]))
  end

  test "new_input with a junk payload still resets", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    view |> element("#input-prompt-edit") |> render_click()
    render_hook(view, "new_input", %{"x" => 1})

    assert has_element?(view, "#inputs-form")
    refute has_element?(view, ~s(#{@name_field}[value="prompt"]))
    refute has_element?(view, @required_checked)
  end
end
