# Core changes the composer needs

The composer runs workflows through Domovoy Core (`deps/domovoy_core`, 0.3.4), which this
repository does not edit. Each section below is one engine contract the composer lacks.
Until Core ships it, the app works around the gap or shows the feature as unavailable with
a reason, never with a guess.

Each gap names the code that shows it, the contract that would close it, what the app does
meanwhile, and the composer phase that relies on it.

## A. Run inputs per generation, with their provenance

**Evidence**
`DomovoyCore.Run.Owner.Control` builds the public view without the run's inputs
(`deps/domovoy_core/lib/domovoy_core/run/owner/control.ex:92-110`), so the app can't say
which values a generation ran with, or whether each was typed or a default.

**Proposed contract**
A bounded read of a run's inputs for one generation, each value tagged `:explicit` or
`:default`, with sensitive types redacted by Core.

**App behaviour until it ships**
The run page lists the snapshot's input definitions, not their values. New run opens the
launcher on the current saved draft with blank or default fields, and fills only what the
app stored itself in a saved input set; an opt-in sensitive value is named, never shown.

**Relied on by phase**
3 (New run), 5 (saved input sets).

## B. A structured diagnostic for `invalid_input`

**Evidence**
Preparation returns the changeset's raw `errors` as the reason
(`deps/domovoy_core/lib/domovoy_core/engine/preparation.ex:136`), and the inputs check
returns a free-form map (`deps/domovoy_core/lib/domovoy_core/inputs.ex:299-302`). Neither is
safe to render.

**Proposed contract**
An allowlisted diagnostic: `%{field: name, cause: atom}` with a fixed set of causes, and no
value in it.

**App behaviour until it ships**
The launcher marks the refused field with a fixed sentence ("Core refused this value. Check
it and try again.") and never renders the reason.

**Relied on by phase**
5 (launcher upgrade), 6 (failure paths).

## C. Input provenance per attempt

**Evidence**
Attempt facts (`attempt_admitted`, `attempt_settled`) carry no record of where each input
field came from (`deps/domovoy_core/lib/domovoy_core/events/envelope.ex:55-56`).

**Proposed contract**
Each admitted attempt names, per input field, its source: a workflow input, an upstream
node's output at a generation, or a literal.

**App behaviour until it ships**
The inspector lists a node's input sources from the run's snapshot, under "Input sources,
from the definition", not as observed; a literal's value is left out.

**Relied on by phase**
6 (results workspace).

## D. A bounded read of a decision's accepted inputs

**Evidence**
`decision_accepted` carries only `occurrence`, `choice`, `generation` and `cursor`
(`deps/domovoy_core/lib/domovoy_core/events/envelope.ex:61`), not the inputs a rerun choice
was answered with.

**Proposed contract**
A read of the accepted decision's inputs, bounded in size, with sensitive types redacted.

**App behaviour until it ships**
The decision outcome names the choice only; the inputs a rerun was answered with aren't
shown anywhere.

**Relied on by phase**
6 (decision evidence).

## E. An exact-attempt result read

**Evidence**
The store reads a node's newest attempt at a generation
(`ORDER BY attempt DESC LIMIT 1`, `deps/domovoy_core/lib/domovoy_core/store/postgres.ex:244-251`);
an earlier attempt's result can't be read.

**Proposed contract**
`get(node, generation, attempt)` returning that attempt's stored result, or a typed
`:not_stored` / `:not_found`.

**App behaviour until it ships**
Only the latest attempt's output at a generation is shown; earlier attempts list their
status and timing without output.

**Relied on by phase**
6 (results workspace).

## F. The effective `max_generations`

**Evidence**
The rerun limit is only visible in the error raised when it's exceeded
(`deps/domovoy_core/lib/domovoy_core/error.ex:1277-1281`).

**Proposed contract**
The run's view carries `max_generations` and the generation it's at.

**App behaviour until it ships**
The app shows the generations a run has reached, and the limit only after a `rerun_limit`
refusal, which says the run can't create another generation and offers New run.

**Relied on by phase**
7 (generation scope).

## G. A bulk committed-status listing

**Evidence**
Core lists runs from projection records with no phase or outcome
(`deps/domovoy_core/lib/domovoy_core/store/postgres.ex:87-93`), so a status per run needs one
open per run.

**Proposed contract**
An optional, paged listing of `run_id`, `committed_phase`, `outcome` and `committed_seq`.

**App behaviour until it ships**
The app keeps its own run summary, written through on each re-read view, swept in bounded
batches and refreshed lazily for stale rows a page shows. A summary authorises nothing:
every command re-reads Core.

**Relied on by phase**
9 (run summaries and Runs view).

## H. Observed `phase` can lag `committed_phase`

**Evidence**
The view's `phase` comes from the live owner's observation and `committed_phase` from the
journal (`deps/domovoy_core/lib/domovoy_core/run/owner/control.ex:94-95`); they can disagree,
for example `running` beside `waiting` with a pending decision.

**Proposed contract**
Either one authoritative phase in the view, or a documented rule for which one a consumer
should show.

**App behaviour until it ships**
The app treats the committed phase as authoritative for its sentence and controls.

**Relied on by phase**
4 (trustworthy status).

## I. A resync snapshot rich enough to rebuild a fold

**Evidence**
`resync/1` returns the committed public view and a cursor
(`deps/domovoy_core/lib/domovoy_core/events.ex:345-357`), not the facts a consumer folded, so
occurrences and attempts behind the cursor are lost.

**Proposed contract**
A resync that also returns the open occurrences, attempt states and stage facts at the
cursor, or a guaranteed replay from a retained floor.

**App behaviour until it ships**
The app marks its fold stale ("Step badges may be out of date. Reload to refresh."), and
keeps answering decisions from `status.awaiting`.

**Relied on by phase**
4 (resync handling).

## J. `superseded_by_command_id` on `operation_completed`

**Evidence**
`operation_completed` says an operation ended but not which later command superseded it.

**Proposed contract**
`operation_completed` carries `superseded_by_command_id` when another command replaced it.

**App behaviour until it ships**
The app tracks its own command id for Stop, Resume, Pause, Unpause, Cancel and reconcile
against `pending_operation`, and drops its progress note once another id, or none, is
pending.

**Relied on by phase**
4 (Stop and Resume), 10 (Pause, Unpause and reconcile).

## K. A public, versioned transition matrix

**Evidence**
`DomovoyCore.Run.Transition` is `@moduledoc false` and every function is `@doc false`
(`deps/domovoy_core/lib/domovoy_core/run/transition.ex:2`, `:299-305`).

**Proposed contract**
A documented, versioned matrix of which command each phase accepts.

**App behaviour until it ships**
`Domovoy.Composer.RunView.controls/1` mirrors the matrix for Stop, Resume, Cancel, Pause
and Unpause, pinned by a contract test against Core's private data; Unpause on a
`pause_timeout` block and reconcile on an `effect_uncertain` block have their own tests.

**Relied on by phase**
4 (controls), 10 (Pause and Unpause).

## L. A reconcile evidence schema

**Evidence**
The reducer accepts any map as reconcile evidence
(`deps/domovoy_core/lib/domovoy_core/run/reducer.ex:1332-1351`).

**Proposed contract**
A documented evidence shape, with the fields Core validates and keeps.

**App behaviour until it ships**
The app offers one action only, "Checked: safe to retry", behind a confirmation, and sends
the fixed, value-free evidence `%{"kind" => "operator_checked", "action" => "retry"}`.
Because Core reads nothing in the evidence, the app can't record that an effect did happen
and must not be retried: there is no "Mark succeeded" and no blind retry, so such a run can
only be stopped or cancelled.

**Relied on by phase**
10 (reconcile).
