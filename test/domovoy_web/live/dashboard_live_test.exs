defmodule DomovoyWeb.DashboardLiveTest do
  use DomovoyWeb.ConnCase, async: true

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer
  alias Domovoy.Dashboard.Mock
  alias DomovoyWeb.DashboardComponents
  alias DomovoyWeb.Keymap

  @spec count(view :: term(), selector :: String.t()) :: non_neg_integer()
  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  @spec text(view :: term(), selector :: String.t()) :: String.t()
  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  @cards ~s(#projects > [id^="project-"])
  @rows ~s(#jobs > li[id^="job-"])

  describe "overview" do
    test "/dashboard is its own page with Dashboard active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "#dashboard-nav-dashboard[aria-current=page]")
      refute has_element?(view, "#dashboard-nav-projects[aria-current]")
      refute has_element?(view, "#dashboard-search")
      refute has_element?(view, "#projects")
      assert has_element?(view, "#dashboard-tiles")
    end

    test "the tiles count the mock and the drafts", %{conn: conn} do
      draft!(scenario_a(), "One")
      draft!(scenario_a(), "Two")
      active = Enum.count(Mock.jobs(), &(&1.status in [:running, :queued]))
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert text(view, "#dashboard-tile-projects-count") == "6"
      assert text(view, "#dashboard-tile-jobs-count") == Integer.to_string(active)
      assert text(view, "#dashboard-tile-workflows-count") == "2"
      assert Composer.count_drafts() == 2
    end

    test "each tile links to its section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, ~s(#dashboard-tile-projects[href="/dashboard/projects"]))
      assert has_element?(view, ~s(#dashboard-tile-jobs[href="/dashboard/jobs"]))
      assert has_element?(view, ~s(#dashboard-tile-workflows[href="/dashboard/workflows"]))

      view |> element("#dashboard-tile-projects") |> render_click()
      assert_redirect(view, ~p"/dashboard/projects")
    end
  end

  describe "drawer" do
    test "each item carries its key from the keymap", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      for {item, action} <- [
            {"dashboard", "go.dashboard"},
            {"projects", "go.projects"},
            {"jobs", "go.jobs"},
            {"workflows", "go.workflows"}
          ] do
        assert has_element?(
                 view,
                 ~s(#dashboard-nav-#{item}[data-shortcut="#{Keymap.key(action)}"])
               )
      end

      assert has_element?(view, ~s(#dashboard-nav-workflows[data-shortcut="g w"]))
    end

    test "the shell hosts the shortcuts hook with the keymap's prefixes and hints key", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(
               view,
               ~s(#dashboard-shell[phx-hook="Shortcuts"][data-prefixes="g f c"][data-hints-key="?"][data-focus-key="/"])
             )
    end

    test "lists Dashboard first, then Projects, Jobs and Workflows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#dashboard-drawer a[id^="dashboard-nav-"]))
        |> LazyHTML.attribute("id")

      assert ids ==
               ~w(dashboard-nav-dashboard dashboard-nav-projects dashboard-nav-jobs dashboard-nav-workflows)
    end

    test "holds the one toggle in its header and no other menu buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "#dashboard-drawer-head #dashboard-toggle")

      assert [click] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#dashboard-toggle")
               |> LazyHTML.attribute("phx-click")

      assert click =~ "domovoy:toggle"
      assert has_element?(view, "#dashboard-drawer[data-open][data-close]")

      for gone <- ~w(#dashboard-menu #dashboard-topbar #dashboard-collapse),
          do: refute(has_element?(view, gone))
    end

    test "the brand is only Domovoy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      drawer = text(view, "#dashboard-drawer")

      assert drawer =~ "Domovoy"
      refute drawer =~ ~r/control room/i
    end
  end

  describe "projects" do
    test "/dashboard/projects shows the drawer with Projects active and every card", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/projects")

      assert has_element?(view, "#dashboard-nav-projects[aria-current=page]")
      refute has_element?(view, "#dashboard-nav-jobs[aria-current]")
      assert count(view, @cards) == 6
    end

    test "the drawer navigates to Jobs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/projects")

      view |> element("#dashboard-nav-jobs") |> render_click()
      assert_redirect(view, ~p"/dashboard/jobs")

      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")
      assert has_element?(view, "#dashboard-nav-jobs[aria-current=page]")
    end

    test "search patches the URL and filters the cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/projects")

      view |> element("#dashboard-search") |> render_change(%{"search" => %{"q" => "borg"}})
      assert_patch(view, "/dashboard/projects?q=borg")
      assert count(view, @cards) == 1
      assert has_element?(view, "#project-borg")

      {:ok, view, _html} = live(conn, ~p"/dashboard/projects?q=zzz")
      assert count(view, @cards) == 0
    end
  end

  describe "jobs" do
    test "chip counts cover every job without a query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")

      assert text(view, "#jobs-chip-all-count") == "16"
      assert text(view, "#jobs-chip-running-count") == "2"
      assert has_element?(view, "#dashboard-search input[phx-debounce]")
    end

    test "search and a chip patch the URL, narrow the list and survive a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")
      borg_jobs = Enum.count(Mock.jobs(), &(&1.project == "borg"))
      [running] = Enum.filter(Mock.jobs(), &(&1.project == "borg" and &1.status == :running))

      view |> element("#dashboard-search") |> render_change(%{"search" => %{"q" => "borg"}})
      assert_patch(view, "/dashboard/jobs?q=borg")
      assert text(view, "#jobs-chip-running-count") == "1"
      assert text(view, "#jobs-chip-all-count") == Integer.to_string(borg_jobs)

      view |> element("#jobs-chip-running") |> render_click()
      assert_patch(view, "/dashboard/jobs?q=borg&status=running")
      assert count(view, @rows) == 1
      assert has_element?(view, "#job-#{running.id}-progress")

      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs?q=borg&status=running")
      assert count(view, @rows) == 1
      assert has_element?(view, "#job-#{running.id}")
      assert has_element?(view, "#jobs-chip-running[aria-current]")
    end

    test "no match keeps the chips and says nothing matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs?q=zzz")

      assert count(view, @rows) == 0
      assert has_element?(view, "#jobs-chip-all")

      for value <- ~w(all running queued succeeded failed cancelled),
          do: assert(text(view, "#jobs-chip-#{value}-count") == "0")

      assert text(view, "#jobs-empty") =~ "No jobs match"
    end

    test "an unknown status falls back to All and is dropped from the next patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs?status=bogus")
      assert has_element?(view, "#jobs-chip-all[aria-current]")

      view |> element("#dashboard-search") |> render_change(%{"search" => %{"q" => "borg"}})
      assert_patch(view, "/dashboard/jobs?q=borg")
    end

    test "the empty row tells no jobs from no match" do
      for {total, expected} <- [{0, "No jobs yet."}, {16, "No jobs match."}] do
        html = render_component(&DashboardComponents.jobs_empty/1, total: total)

        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#jobs-empty")
               |> LazyHTML.text()
               |> String.trim() == expected
      end
    end
  end

  describe "panel header" do
    test "no page heading renders, nothing precedes the panel content and the tab keeps its title",
         %{conn: conn} do
      for {path, title, first} <- [
            {"/dashboard", "Dashboard", "#dashboard-tiles"},
            {"/dashboard/projects", "Projects", "header"},
            {"/dashboard/jobs", "Jobs", "header"},
            {"/dashboard/workflows", "Workflows", "header"}
          ] do
        {:ok, view, _html} = live(conn, path)

        refute has_element?(view, "#dashboard-main h1")
        assert has_element?(view, "#dashboard-panel > #{first}:first-child")

        refute has_element?(
                 view,
                 "#dashboard-panel > header > :not(div):not(#dashboard-filter-query)"
               )

        assert page_title(view) =~ title
      end
    end

    test "the search field carries the focus key and wraps the debounced input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/projects")

      assert has_element?(
               view,
               ~s(#dashboard-search-field[data-shortcut="/"][data-shortcut-focus] input[name="search[q]"][phx-debounce])
             )
    end

    test "the status chips carry f 1 to f 6 in order as patch links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")

      for {value, i} <- Enum.with_index(~w(all running queued succeeded failed cancelled), 1) do
        assert has_element?(
                 view,
                 ~s(#jobs-chip-#{value}[data-shortcut="f #{i}"][data-phx-link="patch"])
               )
      end
    end

    test "the jobs query chip sits with the chips and clears q but keeps status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs?q=borg&status=running")

      assert has_element?(view, ~s(#search_q[value="borg"]))
      assert has_element?(view, "#jobs-filters > #dashboard-filter-query")
      refute has_element?(view, "header #dashboard-filter-query")

      view |> element("#dashboard-filter-clear") |> render_click()
      assert_patch(view, "/dashboard/jobs?status=running")

      refute has_element?(view, "#dashboard-filter-query")
      assert has_element?(view, ~s(#search_q[name="search[q]"]))
      refute has_element?(view, ~s(#search_q[value="borg"]))
      assert has_element?(view, "#jobs-chip-running[aria-current]")
    end

    test "the projects query chip sits in the header and clears to the bare panel", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/projects?q=borg")

      assert has_element?(view, "header #dashboard-filter-query")

      view |> element("#dashboard-filter-clear") |> render_click()
      assert_patch(view, "/dashboard/projects")
    end

    test "no query chip renders without a query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

      refute has_element?(view, "#dashboard-filter-query")
    end
  end

  test "hostile events leave the page rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")

    render_hook(view, "search", %{})
    render_hook(view, "search", %{"search" => %{"q" => 1}})
    render_hook(view, "nope", %{})

    assert has_element?(view, "#dashboard-drawer")
  end

  test "a stray search on the overview patches nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_hook(view, "search", %{})
    render_hook(view, "search", %{"search" => %{"q" => "x"}})
    render_hook(view, "nope", %{})

    assert has_element?(view, "#dashboard-tiles")
    refute_patched(view)
  end

  describe "drawer cookie" do
    @spec drawer(conn :: Plug.Conn.t()) :: [String.t()]
    defp drawer(conn) do
      conn
      |> get(~p"/dashboard")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("html")
      |> LazyHTML.attribute("data-drawer")
    end

    test "a collapsed cookie renders collapsed on the dead render", %{conn: conn} do
      assert conn |> put_req_cookie("domovoy_drawer", "collapsed") |> drawer() == ["collapsed"]
    end

    test "a tampered cookie renders expanded and is not echoed", %{conn: conn} do
      conn = put_req_cookie(conn, "domovoy_drawer", "<script>")
      assert [value] = drawer(conn)
      assert value == "expanded"
      refute value =~ "script"
    end

    test "no cookie renders expanded", %{conn: conn} do
      assert drawer(conn) == ["expanded"]
    end
  end
end
