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
          "/fonts/dm-sans/dm-sans-var-latin.woff2",
          "/fonts/dm-mono/dm-mono-400-latin.woff2",
          "/fonts/bodoni-moda/bodoni-moda-var-latin.woff2",
          "/fonts/dm-sans/OFL.txt",
          "/fonts/dm-mono/OFL.txt",
          "/fonts/bodoni-moda/OFL.txt"
        ] do
      assert %{status: 200} = get(conn, path)
    end
  end

  test "the old fonts are gone", %{conn: conn} do
    old = "/fonts/" <> "ibm" <> "-plex-sans/" <> "ibm" <> "-plex-sans-var-latin.woff2"
    assert %{status: 404} = get(conn, old)
  end
end
