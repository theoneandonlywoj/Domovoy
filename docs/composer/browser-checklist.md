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
`23-draft-list`. `14` and `20` onward show the dark theme; the rest predate it.
