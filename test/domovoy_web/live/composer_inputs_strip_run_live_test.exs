defmodule DomovoyWeb.ComposerInputsStripRunLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.RunCase, only: [setup_runs: 1, start_attrs: 2, open_gate: 0]

  alias Domovoy.Composer

  setup :setup_runs

  test "a run has no inputs strip and keeps its inputs in the outline", %{conn: conn} do
    open_gate()
    draft = draft!(hold_run(), "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", runner}, 5_000

    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?run=#{run_id}")
    render_async(view, 5_000)

    refute has_element?(view, "#inputs-rail")
    assert has_element?(view, "#outline-panel #run-input-trap_exit")

    send(runner, :release)
  end
end
