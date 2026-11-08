defmodule DomovoyWeb.WorkflowExportController do
  @moduledoc """
  Downloads a draft's definition as JSON, after validating it afresh. It never logs
  the document: nothing here is passed to a logger, and the only param is the id.
  """

  use DomovoyWeb, :controller

  alias Domovoy.Composer

  @doc """
  Sends the JSON attachment, a 422 with the issues, or a 404.
  """
  @spec show(conn :: Plug.Conn.t(), params :: map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, draft} <- Composer.get_draft(id),
         {:valid, %{json: json}} <- Composer.validate(draft.document) do
      send_download(conn, {:binary, json},
        filename: "#{draft.document["name"]}.json",
        content_type: "application/json"
      )
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:invalid, issues} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid", issues: Enum.map(issues, &issue_json/1)})
    end
  end

  @spec issue_json(issue :: Composer.Issue.t()) :: map()
  defp issue_json(issue) do
    %{code: issue.code, core_id: issue.core_id, message: issue.message}
  end
end
