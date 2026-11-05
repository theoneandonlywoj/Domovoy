defmodule DomovoyWeb.WorkflowExportControllerTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias DomovoyCore.Workflow

  test "a valid draft downloads JSON that Core reads back", %{conn: conn} do
    draft = draft!(scenario_a())

    conn = get(conn, ~p"/composer/#{draft.id}/export")

    assert response(conn, 200)
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="scenario_a.json")
    assert ["application/json" <> _charset] = get_resp_header(conn, "content-type")
    assert {:ok, %Workflow{}} = Workflow.from_json(conn.resp_body)
  end

  test "it validates afresh, so an invalid draft is a 422 with its issues", %{conn: conn} do
    invalid = edit_all(scenario_a(), [{:remove_node, "prepare", "worktree_directory"}])
    draft = draft!(invalid)

    conn = get(conn, ~p"/composer/#{draft.id}/export")

    assert %{"error" => "invalid", "issues" => [_ | _]} = json_response(conn, 422)
  end

  test "an unknown or malformed id is a 404", %{conn: conn} do
    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert %{"error" => "not_found"} =
               conn |> get(~p"/composer/#{id}/export") |> json_response(404)
    end
  end
end
