# Composer UI research and improvement plan

Research and browser walkthrough: 7 November 2026. Final validation: 8 November 2026. Repository baseline: `7fea18d`. Scope: the composer, workflow launch, run controls, decisions, results, errors, generations, and run history.

Reading guide: [recommendations](#1-recommended-direction), [current capabilities](#3-current-functionality-what-users-can-actually-do), [findings](#4-findings-and-their-user-impact), [external research](#5-external-research-patterns-worth-adapting), [canvas design](#6-proposed-workspace-maximize-useful-node-space), [new runs](#7-make-new-runs-easy), [run controls](#8-run-controls-and-state-communication), [results and generations](#9-results-decisions-and-generation-history), [implementation phases](#13-engineering-plan-and-dependencies), [validation](#14-validation-plan-and-measurable-outcomes).

## 1. Recommended direction

Make Composer a **canvas-first workspace with an always-available New run action**. Keep workflow editing, operating a run, and inspecting its history clearly distinguishable within that workspace. Let panels appear when needed, rather than reserving most of the screen for them.

The two primary goals are:

1. **See and navigate more nodes at a readable size.** The user's additional requirement to maximize node space is a primary design constraint, not a later fullscreen enhancement.
2. **Run a workflow again with very little effort.** Starting another run should be available from the workflow list, draft, active run, and completed run, without reconstructing the same inputs or losing the run being inspected.

The highest-value changes, in order of product importance:

| Priority | Recommendation | Why it matters |
| --- | --- | --- |
| P0 | Remove permanent left/right rails from the default canvas layout; add canvas-only mode and responsive inspectors | The current rails consume 688 px before gaps. At a 1024 px viewport, the selected-node draft canvas measured only 272 px wide; at 390 px it measured zero. |
| P0 | Add New run to run pages and a shared launch surface | Currently a completed run ends in a Back to draft dead end for someone who wants to run again. |
| P0 | Implement Stop and Resume through the existing engine capabilities | Current messages instruct users to press Resume, but Composer has no such control. Cancel is terminal and cannot substitute for Stop. |
| P0 | Fix contradictory live status and cancellation-dialog focus containment | Both were observed in the fresh browser walkthrough. Clear controls depend on trustworthy state and focus. |
| P1 | Make reusable input sets, required fields, defaults, and launch source explicit | The launch form is blank on every new run, uses technical labels, and omits helpful input descriptions already present elsewhere. |
| P1 | Provide Results and Review surfaces that can use the full workspace | Users should not have to inspect a small node, read narrow JSON, remember it, then navigate back to approve it. |
| P1 | Expose useful run history and distinguish runs, generations, and attempts | Timestamp-plus-ID links and unexplained Gen buttons make investigation and comparison unnecessarily difficult. |
| P2 | Add richer comparison, artifact handling, and advanced operational controls | These need deliberate data contracts, not just more buttons. |

Preserve the existing strengths: immutable run snapshots, guarded read-only run pages, stable start IDs, asynchronous opening and result reads, typed errors, bounded output previews, explicit cancellation confirmation, and event-based attempt tracking. The redesign should make those guarantees understandable while removing navigation overhead.

## 2. Research method and confidence

### Evidence collected

- Read the LiveView, composer components, canvas hooks, run gateway, input parser, result renderer, run projection, examples, and relevant tests.
- Read the checked-out Domovoy Core 0.3.4 command matrix and run lifecycle documentation. This matters because the engine supports more operations than Composer exposes.
- Inspected the live application served by this worktree at `localhost:4444`, using an isolated headless Chrome session and trusted pointer/keyboard events.
- Examined the draft list, workflow graph, stage graph, launch form, decision screen, successful run, cancelled run, failed run, node output, and generation selection.
- Measured draft layout at 1440×1000, 1024×768, and an emulated 390×844 viewport.
- Created a disposable copy of the calculation-only Cracow review example. Exercised three runs: a successful run with generations 0 and 1, a cancellation while awaiting review, and a runtime validation failure. Existing user drafts were not edited.
- Consulted official workflow-product documentation, Nielsen Norman Group guidance, GOV.UK Design System guidance, and W3C accessibility guidance. Sources and their specific implications appear below.

### What is established, and what is not

**Browser-observed** means seen during this review. **Code-confirmed** means the implementation or engine contract establishes the behavior. **Recommendation** means a proposed design; usability benefits and timings still require validation with users.

Stop, Resume, Pause, and reconciliation could not be exercised through Composer because those controls do not exist. Their semantics were established from the pinned Core source and existing tests. Recovery, projection lag, unavailable runners, and storage-policy behavior were reviewed in code/tests, not deliberately induced in the running development application.

The contradictory Running/awaiting-decision display was observed once, remained after the driver's 12-second wait expired, and corrected on reload. This is a concrete symptom, not proof of a specific race or its frequency. Do not treat every waiting run as affected.

The browser walkthrough was not a screen-reader audit, a physical touch-device test, a contrast certification, or a study with representative users. Existing results in `docs/composer/browser-checklist.md` are historical evidence, not checks rerun by this report.

Temporary browser evidence is recorded in `/private/tmp/composer-ui-observations.json` and `/private/tmp/composer-ui-*.png`. The findings below are self-contained because temporary files are not a durable documentation dependency.

### Implementation evidence map

Paths and line numbers refer to the baseline above; line numbers will move during implementation.

| Area | Primary evidence |
| --- | --- |
| Draft list, creation, deletion | `lib/domovoy_web/live/workflows_live.ex:1` |
| Draft/run routing and fixed panel layout | `lib/domovoy_web/live/composer_live.ex:60`, `:135` |
| Draft toolbar and Start entry point | `lib/domovoy_web/components/composer_components.ex:59` |
| Launch form and effects confirmation | `lib/domovoy_web/components/composer_run_components.ex:37`, `:176` |
| Run toolbar and notices | `lib/domovoy_web/components/composer_run_components.ex:219` |
| Cancel dialog | `lib/domovoy_web/components/composer_run_components.ex:373` |
| Permanent run panels | `lib/domovoy_web/components/composer_run_components.ex:428` |
| Node results, attempts, generations | `lib/domovoy_web/components/composer_run_components.ex:622` |
| Decisions | `lib/domovoy_web/components/composer_run_components.ex:887` |
| Recent history and status wording | `lib/domovoy_web/components/composer_run_components.ex:1007`, `:1059` |
| Run event allowlist, subscriptions, result selection, launch | `lib/domovoy_web/live/composer_live/run_events.ex:1`, `:416`, `:492`, `:612` |
| Run lifecycle gateway and history queries | `lib/domovoy/composer/runs.ex:1`, `:273`, `:281`, `:508` |
| Status and generation projection | `lib/domovoy/composer/run_view.ex:1`, `:208`, `:278` |
| Inputs, missing/bound values, effect classification | `lib/domovoy/composer/run_inputs.ex:1` |
| Safe output/error rendering and 16 KiB limit | `lib/domovoy/composer/run_values.ex:1` |
| Canvas viewport and fit-relative zoom | `assets/js/composer/canvas_hook.js:113`, `assets/js/composer/viewport.js` |
| Core lifecycle and exact transition rules | `deps/domovoy_core/guides/learning/runs.md`, `deps/domovoy_core/guides/learning/run_owner.md`, `deps/domovoy_core/lib/domovoy_core/run/transition.ex:24` |
| Latest-attempt record read semantics | `deps/domovoy_core/lib/domovoy_core/store/postgres.ex:244` |

## 3. Current functionality: what users can actually do

### 3.1 Workflow authoring and launch

The `/composer` page lists drafts and supports creation and deletion. It presents itself as a place to compose definitions. It has no direct Run action per workflow and no status overview of recent executions.

The draft editor has workflow-level stage/decision cards and a stage-level node graph. Users can configure inputs, runners, bindings, ordering, validators, retries, and output storage; validate and export a definition; and undo edits within the current session. A header Start button opens the run form inside the 19 rem left rail, replacing its authoring contents. The graph remains visible.

The launch path is:

1. Open a draft or stage.
2. Press Start.
3. Enter workflow inputs in a narrow, alphabetically ordered form.
4. Press Start run.
5. If any runner is classified as non-pure, review a separate effects panel and press Start run again.
6. The gateway rereads and validates the draft, checks the draft lock version, snapshots the document, and starts the run.
7. The page patches to `?run=<id>` and displays the immutable snapshot.

Important details:

- The form supports text-like primitives, booleans, JSON, and paths. Some types cannot be entered and need a default or another supported route.
- A required **or bound** input without a default is required to launch. The editor can nevertheless label a bound input “optional,” because its schema flag and launch requirements are different concepts.
- Blank values mean use the default, omit the optional value, or report missing input. Whitespace-only strings also count as blank. There is no explicit launch mode for “send an empty string” versus “use default.”
- The run fields retain safe text after field errors, but an invalid workflow closes the launch form and opens Issues / Tools. The confirmation has Cancel but no Back to inputs action.
- Start IDs are stable for the life of the form, protecting against duplicate submissions and uncertain acknowledgements. This is a useful foundation, not a complete cross-reconnect launch-recovery contract.
- The host feature flag gates runs. It is enabled in development configuration and disabled by default; this is not yet a general authenticated production operations console.

### 3.2 Watching and navigating a run

Runs show live status, node/stage badges, travelled wires, a read-only graph, recent run links, input definitions, and a permanent summary inspector. Opening a run does not start an owner or execute workflow work. Changing between workflow and stage levels preserves the run ID.

The left Inputs section describes the inputs but **does not show the actual supplied values**. The application run row stores the workflow snapshot and identifiers, not a duplicate input payload or authoritative status.

Cards use the latest known attempts. Workflow-stage status is an aggregate of its nodes. The public run status separately exposes phase, outcome, availability, generation, pending operation, decisions, and uncertainties; only some of this information becomes useful UI.

On the live sample, the waiting run initially displayed Running in the header and phase field while simultaneously showing Answer review and a Needs you decision. Reload corrected the phase. A proposed live dashboard must handle this coherency issue before expanding its status displays.

### 3.3 Stop, pause, resume, cancel, and recover

| Operation | Engine meaning | Composer today |
| --- | --- | --- |
| Start a new run | New run identity and execution of a snapshotted definition | Supported from draft only |
| Stop | Interrupt active work, drain it, then commit a resumable stopped checkpoint | No gateway/UI action |
| Resume | Continue a stopped run through a resume barrier; preserve any underlying pause or decision wait | No gateway/UI action, despite Resume wording |
| Pause | Close admission, let current work drain, then hold | Status can render; no action |
| Unpause | Release a pause; not equivalent to resuming a stopped run | No action |
| Cancel | End permanently with a cancelled outcome after cleanup | Supported with confirmation |
| Recover | Explicitly activate an owner after process loss; recovery may block on uncertain effects | Supported for the UI's frozen-run condition |
| Reconcile | Supply evidence that retrying a particular uncertain effect is safe | Engine support; no Composer action |
| Answer a decision | Commit a choice and optional typed input changes; may continue, halt, or create another generation | Supported for human decisions |

Core's `activate` does not resume a paused or stopped run. A cancelled or failed terminal run cannot simply become running again. A decision whose target is `halt` can finish a stopped run immediately; a rerun choice on a stopped run is recorded but waits for Resume. Existing LiveView tests use Core directly to resume that scenario.

The current stopping message says it is waiting for the current step to end. Core's Stop semantics are more specific: work is interrupted and drained before the checkpoint commits. New wording must reflect that difference from Pause.

### 3.4 Results, errors, generations, and attempts

- Select a stage, enter it, then select a node to see a result. There is no workflow-level results landing view or designated primary result.
- A node result includes bounded JSON/text representation when supported, runner/version metadata, timing, input-source names, and attempt status.
- JSON previews are capped at 16,384 bytes, cut at a UTF-8 boundary. Binary output exposes size, not contents. Some values expose only a type name.
- Missing results distinguish not run, running, interrupted, not stored by policy, unavailable, and projection lag. However, lag and unavailable share “Loading the output” plus Try again.
- Try again in that result panel retries **reading** a result. It does not execute the node.
- Errors show the error type, retryability, and fixed text. Raw reasons/messages are intentionally excluded because they may contain input values or paths. The sampled `rooms = 0` run failed with `invalid_input` and “Retrying won't help,” but did not tell the operator which constraint to fix.
- Human decisions offer one form per choice. The review prompt and its action are not accompanied by the result being reviewed.
- A rerun decision creates a new generation within the same run. The sample kept both generation 0 and generation 1 outputs, and selecting them worked.
- Generation buttons appear only when the selected node has multiple generations. They change that node's detail, not the whole graph's status scope.
- Attempts are listed within a generation, but there is no attempt-result selector. The current public read returns the latest attempt for a node/generation. `at_least_seq` is a freshness barrier, not an “as of this attempt” query.
- Node retry policies can allow automatic additional attempts within a generation; this is distinct from a person's rerun decision. Core's default maximum generation is 10, and the Composer gateway does not currently override its run options. A generation limit is therefore another possible decision refusal that needs a useful explanation.
- Recent runs are the latest ten rows, displayed as minute-resolution timestamps and truncated IDs, without outcome or duration. The “Unfinished run” lookup searches that recent slice; an older unfinished run can be missed.

## 4. Findings and their user impact

### F1. Permanent panels make the graph compete for leftover space — critical

**Browser-observed and code-confirmed.** Draft and run layouts reserve 304 px on the left and 384 px on the right when the inspector is present, plus gaps. At 1440 px the run canvas has roughly 688 px; at 1024 px the selected draft canvas measured 272 px. In the 390 px draft inspection, the canvas measured zero and the inspector extended beyond the visible right edge.

The run view has a small-screen stacking rule; the draft view does not. Therefore the zero-width finding is specifically established for the selected-node draft layout, not all run layouts.

The stage graph also fits dense, verbose cards into the remaining space. In the sampled run, nodes were visible but their content was tiny while most of the left rail showed input descriptions. **Reduce permanent chrome and card density together.** A larger canvas alone will not solve unreadable cards in large graphs.

### F2. Launching again is a navigation task — high

**Browser-observed and code-confirmed.** From a result, users must return to the draft, open Start, enter inputs again, submit, and possibly confirm. A run page's event allowlist also blocks start events; a new header button alone cannot implement this feature.

There is no Run again, reusable input set, or source-run association. A completed run offers Back to draft but no next-run action. Optimize this entire journey, not just the label of Start.

### F3. The control vocabulary promises unavailable actions — critical

**Code-confirmed.** Stopped runs say Resume when ready, and decision copy refers to pressing Resume. The only lifecycle controls emitted by `RunView.controls/1` are Recover and Cancel.

Users may cancel work they intended to continue later, or need developer tooling to continue a legitimate stopped run. Stop/Resume must be treated as functional work with gateway, transition, and receipt handling.

### F4. Status can contradict the next required action — high

**Browser-observed once.** Running persisted while review awaited an answer, and reload corrected it. Inspect the relationship between observed owner phase, committed phase, event delivery, and rereads. `RunView.phase/1` prefers observed `phase` over `committed_phase`; this is a place to investigate, not a proven root cause.

Also review subscription resync: the current `resync_required` path replaces status/cursor without rebuilding the event-derived attempt fold. A stale or incomplete fold is a code-level risk to investigate separately; it was not reproduced in this walkthrough.

### F5. Launch fields hide the information needed to fill them — high

**Browser-observed and code-confirmed.** Input descriptions exist in the draft/run views but are not carried into `RunInputs.fields/1`. The start form presents labels such as `area (Examples Float)` without the square-metre explanation. Defaults are described as present, rather than visibly explained when safe. Required-to-run status is unclear.

The effect screen replaces the input form and offers no direct correction path. The header still says Start while the form already has Start run, weakening the action hierarchy.

### F6. Human review is disconnected from the evidence — high

**Browser-observed.** The sample asks “Accept this estimate?” while the right panel contains Accept and Revise, but no estimate. Users must navigate into a stage, select the result node, then return to the decision. They must remember which generation they inspected.

Decision review should put relevant results and the decision in the same view and explicitly identify the generation being approved.

### F7. Errors identify failure without providing a repair path — high

**Browser-observed.** The failed sample correctly identified `normalize`, but its detailed error was `invalid_input` plus a statement that retrying would not help. There was no direct launch-with-corrected-inputs action or field-level explanation.

Keep the protection against raw error reasons. Add structured, safe diagnostic information and actionable routes rather than dumping exception data into the inspector.

### F8. History is too weak for frequent execution — high

**Code-confirmed and browser-observed.** Three runs with different outcomes looked like timestamp/ID links; two shared the same displayed minute. The ten-row bound is also used for the unfinished-run shortcut. Operators cannot reliably answer “Which succeeded?”, “Which needs me?”, or “Which configuration produced that result?”

### F9. Generation scope is easy to misunderstand — high

**Code-confirmed and browser-observed.** Selecting Gen 0 shows its output while the graph still represents latest attempts. That can be useful, but the scope is not stated. A node's latest generation is also not necessarily the run's current generation. Some stages may not execute again in every generation.

Introduce explicit historical scope and provenance before adding comparison controls. Never imply that every node executed in the selected generation.

### F10. Cancellation's modal behavior is incomplete — high

**Browser-observed.** Focus initially went to Keep running, but successive Tab presses reached controls behind the alert dialog, including the stage selection/Open controls. `aria-modal="true"` does not itself trap focus or make the background inert.

Fix the dialog's mechanics and test with keyboard navigation. The same standard should apply to the new launch surface if it is modal.

### F11. The zoom percentage can suggest a readable native scale when it means fit — medium

**Code-confirmed and visible in screenshots.** Current 100% means 100% of the fitted view, not a one-to-one rendering scale. This is intentional in the hook. Consequently tiny cards can coexist with a 100% label.

Preserve the established fit-relative model unless a deliberate compatibility decision changes it. Clarify it with “Fit · 100%,” a tooltip explaining the scale, and a separate Actual size action. Rename ambiguous Reset to Fit workflow or Fit stage.

### F12. Effect warnings are conservative but insufficiently informative — medium

**Browser-observed and code-confirmed.** The mathematical Cracow example lists five potentially effectful runners because they do not declare purity. The current policy is conservative by design. It groups by runner type rather than the actual node instances and effects the user is authorizing.

Improve effect metadata and copy; verify truly pure examples and annotate them appropriately in a later implementation. Do not merely suppress a warning because a runner sounds harmless. The confirmation should identify affected steps and known consequences, and label unknown effects as unknown.

## 5. External research: patterns worth adapting

These are documented patterns, not proof that copying another product will improve Domovoy. The application-specific choices in the rest of this document are design recommendations derived from the local findings.

| Source | Relevant documented pattern | Application to Composer |
| --- | --- | --- |
| [AWS Step Functions execution details](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-view-execution-details.html) | Execution pages combine summary, graph/table views, step details, events, and a direct new-execution action. Selection is coordinated across views. | Keep New run reachable from a run; offer a compact step list alongside the graph; make an error lead directly to the affected step. |
| [AWS redrive semantics](https://docs.aws.amazon.com/step-functions/latest/dg/redrive-executions.html) | Redrive preserves successful work and the original definition; a changed definition requires a new execution. | State precisely what an action repeats and which definition it uses. Do not transplant AWS redrive behavior into Core without an engine contract. |
| [n8n execution history](https://docs.n8n.io/build/understand-workflows/understand-executions/view-all-executions.md) | Executions can be filtered; retry distinguishes the original workflow from the currently saved workflow. Retry may repeat partially completed work within the failed node. | Add useful history filters and explicit source selection. Explain replay scope and external effects, rather than presenting a generic Retry button. |
| [n8n execution debugging](https://docs.n8n.io/build/understand-workflows/understand-executions/debug-executions.md) | Saved execution data can be brought into the editor for investigation. | Provide an intentional Use inputs from this run path without silently overwriting the draft or changing the old run. |
| [Temporal cancellation/reset](https://docs.temporal.io/develop/go/workflows/cancellation) | Reset selects a history point, creates a new execution, and records a reason. | Keep recovery, checkpoint continuation, and new execution separate. Any future reset needs an explicit scope preview and lineage. |
| [GitHub Actions reruns](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs) | Rerun scope can be all jobs, failed jobs, or a specific job, with defined revision semantics. | Reserve labels for supported operations and display affected scope. Do not suggest Retry failed steps until Core actually supports that operation. |
| [NN/g usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/) | Feedback, familiar language, visible choices, error prevention, and efficient expert paths are foundational. | Explain run state and next action; make remembered inputs explicit; use named actions instead of internal engine vocabulary alone. |
| [NN/g progressive disclosure](https://www.nngroup.com/articles/progressive-disclosure/) | Frequently needed information belongs in the primary view; secondary complexity should remain discoverable. | Default to canvas plus a small status/action strip. Open catalog, configuration, metadata, and diagnostic details on demand. |
| [GOV.UK buttons](https://design-system.service.gov.uk/components/button/) | Action labels should state what happens, and multiple competing primary actions reduce clarity. | New run on drafts; Start run in the launcher; a prominent decision action when attention is required. Use lower emphasis for secondary actions. |
| [GOV.UK error summary](https://design-system.service.gov.uk/components/error-summary/) and [error messages](https://design-system.service.gov.uk/components/error-message/) | Summaries link to field errors; submitted values are retained; service failures are not presented as bad input. | Keep the launch form intact, link blockers to fields/nodes, and separate failed execution from unavailable status or output. |
| [W3C modal dialog pattern](https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/) | Modal focus stays inside; background content is inert; focus is deliberately placed and restored. | Repair Cancel and implement launch/review dialogs with complete behavior, not ARIA attributes alone. |
| [W3C dragging alternatives](https://www.w3.org/WAI/WCAG22/Understanding/dragging-movements) and [target size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum) | Dragging needs a single-pointer alternative; targets need adequate size or qualifying spacing. | Preserve connection forms and add accessible move/navigation alternatives. A tiny visible socket is not sufficient evidence of a usable target. |
| [W3C status messages](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html) | Important status changes should be available to assistive technology without taking focus. | Announce waiting, stopped, failed, and completed transitions; avoid reading every node event or continuously moving focus. |

The recurring useful pattern is separation between **configuration, live execution, and historical inspection**, with a clear bridge between them. Composer can adopt that separation without sacrificing its graph or introducing permanent dashboard panels.

## 6. Proposed workspace: maximize useful node space

### 6.1 A stable shell with two explicit modes

Keep a single workflow identity at the top. Provide Editor and Runs navigation, a run selector when applicable, one compact status area, and New run. Viewing a run displays a clear read-only snapshot indicator. Editing the current draft is an explicit action.

Suggested normal canvas arrangement:

```text
Workflow name / stage     [Editor | Runs]    Run / status     [New run] [⋯]
┌────┬──────────────────────────────────────────────────────────────────┐
│ +  │                                                                  │
│ ≡  │                         NODE CANVAS                              │
│ !  │                                                                  │
│ ↶  │        Inspector / Results appear only when requested             │
│    │                                                                  │
└────┴─────────────────────────────────────[Fit] [−] [zoom] [+] [Expand]─┘
```

The narrow tool strip has accessible names and tooltips: Add, Outline, Issues, and History where relevant. It is not another full sidebar. Keep infrequently used metadata, engine version, export, and detailed validation controls in a menu or context panel. Keep Undo available in the editor and discoverable through its existing shortcut.

In run mode, a concise strip can read “Awaiting review · Generation 1 · View result · Review.” Lifecycle controls belong beside it or in the run action menu. New run remains visible but can have secondary emphasis while an urgent review or recovery action is primary.

### 6.2 Space budgets and responsive behavior

These are **proposed acceptance targets**, not observed outcomes:

| Viewport/context | Default layout | Target |
| --- | --- | --- |
| 1440 px desktop | 16 px outer gutters, 40 px tool strip, 8 px gap; no open panel | Approximately 1360 px canvas width, versus roughly 688 px in the current run view |
| 1440 px canvas-only | Hide tool strip and optional status/detail areas; retain an exit and essential run state | Approximately 1408 px canvas width |
| 1024 px laptop | Same collapsed tools; panels overlay rather than force a third column | Approximately 944 px canvas width before optional overlays |
| Wide desktop with explicitly pinned inspector | Resizable 320–440 px inspector; catalog remains closed | Retain at least 600 px of unobscured canvas; otherwise revert to overlay |
| Narrow/mobile | One main surface at a time: Canvas, Steps, Results, or Review | No zero-width canvas, clipped primary actions, or body-level horizontal overflow |

Measure **unobscured canvas area**, not just the DOM rectangle: a full-width canvas hidden behind a 500 px overlay is not fully available to the user. Overlay panels are for temporary inspection; pinning is an explicit tradeoff. Do not silently open both a catalog and an inspector.

Use a compact header around 48–56 px on desktop and an optional short run-status row. On narrow screens, allow wrapping and readable text rather than enforcing a fixed height. The viewport should use available height predictably; panel content scrolls independently without trapping the page.

### 6.3 Panel behavior

- **Outline:** searchable stages/nodes and status filters; opens from a small button. Selecting an entry focuses that node without requiring dragging or zooming first.
- **Catalog:** opens only on Add, a connection action, or explicit search. Show compatible runners in that context. Close after insertion unless the user pins it.
- **Inspector:** selection highlights a node; an explicit Inspect action, double-click, or keyboard action opens details. Provide a preference for opening on selection, but avoid forcing it on users scanning many nodes.
- **Results:** offer a resizable panel and Expand results to use the workspace. Allow bottom docking as an option for wide text. Do not open bottom and side detail panels automatically at the same time.
- **Issues:** a badge with count opens a focused list. Clicking an issue reveals its target and relevant field, without opening unrelated tools.
- **Run history:** a popover/drawer for quick switching and a full Runs view for filtering. It should never occupy 304 px merely because a run is open.
- **Launch:** temporary, task-focused surface. Closing it returns to the exact view being inspected.

Remember panel preferences locally by workflow/mode, but never include input values or secrets in that preference storage. Keep draft graph coordinates separate from ephemeral run-view navigation.

### 6.4 Canvas interaction details

1. Add Fit workflow/stage, Fit selection, Actual size, Zoom in/out, and Canvas-only. Avoid a permanently visible minimap; make it an opt-in aid for large graphs.
2. Preserve pan and scale when a panel opens, closes, or receives a new result. Opening details must not refit the entire graph or move the selected node offscreen. If it becomes occluded, make a minimal reveal movement, not a global fit.
3. Maintain a viewport per draft/run snapshot and stage. Restore it when returning from history, results, or a decision. Reset deliberately with Fit.
4. Preserve the current fit-relative zoom semantics initially, but label them clearly. Add an Actual size action without redefining an existing 100% preference silently.
5. Add compact run cards: display name, state, and a small progress/attempt cue. Hide validator names, full type signatures, effect class, storage policy, and every input row until inspection. Editing can retain a more detailed card mode.
6. Consider semantic zoom: at small scales show title/status; reveal ports and configuration at readable scales. Keep accessible names and list navigation stable when details are visually hidden.
7. Add Focus active step and Focus failed step. “Follow execution” must be opt-in and suspend when the user pans or inspects history; live events must not wrestle the viewport away.
8. Keep run-view node placement read-only initially. Panning/zooming is enough to improve navigation. If temporary node rearrangement is later added, store it as view state, never as a write to the historical snapshot.
9. Test wires after every panel resize, zoom, and mode change. The current hook has geometry and resize machinery worth preserving.

## 7. Make new runs easy

### 7.1 Entry points and action budget

New run should be available on:

- Each workflow row, next to Open editor.
- The draft toolbar, at both workflow and stage levels.
- Every active, waiting, stopped, failed, cancelled, or successful run page.
- The Results view and run-history row menu.

The normal repeat flow should be **New run → adjust/review inputs → Start run**. Target two deliberate clicks for an unchanged approved input set, excluding text entry. A real external-effect review may add a step; optimize it by placing a meaningful summary in the launcher rather than repeating generic confirmations.

Starting a new run while another is active must be explicit: “Starts a separate run; the current run continues.” Do not invent a one-run-per-workflow restriction. Where known resource conflicts exist, show them as specific launch checks; do not infer arbitrary paths or external locks from UI state.

### 7.2 Launcher specification

Use a 480–560 px temporary drawer on desktop and a full-screen surface on narrow screens. For large structured inputs, let the launcher expand. Keep one sticky footer with Close and Start run, including pending state.

The launcher contains, in this order:

1. **Workflow and definition source.** Default: Current saved draft. If opened from an old run, explicitly say the old run is a snapshot and the new run will use the current draft. A future Run from this snapshot option is separate and needs backend support.
2. **Input source.** Defaults/new values initially; later Saved input set or From run … / generation …. Never silently copy the latest run or arbitrary generation.
3. **Essential fields.** Fields required to launch first, with human-readable labels, descriptions, units, and allowed choices where supported by metadata.
4. **Optional fields.** Compact disclosure with a summary of defaults and overrides. Do not conceal optional values that have been changed or have errors.
5. **Readiness and effect summary.** Show actionable blockers and relevant external changes, tied to the exact definition being launched.
6. **Start action.** State that it starts a new run. Show Starting immediately, prevent duplicate intent, and retain a way to inspect an uncertain start.

Field behavior:

- Distinguish Required to run from the schema's optional flag. Explain dependency-derived requirements in help text.
- Display safe defaults as values or explicit “Use workflow default” controls. Do not expose a potentially sensitive default simply because it is stored in the definition.
- Use explicit modes for Use default / Set value / Omit when semantically supported; distinguish blank, empty string, and null. This needs parser and data-contract work, not just placeholders.
- Use suitable numeric input hints, booleans, structured JSON assistance, and supported domain editors. Do not execute path validation or effectful type logic on every keystroke.
- Preserve all safe entered text on validation errors, draft conflicts, and returning from effect review. Show a linked error summary and focus the first relevant problem.
- If workflow validation fails, retain the launcher state while offering Fix in editor. Returning should restore the form and revalidate it against the updated definition.
- Provide short field examples from workflow metadata, not fabricated guesses about a runner's acceptable values.

### 7.3 Reusable inputs and explicit provenance

Introduce named input sets such as “Sample flat” or “Worktree setup defaults.” These are application metadata associated with a workflow definition/schema, not mutations of the old run.

Required design decisions:

- Record the input schema/version compatibility and validate again when the draft changes.
- Show added/removed/type-changed fields; never silently discard a changed field and launch.
- Store only fields explicitly eligible for reuse. Use a sensitivity policy with safe defaults; do not save every form field to localStorage.
- For input reuse from history, request a bounded, server-side projection of the selected run and generation. The current Composer row does not contain these values.
- Preserve whether a value was explicit, inherited, or defaulted. Historical resolved defaults and current draft defaults can differ.
- Unsupported or unavailable historical values should be clearly marked for re-entry. A partially recovered input set must not pretend to be complete.
- A shortcut labeled Run again must open this reviewable launch intent, not silently execute a stale snapshot with whatever values happen to be available.

A true one-click quick-run option can come later for validated, explicitly saved configurations whose effects are understood. It should be opt-in and should not become the default solution to repetitive confirmation fatigue.

### 7.4 Preserve launch correctness

Retain immutable snapshots and draft-version checks. Bind a launch intent to the exact definition version/fingerprint, input payload, effect acknowledgement, and stable IDs. If the user changes inputs after an attempt may have committed, create a new intent only after reconciling that attempt's outcome.

After acknowledgement loss, show “Checking whether this run started” with a link to the same run identity. Do not encourage a new UUID as the first recovery action. Persisting the intent across a reconnect requires an explicit design because current forms disable automatic recovery and the IDs live in the LiveView state.

“Run from current draft” is an incremental extension of the existing path. “Run from historical snapshot,” durable presets, and generation-specific input reuse are **new backend capabilities** and must not be represented as existing features.

A saved definition is not an archived executable environment. Starting from a historical snapshot still requires available, compatible runner contracts and currently installed code. Validate those contracts and disclose version differences; do not promise bit-for-bit reproducibility or the original runner binary merely because the definition is unchanged.

## 8. Run controls and state communication

### 8.1 Action semantics and wording

Use precise verbs:

| UI label | Meaning and explanatory copy |
| --- | --- |
| New run | Start a separate execution from the selected definition and inputs. |
| Stop run | Interrupt active work and save a checkpoint for later continuation. Work already performed outside the app is not undone. |
| Resume run | Continue this stopped run. If it was paused or awaiting a decision, that condition may still need attention. |
| Pause after active work | Allow active work to settle, then hold before dispatching more. Keep this advanced control secondary initially. |
| Continue paused run | Release the pause using Core's unpause command. |
| Cancel run | End this run permanently. A new run can be started, but this run cannot resume. |
| Recover run | Restore execution ownership after process loss. Recovery may require review of an uncertain external effect. |
| Reload result | Read stored output again; executes no workflow step. |
| Run another generation | Only a declared decision rerun action; creates a generation within this run. Prefer the workflow's meaningful choice label with this consequence explained. |

Do not put Cancel in the prominent position intended for temporary stopping. Keep it accessible as a secondary/destructive action with one focused confirmation. Stop needs immediate feedback and concise effect context; avoid a generic repeated confirmation on every reversible stop request unless a specific effect makes that necessary.

### 8.2 Proposed state/action matrix

This matrix describes presentation. Core's actual transition matrix remains authoritative for races and uncommon states.

| State | Primary next action | Other controls / message |
| --- | --- | --- |
| Opening | None pending | Show loading; allow navigation and starting a separate run when definition access is valid. |
| Starting / resuming | Show progress | Stop/Cancel as allowed; no duplicate transition button. |
| Running | Inspect progress/results | Stop; advanced Pause; secondary Cancel; New run remains available. |
| Awaiting human decision | Review decision | Stop/Cancel; review links show which occurrence/generation is pending. |
| Pausing | Show “Finishing active work before pausing” | Stop or Cancel can supersede where Core permits. |
| Paused | Continue paused run | Show scheduled unpause time if present; Stop/Cancel. |
| Stopping | Show “Stopping active work and saving checkpoint” | Cancel may supersede; Resume only after stopped is committed. |
| Stopped | Resume run | Pending decisions can still be answered according to Core semantics; Cancel remains secondary. |
| Frozen after process loss | Recover run | Explain that opening/reloading does not recover; do not silently activate on mount. |
| Blocked by uncertain effect | Review uncertainty | Explain the affected step and evidence required; Stop/Cancel where allowed. No blind retry. |
| Blocked for another reason | Cause-specific action | Pause timeout, unavailable prerequisites, and uncertainty require different explanations. |
| Cancelling / finishing | Show cleanup progress | Do not report terminal completion before its commit. |
| Finished: succeeded | View results / New run | No Resume. |
| Finished: failed | View error / New run with corrected inputs | No suggestion that Reload result or Recover reruns the failed workflow. |
| Finished: cancelled | New run | Preserve partial results and interruption history. |
| Unavailable / stale observation | Refresh status | Retain last known state with age; distinguish disconnection from failure. Recheck before commands. |
| Incompatible runner contract | Inspect snapshot / return to draft | Explain why this run cannot continue; do not offer ineffective Resume. |

### 8.3 Accepted is not completed

Extend the gateway to preserve command receipts and operation identity instead of reducing every accepted command to `:ok`. The UI should distinguish:

1. Sending request.
2. Request accepted; transition in progress.
3. Operation completed, superseded, failed, or still pending.

Use stable IDs for the same user intent. A timeout is not evidence of rollback; retry the same intent or read its receipt. Disable duplicate activation while pending, and surface typed refusals such as transition in progress in plain language. Revalidate decisions against their occurrence ID so two tabs cannot make a later occurrence appear answered by an old form.

Keep phase, outcome, and availability separate in the model. In the main UI, lead with a human-readable sentence. Move raw phase/availability codes into details unless they require action. “Temporarily unable to save progress” must not become “Workflow failed.”

### 8.4 Uncertain effects

Add a dedicated review only after a safe reconciliation API exists in Composer. Show affected node, generation/attempt, known effect classification, and a plain explanation of what is uncertain. The supported Core example accepts evidence that retry is safe; do not invent a Mark succeeded action or claim that an external operation has been reversed.

Distinguish recovery from reconciliation: recovery can reveal uncertainty; it cannot establish whether an external effect happened. This is an advanced state, but it needs a visible escape and next step rather than a generic Blocked badge.

## 9. Results, decisions, and generation history

### 9.1 Result-first inspection

Provide a Results action in the run header and on successful completion. It opens a full-width or expanded result workspace with a compact node list and optional graph context. The canvas-only state remains one action away.

Do not guess a single workflow output from alphabetical node order or the last event. Initially list stored node outputs grouped by stage. Later allow workflows to designate named outputs, such as “Estimate” or “Created worktree,” in the document schema. Validate those references when nodes change.

Support appropriate result presentations:

- Short scalar/text: readable text and Copy.
- JSON/map: collapsed structured tree, raw view, search, and clear size/truncation information.
- Tables: only when the structure actually supports tabular display; do not flatten away meaning.
- Binary/custom values: type, size, availability, and supported actions. Do not pretend the current API provides an artifact download.
- Large output: bounded preview and an explicit expansion/download path only after backend limits and disclosure behavior are designed.

Keep runner/version, input sources, timing, and technical metadata in secondary tabs or disclosures. Show missing versions as Unknown/not recorded; never substitute the currently installed runner version for the historical one.

### 9.2 Review workspace

Review should show:

1. Decision prompt, run identity, and generation.
2. Relevant result preview(s), with the node and generation attached.
3. Changes since the preceding generation when comparison is available.
4. Choice descriptions and consequences.
5. Only the inputs needed for the chosen action.

For the Cracow example, the proposed review shows the estimate next to Accept estimate and Revise estimate, with district changes below Revise. This needs an explicit decision-to-result reference in workflow metadata; the UI should not hardcode `estimate` or guess by node name.

While viewing an older generation, label it Historical. Decision submission must refer to the current pending occurrence, and the interface should require returning to its current evidence before presenting an approval action. Viewing history should never silently redirect an old approval form to a new occurrence.

After answering, preserve context and show a brief acknowledgement. If a rerun begins, show which stage will execute and which generation it creates. If the run is stopped, say that the answer is saved and execution waits for Resume. A halt choice needs copy stating that it finishes immediately, even while stopped.

### 9.3 Define the hierarchy explicitly

| Concept | Meaning | UI treatment |
| --- | --- | --- |
| Draft revision / definition snapshot | The workflow structure and configuration used for execution | Display Current draft or Run snapshot; compare changes explicitly. Layout-only edits should not imply semantic differences. |
| Run | An independent execution with a stable ID | Run selector/history row; New run creates another. |
| Generation | An iteration inside a run, created by a declared rerun decision | Label “Generation 0 · Initial” and later generations with their cause. |
| Attempt | A particular node execution attempt within a generation | Attempt list with timing/outcome; do not confuse with a new generation. |
| Decision occurrence | One specific asking of a decision | Bind form submission to the occurrence and its generation, not just the decision's name. |

Keep the engine's zero-based generation identity visible to avoid off-by-one confusion with events and APIs. A short explanation can say “A generation is another pass within this run.”

### 9.4 Historical scope and comparisons

Start with a node-level generation selector labeled “Showing estimate from generation 0; graph shows latest state.” That can be delivered before a full historical graph.

Then introduce a coordinated generation scope for graph, result list, decision history, and inspector. This requires a generation-aware projection. Distinguish:

- Executed in this generation.
- Not executed in this generation.
- An older value reused as input, with its originating generation.
- Skipped, cancelled, interrupted, or not reached.

Never paint an older successful attempt as proof that the node ran successfully in the selected generation. Likewise, resetting the whole graph to Not run would hide valid reuse provenance.

Provide comparison between two selected generations or runs, with definition/input differences before output differences. For JSON, highlight added/removed/changed fields. Missing, withheld, and truncated output must remain explicit; do not render them as an empty object or a zero-value difference. Compare complete compatible data or clearly label a preview-only comparison.

Attempt-level historical payloads need a new exact-attempt read contract. Although the Store persists attempt records, the current Composer/Core read selects the latest attempt. Passing an older sequence to `at_least_seq` cannot make an earlier attempt's result appear correctly.

## 10. Errors and recovery as usable product flows

Use an error model with category, affected node/field, safe message, available action, and optional technical code. Keep error messages fixed or derived from an allowlisted structured contract. Do not expose raw exceptions, shell output, credentials, or expanded paths as a shortcut to better diagnostics.

| Category | Main message/action | Technical notes |
| --- | --- | --- |
| Launch field error | “Enter an area of at least 15 m²,” when the validated metadata actually supplies that rule | Link to field, preserve text; do not invent the specific violated constraint from `invalid_input` alone. |
| Invalid definition | “Connect the required input on Normalize” with Go to node | Keep launch inputs while returning to editing. |
| Runtime input/validator failure | Explain safe field/rule context; New run with corrected inputs | Requires a structured safe diagnostic extension where existing errors are opaque. |
| Transient runner failure | State whether automatic attempts remain or are exhausted | Retryability is not permission to resume a terminal run. |
| Result projection lag | “The step finished; its stored result is still catching up” | Bounded automatic refresh plus Reload result; never redispatch work. |
| Output unavailable | “The result could not be loaded” | Distinguish service error from loading; retain last known run state. |
| Output not retained | “Output was not stored for this step” | Link to storage policy in the draft for future runs; cannot recover unavailable content by restyling. |
| Output too large | Explain the output limit and an actual remedy | Do not offer an unchanged retry when `canonical_too_large` is non-retryable. |
| Process loss | Explain Recover and potential uncertain effects | Opening history must remain read-only. |
| Conflicting/stale action | Explain what changed and refresh controls | Preserve typed input and source context where safe. |
| Generation limit reached | Explain that this run cannot create another generation under its current limit | Offer a new run; only offer changing limits if a configure feature is deliberately implemented. |

Provide a top-level error card with View failed step and New run. Use inline field errors for fixable input problems. Keep a safe diagnostic-copy action for IDs, state, node, generation, attempt, code, and version; label its contents and exclude payload values by default.

## 11. Useful run history without sacrificing canvas space

The quick run switcher should show status icon/text, start time, duration or elapsed time, optional user label, generation, and an attention indicator. Short ID is secondary. Show the timezone and provide the precise timestamp on inspection; current `Calendar.strftime` renders stored UTC timestamps without an explicit timezone label.

The full Runs view should support status, date, text/label, and needs-attention filters; stable sorting; pagination; and direct links to a run, node, and generation. Keep run comparison and saved input sets discoverable from here.

Do not populate status by opening and replaying every run during a page render. Introduce a bounded read projection with timestamps, outcome, pending decisions, generation, and freshness cursor. Core remains authoritative; stale summaries must be labelled and commands must consult current state. The existing async recent-run lookup is useful but does not solve an unbounded history view.

Replace the newest-ten unfinished scan with a query/index suitable for all unfinished runs. A run from yesterday must remain discoverable after ten newer runs. Include waiting, stopped, blocked, and uncertain/unavailable states according to an explicit attention policy.

Persist new-run lineage separately from generations: `source_run_id` and selected input-generation provenance, if implemented. Do not imply that every run started after another is its retry.

Decide what happens to history when a draft is deleted. Today its run row survives with `draft_id = nil`, while Composer routes first load the draft. That leaves retained history without the normal UI entry point. Prefer Archive workflow or a run route that can inspect its snapshot independently; document retention/deletion semantics before adding history cleanup actions.

## 12. Accessibility and visual refinement

Preserve the current dark palette and custom component identity where it helps. Reduce excessive nested shadows and rounded containers in dense operational views; use surface differences and restrained borders to establish hierarchy. The goal is readable nodes and clear actions, not a wholesale theme rewrite.

Recommended details:

- Use readable body text in panels; reserve small monospace text for IDs and code. Compact cards should still have readable titles at their intended inspection scale.
- Pair color with text/icon/shape for all run states. Retain existing reduced-motion handling, but ensure selection, focus, and failure do not look identical.
- Keep important help accessible on focus/tap. Native `title` tooltips alone are unsuitable for essential input or decision guidance.
- Use true modal focus containment for Cancel and modal launch/review surfaces; restore focus to the trigger. Non-modal inspectors must allow intentional movement back to the graph.
- Provide keyboard and single-pointer alternatives for drag operations. Do not assume keyboard support alone satisfies a non-dragging pointer requirement.
- Use at least the WCAG 24×24 CSS px target/spacing requirements where applicable, with larger practical targets for frequent toolbar actions. Evaluate transformed graph controls and equivalents rather than measuring only unscaled CSS boxes.
- Announce meaningful state changes through a restrained live region. Do not announce every event, every elapsed second, or every node badge update.
- Provide a normal Steps list for keyboard/screen-reader navigation and narrow screens. The two-dimensional graph can remain scrollable, while its surrounding controls and forms must reflow.
- Add shortcut help. Reuse existing Undo; proposed shortcuts for New run, search, and canvas-only must avoid text inputs, browser conflicts, and accidental execution. A shortcut should open the launcher, not run immediately.
- Use subtle 120–180 ms panel transitions as a design starting point, honoring reduced motion. Avoid pulsing every active node or animating graph rearrangement during execution.

The normative/accessibility basis is [WCAG 2.2](https://www.w3.org/TR/WCAG22/); the implementation patterns are the W3C sources in section 5. These recommendations are not a claim that the current application has passed or failed every criterion.

## 13. Engineering plan and dependencies

### Phase 1 — Canvas space and immediate navigation wins

**Outcome:** users can inspect a graph without permanent rails, at laptop and narrow sizes, and can reach a new-run setup from a run page.

**Work:**

- Introduce shared workspace panel state: outline/catalog/inspector/results, dock preference, and canvas-only mode.
- Remove mandatory left/right columns from the default layout. Add temporary overlays and optional pinning with minimum usable canvas width.
- Move history and input definitions out of the default run canvas. Keep the pending decision/status strip visible.
- Add New run entry points using the current-draft path; preserve return context. Initially input reuse can remain unavailable and honestly labelled.
- Add Fit selection and clarify Fit/Reset wording without silently changing zoom semantics.
- Correct modal focus containment while modifying workspace overlays.

**Likely files:** `composer_live.ex`, both composer component modules, `canvas_hook.js`, `viewport.js`, `keys.js`, `app.css`, `workflows_live.ex`.

**Acceptance:** default desktop canvas meets the space budgets; 390 px layout has no collapsed canvas or clipped launch control; closing an inspector restores usable canvas without changing saved coordinates; canvas-only can be exited by keyboard; wire endpoints remain aligned; New run from a run is reachable without an editor detour.

**Dependency note:** opening a launcher from run mode needs explicit, narrow permission in `RunEvents`; retain denial of all draft-edit events. A naïve reuse of the current `document` assign would launch the historical snapshot unintentionally, so source the current draft deliberately.

### Phase 2 — Trustworthy status, Stop, Resume, and command progress

**Outcome:** users can safely stop and continue work, and displayed state agrees with the action required.

**Work:**

- Reproduce/instrument the observed Running/decision mismatch with synthetic data and sequence-aware tests. Separate observed and committed state explicitly; fix the verified cause.
- Test the resync path's fold completeness; rebuild/replay relevant history or obtain a trustworthy snapshot before presenting old badges as current.
- Add gateway methods and facade delegates for Stop and Resume. Preserve receipts and operation completion tracking.
- Centralize capability/action presentation from current state and the engine transition matrix. Handle superseded operations and typed refusals.
- Correct stopping/paused/frozen/cancelled wording; show last-confirmed freshness when updates fail.
- Add optional Pause/Unpause only after Stop/Resume is clear, or deliver it in a later small phase.

**Likely files:** `composer/runs.ex`, `composer.ex`, `run_view.ex`, `run_events.ex`, `composer_run_components.ex`; relevant run tests. Core changes only if the reproduction demonstrates a missing Core guarantee.

**Acceptance:** stop interrupts and reaches a committed checkpoint; resume preserves the same run and appropriate generation; a stopped decision answer behaves correctly; cancelled/failed runs never offer Resume; duplicate clicks converge; accepted operations do not claim completion early; reconnect updates the UI without replaying execution.

### Phase 3 — A better launch form and reusable configurations

**Outcome:** common new runs require only choosing/reusing inputs, changing what matters, and starting.

**Work:**

- Add field descriptions, required-to-run status, safe default presentation, linked validation summary, and Back to inputs.
- Build a launch-intent model independent of the currently displayed run snapshot.
- Retain entered values through definition errors and conflicts, with explicit revalidation.
- Add saved input sets and generation-specific historical-input reuse through a bounded backend API and explicit sensitivity policy.
- Bind effects acknowledgement and source version to the launch intent; preserve idempotency through uncertain acknowledgements.
- Add original-snapshot launching only as a distinct, tested source path.

**Likely files:** `run_inputs.ex`, `run_events.ex`, run components, document metadata/schema modules, gateway and new preset/intent storage as needed. Generate any migrations with `mix ecto.gen.migration`.

**Acceptance:** common repeat-run path meets the two-click target after configuration; no retyping unchanged eligible fields; schema drift is explained; default/empty/omit semantics are tested; changed confirmation state cannot start a different definition; a reconnect cannot accidentally create two runs.

**Dependencies:** Phase 1 entry points and stable source selection. Snapshot launching and persistent reuse require backend work; do not block the simpler launcher improvement on them.

### Phase 4 — Results and decisions that support actual review

**Outcome:** users can find outputs, understand failures, and approve a result without remembering data from another screen.

**Work:**

- Add an expandable Results workspace and node-result navigation independent of graph positioning.
- Add typed output viewers with bounded previews and clear absent/loading/error states.
- Provide View failed step and New run with corrected inputs.
- Add safe structured diagnostic mappings; retain the exclusion of raw reasons.
- Introduce validated optional output declarations and decision-to-result references.
- Present decision evidence and choices together with generation provenance.

**Acceptance:** the Cracow estimate is visible alongside its approval; failure leads to the correct node in one action; output read retries execute no runner; nonstored/binary/truncated output is truthful; switching selections never shows an old async result under a new node.

### Phase 5 — Generations, attempts, and comparison

**Outcome:** users can tell what changed, what ran again, and which output belongs to which execution context.

**Work:**

- First label the existing node-level generation scope accurately.
- Add generation-aware history/projection and a coordinated historical view.
- Add generation/run comparisons with input and definition provenance.
- Extend exact-attempt result reads before exposing historical attempt payload selection.
- Preserve selection and view mode in URLs and browser navigation; avoid unbounded URL data.

**Acceptance:** graph and detail agree on scope; reused earlier values are labelled; historical review cannot answer a newer occurrence; comparison distinguishes missing/withheld/truncated data; refresh restores a linked node/generation; exact-attempt selection cannot return a newer attempt silently.

### Phase 6 — Run history, attention queue, and retention

**Outcome:** frequent users can find any relevant run without leaving a history rail open on the canvas.

**Work:**

- Add a status-aware run switcher and full Runs view with filters and pagination.
- Build a bounded summary projection with cursor/freshness tracking and a rebuild strategy.
- Replace the latest-ten unfinished lookup with reliable unfinished-run discovery.
- Show start/end/duration, timezone, generation, labels, and source-run lineage where available.
- Define archived/deleted workflow history access and retention.

**Acceptance:** an unfinished run remains reachable after more than ten new runs; 100+ history items do not require replaying every run on navigation; summaries converge after reconnect; stale summaries never authorize commands; orphaned retained runs have a deliberate inspection path.

### Phase 7 — Advanced operational recovery and polish

**Outcome:** blocked and recovered runs have a complete operator journey, and the interaction model works beyond the happy path.

**Work:**

- Add uncertainty review and supported evidence-backed reconciliation.
- Add any remaining Pause/timed-pause controls with explicit semantics.
- Consider artifact export, optional minimap, semantic zoom, and configurable result layouts based on measured need.
- Complete keyboard, screen-reader, high-contrast, reduced-motion, narrow-screen, and performance checks.

**Acceptance:** no blind retry of an uncertain effect; no unsupported “mark succeeded” path; recovery preserves history; advanced controls do not crowd the default canvas; real users complete the core scenarios below without assistance.

### Suggested first implementation slice

Ship **collapsed panels + canvas-only mode + New run from run pages + cancellation focus fix** as the first visible slice. Follow immediately with **status coherency and Stop/Resume**. These changes directly satisfy the user's two priorities and remove the most misleading operational behavior. Do not postpone them behind a complete history database redesign or visual theme replacement.

## 14. Validation plan and measurable outcomes

### Core task scenarios

| Scenario | Success criteria |
| --- | --- |
| Launch a workflow for the first time | User identifies required values and starts without opening unrelated configuration panels. |
| Run it again with one changed input | New run is visible from results; unchanged eligible inputs need no retyping; source definition is clear. |
| Inspect a 30–50-node graph on a laptop | Nodes remain navigable/readable; panels can be dismissed; canvas-only works; no forced refit on each selection. |
| Stop and return later | User chooses Stop rather than Cancel; reload shows the stopped run; Resume continues the same run. |
| Review and create another generation | User sees the result, knows the generation, and understands which stage repeats. |
| Inspect generation 0 while generation 1 exists | Historical state is clearly labelled; current decision actions do not silently target history. |
| Diagnose a failed input | User reaches the affected node, understands the available safe detail, and starts a corrected run without rebuilding configuration. |
| Recover from lost status updates | The UI distinguishes stale display from failed execution and refreshes without restarting work. |
| Cancel via keyboard | Focus stays within confirmation, Escape restores focus, and final state is announced. |
| Find an old waiting run | It remains discoverable beyond the first ten history entries. |
| Use at 390 px or browser zoom | Main actions and forms reflow; no zero-width canvas; a usable Steps alternative exists. |

### Proposed product targets

- New-run setup reachable in one action from any run screen.
- Two-click launch for an unchanged reusable, validated configuration when no separate effect review is required.
- At least 90% of desktop content width available to the default closed-panel canvas, with unobscured area measured separately when panels open.
- At least 600 px canvas width when a desktop inspector is pinned; otherwise use overlay/single-surface mode.
- No pan/zoom reset solely because status, selection detail, or a panel changes.
- Failure-to-detail and pending-decision-to-review each require one action.
- Zero duplicate runs caused by a double submit or a reconciled acknowledgement retry.
- Zero cases where a displayed historical result can silently approve a newer decision occurrence.

These are proposed acceptance targets. Establish current task-time, error-rate, and canvas-area baselines before claiming improvement. Test a small round with people who build workflows and people who mainly run them; record completion, wrong-action attempts, hesitation, and whether they can explain Run/Generation/Attempt in their own words.

### Automated and browser coverage

Use existing LiveView tests as foundations: `composer_run_start_live_test.exs`, `composer_run_cancel_live_test.exs`, `composer_run_decision_live_test.exs`, `composer_run_recover_live_test.exs`, `composer_run_results_live_test.exs`, and `composer_run_view_live_test.exs`.

Add meaningful cases for missing capabilities and changed contracts: Stop/Resume, durable launch intent, input reuse/schema drift, stale status, history pagination, generation scope, and exact-attempt reads. Use stable DOM IDs and outcome assertions. Preserve the hostile-event/read-only tests when changing run-mode event handling.

Extend the canvas geometry/viewport/keyboard tests for panel changes, viewport restoration, and any new zoom behavior. Use real browser tests for focus trapping, reflow, overlapping panels, reachable controls, and wire alignment; LiveView assertions cannot establish those visual behaviors.

Use `start_supervised!/1` and event/process synchronization in new Elixir tests. Keep the existing Phoenix conventions: function components, `Layouts.app`, `.input` forms, external hooks in the app bundle, and explicit DOM IDs. Paginated history collections should use LiveView streams; bounded graph projections need a deliberate collection strategy consistent with their editing/undo needs.

Follow the project completion checks with `mix precommit`. Before any implementation commits, run `mix test` followed by `make quality`, and resolve failures. This report does not authorize implementation commits.

## 15. Decisions to settle during implementation

These are design decisions with recommended defaults, not reasons to delay the first slice:

| Decision | Recommended default |
| --- | --- |
| Should selection always open details? | Highlight first; explicit Inspect, with an opt-in preference for automatic inspection. |
| Should a panel resize the graph? | Temporary overlay by default; explicit pinning only when enough canvas remains. |
| Should New run from history use the old definition? | Current saved draft, explicitly labelled. Historical snapshot is a separate option. |
| Which previous values are reused? | Only an explicitly selected run/generation or saved input set, subject to reuse/sensitivity policy. |
| Should a decision show all outputs? | Show declared relevant outputs and links to others. Until declared, offer result navigation rather than guessing. |
| Should the graph follow execution automatically? | No; provide an explicit follow toggle. |
| Should Pause and Stop share a label? | No. Their interruption/drain semantics differ. |
| Should a failed run offer Retry? | Only if a specific supported retry contract exists. Otherwise New run with corrected inputs. |
| Should advanced metadata be permanently visible? | No; retain it in details, with important availability/blocking information promoted when relevant. |
| Should maximizing canvas hide run controls completely? | No; retain a compact status/control affordance and a clear exit. |

## 16. Review completion record

This deliverable is a research and implementation plan. Application source was not changed for the proposed redesign. The repository's existing Elixir style guide was retained. No separate shipped guide body was present in the installed skill directory, so a two-way comparison against a bundled reference could not be performed.

The disposable browser draft was removed using the normal Composer deletion path after its three runs became terminal. As designed by the application, terminal run history is retained with the draft reference removed. No user workflow was cancelled or edited.

Validation on 8 November 2026:

- `mix precommit` passed: compilation with warnings as errors, unused dependency check, formatting, strict Credo, and tests. Credo found no issues; ExUnit reported **730 passed, 5 excluded**. The configured exclusion was `:pending_core_crash_redaction`.
- `git diff --check` passed. A direct whitespace/reference check was also performed on the new untracked Markdown file, which Git's ordinary diff check does not inspect.
- Git status showed only `CODEX_UI_SUGGESTIONS.md` as a new file. No application source changes or commits were made.
- Fresh browser observations covered launch, human review, generation switching, successful completion, cancellation, failure inspection, modal keyboard focus, and the draft layout sizes described above. No JavaScript exception was reported by the walkthrough driver. The observed status inconsistency and modal focus escape remain findings for implementation; passing automated tests does not negate them.
