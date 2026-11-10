# Review of `project-management` against `main`

Scope: the 6 commits on this branch (Onyx Gloss theme, dashboard shell, mock data, inputs
strip, shell-aware composer paths). Auth is excluded, as requested.

State at review time: `mix test` passes (947 passed, 5 excluded). I did not run
`make quality` or the JS tests, and nothing was checked in a browser.

No finding is a data-loss or security bug. One is a crash that takes down a whole page
(1). The rest are performance, navigation and consistency problems.

| # | Severity | Area | Summary |
|---|----------|------|---------|
| 1 | High | Dashboard workflows | One draft with a malformed `layout` crashes the whole list |
| 2 | Medium | Dashboard queries | Every draft document is loaded to count them, and one run query runs per draft on each keystroke |
| 3 | Medium | Dashboard search | Each debounced keystroke adds a browser history entry |
| 4 | Medium | Shell routing | Runs links in the dashboard composer leave the dashboard for good |
| 5 | Low | Examples | Existing seeded `create_worktree` drafts keep the old optional inputs |
| 6 | Low | Composer | One error redirect still hardcodes `/composer` |

---

## 1. A malformed `layout` crashes `/dashboard/workflows` (High)

`lib/domovoy_web/components/dashboard_components.ex:265`

```elixir
defp layout_points(document) do
  case get_in(document, ["layout", "workflow"]) do
```

The comment above says "a malformed layout draws nothing", but `get_in/2` raises when
`document["layout"]` is not a map. I checked the three shapes: a string and an integer
raise `FunctionClauseError`, a list raises `ArgumentError`.

The composer protects itself from such drafts: `ComposerLive.load_draft/1` runs
`Composer.shape_issues/1` and treats a bad document as "That draft doesn't exist
anymore". The dashboard has no such guard, and the card is rendered for every draft, so
one bad row makes the whole workflows page fail to mount, for every draft. The old
`/composer` list never reads the document, so it is not affected.

I confirmed the `get_in` behaviour directly, but did not insert a malformed draft and
load the page.

Suggested fix: match the shape instead of walking it.

```elixir
defp layout_points(%{"layout" => %{"workflow" => %{} = positions}}) do
  for {_name, %{"x" => x, "y" => y}} <- positions, is_integer(x), is_integer(y), do: {x, y}
end

defp layout_points(_document), do: []
```

Add a test in `test/domovoy_web/live/dashboard_workflows_live_test.exs` that inserts a
draft with `"layout" => "x"` and asserts the page still renders its card with the
placeholder.

## 2. Dashboard loads far more than it shows (Medium)

`lib/domovoy_web/live/dashboard_live.ex:179` and `:237`

- The overview tile calls `length(Composer.list_drafts())`, which loads every draft row
  with its full JSON document only to count them.
- `load(socket, :workflows)` loads every draft, then `latest_runs/1` runs
  `Composer.run_page/3` once per shown draft. `handle_params` calls it on every patch, so
  each debounced search keystroke repeats 1 + N queries.

It works with a handful of drafts and degrades linearly with more.

Suggested fix:

- Add `Composer.count_drafts/0` (`Repo.aggregate(Draft, :count)`) for the tile.
- Add one query for the newest run per draft, for example `distinct: run.draft_id,
  order_by: [run.draft_id, desc: run.inserted_at, desc: run.id]` filtered by
  `draft_id in ^ids`, behind the same `gated/1` check that `Runs.page/3` uses.

## 3. Search fills the browser history (Medium)

`lib/domovoy_web/live/dashboard_live.ex:143`

```elixir
{:noreply, push_patch(socket, to: panel_path(action, q, socket.assigns.status))}
```

The search box sends `search` on change with a 300 ms debounce, and each one pushes a new
history entry. Typing "borg" can add four entries, so Back steps through partial queries
before it leaves the page.

Suggested fix: `push_patch(socket, to: ..., replace: true)`. Trimming `q` here as well
would keep a trailing space out of the URL, since `handle_params` trims it anyway.

## 4. Runs links drop the user out of the dashboard shell (Medium)

`lib/domovoy_web/components/composer_run_components.ex:1853` and `:1877`,
`lib/domovoy_web/live/runs_live.ex:120`

The branch threads `shell` through every composer path, but the two links in
`recent_runs` ("needs attention" and "All runs") still point at `/composer/runs`. That
route exists only in the `:composer` live session, and `RunsLive` opens runs with
`run_link(:composer, ...)`. So from `/dashboard/workflows/:id`, one click on "All runs"
does a full page load into the standalone composer, with no drawer, and every later link
stays there.

`Shell`'s moduledoc says the composer's links "stay in the shell it opened in", so this
looks unintended, not a decision.

Suggested fix, either:

- add `live "/dashboard/workflows/runs", RunsLive, :index` to the `:dashboard` session
  (before the `:id` route), give `RunsLive` the dashboard layout variant, and build its
  links from `socket.assigns.shell`; or
- hide those two links when `@shell == :dashboard` until the runs list has a dashboard
  home.

## 5. Seeded `create_worktree` drafts are not updated (Low)

`lib/domovoy/examples/definitions.ex:46`, `lib/domovoy/examples/seeds.ex:26`

The fix makes `repository_path` and `branch_name` required, but the seeder keeps any
draft whose engine name already exists (`:kept`). Databases seeded before this branch
keep the old document, where both inputs are optional, so the bug the commit fixes stays
in every existing install.

Suggested fix: decide whether that is acceptable. If not, a one-off data migration, or a
note in the changelog telling people to delete and re-seed that draft, closes it.

## 6. One redirect still hardcodes `/composer` (Low)

`lib/domovoy_web/live/composer_live.ex:53`

The "That run doesn't exist" redirect uses `~p"/composer"`. It is correct today, because
the `:run` route exists only in the composer session. Using
`drafts_path(socket.assigns.shell)` keeps it right if finding 4 is fixed by adding run
routes to the dashboard.

---

## Checked and found fine

- Drawer overlay: `inert` on `#dashboard-main`, the capture-phase Escape and Undo
  handler, and the close on widening past 48rem are consistent with each other and with
  the composer's `[aria-modal='true']` check.
- `drawer_state/1` renders only the two known cookie values.
- Inputs popover: click-away runs before the click that reopens it, and Add input resets
  the form, so a removed input can't be saved back from a stale form.
- `run_link/5` and `composer_path/5` have no default arguments, so no old 3- or
  4-argument call site survives; the suite compiles and passes.
- Unknown `status` and non-string `q` params fall back safely in `handle_params`.
