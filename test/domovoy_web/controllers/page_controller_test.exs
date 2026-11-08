defmodule DomovoyWeb.PageControllerTest do
  use DomovoyWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "the one theme has no switcher and no script choosing one", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ "phx:theme"
    refute html =~ "data-phx-theme"
    refute html =~ "data-theme"
  end

  test "the fonts are self-hosted", %{conn: conn} do
    for path <- [
          "/fonts/ibm-plex-sans/ibm-plex-sans-var-latin.woff2",
          "/fonts/ibm-plex-mono/ibm-plex-mono-400-latin.woff2"
        ] do
      assert %{status: 200} = get(conn, path)
    end
  end
end
