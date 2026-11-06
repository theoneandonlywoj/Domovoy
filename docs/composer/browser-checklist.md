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

## Screenshots

In `screenshots/`: `02-mid-drag`, `04-preview`, `05-hover-refused`, `06-rejection`,
`07-hover-fits`, `09-picker`, `10-after-hover`, `12-confirm-literal`, `13-hyphens`,
`14-workflow`, `15-stage-walked`, `20-home`, `21-stage-mid-connect`, `22-dialog`,
`23-draft-list`, `34-cracow-stage-source-nodes`. `14` and `20` onward show the dark theme; the
rest predate it.

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
