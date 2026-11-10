# Composer canvas: browser checklist

These are the only evidence for wire alignment, focus and patch timing, which unit tests
can't see. Run on 2026-11-05 with headless Chrome 156 at 1600x1000, driven through the
DevTools protocol against a dev server, with trusted pointer and key input. Wire
alignment was measured: the distance in screen pixels from each path's two ends to the
centres of its sockets. Patches came from Validate; latency from
`liveSocket.enableLatencySim`; disconnects from `liveSocket.disconnect()`.

A lost release can't be produced for real here, so it was simulated: a mouse move with
`buttons: 0` during a drag, `releasePointerCapture`, a dispatched `contextmenu` event, and
a second press with no release. No real context menu or out-of-window release was tried.

Owner sign-off is still open: a headless run shows the behaviour, not how it feels, and
nothing here was tried on a trackpad or with a physical mouse.

## Spike

The plan's design: server-rendered cards, and a hook on an ignored wire layer that
reapplies its positions from a `MutationObserver`. The spike ran on the real code rather
than on a temporary patch timer. Its result: **the design holds**.

| Pass criterion, for a patch during a drag and after release before the ack | Result |
|---|---|
| No card jump | Pass: `left`/`top` unchanged, with `data-x` still old until the ack |
| Wires on their sockets | Pass: 0.00 px, measured mid-drag and before the ack |
| Lock released | Pass: no `data-phx-ref-lock` on `#composer-wires` after the ack |
| Viewport kept | Pass: the transform is the same after a patch and after a reconnect |
| Reconnect survives | Pass: cards at server positions, wires 0.00 px, no undo offered |

## Rows

| Row | Result | How |
|---|---|---|
| One event on drag | Pass | One `node_moved` frame on the socket for a whole drag, none during the moves |
| Patch mid-drag | Pass | Validate during a drag: the card keeps its place; validity stays after the move |
| Wires after a patch | Pass | 0.00 px after a patch, pan, zoom in and out, drag at zoom, and a banner shifting the canvas |
| After dashed, value solid | Pass | Computed `stroke-dasharray`: `6px, 5px` and `none` |
| Release while disconnected | Pass | No frame sent, the card returns, and the notice says so |
| Disconnect after release, before the ack | Pass | Settles at once, with the notice; then the server position wins on reconnect |
| Reconnect | Pass | Wires redraw, viewport kept, Undo disabled |
| Press on a pending card | Pass | At 1000 ms latency: a click, or a press and Escape, leaves the card at its pending position and the ack lands there. A disconnect or a conflict after it reverts with the notice. A real drag from it continues from where it shows, ignores the earlier answer, and sends a second `node_moved` |
| Card removed mid-drag | Pass | Cmd+Z undoes `add_node` during a drag: no exception, no `node_moved`, whether the next event is a move or the release. Navigating away mid-drag wasn't driven |
| Lost release | Pass | Card and wire: a move reporting no button, or lost capture, cancels with nothing sent, and the next drag works. Also for a card: a context menu event, and a new press while an uncaptured press is stuck |
| Ack lost after the server saved | Pass | The socket dropped right after the `node_moved` frame: the card goes back with the notice; on reconnect it shows the saved position and the notice is cleared |
| Stale tab | Pass | The second tab's drag reverts, with the notice and the conflict banner |
| Escape order | Pass | Picker, then gesture, then selection; the confirmation takes its own Escape, keeps the literal, leaves the selection |
| Focus on a replacement confirmation | Partial | Observed: focus lands on Cancel when it opens. Not observed: focus returning after it closes (see below) |
| Cmd+Z in a text input and on the canvas | Pass | The input's own undo with no `undo` frame; on the canvas, one draft undo |
| Pointer walkthrough, one stage | Pass | See below |
| Keyboard walkthrough, one stage | Pass | Connect-to by Enter, the confirmation by Enter, then Validate |
| A validated with `claude` and `mise` absent from PATH | Pass | `Composer.validate/1` gives `:valid` with `System.find_executable/1` nil for both. Validation only, not through a browser |
| Hyphenated names | Pass | Nodes `a`, `a-select`, `b-c`, `a-b`, `c`: no duplicate DOM id, each wire on its own sockets, and an issue link focuses `#field-t‿x-worktree` |

### Not walked yet

- **Focus return after cancelling a replacement.** `JS.pop_focus` is in place, but the
  run opened the dialog by pointer, which pushes no focus, so return wasn't observed.
- **Real pointing devices.** Trackpad pinch was simulated as Ctrl+wheel. Touch is untried.

## All of scenario A

Run on 2026-11-05 the same way, each walk from a new draft through to Validate, Export and
a reload. Both ended with `#definition-valid`, an export of 200 holding
`metadata.domovoy_editor`, the vertices kept and 0.00 px wires after the reload, and no page
exception.

| Row | Result | How |
|---|---|---|
| Pointer walkthrough of A | Pass | See below |
| Keyboard walkthrough of A | Pass, with a limit | Text by key input, buttons and links by Enter. **Limit:** `select` values were set by script with the browser's own `input` and `change` events, since a headless native select menu can't be driven by keys. Tab order wasn't walked: each control was focused by script, then pressed |
| Double-click opens a stage | Pass | A trusted double-click on a Stage card patches to its stage view |
| Enter opens a stage | Pass | Enter on the card's `Open` link |
| Workflow card drag | Pass | One `node_moved` frame per drag, for Stage and Decision cards; `data-x` saved; wires 0.00 px after |
| Route by drag | Pass | A Stage's handle dropped on the Decision sets `next`, and draws the wire |
| Rerun wire dashed | Pass | Computed `stroke-dasharray` isn't `none` |
| Each level has its own view | Pass | Zoomed workflow, double-click: the stage opens at the initial view, and so does the workflow on return |
| Catalog after a patch | Pass | The runner list renders on entering a stage from the workflow |
| Issue link focuses a route | Pass | By Enter: a Rerun on a Decision links to its route, which takes focus |
| Add and choice forms clear | Pass | By button and by Enter in a text field |

One walk hazard: a press straight after a programmatic scroll of the left rail, which had
been far down the catalog, missed its socket, with `elementFromPoint` answering
`left-rail`, even after 250 ms. The walk now waits until the socket answers. The cause wasn't
established, and a person scrolling by hand wasn't tried.

Not walked: dragging a Decision's choice onto a card, which doesn't exist. A choice's route
is set by its form.

### Pointer walk of A

1. Create the draft, then set the engine name and two inputs by form.
2. Add stage `prepare`, set it as start, remove `main`, and drag `prepare`.
3. Double-click `prepare`. Add the five runners from the catalog, zoom out, and drag
   `ask_claude` clear of the first row.
4. Drag each binding from its socket onto its field, then the After handle of `trust_mise`
   onto `ask_claude`. Type the `options` literal.
5. Back by the breadcrumb. Add decision `review`, and drag it clear.
6. Drag `prepare`'s handle onto `review`. Fill the prompt, then choices `approve` (Halt) and
   `revise` (Rerun on `prepare`, typed input `prompt`). Drag `review` again.
7. Validate, fetch the export, reload.

## The pointer walkthrough of one stage

On stage `prepare`, in order:

1. Drag `resolve_worktree` by its name. A press with no movement still selects it.
2. Pan with the empty canvas, and zoom with Ctrl+wheel.
3. Drag from `ask_claude`'s output: `trust_mise.worktree` isn't highlighted, since it would
   form a cycle. Escape cancels and leaves nothing behind.
4. Drop `resolve_worktree` on `ask_claude.working_directory`, opened by hovering its card.
   The hover says it won't fit; the drop explains and offers WorktreeDirectory, which
   inserts.
5. Drop `detect_mise` on `trust_mise.mise`: highlighted, and it binds.
6. Drop `worktree_name` on empty canvas: the picker opens, filtered and focused.
7. Drag the After handle of `detect_mise` onto `worktree_directory`: a dashed wire. The
   reverse is refused while hovering and explained on drop.
8. Drop `prompt` on a field holding a literal: the confirmation opens.

## The dark theme

Superseded by Onyx Gloss (2026-11).

Tokyo Night as dark soft UI, walked on 2026-11-05 with headless Chrome at 1600x1000 on port
4010, by computed style and trusted pointer input.

| Row | Result | How |
|---|---|---|
| Surface | Pass | Body background `rgb(36, 40, 59)`, text `rgb(192, 202, 245)`, `color-scheme: dark`, no `data-theme` attribute |
| Paired shadows | Pass | Card `9px 9px 20px`, button `4px 4px 10px`, field and pressed button `inset 4px 4px 9px`, each with the matching light half. A resting primary shows the halo and the dark half |
| Selected card | Pass | Name pressed in on `rgb(46, 60, 100)`, with a blue ring over the card's own shadow |
| Focus | Pass | `2px solid rgb(187, 154, 247)`, offset 2px |
| Toast | Pass | `rgb(192, 202, 245)` with `rgb(31, 35, 53)` text |
| Fonts | Pass | Plex Sans on the body, Plex Mono on `code`. Every font request is under `/fonts/`; no 4xx, no failed load, no external request |
| Dark only | Pass | `phx:theme=light` in localStorage, then `prefers-color-scheme: light` emulated: background, text, scheme, card, field and primary all unchanged |
| Reduced motion | Pass | `transition-duration: 0s` on a button, emulated |
| Forced colours | Pass, emulated | Wires, sockets, and the otherwise invisible button and card borders all resolve to the forced text colour |
| Wires on sockets | Pass | 0.00 px mid-drag and after a drag, on the workflow and on a stage |
| Value solid, Rerun dashed | Pass | Computed `stroke-dasharray`: `none` and `6px, 5px` |
| Backward wire | Pass | Rerun from `review` to `main`, side by side: none of 200 sampled points is under a card, and the whole loop is inside the canvas |
| New card spacing | Pass | Two new cards side by side, 180 px apart on the workflow and 140 px on a stage |
| `node_moved` level | Pass | One frame per drag, with `"level":"workflow"` or `"level":"stage:main"` |
| Navigation during a drag | Pass | A click on the breadcrumb mid-drag ends the gesture, and the release sends no `node_moved` |

Contrast, computed from the values: ink on surface 9.02, muted 6.90 (7.37 on sunken, 5.11 on
the selection), links 8.49, primary label 6.79, toast 9.63, focus 6.30 (4.66 on the
selection), error text 5.51, failed pill 5.10, active pill 5.27. Wires on the surface: value
6.90, After 8.75, Rerun 7.28, preview 5.78. As in Borg's theme, the shadow pair and a field's
edge are decorative and below 3:1, so fields keep a visible label.

Not walked: a real forced-colours mode (only emulated), the halved shadows below `lg`, and how
the theme looks on a physical display.

## Onyx Gloss

Lacquered near-black with a glass sheen, a gradient hairline edge and champagne gold, walked
on 2026-11-09 with headless Chrome on port 4011, by computed style. The component rows were
first read from probe elements injected into `/` with the app's own classes; a second pass
the same day walked the real pages (Pages row, Running on the canvas row).

| Row | Result | How |
|---|---|---|
| Pages | Pass | `/`, `/composer`, `/composer/runs` and `/composer/:id` at 1440, 1280, 1024 and 390 px: body `rgb(12, 12, 14)` on `rgb(239, 232, 216)`, DM Sans, no `data-theme`, no horizontal overflow |
| Running on the canvas | Pass, forced | On `/composer/:id/stages/estimate_price`, `data-run-status="running"` plus `ring-2 ring-primary` set on a card in DevTools: `box-shadow` holds the gold `0 0 0 2px` ring, the panel shadow and the `0 0 22px 2px` glow; outline solid gold, offset `3px`, animation `run-glow` (screenshot 41) |
| Surface | Pass | Body background `rgb(12, 12, 14)`, text `rgb(239, 232, 216)`, no `data-theme` attribute |
| Gloss layers | Pass | `.soft-btn` background image is the sheen over a `rgb(12, 12, 14)` fill layer and the gradient edge; border `transparent`; shadow `0 6px 14px -8px`. A resting primary is the gold gradient with the gold glow and `rgb(27, 22, 8)` text |
| Pressed and current | Pass | `aria-pressed="true"` and `aria-current="page"` fill `rgb(45, 39, 25)` with a solid gold edge; `box-shadow` has no `inset` |
| Disabled primary | Pass | Base fill with the default edge, `rgb(168, 161, 145)` text, no shadow: not gold |
| Running, selected | Pass | `article.soft-panel.ring-2.ring-primary[data-run-status=running]`: the gold `0 0 0 2px` ring, the panel shadow and the `0 0 22px 2px` glow all in `box-shadow`; outline `solid` gold, offset `3px`, animation `run-glow` |
| Running pill | Pass | Gold text on `rgb(38, 33, 19)` with a soft gold glow |
| Focus | Pass by value | `2px solid` `--color-accent` `#fff6df`, offset 2px. Not observed with real keyboard focus on a card |
| Toast | Pass | `rgb(28, 28, 33)` with `rgb(239, 232, 216)` text and a 45% gold edge |
| Fonts | Pass | DM Sans on the body, Bodoni Moda on `h1`; the loaded faces are `Bodoni Moda 400 900` and `DM Sans 100 1000`. Every font request is under `/fonts/`; the old Plex path is 404 |
| Single theme | Pass | `phx:theme=light` in localStorage and `prefers-color-scheme: light` emulated: body background unchanged |
| Reduced motion | Pass, emulated | The running card's animation is `none`; the outline and glow stay |
| Forced colours | Pass, emulated | Rest and current buttons and the running card keep a solid `CanvasText` border |

Contrast, by the WCAG relative-luminance formula: ink 16.01 on base, 15.19 on panels, 13.90
on rows, 16.50 on sunken and 12.15 on the selection; muted 7.60 on base, 7.22 on panels,
6.60 on rows, 7.84 on sunken and 5.77 on the selection; links 12.85 on panels; primary
label 13.66 / 11.07 / 7.53 across the gold gradient; toast 13.90; focus 18.15 on base and
13.77 on the selection; error text 5.94 on panels; active and running pill 9.85, failed pill
5.49, done 9.32, attention 6.38 and muted 7.84 on sunken. Wires on the surface: value 7.60,
After 9.48, Rerun 6.19, preview 12.00, problem 6.25. The gradient edge is decorative and
below 3:1 in its middle stops; the pressed edge is solid gold at 12.00.

Not walked: a run with two generations (none in the dev database, so the pressed row is from
the probe, not `#generation-scope-1`), a node held in `running` by a real run, the topbar
during navigation, real keyboard focus on a card (headless focus did not match
`:focus-visible`), a real forced-colours mode and a physical display.

## Dashboard shell — phase 2, 2026-11-09

Walked with headless Chrome 156 through the DevTools protocol against a dev server, with
trusted mouse and key input, cache disabled. Phases 3–5 extend this section.

| Check | Result |
|---|---|
| Desktop collapse, 1440 px | Pass: Collapse narrows `#dashboard-drawer` from 256 to 64 px, labels `display: none`, cookie `domovoy_drawer=collapsed` |
| Collapse survives navigation | Pass: Projects → Jobs by the drawer link keeps `data-drawer="collapsed"` and 64 px |
| First paint after reload | Pass: at `DOMContentLoaded` the drawer is already `collapsed` and 64 px, so no expanded flash |
| Collapsed links keep their name | Pass: `#dashboard-nav-jobs` has `aria-label="Jobs"` |
| Mobile overlay, 390 px | Pass: hidden (`visibility: hidden`, off-screen) until Menu; Menu sets `role="dialog"`, `aria-modal`, `inert` on `#dashboard-main`, shows the scrim and focuses the first link |
| Tab inside the overlay | Pass: Tab visits the two links, then the document end, then wraps; nothing in `#dashboard-main` takes focus. No flash was showing |
| Closing the overlay | Pass: Escape and the scrim each close it and return focus to `#dashboard-menu`; choosing Projects navigates and closes it |
| Widening with the overlay open | Pass: at 1024 px it closes (`aria-modal` and `inert` removed) and `#dashboard-main` is hit by `elementFromPoint` |
| Tampered cookie | Pass: `domovoy_drawer=<script>` plus a reload renders `expanded`, 256 px |
| Jobs URL filter | Pass: `/dashboard/jobs?q=borg&status=running` shows one row, its progress bar at 64 % |

The first walk found that `JS.focus_first` left focus on the body: `JS.add_class` applies
a frame late, so the drawer was still hidden at the focus attempt, and the retry was
skipped once `inert` had dropped focus from Menu. The open state is now keyed on
`aria-modal`, which `JS.set_attribute` sets at once, and the drawer turns visible with no
transition delay.

Not walked: a physical display, a real phone, a screen reader, and Tab with a flash shown.

### Embedded composer — phase 3, 2026-11-09

Walked the same way on port 4010, on the seeded "Cracow house price review" draft at
`/dashboard/workflows/<id>`, with the drawer cookie cleared and `composer:pin` removed
first. Pan was a trusted background drag and zoom a ctrl-wheel, each read from
`#stage-world`'s transform.

| Check | Result |
|---|---|
| 1440 px | Pass: drawer 256 px, canvas 1136x800 from x 288, no page or `<main>` scroll, Workflows `aria-current="page"`; pan (+40, −20) and zoom 1 → 1.5 |
| 1280 px | Pass: drawer 256 px, canvas 976x658, no scroll; pan and zoom 1 → 1.5 |
| 1024 px | Pass: drawer 256 px, canvas 720x626, the fit at 0.897; pan and zoom → 1.345 |
| 390 px | Pass: drawer hidden, canvas 374x586 from x 8, no scroll; pan and zoom 0.373 → 0.559. A drag at the canvas's lower left starts on `#canvas-zoom`, which spans the width here, so the pan was dragged from the top |
| Pin refused, 1280 px expanded | Pass: workspace 976 px, "Not enough room to pin: the canvas needs at least 600 px.", `aria-pressed="false"`, no `data-pinned`, transform unchanged |
| Pin after collapsing | Pass: drawer 64 px, workspace 1168 px; Pin docks (`data-pinned`, `aria-pressed="true"`), with pan and zoom unchanged across the collapse and the pin (`translate(98px, 143px) scale(1)`); the selected card wasn't under the inspector |
| Canvas only | Pass: `#dashboard-drawer` and the header `display: none`, canvas 1408 px; Escape exits and the drawer is back (`flex`) |
| Overlay over an open outline, 390 px | Pass: Outline then Menu gives `aria-modal`, `inert` main, focus on the first link, outline still open; Escape closes only the drawer (outline open, surface `outline`), focus back on `#dashboard-menu` |
| Links stay in the dashboard | Pass: a card's Open goes to `/dashboard/workflows/<id>/stages/estimate_price`; no `/composer` href but the run pages and export |
| Confirmation scrim covers the drawer | Not walked: a confirmation needs an unfinished run or a literal-replacing edit, and the dev data had neither; making one would have changed it |

### Overview and the toggle in the bar — phase 4, 2026-11-09

Walked the same way on port 4010, with cookies cleared first. Menu (`#dashboard-menu`), the
phone top bar and the bottom Collapse button are gone; `#dashboard-toggle` in
`#dashboard-drawer-head` replaces all three, so the phase 2 and 3 rows that name
`#dashboard-menu` now mean the toggle.

| Check | Result |
|---|---|
| Desktop collapse, 1440 px | Pass: the toggle narrows the drawer from 256 to 64 px, labels and brand `display: none`, `data-drawer="collapsed"`, cookie `domovoy_drawer=collapsed`; focus stays on the toggle; no `aria-expanded` on desktop |
| First paint after reload | Pass: at `DOMContentLoaded` the drawer is already 64 px and `collapsed`, so no expanded flash; collapse survives Dashboard → Jobs; the toggle expands it again (256 px, cookie `expanded`) |
| Phone rail, 390 px | Pass: `#dashboard-drawer` is `position: fixed`, 64 px, icons only; `#dashboard-main` keeps x 0 and width 390 with a 4rem inline-start padding, the tiles start at x 80 |
| Open by the toggle | Pass: drawer 256 px with labels and brand, `role="dialog"`, `aria-modal`, `inert` main, scrim shown, toggle `aria-expanded="true"`, focus on `#dashboard-nav-dashboard`; main stays at x 0, width 390, so nothing behind it shifts |
| Closing the overlay | Pass: the toggle, the scrim (a click at x 360) and Escape each close it back to the 64 px rail, `aria-expanded="false"`, focus on `#dashboard-toggle`; choosing Jobs navigates and closes it |
| Widening with the overlay open | Pass: at 1024 px `aria-modal`, `role` and `inert` are removed, the drawer is static at 256 px, and `elementFromPoint` lands in `#dashboard-main` |
| Composer, 390 px | Pass: on `/dashboard/workflows/<id>` the rail sits beside the workspace (x 72, 310 px wide after the composer's own padding), no horizontal overflow |
| Overlay over the outline and the launcher, 390 px | Pass: with surface `outline`, then `launcher`, the toggle opens the overlay; Escape closes only the drawer, the surface and its panel stay open, focus back on the toggle |
| Results surface | Not walked: `#open-results` needs a run, and the dev draft had none; starting one would have changed the data |

Not walked: a physical display, a real phone and a screen reader.

### Inputs strip — phase 5, 2026-11-10

The workflow inputs, a stage's "From earlier" sources and the add/edit input form moved
out of the Outline panel into `#inputs-rail`, a strip above `#workspace`, on `/composer/<id>`
and `/dashboard/workflows/<id>` alike. A run shows no strip; its inputs stay in Steps.

Walked 2026-11-10 in headless Chrome 157.0.8103.39 through CDP (trusted mouse and key
events, two animation frames before each read), port 4012, on the seeded draft "Create a
worktree" (`repository_path` Directory, `branch_name` and `base_branch` String with default
`main`; unchanged from the seed). Routes: `/composer/<id>` at 1440x900 and 390x844,
`/dashboard/workflows/<id>` at 390x844. Nothing was saved or removed; selecting a card was a
press and release at one point.

| Check | Result |
|---|---|
| Load | Pass, all three: `#inputs-popover` has `hidden`, computed `display: none` |
| Strip above the graph, 1440 px | Pass: chips wrap in one panel above the canvas; Add input sits at the strip's right |
| 1024 px | Not walked |
| 390 px | Pass, both routes: `#inputs-scroller` scrolls (scrollWidth 1968, clientWidth 229 on `/composer`, 165 on the dashboard); `#add-input` and the popover don't, and Add input stays fully visible; `#inputs-rail` computed `overflow-x: visible`; no page overflow (`scrollWidth` 390) |
| Stage level | Not walked: the walk stayed at the workflow level; covered by the LiveView test |
| Add input | Pass, all three: with a card selected, Add input removes `hidden` (`display: block`) and focuses the popover itself; the popover lies inside the viewport and above the bottom of `main` (1440: 384x382 at 29,205; 390: 348 wide at x 21; dashboard 390: 284 wide at x 85, right edge 369); `elementFromPoint` at the centre of `#inputs-form`, `#save-input` and `#close-inputs-popover` lands inside the popover; `#workspace` doesn't move or resize |
| Escape | Pass, all three: Escape inside the popover closes only the popover (`hidden` back, `display: none`); the card stays selected and focus leaves the popover (`body`). A second Escape deselects the card |
| Edit | Pass, all three: `#input-base_branch-edit` opens the popover with Name `base_branch`, Type String, Default Value `main` |
| Add input again | Pass, all three: Name empty, Type String, Default None; after Edit `repository_path` (Directory), Add input brings Type back to String. No seeded input is required, so the Required reset is covered by the LiveView test only |
| Typed, then Add input | Pass, all three: typing `abc` in the focused Name, then Add input, leaves Name empty |
| Save | Not walked: it would write dev data |
| Close | Pass, all three: hides the popover and returns focus to `#add-input` |
| Click-away | Pass, all three: clicking the strip's heading hides the popover |
| Tools open, 390 px | Known limit, both routes: opened while Tools is open, the popover is covered by `#composer-tools` (both `z-40`, Tools later in the DOM); `elementFromPoint` at the popover misses it |
| Canvas only | Pass, all three: the strip is `display: none` with the headers and back (`flex`) on exit |
| A dialog makes it inert | Not walked: the only cancellable dialog here (replace a literal) needs a wire drag onto a literal field, which the walk did not script |
| Pin rule | Not walked: canvas geometry is untouched by this phase |

Not walked: a physical display, a real phone and a screen reader.

## Screenshots

In `screenshots/`: `02-mid-drag`, `04-preview`, `05-hover-refused`, `06-rejection`,
`07-hover-fits`, `09-picker`, `10-after-hover`, `12-confirm-literal`, `13-hyphens`,
`14-workflow`, `15-stage-walked`, `20-home`, `21-stage-mid-connect`, `22-dialog`,
`23-draft-list`, `34-cracow-stage-source-nodes`. `14`, `20`-`23` and `30`-`34` show the old
dark theme; the rest predate it. Onyx Gloss, 1440x900: `40-onyx-workflow`,
`41-onyx-stage-running-selected` (a card forced to running and selected) and `42-onyx-runs`.
Inputs popover opened by Add input, with a card selected:
`43-inputs-popover-1440` and `44-inputs-popover-390`.

## Contextual inspector and Issues/Tools — phase 1, 2026-11-05

Fresh observations against this phase on port 4010, headless Chrome 156 at
1600x1000 through CDP, using a disposable draft created through the UI. Pointer
press/move/release and keyboard input were trusted browser events. Native select
values used the browser's `change` event. No physical mouse/trackpad or touch was
used. Earlier results above are historical and do not establish this phase.

| Check | Fresh result |
|---|---|
| Workflow reclaimed width | Pass: canvas 1248px unselected, 848px selected, 1248px after an unmoved blank click; no right rail before/after. |
| Stage reclaimed width | Pass: 1248px unselected, 848px selected, 1248px after Close and after an unmoved blank click. |
| Independent Tools keyboard access | Pass: Enter on `open-tools` mounts the panel and focuses `close-tools`; Escape closes it and returns focus to `open-tools`. |
| Edit and Escape | Pass: typing `branch` in `literal-resolve-worktree_name_value` and Escape keeps the inspector and input focus; blur saves the value. Canvas Escape closes selection. |
| Pan and drag | Pass on stage: background pan to `translate(40px, 20px) scale(1)` keeps selection. Card drag by (+55,+35) saves directory at (575,115), with selection intact. |
| Wire cancellation | Pass on stage: press output socket, move, Escape, release; after the scheduled draw there is no preview/gesture and selection remains. |
| Connect-to without selection | Pass: source Connect-to opens Tools without an inspector; Tools Close returns focus to the initiating source button; reopening restores unresolved Connect-to. |
| Replacement cancellation | Pass after correction: dialog focuses Cancel; Escape returns focus to `connect-resolve-worktree_name`, keeps Tools/Connect-to/selection and the literal. The first implementation also closed Connect-to; the hook now excludes the covered connection picker from Escape arbitration, and the exact check was repeated. |
| Replacement confirmation | Pass: Replace changes the field to `reads name`, keeps Tools/selection and returns focus to `input-name-connect` after the target disappears. |
| Node issue focus | Pass: opening Tools then its field issue selects resolve, closes Tools and focuses visible `field-resolve-worktree_name`. |
| Relationship issue focus/delete | Pass: unresolved After issue selects directory, keeps Tools and focuses `rel-after-directory-resolve`; its delete control removes the relationship. |
| Choice issue focus | Pass: after deselection, a workflow issue selects review, mounts its inspector, closes Tools and focuses visible `choice-review-bad`. |
| Cross-level issue navigation | Pass: workflow node issue reaches `stage:main`; stage choice issue reaches workflow. |
| Stage wire alignment | Pass: both ends of both value wires measure 0.00px from socket centres with inspector, after dismissal, after Validate and after saved card drag. |
| Workflow wire alignment | Pass: route wire ends measure 0.00px with inspector, after dismissal and after Validate. |

No application exception was observed in these walkthroughs. Temporary CDP driver
errors (missing Enter character text, appending to a prefilled name, selector quoting,
and observing before a patch/draw completed) were corrected in the driver and the
corresponding observations repeated. The browser draft is
`e209de56-4424-41bb-abd4-7d4f1f2b781d`.

Limits: warning-producing clear previews and their focus return, workflow pan/drag/
wire cancellation, and physical-device behavior were not walked in this fresh browser
run. Clear preview auto-opening, close/reopen retention, cancel/confirm effects and
view-only document/lock/history invariants are covered by the focused LiveView tests;
gesture exclusions/cancellations and Escape priorities are covered by hook tests.
Those tests do not establish the unobserved browser claims.

## Phase 1 Escape retry — 2026-11-05

Fresh retry observations used the same isolated port 4010 server and headless
Chrome 156 at 1600x1000 through CDP, with trusted keyboard and pointer input.
The earlier replacement-cancellation result above covered Connect-to alone; it
did not cover a pending catalog choice mounted alongside the confirmation.

| Check | Retry observation |
|---|---|
| Overlapping catalog choice and replacement confirmation, before correction | **Behavioral red:** pick Git WorktreeDirectory without adding it, enter `pending_directory`, then use input `name` Connect-to on literal-backed `resolve.worktree_name`. One Escape canceled the confirmation **and clicked `close-picker`**, removing the choice and add form. Tools, Connect-to, selection and literal `branch` remained. |
| Same overlap after correction | **Pass:** one Escape removed only the confirmation; Git WorktreeDirectory, `pending_directory`, Connect-to, Tools, selected resolve and literal `branch` remained. No picker click occurred, and focus returned to visible `connect-resolve-worktree_name`. |
| Underlying Escape behavior after cancellation | **Pass:** subsequent individual Escapes closed Connect-to, the catalog picker, Tools and selection, in that order; each lower surface remained until its own key. |
| Workflow and stage width | **Pass:** each measured 1248px initially, 848px selected, 1248px after unmoved blank click. |
| Tools keyboard focus on both levels | **Pass:** Enter on `open-tools` focused `close-tools`; Escape removed Tools and focused `open-tools`. |
| Editable-field Escape | **Pass:** Escape in `literal-resolve-worktree_name_value` preserved its focus and inspector. |
| Stage wire after resize and Validate | **Pass:** both ends of the resolve-to-directory value wire measured 0.00px from socket centers with inspector, after dismissal and after Validate. |

Evidence files: `/private/tmp/sidebar-phase1-retry-escape.mjs` and
`/private/tmp/sidebar-phase1-retry-smoke.mjs`; logs
`/private/tmp/sidebar-phase1-retry-browser-red.log`,
`/private/tmp/sidebar-phase1-retry-browser-green.log` and
`/private/tmp/sidebar-phase1-retry-smoke.log`. The red driver initially clicked
Validate before inspecting focus; that focus observation is not used as evidence.
The green driver inspects focus after the cancellation patch and two animation
frames, without that focus-changing click. Both runs asserted preservation of
the same pending catalog form and covered surfaces. Disposable draft IDs:
red `1cc258ff-f579-447c-8a1d-a6648dd7cba8`, green/smoke
`3f913598-510e-473d-acab-5bbb5095462b`. Neither successful driver reported a page
exception.

The updated hook regression also failed against an isolated copy of the retry
baseline hook (8 passed, 1 failed: unexpected `close-picker` click) and passes
with the correction. Final checks: `make test-js` (52 passed), the four focused
phase 1 LiveView files (100 passed), and `mix precommit` (489 passed; no Credo
findings). Logs are `/private/tmp/sidebar-phase1-retry-js-red.log`,
`/private/tmp/sidebar-phase1-retry-js-green.log`,
`/private/tmp/sidebar-phase1-retry-focused.log` and
`/private/tmp/sidebar-phase1-retry-precommit.log`. Initial sandbox-only browser
and Mix attempts failed with local-network/TCP-lock `EPERM`; reruns with local
access succeeded. Those setup failures are not behavioral red evidence.

Limits: this bounded retry did not repeat browser drag/pan/wire cancellation,
node/choice/relationship issue focus or cross-level navigation, replacement
confirmation by Replace, workflow wire measurements, warning-producing clear
preview focus, or physical-device checks. Earlier observations remain historical;
the focused automated tests do not establish these unobserved browser claims.

## Canvas auto-fit — phase 1, 2026-11-06

Fresh observations against this phase on port 4010, headless Chrome 156 at 1600x1000
through CDP, with a temporary driver outside the repo. Pointer press/move/release, wheel and Escape
were trusted browser events. The slider was set by script with the browser's own `input`
event. The node and draft forms were filled and submitted by script. Seeded drafts were
only observed; the mutating rows used a disposable draft created and deleted through the
UI. No page exception was observed. Earlier results above are historical: the "Each level
has its own view" row's initial view is now a fit.

The seeded facts held: `Create a worktree` has five workflow vertices reaching x 1580, and
`Cracow house price` has a five-node `estimate_price` stage reaching x 900.

| Check | Fresh result |
|---|---|
| `create_worktree` workflow opens fitted | Pass: all 5 `article[data-node]` rects inside `#stage-canvas`, 100%, slider 100, scale 0.622222. |
| `estimate_price` stage opens fitted | Pass: all 5 rects inside, 100%, slider 100, scale 0.965517. |
| Slider to max, then to 25 | Pass: workflow max 200 gives scale 1.24444, stage max 200 gives 1.93103; 25 shows 25% on both, true scale 0.155556 and 0.241379. |
| Route wires at the fitted scale | Pass: both ends of all 5 workflow wires measure 0.00 px from socket centres, fitted and after Ctrl+wheel. |
| Ctrl+wheel at a fit | Pass: 115%, 125%, 145%, 125%: each a 5% step of the fit. |
| Select and open a list on stage `inspect` | Pass: selecting `worktree_name` and opening its optional list (card 207 to 255 px tall) left `translate(237px, 305.5px) scale(1)` and 100% unchanged. |
| Reset with the inspector open | Pass: 100%, every card inside the 848 px canvas, scale 0.871671, which is the expected re-measure of the narrower canvas. |
| Pan, leave the level and come back | Pass: panned to `translate(327px, 360.5px)`; the workflow opened at its own fit; the stage returned to its fresh `translate(237px, 305.5px) scale(1)`. |
| One runner | Pass: disposable draft on load, scale exactly 1, 100%, translated to `translate(404px, 258.5px)`. |
| Card drag at a fit that isn't a 5% step | Pass: at scale 0.7128712871287128, a (97, 61) px drag saved (+136, +86), against 136.07 and 85.57 expected; transform and 100% unchanged. |
| Wire and preview wire at that fit | Pass: the value wire's ends measure 0.00 px after the drag. The preview starts 0.00 px from its socket, ends 0.00 px from the pointer in the open and 0.00 px from the field socket on hover. Escape removes it, with the transform unchanged. |
| Fit below 0.5 | Pass: scale 0.439829, slider max 230, and the slider at 230 gives true scale 1.01161, 230%. |

The disposable draft `b6bb0ff1-1939-4577-9547-5234b53b2b26` was deleted through the UI, and
its row left the list.

Limits: a physical mouse or trackpad wasn't used, and a pinch was simulated as Ctrl+wheel.
The fit at the floor of 0.1, and a page that loads its fonts late, weren't walked in a
browser; the floor is covered by the `fitView` unit tests, which don't establish how it
looks. Resizing the window after a fit wasn't driven: the hook test shows the resize
callback leaves the view and fit alone, and the selection row above shows it for the
inspector's width change.

## Stage source nodes — phase 2, 2026-11-06

Fresh observations against this phase on port 4010, headless Chrome 156 at 1600x1000
through CDP, with a temporary driver outside the repo. Pointer press/move/release and clicks
were trusted browser events. The draft, vertex, input and node forms were filled and
submitted by script, and buttons pressed by script. Seeded drafts were only observed; the
mutating rows used a disposable draft created and deleted through the UI. Each wire was
sampled at 200 points with `getPointAtLength`, and its ends measured from its socket centres.
No page exception or console error was observed. Earlier results above are historical: where
they name an input's socket on the rail, on a stage it is now on the input's node.

The seeded facts held: `Cracow house price` stage `estimate_price` has seven inputs, each
bound once, and `Create a worktree` stage `sync` reads `resolve` from two fields.

| Check | Fresh result |
|---|---|
| `estimate_price` input wires | Pass: 7 source nodes, 7 input wires, 0 of 200 points outside `#stage-canvas` on each, both ends 0.00 px from their sockets. The other 7 wires measure the same. |
| `estimate_price` fit | Pass: all 12 `article[data-node]` rects inside the canvas, 100%, slider 100, scale 0.746667, every source node left of the leftmost runner. |
| `estimate_price` overlap | Pass: no two source nodes overlap; each is 64 px tall under the 112 px row step. |
| `sync` earlier source | Pass: `#source-resolve` exists, and its 2 wires have 0 of 200 points outside, both ends 0.00 px. |
| Position per stage | Pass: `topic` dragged on `first` from (-280, 80) to (-310, 190); on `second` it stayed at (-280, 192). |
| Undo, then reload | Pass: back on `first`, Undo restored (-280, 80). Dragged again to (-306, 172), a reload kept it. |
| After handle dropped on a source node | Pass: no console error, no `add_after` frame, no `data-drop-hover` while over it or after. |
| Value wire dropped on a source node | Pass: no `connect` or `open_picker` frame, no picker, no `data-drop-hover`. |
| Click and double-click a source node | Pass: with `a` selected its select button stays pressed and the inspector stays; no select frame, no navigation. |
| Drag from an unread row onto a field | Pass: `b`'s row socket onto `create.branch_name` sent one `connect`; `#source-b` appeared, and the row has no socket and no Connect to. |
| The new wire after Reset | Pass: 0 of 200 points outside, both ends 0.00 px. |

The disposable draft `b1afc54d-60cc-4416-81db-4f7290624755` was deleted through the UI, and its
row left the list.

Limits: nothing refits on an edit, which is accepted. A runner added to `second` opened outside
the fitted view until the next fit: `create` was out of view after the Connect to that built the
draft. The row-to-field check started from a fresh fit, and there `#source-b` and every other
card were already in view before Reset, so the off-view state of a newly bound source wasn't
seen. A physical mouse or trackpad wasn't used, the first-selection clipping of the right side
wasn't measured, and a real keyboard walk of the moved Connect-to buttons wasn't run; their
events are covered by the LiveView tests, which don't establish focus behaviour.

## Seeded descriptions — phase 2, 2026-11-06

Fresh observations against this phase on port 4010, headless Chrome 156 at 1600x1000
through CDP, with a temporary driver outside the repo. Pointer press/move/release were
trusted browser events. Nothing was re-seeded: `Walkthrough Create a worktree` and
`Walkthrough Cracow house price` were disposable copies of the documents from
`Definitions.all()`, made with `Composer.create_draft/2`, and every existing draft was left
alone. `make db-start-dev` stopped on `proxy already running` from the container runtime;
the dev database was already up and its one migration applied, so the walk went on. Each
expected title came from the `Definitions.all()` document, compared in full. No page
exception, console error or error log entry was observed. Earlier results above are
historical.

| Check | Fresh result |
|---|---|
| Runner node card `title` | Pass: every node on all 4 `create_worktree` stages (9) and on `estimate_price` (5), e.g. `#node-resolve-description`. |
| Stage card `title` | Pass: `#vertex-inspect-`, `-create-`, `-sync-`, `-finalize-` and `#vertex-estimate_price-description`. |
| Decision card `title` | Pass: `#vertex-route-description`. `cracow_prices`: not applicable, it has no decision. |
| Input source node `title` | Pass: every input source node on each stage of both drafts, e.g. `#source-branch_name-description`; all 7 on `estimate_price`. |
| Earlier source `title` | Pass: `#source-worktree_name-description` on `create` and `finalize`, and `#source-resolve-description` on `sync`, each with its origin node's text. `cracow_prices`: not applicable, it has one stage. |
| Rail input row `title` | Pass: 3 and 7 rows, on the workflow and on each stage. |
| Icon state and ids | Pass: 7 views, each icon holds the information icon, none is red, and no id on a page repeats. |
| Height and socket positions | Pass: on all 7 views, removing every icon span by script in the same page left x, y, width and height of each card, socket and rail row unchanged (delta 0 within 0.001 px). 42 cards, 116 sockets and 29 rail rows across the views, at fits from scale 0.622222 to 1. |
| Press an icon without moving | Pass: on the 8 cards of the next row. No event frame, no `aria-pressed="true"`, canvas still 1248 px, card not moved. |
| Drag from an icon | Pass: one `node_moved` frame each, `data-x`/`data-y` moved, and a reload kept them. `resolve` (480, 80) to (540, 122); `branch_name` (-280, 192) to (-219, 235); `worktree_name` on `create` (-280, 416) to (-220, 458); `inspect` (60, 300) to (156, 368) and `route` (440, 300) to (531, 364) at scale 0.622222; `normalize` (60, 144) to (140, 200); `rooms` (-200, 640) to (-124, 693); `estimate_price` (60, 80) to (120, 122). |

Rail rows aren't draggable, so the press and drag rows don't apply to them. The two copies,
`180523d4-069b-4d04-bccc-ee7678c7ab53` and `bc1c564d-87f5-4f12-a608-1f03a8ea360d`, were
deleted through the UI with its confirmation, and their rows left the list after a reload. No
`Walkthrough` draft is left, so a later seed isn't taken in by one.

Limits: **a native tooltip's display is unverified.** A headless agent can read `title` but
can't see the browser show it, so hovering one icon of each kind in a real browser remains a
one-minute check for a person. A physical mouse or trackpad wasn't used, and keyboard and touch
can't reach the text by design. Re-seeding after deleting real drafts wasn't walked, because no
person's draft may be touched; `Seeds.run` on an empty table is covered by the LiveView tests,
which don't establish it in a browser. A red icon wasn't walked here either, since the seeds
hold none; the LiveView tests cover it.

## Start, watch and cancel a run — phase 2, 2026-11-07

Fresh observations on port 4010 with headless Chrome at 1600x1000 through CDP, with a
temporary driver outside the repo: trusted pointer input, and `Input.insertText` for the
start fields. `Walkthrough Cracow house price review`
(`cd2ad769-007e-4162-9402-6cc2b44b67f1`) was a disposable copy of the
`Definitions.all()` document made with `Composer.create_draft/2`; no existing draft was
touched. `domovoy_dev` (port 54323) now holds `composer_runs` and Core's tables, with all
three migrations up. Wire alignment was measured, for every edge of the view, as the
distance from each end of its drawn path (`getPointAtLength` through `getScreenCTM`) to
the centre of its socket. No page exception, console error, or error or warning log line
was observed, and no start value (`Krowodrza`, `58.5`) appeared in the server log.

| Check | Fresh result |
|---|---|
| Start form and effect confirmation | Pass: `#start-run` opened `#start-form` with all 7 inputs; rooms `3`, bathrooms `1`, area `58.5`, district `Krowodrza` typed, the rest left to their defaults. Submit showed `#start-effects` listing Examples AreaModel, Estimate, LayoutModel, LocationModel and Normalize |
| Start | Pass: Confirm patched to `?run=b486d71c-6e90-491c-a14c-6b4ac064653c`; `#stage-canvas` carries `data-read-only`; `#run-status` "Waiting for your decision on review", phase `waiting`, outcome "not yet", `#run-pending` "review is waiting for a decision." |
| Live status on cards | Pass: `estimate_price` `data-run-status="succeeded"`, `review` `needs_you`. `data-x`/`data-y` (60, 80) and (440, 80) and each card box (280 x 93.297, 280 x 144.297) were the same as in the draft before the start |
| Wires after a status change | Pass: 2 of 2 wires on the workflow, 0 px from their sockets; the route into `review` drew `wire-run-succeeded`, the untaken `revise` rerun route no run class. On `estimate_price`, 14 of 14 wires at 0 px, 7 `wire-run-succeeded` and 7 with no run class, matching the 7 input source nodes, which carry no status; all 5 runner nodes `succeeded` |
| Stage round trip | Pass: the card's open link reached `/stages/estimate_price?run=...`, and `#breadcrumb-workflow` came back to `?run=...` with the same statuses |
| Drag in a run | Pass: a trusted press and 80 x 50 px move on `estimate_price` changed no `data-x`/`data-y` |
| Reload | Pass: same URL, level, phase, statuses and wire classes, wires at 0 px |
| Cancel | Pass: `#cancel-run` opened `#cancel-run-dialog`; `#confirm-cancel-run` gave "Cancelled", phase `finished`, outcome `cancelled`, no pending decision and no `#cancel-run`; wires at 0 px |
| Decision after cancel | Fixed during this walk: `review` first kept `needs_you`, because the fold ignored Core's `decision_superseded`. After the fix and a reload it reads `cancelled` |
| A start whose task dies | From the attempt earlier today, when the tables were missing: the form stayed with its ids, the rejection read "Starting the run didn't finish. Try again.", and no value reached the error log |

The copy was deleted through the draft list with its confirmation, and its row stayed gone
after a reload; its run's row keeps a nil `draft_id`. No `Walkthrough` draft is left.

Limits: Cracow's runners finish too fast to see a card in `running`; that transition is
covered by `composer_run_view_live_test.exs` with the hold runner. "No duplicate
attempts after reload" isn't visible in this phase's UI, which shows no attempt list, and
rests on the same test file. A physical mouse, keyboard focus order and a socket
reconnect without a reload weren't walked.

## Overlay workspace and trapped dialogs — phase 1, 2026-11-08

Fresh observations on port 4010 with headless Chrome 156 through CDP, with a temporary
driver outside the repo: trusted mouse and key input (`Input.dispatchMouseEvent`,
`Input.dispatchKeyEvent`), and device sizes set with `Emulation.setDeviceMetricsOverride`.
`Walkthrough workspace phase 1` (`1de30e33-5295-4de7-b2cb-39b39e492a96`) was a disposable
copy of the `Cracow house price review` document made with `Composer.create_draft/2`; no
existing draft was touched. Its run `4d62e34a-27bc-444e-aa51-addf7441fdff` was started
through `#start-run` with rooms `3`, bathrooms `1`, area `58.5` and district `Krowodrza`.
Wire alignment was measured as before: each end of each drawn path, through
`getScreenCTM`, against the centre of the socket its key names. No page exception,
console error, or error or warning log line was observed, and no start value appeared in
the server log.

| Check | Fresh result |
|---|---|
| 1440x1000, no panel open | Pass: `#stage-canvas` 1408 px wide on the draft workflow, the `estimate_price` stage and the run page; no `#left-rail` or `#right-rail` exists |
| 1024x768, inspector opens | Pass: `#stage-canvas` 992 px before and after `#vertex-review-select`, with `#inspector-panel` shown over it |
| Wires with outline and inspector open | Pass: on `estimate_price` with `#outline-panel` open and `normalize` selected, 28 path ends, the largest offset 0.00 px (3.5e-5); on the run's workflow with both open, 4 ends at 0.00 px |
| Start opens the outline | Pass: `#start-run` showed `#start-form` in the open `#outline-panel`; submit and `#confirm-start` patched to `?run=...` with `review` `needs_you` |
| Cancel dialog traps focus | Pass: five Tab and five Shift+Tab presses alternated between `#confirm-cancel-run` and `#close-cancel-run`, each inside `#cancel-run-focus`; `#run-header` and `#workspace` carried `inert` |
| Escape in the dialog | Pass: the dialog closed, focus returned to `#cancel-run`, `review` stayed selected (`aria-pressed="true"`), and no element kept `inert` |
| Server-side close | Pass: with the dialog open, `#back-to-draft` patched to the draft; the dialog unmounted and no element kept `inert` |
| 390x844, one surface | Pass: on the draft and the run, the canvas surface showed no panel; Outline / Steps showed only `#outline-panel`, covering the workspace; selecting `review` on the draft, and Review on the run (which patched to `?run=...&node=review`), showed only `#inspector-panel`, covering it. `#stage-canvas` stayed 374 px wide underneath, `scrollWidth` 390 = `innerWidth`, and no header link or button lay outside the viewport |
| Confirm cancel | Pass: `#confirm-cancel-run` gave "Cancelled", with no element left `inert` |

The copy was deleted with `Composer.delete_draft/1` and `get_draft/1` then returned
`:not_found`; its cancelled run's row keeps a nil `draft_id`. No `Walkthrough` draft is left.

Limits: the walk was headless, so the panels' 150 ms fade was not watched, and
`prefers-reduced-motion` was not emulated. "No header control clipped" was checked as no
visible link or button outside the viewport, not by eye. A physical mouse, a screen reader
and a socket reconnect while the dialog is open weren't walked.

## Canvas controls — phase 2, 2026-11-08

Fresh observations on port 4012 with headless Chrome through CDP, with a temporary driver
outside the repo: trusted mouse and key input (`Input.dispatchMouseEvent`,
`Input.dispatchKeyEvent`), device sizes set with `Emulation.setDeviceMetricsOverride`.
`Walkthrough canvas controls phase 2` (`bac628ca-3c52-4553-bcd5-b8d6b0ac4478`) was a
disposable copy of the `Cracow house price review` document made with
`Composer.create_draft/2`; no existing draft was touched. Wires were measured as in
phase 1. `localStorage` was cleared between rows, and no page exception or console error
was observed.

| Check | Fresh result |
|---|---|
| 1024x768, pin at 440 px | Pass: refused. `#canvas-notice` read "Not enough room to pin: the canvas needs at least 600 px.", `#workspace` got no `data-pinned`, `#pin-inspector` stayed `aria-pressed="false"`, and the transform stayed `translate(106px, 161px) scale(1)` |
| 1024x768, pin at 384 px | Docked: `#inspector-panel` 384 px, transform unchanged. `#stage-canvas` was 596 px, because the dock also keeps a 0.75rem gap that `canPin` doesn't count |
| 1440x1000, pin with `estimate_price` selected | Pass: docked at 384 px, `#stage-canvas` 1408 → 1012 px, transform `translate(314px, 298px) scale(1)` unchanged, 4 wire ends at 0.00 px |
| 1440x1000, pin with `review` selected | Docked at 440 px. The dock covered `review`, so the view panned 56 px left (`292px` → `236px`) to reveal it, with the zoom unchanged and wires at 0.00 px |
| Opening the overlay inspector | Pass: `estimate_price` at 1440 kept the transform. `review`, under the panel, panned only enough to clear it: 22 px at 1440 and 230 px at 1024 |
| Resize handle with the keyboard | Pass: four ArrowLeft presses on `#inspector-resize` went from 384 to 440 px and stopped there; ArrowRight went from 440 to 424 px. The transform and wires (0.00 px) didn't change, and `localStorage["composer:pin"]` held only `{"pinned":true,"width":440}` |
| Pin kept across a reload and a resize | Pass: a reload docked at 440 px and fitted to the 956 px canvas. Resizing to 1024 px floated the inspector, kept `aria-pressed="true"` and the transform; going back to 1440 px docked it again |
| Unpin | Pass: `#stage-canvas` went back to 1408 px and the transform stayed the same |
| Fit · N% on the `estimate_price` stage | Pass: the fit is scale 0.853 and reads "Fit · 100%". Actual size gave scale 1 and "Fit · 117%"; Fit stage put back the same transform and "Fit · 100%" |
| Canvas only at 1440 | Pass: `#composer[data-canvas-only]`, the header `display: none`, `#stage-canvas` 1408 px, focus on `#exit-canvas-only`. Escape left canvas only and focus went back to `#canvas-only` |
| 390x844 | Pass: `#canvas-zoom` wraps between 20 and 370 px, and `scrollWidth` 390 = `innerWidth`. `#pin-inspector` is not shown. Canvas only hid the inspector, `#stage-canvas` was 374 px, and the bar ended at 370 px |

The copy was deleted with `Composer.delete_draft/1`, and `get_draft/1` then returned
`:not_found`. No `Walkthrough` draft is left.

Limits: the walk was headless, and a drag on the resize handle wasn't walked in the browser.
Its drag path is covered by `canvas_hook.test.js`. Canvas only on a run page was not walked
in the browser; `composer_workspace_live_test.exs` covers it. Fit selection was not walked.
A physical mouse, a trackpad and a screen reader weren't tried.

## New run from every page — phase 3, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server`, a disposable
copy of `Cracow house price review`, and device sizes 1440x1000 and 390x844.

| Check | Fresh result |
|---|---|
| 1440x1000, New run on a finished run | Not walked. Expected: `#new-run` opens `#launcher-panel` on the right, reading "Starts a separate run from the current saved draft."; the fields are the saved draft's, blank; Start run patches to the new run and the old one is unchanged |
| 1440x1000, New run on an awaiting run | Not walked. Expected: the launcher adds "; the current run continues"; closing it leaves the run's status live; starting patches to the new run while the old one still awaits its decision |
| 1440x1000, New run on a workflow-list row | Not walked. Expected: `#new-run-<id>` opens the draft with the launcher shown and the URL without `?launch=1` |
| 390x844, the same three | Not walked. Expected: the launcher covers the workspace as the one surface, the switcher shows "New run", `scrollWidth` equals `innerWidth`, and no header control is clipped |

Limits: not walked, for the reason above. `composer_run_new_run_live_test.exs` covers the
behaviour of each row except layout, motion and focus.

## Stop, Resume and command progress — phase 4, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server`, a disposable
draft holding `Domovoy.PureHoldRunner` with `trap_exit` on (or a disposable copy of
`Cracow house price review` stopped at its decision), and device sizes 1440x1000 and
390x844.

| Check | Fresh result |
|---|---|
| Stop with a held runner | Not walked. Expected: `#stop-run` shows `#run-op` "Stop accepted. Stopping active work and saving checkpoint", `#run-status` "Stopping active work and saving checkpoint", no `#resume-run` and no `#stop-run` |
| Stop completes | Not walked. Expected: once the runner ends, `#run-op` goes, `#run-status` reads "Stopped. Resume run continues it from its checkpoint", and `#resume-run` is the one filled button beside `#cancel-run` |
| Resume | Not walked. Expected: `#resume-run` shows "Resume accepted. Continuing this run", then the same `#run-id` goes on running |
| Double click on Stop | Not walked. Expected: the second click shows the same `#run-op` and no `#rejection`; the button is disabled while the request is in flight |
| Finished run (succeeded, failed, cancelled) | Not walked. Expected: no `#stop-run`, `#resume-run` or `#cancel-run`; `#new-run` shows |
| Stopped review run | Not walked. Expected: the decision note reads "Accept finishes it now. Revise runs when you press Resume run." |
| 390x844 | Not walked. Expected: the header's Stop run, Resume run and Cancel run wrap without clipping, and `scrollWidth` equals `innerWidth` |

Limits: not walked, for the reason above. `composer_run_stop_resume_live_test.exs` and
`composer_run_decision_live_test.exs` cover the behaviour of each row except layout,
focus and motion. The resync notice `#run-fold-stale` can't be forced from a browser
without Core's retention moving its floor, and rests on the same test file.

## Launcher and saved input sets — phase 5, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server`, a disposable
copy of `Cracow house price review` (it has an effect review) and a disposable draft of
one pure runner (it has none), and device sizes 1440x1000, 1024x768 and 390x844.

| Check | Fresh result |
|---|---|
| Field notes | Not walked. Expected: `area` shows its description, a "Required to run" chip with "A step reads it.", and a field with a plain default reads "Default: <value>"; a path default reads "Has a default" |
| Effects review | Not walked. Expected: `#start-effects` lists `estimate_price / normalize: …` and each other node by stage and node, with "These steps may change things outside Composer." |
| Back to inputs | Not walked. Expected: `#back-to-inputs` shows `#start-form` again with every typed value in place; Start run then shows the same review |
| Save a set | Not walked. Expected: type `58.5` into `area`, give `#save-input-set-name` "Sample flat" and press `#save-input-set`: "Saved as Sample flat." shows, the row appears under `#input-sets`, and no run starts |
| Use a set | Not walked. Expected: after closing and reopening the launcher, Use fills `area` with `58.5`; a field the set doesn't hold reads "Not saved in Sample flat." |
| Opt-in value | Not walked. Expected: a set saved with `#save-opt-in-<path>` ticked shows "Using the saved value from <set>." with Clear and an empty field; view-source and devtools show no saved path |
| Drift | Not walked. Expected: after removing or retyping a saved input in the editor, Use shows `#start-drift` naming it, `#submit-start` disabled until `#ack-drift` |
| Two clicks from a run page | Not walked. Expected: on a finished run of the pure draft, `#new-run` then `#input-set-start-<id>` patches to the new run |
| 390x844 | Not walked. Expected: the set rows' Use, Start with this set and Delete wrap without clipping, and `scrollWidth` equals `innerWidth` |

Limits: not walked, for the reason above. `composer_launcher_live_test.exs` covers the
behaviour of each row except layout, focus, the delete confirmation and motion.

## Results workspace, decision evidence and failure paths — phase 6, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server`, a disposable
copy of `Cracow house price review` with `estimate` ticked under `#evidence-form` on
`review` and under `#outputs-form` in the outline, a disposable draft of one
`Domovoy.LeakRunner` node set to fail, and device sizes 1440x1000, 1024x768 and 390x844.

| Check | Fresh result |
|---|---|
| Declare evidence and outputs | Not walked. Expected: ticking `estimate` under `#evidence-form` and `#outputs-form` saves at once; an older run of the draft then shows `#run-draft-changed` |
| Evidence at generation 0 | Not walked. Expected: Answer review shows `#decision-evidence` above the choices, `estimate` labelled "Generation 0" with its output in a sunken well |
| Evidence after Revise | Not walked. Expected: after Revise with `Kazimierz`, the next review labels `estimate` "Generation 1" and shows the revised output |
| Results panel | Not walked. Expected: `#open-results` opens `#results-panel` on the right with "Workflow outputs" listing `estimate` first, then `estimate_price` listing the other four nodes; a row expands to its output and collapses again; selecting a card shows the inspector, and Close brings Results back |
| Reload result | Not walked. Expected: shown only when a read ends without a result; pressing it reads again and starts no attempt (the run's step badges and `#run-phase` stay as they were) |
| Failed run | Not walked. Expected: the failed leak run shows `#view-failed-step` and `#new-run`; View failed step opens stage `main` with `leak` selected and its `leak_failed` type |
| 390x844 | Not walked. Expected: the switcher offers Canvas, Steps, Review and Results, exactly one shows at a time, `#results-panel` fills the workspace, and `scrollWidth` equals `innerWidth` |

Limits: not walked, for the reason above. `composer_run_results_live_test.exs` and
`composer_run_decision_live_test.exs` cover the behaviour of each row except layout,
focus and motion. Lag, an unavailable read and a stopped read are set by hand in the
test, since none can be forced from a browser; Core's real refusal at generation 10 is
covered by the decision test, not by a browser walk.

## Stated generation scope — phase 7, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server`, a disposable
copy of `Cracow house price review` revised once at `review` (so generation 1 is
asked), and device sizes 1440x1000 and 390x844.

| Check | Fresh result |
|---|---|
| Graph scope control | Not walked. Expected: Steps shows `#generation-scope` "Graph shows" with Latest, Gen 0 and Gen 1, Latest pressed; it is absent on a run that has only generation 0 |
| Graph at generation 1 | Not walked. Expected: Gen 1 patches `scope=1`; on `estimate_price`, nodes with no generation-1 attempt read "Not executed in this generation" with a muted title and no outline; a skipped node reads "Skipped" |
| Inspector at generation 0, graph at latest | Not walked. Expected: selecting `estimate` and pressing `#run-generation-0` patches `node=estimate&gen=0`; `#run-scope-label` reads "Showing estimate from generation 0; graph shows latest" and the cards keep their latest statuses |
| History never answers | Not walked. Expected: with Gen 0 picked and generation 1's review pending, selecting `review` shows `#decision-history-note` and no choices; Show latest brings the form back |
| Refresh | Not walked. Expected: reloading `?run=R&node=estimate&gen=1&scope=1` reopens with `estimate` selected, Gen 1 pressed in both places |
| 390x844 | Not walked. Expected: the scope buttons wrap without clipping, and `scrollWidth` equals `innerWidth` |

Limits: not walked, for the reason above. `composer_run_generations_live_test.exs` and
`run_view_test.exs` cover the behaviour of each row except layout, focus and motion.
Wires keep the latest trace whatever the graph scope; only card statuses follow it.

## Draft-independent run route — phase 8, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server`, a disposable
draft of one `Domovoy.LeakRunner` node run once to `succeeded` and then deleted from
`/composer`, a second disposable draft with a finished run that is kept, and device
sizes 1440x1000 and 390x844.

| Check | Fresh result |
|---|---|
| Orphaned run opens | Not walked. Expected: `/composer/runs/<id>` shows the run's snapshot on the canvas, the breadcrumb names the workflow, `#run-outcome` reads "succeeded", and `#back-to-draft` is absent |
| New run refused | Not walked. Expected: `#new-run` is disabled, with "This workflow's draft was deleted" beside it in muted text |
| Run with a draft | Not walked. Expected: `/composer/runs/<id>` of the kept draft's run lands on `/composer/<draft>?run=<id>` |
| Unknown id | Not walked. Expected: `/composer/runs/not-a-uuid` lands on `/composer` with "That run doesn't exist." |
| Stage on the orphan route | Not walked. Expected: Open on stage `main` patches to `/composer/runs/<id>/stages/main`; selecting `leak` keeps that route |
| 390x844 | Not walked. Expected: the header wraps the disabled New run and its reason without clipping, and `scrollWidth` equals `innerWidth` |

Limits: not walked, for the reason above. `composer_retained_run_live_test.exs` covers
the behaviour of each row except layout and focus, including the crafted commands an
orphaned run refuses before any Core call.

## Run summaries, switcher and Runs view — phase 9, 2026-11-08

No browser was available to this phase's implementer, so none of these rows has a fresh
observation yet. They are listed for the next walk with `mix phx.server` (the dev
sweeper runs every 30 seconds), a disposable draft of the "Cracow house price review"
seed started 12 times with the oldest run left waiting on `review` and the 11 newer ones
answered to `succeeded`, and device sizes 1440x1000, 1024x768 and 390x844.

| Check | Fresh result |
|---|---|
| Waiting run in the switcher | Not walked. Expected: on the draft, Outline lists the old waiting run first with a "Needs you" chip, then the newest runs; the header's Unfinished run links to it |
| Run page switcher | Not walked. Expected: `#run-switcher` shows "Runs" with an attention count; pressing it opens the Steps panel at `#recent-runs` without moving the canvas |
| Needs a check | Not walked. Expected: a run started on the draft and not yet opened or swept shows "Needs a check", and no Unfinished run link points to it |
| Start times | Not walked. Expected: each switcher and Runs row shows its start as `YYYY-MM-DD HH:MM UTC` |
| Runs view | Not walked. Expected: `#runs-link` on `/composer` opens `/composer/runs`; 25 rows show newest first with Show older runs below, which appends the rest and then disappears |
| Filters | Not walked. Expected: Status "Needs attention" patches `?status=attention` and leaves only the waiting run; Draft "Deleted drafts" lists runs of deleted drafts, each opening `/composer/runs/<id>` |
| Lazy refresh | Not walked. Expected: a waiting row last refreshed over 30 seconds ago updates in place shortly after the page renders, without the list jumping |
| 390x844 | Not walked. Expected: the filter selects stack, rows truncate the workflow name without clipping the chip, and `scrollWidth` equals `innerWidth` |

Limits: not walked, for the reason above. `runs_live_test.exs`,
`composer_run_view_live_test.exs`, `runs_test.exs` and `runs_postgres_test.exs` cover the
behaviour of each row except layout, focus and motion, including that rendering and
paging open no run.

## Composer redesign — final walk, phase 10, 2026-11-08

Fresh observations on port 4013 with headless Chrome through CDP, with a temporary driver
outside the repo: trusted mouse and key input (`Input.dispatchMouseEvent`,
`Input.dispatchKeyEvent`), device sizes set with `Emulation.setDeviceMetricsOverride`.
`Walkthrough final phase 10` (`27890746-f45b-4b00-8a6b-71ae4855e8fd`) was a disposable
copy of the `Cracow house price review` document made with `Composer.create_draft/2`; no
existing draft was touched. Its run `90d20905-c880-44b0-934f-38e7414275b8` was started
through `#start-run` with rooms `3`, bathrooms `1`, area `58.5` and district `Krowodrza`.
No page exception or console error was observed, and the server log held no start value.

| Check | Fresh result |
|---|---|
| Canvas widths, no panel open | Pass: on the draft, `#stage-canvas` 1408 px at 1440x1000, 992 px at 1024x768 and 374 px at 390x844, with no `#left-rail` or `#right-rail`; the run page gave 1408 px at 1440x1000. `scrollWidth` equalled `innerWidth` at each size |
| 1024x768, inspector opens | Pass: `#run-pending-link-review` showed `#inspector-panel` 384 px wide over the canvas; `#stage-canvas` stayed 992 px |
| Cancel dialog traps focus | Pass: five Tab and five Shift+Tab presses alternated between `#confirm-cancel-run` and `#close-cancel-run`, each inside `#cancel-run-focus`; `#run-header` and `#workspace` carried `inert` |
| Escape in the cancel dialog | Pass: the dialog closed, focus returned to `#cancel-run`, no element kept `inert`, and the run still read "Waiting for your decision on review" |
| New run from a run | Pass: on the awaiting run, `#new-run` showed `#launcher-source` "Starts a separate run from the current saved draft; the current run continues." with `#stage-canvas` still 1408 px |
| Stop, then Resume | Pass: `#stop-run` led to "Stopped. Resume run continues it from its checkpoint" with `#resume-run` the filled button and no `#stop-run`; `#resume-run` brought back "Waiting for your decision on review" under the same `#run-id` `90d20905` |
| Pause from More | Pass: `#run-more` held only `#pause-run`; on the waiting run, with no active work to finish, it went straight to "Paused. Unpause run lets it go on" (no `#run-op` was seen between polls 50 ms apart), the menu closed, and `#run-more` then held only `#unpause-run` |
| Unpause | Pass: `#unpause-run` brought back "Waiting for your decision on review", with `#pause-run` offered again |
| More menu at each size | Fail, then fixed and re-measured: at 390x844 the open menu began at -91 px, off the left edge. It now stays in the header's flow below `md`: open at 390x844 it spans 25 to 124 px; at 1024x768 383 to 575 px and at 1440x1000 799 to 991 px, right-aligned to More; `scrollWidth` equalled `innerWidth` each time |
| No "Mark succeeded" | Pass: no button or link on the run page reads it while the run was waiting, paused and finished. A blocked run, the one case that offers reconcile, wasn't reached in the browser; it rests on `composer_run_pause_reconcile_live_test.exs` |
| Finished run | Pass: after Accept, `#run-status` read "Finished", and `#run-header` offered no `#stop-run`, `#resume-run`, `#cancel-run` or `#run-more`; `#new-run` showed |
| Orphan route | Pass: after the draft was deleted, `/composer/runs/<id>` stayed on that path at 1440x1000 and 390x844 with "Finished", `#new-run` disabled beside "This workflow's draft was deleted", no `#back-to-draft`, and `scrollWidth` equal to `innerWidth`; `/composer/runs?draft=deleted` linked to it |
| 390x844, one surface | Pass: with `review` selected only `#inspector-panel` showed, `#stage-canvas` stayed 374 px underneath, and `scrollWidth` 390 = `innerWidth` |
| Wires, pinning, Fit and Actual size | Not walked in this pass; measured in phases 1 and 2 above; this phase changed no canvas, wire or pin code |
| Input set in two clicks | Measured in phase 11 below: three clicks on a Cracow copy, because its runners declare no effect and so every start has an effect review. The two-click case, with no effect review, rests on `composer_launcher_live_test.exs` |
| Decision evidence beside the choices | Not walked; the copy declared no evidence node |
| History beyond ten runs | Not walked; it needs 12 runs of one draft |
| Uncertain effect review and reconcile | Not walked; it can't be forced from a browser |

The copy was deleted with `Composer.delete_draft/1`, and `get_draft/1` then returned
`:not_found`; its finished run's row keeps a nil `draft_id`. No `Walkthrough` draft is left.

Limits: the walk was headless, so motion and `prefers-reduced-motion` were not watched, and
no physical mouse, trackpad or screen reader was tried. "Not clipped" was checked as no
visible header control outside the viewport, not by eye. The rows marked Not walked, and
why:
- Wires, pinning, Fit and Actual size: this phase changed no canvas, wire or pin code, so
  the phase 1 and 2 measurements stand. Phase 11 below counted the wire paths drawn
  with the inspector pinned (14) and measured pinning, Fit and Actual size again; it did
  not re-check that the wires line up with their sockets.
- Decision evidence beside the choices: the copy declared no evidence node (measured in
  phase 11 below); `composer_run_decision_live_test.exs`.
- History beyond ten runs: it needs 12 runs of one draft (measured in phase 11 below);
  `runs_live_test.exs` and `composer_run_view_live_test.exs`.
- Uncertain effect review and reconcile: an uncertain effect can't be forced from a
  browser; `composer_run_pause_reconcile_live_test.exs` covers the review, its
  confirmation, one `:reconcile` command, a refused unknown uncertainty, and a frozen run
  that starts no owner.

A pause that has active work to finish ("Finishing active work before pausing") was not
seen in the browser, since the waiting run had none; the same test covers it with a held
runner. Of the breakdown's nine disproof observations, this walk measured four and saw
none of them: a rail reserving width, a 0 px canvas at 390, Tab leaving the Cancel dialog,
and a finished run rendering Resume. The other five were not measured here. A launcher
from a run submitting a stale version and "Running" beside a pending decision were
measured in phase 11 below; a missing history row and a value the sensitivity policy
excludes were measured in phases 11 and 12 below (this walk checked only that the server
log held no start value); and this phase recorded no command results.

## Composer redesign — final walk, phase 11, 2026-11-08

Fresh observations on port 4014 with headless Chrome through CDP, using a temporary driver
outside the repo: trusted mouse and key input (`Input.dispatchMouseEvent`,
`Input.dispatchKeyEvent`, `Input.insertText`), with device sizes set by
`Emulation.setDeviceMetricsOverride`. Two disposable drafts were made with
`Composer.create_draft/2` on the running node. `Walkthrough final phase 11`
(`bb8f0591-9ac4-4507-961c-18de9b0decdf`) was a copy of `Cracow house price review` with
`estimate_price / estimate` declared as `review`'s evidence. `Walkthrough final phase 11
sources` (`f0fc7a6a-5d3c-43ed-b6d0-56dde9cac2c1`) added an empty `report` stage after
`estimate_price`, so it has prior sources, an unbound input `note`, and later a removed
input that made it invalid. No existing draft was touched. Its first run,
`1fe03197-a5d7-4fc9-8a83-fff9ad11f251`, was started through the launcher. No page
exception or console error was seen, the server log had no `[error]` line, and it held
none of the typed values (`Krowodrza`, `Podgórze`, `Kazimierz`, `Atlantis`).

| Check | Fresh result |
|---|---|
| 1. Canvas widths, no panel open | Pass: on the draft, `#stage-canvas` was 1408 px at 1440x1000 (97.8% of the width), 992 px at 1024x768 and 374 px at 390x844. No `#left-rail` or `#right-rail` existed, and `scrollWidth` equalled `innerWidth` at each size |
| 1. Fit · N% and its actions | Pass: on `estimate_price` at 1440x1000 the label read "Fit · 100%" at a true scale of 0.853. Actual size gave scale 1 and "Fit · 117%"; Fit stage brought back the same transform and "Fit · 100%". At 1024x768 the fit was 0.576 and Actual size read "Fit · 174%". Fit selection on `estimate` panned to it and kept the fit's scale. The workflow's control read "Fit workflow" |
| 1. Panels keep pan and zoom | Pass: opening and closing the outline, and selecting `estimate_price` (not under the inspector), left `#stage-world`'s transform unchanged. Selecting `review`, whose card the inspector would cover, moved the view only until the card's right edge (1028 px) met the inspector's left edge (1028 px) |
| 1. Canvas only by keyboard | Pass: with `#canvas-only` focused, Enter set `data-canvas-only` (canvas still 1408 px) and moved focus to `#exit-canvas-only`; Escape left it, with focus back on `#canvas-only` |
| 1. Tools and Connect to at 390x844 (step 2) | Pass: with `normalize` selected (surface `details`), `#open-tools` switched the workspace to `canvas` and showed `#composer-tools`. On the `report` stage, the Steps surface's `#prior-area_model-connect` switched to `canvas` and showed `#connect-to`. The canvas stayed 374 px and `scrollWidth` equalled `innerWidth` |
| 1. Pinning and its gap (step 3) | Pass: at 1440x1000, `#pin-inspector` docked the 384 px inspector (`aria-pressed` true), the canvas went from 1408 to 1012 px, the transform was unchanged and 14 wire paths were drawn. At 1028x768 (996 px workspace) it stayed docked with the canvas at exactly 600 px. At 1024x768 (992 px) it floated, with `aria-pressed` false, and pressing it showed "Not enough room to pin: the canvas needs at least 600 px." and kept the stored pin, which docked again back at 1440x1000. This walk first found that press dropping the stored pin silently; the hook now acts on the dock it reports (a `canvas_hook.test.js` case) |
| 2. New run from a workflow-list row | Pass: `#new-run-<draft>` on `/composer` opened the draft with `#launcher-panel` showing `#start-form` |
| 2. New run from the draft header | Pass: `#start-run` ("New run") opened the launcher with "Starts a separate run from the current saved draft." and the canvas still 1408 px |
| 2. Hidden with runs off | Not walked: the dev server runs with `composer_runs_enabled` true. Rests on `composer_run_new_run_live_test.exs` and `runs_live_test.exs` |
| 3. "Stopping active work and saving checkpoint" | Not walked: a Cracow run has no active work once it waits, and the held runners are test-only. Rests on `composer_run_stop_resume_live_test.exs` |
| 3. Double-click on Stop | Pass: a trusted double-click on `#stop-run` of the waiting run led to "Stopped. Resume run continues it from its checkpoint", with `#resume-run` the filled button and no `#stop-run`. Core's history held one `stop` operation (`op-16`: accepted, `stopping`, `stopped`, completed). `#resume-run` brought back "Waiting for your decision on review" under the same run id |
| 3. Finished run renders no Resume (disproof) | Pass: after Accept the run read "Finished", outcome `succeeded`, and of `#stop-run`, `#resume-run`, `#cancel-run`, `#run-more`, `#pause-run` only `#new-run` was present. The failed run below showed only `#view-failed-step` and `#new-run` |
| 3. No "Running" beside a pending decision (disproof) | Pass: the waiting run read "Waiting for your decision on review" beside `#run-pending-link-review` ("Answer review"), and no header text started with "Running" |
| 4. Descriptions, Required to run, defaults | Pass: each field showed its type, description and "Required to run A step reads it"; `floor` added "Default: 1" with the placeholder "Leave blank for the default", and `balcony` a Default/true/false select with "Default: false" |
| 4. Effects review and Back to inputs | Pass: Start run listed the five `estimate_price` nodes, each with its runner, and focused `#confirm-start`; `#back-to-inputs` brought back rooms `3`, bathrooms `1`, area `58.5`, district `Krowodrza` |
| 4. A conflicting draft keeps the launcher open | Pass: on the waiting run, the launcher was filled, the draft was saved elsewhere (lock version 4 to 5), and the confirmed start showed `#launcher-draft-changed` with the launcher open, the URL still on the old run and every typed value kept. The next start went through |
| 4. An invalid draft keeps the launcher open | Pass: on the sources draft, after `year_built` was removed so a step read nothing, the confirmed start showed "The saved draft has 1 issue to fix before it can run." with Fix in editor, no run started, and the typed values were kept |
| 4. Save a set and start it | Pass, in three clicks: from the run page, `#new-run` then `#input-set-start-<id>` reached the effect review after two clicks, and `#confirm-start` started the run with `input_set_id` and `source_run_id` set. Cracow always has an effect review; the two-click case rests on `composer_launcher_live_test.exs` |
| 4. Enter in the set name (step 4) | Pass: typing "Sample flat" into `#save-input-set-name` and pressing Enter showed "Saved as Sample flat.", left the URL unchanged, opened no effect review and kept every typed value |
| 4. Drift blocks Start | Pass: a set saved with `note` as a String, then `note` retyped to Integer, showed "note changed type, so its value is left out." with `#submit-start` disabled until `#ack-drift`. The drift after a conflict rests on `composer_launcher_live_test.exs` |
| 5. Results opens and expands rows | Pass: `#open-results` showed `#results-panel` with the five `estimate_price` rows; expanding `normalize` set `aria-expanded` true and showed its output |
| 5. Results at 390x844 (step 6) | Pass: `#surface-results` made `results` the one surface with `#results-panel` shown, the canvas 374 px underneath, and `scrollWidth` 390 = `innerWidth` |
| 5. Decision evidence beside the choices | Pass: with `review` selected, `#decision-form-review #decision-evidence` showed the estimate's output labelled "Generation 0", and "Generation 1" after a revise |
| 5. A page reload executes nothing | Pass: reloading the browser page of the run after reading results left Core's history at 5 admitted attempts |
| 5. Reload result executes nothing | Not walked: no Reload result button was offered, since every read had a result, and a lagging or unavailable read can't be forced from a browser. Rests on `composer_run_results_live_test.exs`, which presses `#reload-run-record` and finds the fold's attempts unchanged |
| 5. View failed step | Pass: a run started with district `Atlantis` read "Failed at normalize"; `#view-failed-step` patched to `stages/estimate_price?...&node=normalize` with `invalid_input` shown, and `#new-run` opened the launcher on the current draft |
| 5. Generation-limit refusal | Not walked: a Cracow run would need ten revises. Rests on `composer_run_decision_live_test.exs` and the refusal text test in `composer_run_stop_resume_live_test.exs` |
| 6. Scope label and controls | Pass: after a revise, the Steps panel offered `#generation-scope-latest` (pressed), `-0` and `-1`. Scope 0 on the stage patched `?scope=0` and the label read "Graph shows generation 0" |
| 6. Links keep the scope | Pass: from `estimate_price` at `?scope=0`, `#breadcrumb-workflow` went to the workflow with `scope=0` kept, and the stage's Open link went back with `scope=0` kept |
| 6. History hides the approval form | Pass: at `?node=review&scope=0`, with review pending at generation 1, no decide form showed; Latest brought it back and dropped `scope` from the URL |
| 6. node, gen and scope survive a refresh | Pass: loading `stages/estimate_price?...&node=estimate&gen=0&scope=1` selected `estimate`, pressed `#run-generation-0` and `#generation-scope-1`, and read "Showing estimate from generation 0; graph shows generation 1" |
| 7. History beyond ten runs | Pass: with the draft's second run left waiting and 19 newer runs finished, the Steps panel listed the waiting run first as "Needs you", then the newest as "Succeeded", and the header's `#latest-run-link` "Unfinished run" pointed to it. Before the sweep, runs not yet seen read "Needs a check", and a run answered on the node still read "Needs you" from its last summary |
| 7. `/composer/runs` paging and filters | Pass: 25 rows with Show older runs, which added the last 2 and went away; Status "Needs attention" patched `?status=attention` and left only the waiting run; `?draft=<id>` listed its 21 runs; at 390x844 `scrollWidth` equalled `innerWidth` |
| 7. Orphan route | Pass: after both drafts were deleted, `/composer/runs/<first run>` stayed on that path at 1440x1000 and 390x844 with "Finished", `#new-run` disabled beside "This workflow's draft was deleted", no `#back-to-draft`, the canvas 1408 and 374 px, and no horizontal overflow; `?draft=deleted` linked to it |
| 8. `CORE_CHANGES.md` lists gaps A–L | Pass, checked by reading: sections A to L each give evidence, a proposed contract, app behaviour until it ships and the phases relying on it |
| Disproof: a rail reserves width | Not seen: no rail element exists at any size, and the canvas fills the content box |
| Disproof: `#stage-canvas` is 0 px at 390 | Not seen: 374 px with every surface measured |
| Disproof: Tab leaves the Cancel dialog | Not seen: five Tab and five Shift+Tab presses alternated between `#confirm-cancel-run` and `#close-cancel-run`, inside `#cancel-run-focus`, with `#run-header` and `#workspace` inert. Escape closed it, kept `review` selected and returned focus to `#cancel-run` |
| Disproof: a launcher from a run submits a stale version | Not seen: the run started from the run page, after the conflict above, had a snapshot equal to the current saved draft (lock version 5) and `source_run_id` the old run, which stayed waiting |
| Disproof: a history row is missing after ten newer runs | Not seen: measured in row "7. History beyond ten runs" above. With the draft's second run left waiting and 19 newer runs finished, the Steps panel listed it first as "Needs you" and `#latest-run-link` pointed to it |
| Disproof: a UI path renders a value the sensitivity policy excludes | Not seen, measured in phase 12 (2026-11-08, port 4015, headless Chrome at 1440x1000) on a disposable Cracow copy with two extra inputs, `zq_path` (Path) and `zq_json` (Any). A set "Sens set" was saved with `zq_path` opted in as `/tmp/zqpath7781` and `zq_json` typed as `"zqjson4410"` and not opted in; the stored row held the path and not the JSON. In the view where they were typed, `outerHTML` held the path once, as the value of `#start_zq_path`, and the JSON only in the textarea's live value. Afterwards `outerHTML` held neither token on the fresh draft page, the fresh launcher, the launcher after `#input-set-use-<id>` (both inputs empty, with `#start-field-zq_path-reused`), the effects review, the run page before and after a reload, Results with every row expanded, the finished run, `/composer/runs` and `/composer/runs?draft=<id>`. The server log held neither token and no `[error]` line |
| Disproof: `mix precommit`, `mix test` or `make quality` fails | Seen once, not reproduced. In phase 12's final runs `mix precommit` exited 0 (credo found no issues, 864 tests passed, 5 excluded), `make quality` exited 0 (credo no issues, Dialyzer 0 errors) and `make test-js` passed 104 of 104. Of eight full `mix test` runs in phase 12, seven passed 864 of 864 and one failed 1 of 864; that failure's test and seed were not captured. In phase 13, six full runs (seeds 445963, 799270, 863908, 7891, 33888 and one more) each passed 865 of 865, and `mix test --repeat-until-failure 20` on `runs_live_test.exs`, `composer_run_stop_resume_live_test.exs`, `composer_run_cancel_live_test.exs`, `composer_run_pause_reconcile_live_test.exs`, `runs_test.exs` (the sweep tests) and `runs_postgres_test.exs` passed 92 of 92 in all 21 runs. The flaky test is unidentified |

Both drafts were deleted with `Composer.delete_draft/1` once their waiting runs were
answered, and `get_draft/1` then returned `:not_found` for each; their runs keep a nil
`draft_id`. No `Walkthrough` draft is left.

Limits: the walk was headless, so motion and `prefers-reduced-motion` were not watched,
and no physical mouse, trackpad or screen reader was tried. Focus moved to `#canvas-only`
by script before Enter, not by a run of Tab presses. The first three runs were started
through the page; 18 more, and the failed run, were started and answered on the server
node to reach more than ten newer runs, and one sweep was run there by hand rather than
waiting 30 seconds for the dev sweeper. The rows marked Not walked, and why:
- 2. Hidden with runs off: the dev server runs with `composer_runs_enabled` true;
  `composer_run_new_run_live_test.exs` and `runs_live_test.exs`.
- 3. "Stopping active work and saving checkpoint": a waiting Cracow run has no active
  work and the held runners are test-only; `composer_run_stop_resume_live_test.exs`.
- 5. Reload result executes nothing: every read had a result, and lag or an unavailable
  read can't be forced from a browser; `composer_run_results_live_test.exs`.
- 5. Generation-limit refusal: a Cracow run would need ten revises;
  `composer_run_decision_live_test.exs` and `composer_run_stop_resume_live_test.exs`.

Of the nine disproof rows above, seven were measured in this walk and none was seen: a
rail, a 0 px canvas, Tab leaving the Cancel dialog, a stale launcher version, Resume on a
finished run, "Running" beside a pending decision, and, through row 7, a missing history
row. The sensitivity row was measured in the browser in phase 12 and not seen. The
command row records phase 12's runs, including one `mix test` failure that was not
reproduced.

## Honest stage status and Tools on a phone — phase 12, 2026-11-08

Fresh observations on port 4015 with headless Chrome through CDP and a temporary driver
outside the repo (trusted `Input.dispatchMouseEvent` and `Input.insertText`, sizes set by
`Emulation.setDeviceMetricsOverride`). Three disposable drafts were made with
`Composer.create_draft/2`: the sensitivity copy used in the phase 11 table above, and
`Walkthrough phase 12 tools`, whose stage `second` has `worktree_directory` (Git
Worktree) and `trust_mise` (Any) both reading `main`'s `resolve_worktree`, and
`Walkthrough phase 12 issue`, the same with `trust_mise` waiting on a missing `ghost`. No
existing draft was touched. No page exception or console error was seen.

| Check | Fresh result |
|---|---|
| Clear with warnings at 390x844 | Pass: on `second` with `worktree_directory` selected (surface `details`, inspector shown), its Clear on `worktree` switched `#workspace` to `canvas`, showed `#composer-tools` with `#clear-preview` and its Any warning, and focused `#cancel-clear-input`. The canvas stayed 374 px and `scrollWidth` 390 = `innerWidth` |
| Clear with warnings at 1440x1000 and 1024x768 | Pass: `#clear-preview` showed with the inspector still open beside it; the canvas stayed 1408 and 992 px with no horizontal overflow |
| Issue focus into Tools at 390x844 | Pass: Tools was open, so `#workspace` was already on `canvas`, when its issue "trust_mise waits on ghost, which does not exist in this stage." was pressed; the surface stayed `canvas` rather than flipping to `details`, `#composer-tools` stayed shown and focus went to `#rel-after-trust_mise-ghost`. A start from surface `details` was not seen in the browser. That before-fix behaviour, where the surface stayed `details`, which hides Tools below 768 px, rests on `composer_workspace_live_test.exs` failing before the fix |
| A stage at a scope with an interrupted node | Not walked: a stopped Cracow run has no active work, so no node is left interrupted, and the held runners are test-only. Rests on `run_view_test.exs`. A started stage whose nodes that ran include an uncertain, interrupted, cancelled, unknown or failed one reads the worst of those, even while another node still runs; phase 13 added the interrupted+running, cancelled+running, unknown+running and uncertain+running cases, and the first three read `running` before its fix. A started stage reads running only when every node that ran succeeded or still runs, or none ran yet |

The sensitivity draft's run was answered to `succeeded`, and the three drafts were
deleted with `Composer.delete_draft/1`; `get_draft/1` then returned `:not_found` for each
and no input set was left. No `Walkthrough` draft is left.

Limits: the walk was headless, so motion was not watched, and no physical mouse or screen
reader was tried. The issue was reached by opening Tools and pressing its row, the way a
person does; the row's `select_node` push is what switches the surface. The one Not
walked row is the scoped stage status, for the reason in its row.

## Seed names — 2026-11-08

No browser check was run for this note. The seeds now use the names of Core's renamed notebooks,
so earlier results above are historical: they name what was walked then. `create_worktree`'s
stages `inspect`, `create`, `sync` and `finalize` are now `inspect_worktree`,
`create_missing_worktree`, `sync_worktree_folders` and `finish_worktree_setup`, and decision
`route` is `choose_create_or_use_worktree`, whose choices `create` and `existing` are
`create_missing_worktree` and `use_existing_worktree`. Its nodes `worktree_name`, `resolve`,
`result`, `mise`, `trust` and `mise_current` are `derive_worktree_name`, `look_up_worktree`,
`describe_synced_worktree`, `detect_mise`, `trust_mise_config` and `read_mise_versions`.
`cracow_prices`' and `cracow_review`'s nodes `normalize` and `estimate` are `normalize_listing`
and `join_price_terms`.

Seeds keep a draft that already exists, so a draft saved before this keeps the old names, and
its decider returns choice names the decision no longer has. Delete that draft and seed again.
