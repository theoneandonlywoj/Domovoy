# Node editor design research: n8n

Designer handoff for the Domovoy node editor prototype. Researched **4 November 2026**.

## 1. Design direction

Build the editor around three questions: **What happens next? Which branch receives the data? What capabilities does this node use?** Give each answer a clear visual representation.

n8n's most useful pattern is its distinction between a workflow's main data path and typed attachments such as an AI model, memory, or tool. Preserve that distinction, contextual node creation, explicit branch labels, and execution feedback. These are the foundations of understandable wiring. [D1][D3][S1][S2]

The designer's first deliverable should be an interactive connection prototype with ordinary nodes, a conditional branch, a merge, and an AI cluster. A polished static canvas alone will leave the hardest usability problems unresolved.

### Evidence and scope

- **Documented** means supported by official n8n documentation.
- **Source-verified** means confirmed in n8n's public implementation at commit [`a79aac7f9791ae9dc9d1c53a11c878521982e727`](https://github.com/n8n-io/n8n/tree/a79aac7f9791ae9dc9d1c53a11c878521982e727).
- **Recommendation** means a proposed Domovoy design decision or an inference from the research. All proposed sizes, timings, accessibility behavior, and acceptance criteria below belong to this category.

This is documentation and source research, without a hands-on session in a running n8n instance. The source revision is a development snapshot, not a claim about a particular released Cloud or self-hosted build. Documentation is live and may move ahead of deployed versions. Hover timing, touch behavior, actual screen-reader behavior, and release-specific availability still need direct validation.

The inspected Domovoy worktree contains a Phoenix application scaffold and no existing node editor. The recommendations describe a new interface rather than an audit of implemented editor behavior.

## 2. Understand the different meanings of “node type”

Avoid putting every distinction into a single category system. A node has several independent attributes:

| Dimension | Examples | Design consequence |
| --- | --- | --- |
| Workflow role | Trigger, action, routing, aggregation | Explain what the step does in the process. |
| Functional family | Integration, transformation, flow control, AI | Help people browse and search the catalog. |
| Connection contract | Main data, language model, memory, tool | Determine which ports can connect. |
| Composition | Standalone node, AI root, attached sub-node | Determine layout and relationship styling. |
| Configuration | Operation, mode, enabled optional features | Ports can change when configuration changes. |
| Availability | Installed, missing community package, restricted, deprecated | Distinguish setup problems from invalid wiring. |

The documentation distinguishes trigger and action operations, and describes cluster roots and sub-nodes. Source definitions separately specify ports, filters, connection limits, and availability states. These are related concepts, but they are separate axes. [D2][D3][S2][S6][S10]

### Node families to include in the component library

| Family | Representative n8n examples | Connection considerations | Recommended visual treatment |
| --- | --- | --- | --- |
| Entry / trigger | Manual Trigger, Schedule Trigger, Webhook, app event | Starts a path; ordinary trigger nodes do not need a preceding data step. | Recognizable entry silhouette and trigger badge. |
| Integration / action | HTTP Request, service-specific actions | Usually receives and produces main data. Service identity alone does not describe the operation. | App icon, editable name, concise operation subtitle. |
| Data transformation | Edit Fields, Code, Filter | Main data changes shape or quantity. | Shared standard shell; identifiable operation icon. |
| Conditional routing | If, Switch | Multiple named outputs. | Room for legible output labels and per-output add actions. |
| Join / aggregation | Merge | Explicit inputs with mode-specific meaning. | Visible input names and merge-mode summary. |
| Iteration | Loop Over Items | Separate `loop` and `done` paths; return connection. | Stable output labels and a readable return lane. |
| Pause / resume | Wait | Temporarily suspends execution. | Waiting state that differs from running and failed. |
| Reusable workflow | Execute Sub-workflow | Calls another workflow; may wait for completion. | Linked-workflow badge and open-workflow action. |
| AI root | AI Agent, Basic LLM Chain | Combines main data flow with typed capability inputs. | Wider shell with a distinct attachment area. |
| AI provider / sub-node | Chat Model, Simple Memory, tools, retriever | Supplies a typed capability to another node. | Compact shell and diamond capability ports. |
| Annotation / organization | Sticky Note, Canvas Group | Helps explain or organize the graph. | Background annotation or group container, distinct from executable steps. |

Examples and roles: [D2][D3][D4][D5][D6][D7][D8][D10][D11][D17][D18].

**Source-verified visual detail:** n8n's default renderer distinguishes a standard rounded node, a trigger with more rounded left corners, and a rounder configuration-node shell. Its source also contains a separate Agent renderer. Treat these as evidence of role differentiation, with geometry dependent on renderer/version. [S8][S9]

**Recommendation:** derive node shape from role and composition. Use service color inside the icon area, with execution and selection states layered independently. A different card color for every integration would compete with connection meaning.

## 3. Connection grammar

### Main data connections

**Documented:** connecting an output to an input routes data between nodes. n8n's data consists of items, commonly containing JSON and optionally binary data. Most nodes handle multiple incoming items automatically. A wire represents a data route; it does not map an individual field to a form parameter. [D1][D12][D13]

**Source-verified:** main connections use solid paths and target arrowheads. The current main input/output renderers use dot components. Older documentation describes a gray rectangle on the input side, so use the pinned implementation when comparing handle geometry. [S1][S3][S3b][D1]

**Recommendation:** use a left input / right output reading direction, with a visible arrowhead at the destination. Keep node names, port names, and execution counts as separate information layers.

### AI capability connections

**Documented:** an AI cluster consists of a root and attached sub-nodes that extend its capabilities. A model, tool, or memory attachment has a different purpose from passing the next batch of workflow items. [D3][D4]

**Source-verified:** non-main connections use dashed paths without the main connection's arrowhead. Non-main handles use diamonds. Capability input controls extend below the parent; provider output labels sit above the provider. [S1][S2][S4][S4b]

The visual gesture and the stored connection direction require care. A user can begin a capability connection from an input socket or an output socket; the logical provider still supplies an output to a consumer input. Describe the relationship as “Agent uses Chat Model,” while preserving provider-to-consumer direction in the graph contract. [S2][S6][S7]

**Recommendation:** arrange capabilities below their consumer, with labels such as **Chat Model**, **Memory**, and **Tool**. Let users start from the task they recognize: clicking “Add model” on an agent should open compatible models. A dashed attachment is structural; attaching a tool does not guarantee that the agent calls it in every run. [D10]

### Connection-type reference

These identifiers are present in the pinned `NodeConnectionTypes` definition. The friendly labels are proposed designer terminology; the table is a contract inventory, not a promise that every type appears in every node's UI. [S6]

| Contract | Friendly label | What the relationship expresses |
| --- | --- | --- |
| `main` | Data | Workflow items move to the next step. |
| `ai_languageModel` | Model | A consumer uses a language model. |
| `ai_memory` | Memory | A consumer uses conversation memory. |
| `ai_tool` | Tool | An agent can invoke an attached capability. |
| `ai_outputParser` | Output parser | A consumer uses structured output parsing. |
| `ai_embedding` | Embeddings | A component uses an embedding provider. |
| `ai_document` | Documents | A component receives a document-provider capability. |
| `ai_textSplitter` | Text splitter | A document-processing component uses a splitter. |
| `ai_vectorStore` | Vector store | A component uses vector storage/search. |
| `ai_retriever` | Retriever | A component uses a retrieval capability. |
| `ai_reranker` | Reranker | A retrieval component uses relevance reranking. |
| `ai_chain` | Chain | A compatible component uses a chain capability. |
| `ai_agent` | Agent | A compatible component uses an agent capability. |

Concepts and examples: [D4][D19][D21]. Some components have several roles depending on their mode. A vector store can participate in the ordinary data path, supply a vector-store capability, or act as an agent tool. Its selected mode changes available inputs and outputs. [D19]

Do not add a generic `error`, `true`, `false`, or `loop` contract to match these labels. The source models an error output as an output category; branch and loop labels describe particular ports in the main-data family. They are different from an AI connection type. [S6][D5][D6][D8]

### Port anatomy and compatibility

A port needs an identity independent of its visible position: node, input/output direction, contract, and port index or stable key. Its specification can also include a display name, required flag, compatibility filter, and maximum connection count. n8n represents these distinctions in node definitions and handle rendering. [S2][S6]

Source validation checks complementary directions and matching types; node-level validation additionally checks actual configured inputs/outputs and allowed/excluded node filters. A matching diamond shape alone does not establish compatibility. [S7][S11]

| Attempt | Expected interpretation | Recommended feedback |
| --- | --- | --- |
| Main output → main input | Candidate data connection | Highlight target, then commit if permitted. |
| Main output → model input | Type mismatch | “This input needs a chat model.” |
| Model output → model input | Candidate capability attachment | Check supported model and capacity. |
| Memory output → tool input | Type mismatch | “Memory connects to a Memory input.” |
| Compatible type, excluded provider | Node-specific incompatibility | Explain which provider capability is required. |
| Second provider → full single-provider input | Capacity limit | Offer explicit replacement; preserve the current link until confirmed. |
| Main output → another main output | Direction mismatch | Indicate the destination needs an input. |
| Any wire → sticky note | Non-executable annotation | Keep the note outside connection targeting. |

**Source-verified example:** the inspected Agent input helper limits each model, memory, and output-parser input to one connection. Tool input supports multiple attachments. A separately enabled fallback-model input has its own slot. Required and optional ports are configuration-dependent; read the actual node definition rather than applying these limits globally. [S12]

## 4. Creating and editing connections

### Verified interaction patterns

| Intent | n8n evidence | Designer takeaway |
| --- | --- | --- |
| Start a workflow | “Add first step” opens trigger discovery. [D2] | Give the empty canvas an obvious entry action. |
| Connect existing nodes | Drag from a main output to the following input. [D1][S2] | Make sockets easier to acquire than their visible glyphs suggest. |
| Add a next step | Output Add node opens node discovery. The creation path connects the selected node to its originating context. [D2][S11] | Keep the exact originating branch while browsing. |
| Drop a wire on empty canvas | The editor records the originating handle and projected drop position, then opens connection-aware node discovery. [S13] | Turn an unfinished connection into contextual creation. |
| Insert on a wire | Main-edge hover toolbar exposes Add; creation replaces the old connection with a path through the new node. [S5][S11] | Show the insertion location and both resulting connections. |
| Delete a wire | Hover reveals Delete. [D1][S5] | Distinguish deleting a relationship from deleting a node. |
| Attach AI capability | Non-main input exposes an Add control according to connection availability; typed handles support starting from either side. [S2][S4] | Open discovery filtered to the selected capability. |
| Add human review to a tool | Certain agent-tool edges expose an Add action specifically for human review. This is conditional, not universal AI-edge insertion. [S5][S13] | Explain the action's meaning in its label. |

**Source-verified nuance:** the main output's quick-add control is hidden after that output is connected in the inspected renderer. Fan-out should not depend on assuming a persistent plus button beside every occupied output. [S3b]

### Recommended interaction sequence

1. **Discover:** hovering or focusing a port reveals its name, type, availability, and action.
2. **Start:** pointer-down establishes the originating port. Movement produces a temporary connection; clicking its explicit Add control opens discovery.
3. **Guide:** compatible targets gain emphasis. Incompatible targets remain identifiable with a short reason when approached.
4. **Acquire:** the target highlights inside a generous hit region. Resolve nearby ports explicitly rather than choosing an arbitrary socket.
5. **Commit:** release on a valid target creates the connection and leaves a brief confirmation. Announce source, output, target, and input to assistive technology.
6. **Create instead:** release on empty space opens filtered discovery. Preserve the originating port and intended placement until selection or cancellation.
7. **Cancel:** Escape removes the preview and closes pending discovery. Restore focus to the initiating control; leave the graph unchanged.

This is a proposed interaction contract. n8n's inspected canvas has a connection acquisition radius of `60` in its canvas configuration, which supports the principle of forgiving targeting; it is not a measured recommendation for screen-space target size. [S14]

### Recommended editing and recovery rules

- Make adding a node between two steps one undoable operation: `A → B` becomes `A → C → B`. Cancelling discovery leaves `A → B` intact.
- If endpoint dragging is supported, keep the old connection until a valid replacement commits. An invalid drop restores it. Direct endpoint reconnection was not established by this research.
- Deleting a wire should be immediately undoable. Do not remove either endpoint node.
- Suppress exact duplicate edges. Adding a branch should create a distinct destination connection.
- Treat an occupied single-provider socket as a replacement operation with an explicit preview.
- Preview connection changes before removing a Switch route, changing vector-store mode, or disabling an optional AI socket. Preserve meaningful port identity when labels or ordering change.
- Distinguish an invalid target from empty canvas. An invalid-target drop should explain incompatibility; empty-canvas drop should offer creation.
- Define deletion-through behavior separately: deleting a node must not silently join branches or infer a Merge operation.

These are Domovoy requirements, not verified descriptions of every n8n cancellation, deletion, or history behavior.

## 5. Topologies that need distinct designs

### A. A normal sequence

`Trigger → Fetch records → Edit fields → Send notification`

**Recommendation:** make this the default layout. Keep an obvious next-step action on unconnected outputs. Show an operation subtitle so that two nodes using the same service remain distinguishable.

### B. Fan-out and conditional branching

Fan-out sends a source output to several downstream nodes. If evaluates conditions with two outcomes; Switch supports multiple routes and configurable routing behavior. Switch can send data to the first matching output or every matching output, and can ignore unmatched items or route them through a fallback. [D5][D6]

**Recommendation:** label branch ports at the source, with counts beside their own paths. Include a summary such as “First match” or “All matches” on Switch. Make an unconnected fallback visible during configuration review.

An If node can send some items to `true` and other items to `false` within the same run. Avoid a visual model that implies a single global branch choice for an entire batch. Its latest-run counts should make the split understandable. [D5][D12]

**Execution-order caveat:** current n8n documentation says workflows created from 1.0 execute each branch in turn, ordered by canvas position: top to bottom, then left to right for equal height. Branches drawn beside one another do not establish concurrent execution. [D9]

**Recommendation:** if Domovoy adopts a different scheduler, represent its actual ordering rules. Review whether auto-layout may change meaning before offering “Tidy up.”

### C. Joining branches

```text
Fetch customers ──→ Merge: Input 1 ──→ Prepare report
Fetch invoices ───→ Merge: Input 2
```

Merge has explicit modes. Append waits for connected inputs and concatenates their items. Combine can match fields, pair by position, or generate combinations. Current versions support more than two inputs; older versions do not. Merely drawing convergent wires does not specify one of those operations. [D7]

**Recommendation:** show input labels, mode, and join keys where relevant. Keep the incoming path-to-input association stable when moving the node. Do not imply that connecting two sources to an ordinary input provides Merge's synchronization and combination semantics.

### D. Loop and return path

```text
Trigger → Loop Over Items ── loop ──→ Process batch
                  ↑                       │
                  └──────── return ────────┘
                  └── done ──→ Finish
```

Loop Over Items emits each batch through `loop`, then combined processed data through `done` after completion. Many ordinary nodes already process item lists without an explicit loop. n8n also supports return paths, so treating every cycle as invalid would reject valid workflows. [D8][D12]

**Source-verified:** backwards main connections receive special routing that travels below the source to avoid crossing its body. [S15]

**Recommendation:** reserve a return lane, emphasize `loop` versus `done`, and show iteration context. Avoid placing the return label where it appears to be another output. Design termination guidance for explicit repeat-until patterns.

### E. Errors and recovery

There are two separate mechanisms. Node settings can stop execution, continue, or continue using an error output. A workflow-level error handler is selected in workflow settings and begins with Error Trigger in another workflow. [D2][D14]

**Recommendation:** use a labeled **Error** output for local recovery and a workflow settings affordance for global error handling. Reserve persistent red failure styling for an actual failed execution; an error-handling route is a valid designed path even when nothing has failed.

### F. AI cluster

```text
Chat Trigger ─────→ AI Agent ─────→ Send reply
                     ⋄  ⋄  ⋄
                     ┆  ┆  └┄┄ Calculator / API tool
                     ┆  └┄┄┄┄ Simple Memory
                     └┄┄┄┄┄┄ Chat Model
```

The sketch shows visual attachment relationships, not arrow direction or execution order. The model, memory, and tool supply different typed capabilities. Current Agent documentation requires a tool and describes the Tools Agent model; older tutorials may show an agent-type selector that is now deprecated. [D3][D10]

**Recommendation:** show required missing attachments at their own sockets. Separate structural validation from missing credentials. Permit several tools while retaining a distinct single-model slot and, where configured, a fallback-model slot. [S12]

Sub-node parameter expressions can resolve against the first input item, unlike ordinary per-item resolution. The inspector needs contextual help when an expression appears to vary per item but will not. [D11]

### G. Nested retrieval capabilities

`Question and Answer Chain uses Retriever; Retriever uses Vector Store; Vector Store uses Embeddings.`

A retrieval setup can have several levels, rather than every capability being attached directly to an Agent. Vector-store modes and optional rerankers change this composition. [D4][D19][D21]

**Recommendation:** let attached nodes have attachments of their own. Lay out each relationship near its actual consumer and preserve contract labels as the cluster grows.

### H. Sub-workflows, notes, and groups

Execute Sub-workflow calls a separate workflow and can either wait for completion or continue. It is different from an AI sub-node and from an organizational canvas group. [D17]

Sticky notes support documentation and can sit behind nodes. Canvas Groups are a newer documented feature, fully available from 2.31.0 after a gradual rollout. Groups have connectivity restrictions: triggers stay outside; AI roots and their sub-nodes must stay together; external links cannot enter arbitrary middle nodes. [D18][D20]

**Recommendation:** distinguish three concepts in naming and visuals: **annotation**, **group**, and **called workflow**. Do not promise freeform group boundaries while adopting n8n's restricted group behavior. Start with annotations; design grouping once boundary and collapse semantics are explicit.

## 6. Data inspection completes the connection experience

**Documented:** users map fields by dragging from the INPUT pane into parameters, which generates an expression, or by using the expression editor. This is a parameter reference, separate from a canvas connection. [D13]

**Recommendation:** design an inspector with three clear regions: incoming data, configuration, and outgoing data. Preserve the selected source/input when a node has several incoming paths. A field drag should preview the expression being created rather than suggesting it creates another graph wire.

Provide these states explicitly:

| Inspector situation | Recommended presentation |
| --- | --- |
| No upstream execution yet | Explain how to obtain sample input; do not show a misleading empty table. |
| Executed with zero items | Show “0 items” and execution context. |
| Several inputs / routes | Named source and input selector tied to canvas labels. |
| JSON and binary data | Appropriate data views; binary attachments are not another wire family. |
| Repeated execution / loop | Run or iteration selector with counts for the selected context. |
| Pinned sample data | Persistent pinned-data badge and clear unpin action. |
| Settings changed after a run | Identify results as stale until rerun. |

Pinning substitutes saved output in development; production runs ignore pinned data. Partial “Execute step” can execute preceding nodes needed to supply input, so it must not be described as guaranteed to run only the selected node. [D15][D16]

**Recommendation:** connect the canvas's counts and status to a specific execution or sample. Keep pinning, running, and success as distinct states. Do not infer an item's count from how many times an AI tool was invoked.

## 7. Required interaction and execution states

The table is a proposed component-state contract. Source research confirms n8n separately models execution issues, validation, disabled nodes, pinned data, stale results, missing node packages, and restrictions. Exact state precedence below is a design task, not a copy of n8n's implementation. [S10]

| State | Node treatment | Port / connection treatment | Feedback or action |
| --- | --- | --- | --- |
| Idle | Quiet shell, readable name | Neutral structural route | Hover/focus affordances available. |
| Hovered | Subtle elevation or outline | Emphasize related port; show relevant toolbar | Tooltips explain icons. |
| Selected | Persistent selection outline | Keep incident routes traceable | Inspector identifies selected object. |
| Keyboard focused | Focus ring distinct from selection | Focused port/edge has visible target | Accessible name and available action. |
| Dragging connection | Origin remains emphasized | Temporary route follows pointer | Show requested type. |
| Compatible target | Destination gains emphasis | Clear acquisition ring | Preview exact named input. |
| Incompatible / full | Remain legible | Rejection cue at target | Specific explanation; replacement if supported. |
| Required setup missing | Setup badge | Missing required socket identified | “Add chat model” or “Set credentials.” |
| Running | Running indicator | Highlight only actual active execution | Stop and execution details available. |
| Waiting | Clock / waiting badge | Preserve graph without continuous flow animation | Show resume condition. |
| Succeeded | Check and selected-run context | Subtle executed-path emphasis, item count | Inspect output. |
| Executed, zero output | Successful execution with zero items | Explicit count where data exists | Distinguish from an unexecuted path. |
| Failed | Error indicator | Identify failing step and actual execution path | Inspect error and recovery route. |
| Not executed / untaken route | Neutral or muted state | No fabricated success or zero count | Explain selected-run context. |
| Disabled | Disabled badge and muted shell | Keep connections readable | Re-enable action. |
| Pinned | Pin badge | Sample-data context | Unpin / edit sample. |
| Stale | Warning badge | Old results identifiable as old | Rerun. |
| Read-only | View-only context | Hide editing controls; allow inspection/navigation | Explain restriction when relevant. |

**Recommendation:** keep status icons, port contract shapes, and selection outlines independent. An error badge must remain visible on a selected node. Avoid using the same red or dashed styling for incompatibility, runtime failure, and AI attachments.

## 8. Visual and spatial specifications to explore

These are **starting values for Domovoy prototypes**, not measurements of n8n or accessibility-conformance claims.

| Element | Suggested starting point | Reason |
| --- | --- | --- |
| Standard node | 88–104 px visual body, name below | Keeps the canvas compact and the label editable. |
| AI root | 240–320 px width; height grows with sockets | Accommodates several named attachments. |
| Capability node | 64–80 px body, visible type label | Reads as an attached resource. |
| Port glyph | 8–12 px circle or diamond | Clearly communicates family without dominating. |
| Pointer hit area | At least 28–32 px around isolated ports | Forgiving acquisition. Resolve overlaps on dense nodes. |
| Touch controls | Aim for 44 px targets | Explore a tap-based connection mode separately. |
| Edge stroke | About 2 px at working zoom | Supports scanning without dominating cards. |
| Edge hit corridor | 12–20 px screen-space width | Enables reliable selection and toolbar acquisition. |
| Horizontal node gap | 100–160 px before labels | Leaves room for arrows, counts, and insertion controls. |
| Branch separation | At least 80 px clear space between node bodies | Keeps labels and controls from colliding. |
| Motion | 120–180 ms for local feedback | Short, interruptible transitions; respect reduced motion. |

Use a restrained canvas, low-contrast grid, strong text, and a single interaction accent. Make light and dark themes equally legible. Preserve contract distinctions through shape, text, and stroke pattern as well as color.

Use curved forward paths and a deliberate lane for returns. Avoid routing through node names, port labels, or toolbars. n8n's renderer explicitly handles backward main paths differently, supporting this distinction. [S15]

At distant zoom, prioritize node identity and overall structure; at working zoom, show ports, branch names, and counts. Keep active controls and focus indicators usable as scale changes. n8n's source includes zoom compensation for edge controls and labels, but final screen behavior needs direct inspection. [S1][S3b][S4][S5]

**Recommendation:** when selecting a node or edge, emphasize its local path and gently de-emphasize unrelated paths. Ensure this works in crowded crossings. Hover toolbars should remain available while the pointer moves from the wire into the controls, without covering the branch name permanently.

## 9. Discovery, keyboard use, and accessibility

### Contextual node discovery

The picker should retain its task context: **Start a workflow**, **Add after “If: true”**, **Insert between Fetch and Send**, or **Add a model to Agent**. Catalog groupings help browsing; compatibility determines what can actually be attached. n8n supports trigger/action operation selection and connection-aware discovery. [D2][S13]

**Recommendation:** include search, operation descriptions, compatible options, and a clear empty-result explanation. “No compatible chat models found” should explain how to change the search or install an available provider. Keep installation, credentials, and connection incompatibility as separate messages.

### Verified keyboard reference

The current official shortcut page documents the following. Older material often says Tab opens node discovery; the current page specifies **N**. Confirm against the target release before copying shortcut behavior. [D22]

| Task | Current documented n8n shortcut |
| --- | --- |
| Open node picker | `N` |
| Insert picker selection / close picker | `Enter` / `Escape` |
| Open selected node / rename | `Enter` / `F2` |
| Select adjacent node | Arrow keys |
| Undo / redo | `Ctrl/Cmd+Z` / `Ctrl/Cmd+Shift+Z` |
| Fit workflow / reset zoom | `1` / `0` |
| Pan | `Space+drag`, middle-button drag, or documented modifier gestures |
| Execute workflow | `Ctrl/Cmd+Enter` |
| Command bar | `Ctrl/Cmd+K` |

### Additional Domovoy requirements

These are recommendations; the research does not establish that n8n offers a complete keyboard-only connection flow.

- Provide **Connect to…** on an output: choose destination node, then named input. Offer compatible targets as a searchable list.
- Permit selecting and deleting an edge without pointer hover. Announce “If, true output, connected to Send email, input.”
- Make quick-add, insertion, and capability attachment available on focus as well as hover.
- Keep shortcut letters inactive while typing in fields or editors.
- Return focus after cancelling a picker or deleting an object.
- Explain required sockets in text; accompany color changes with icons, shape, or labels.
- Support reduced motion and avoid continuous animation on an idle graph.
- Provide a useful node/connection list for nonvisual navigation and highly zoomed-out workflows.
- Define touch connection gestures explicitly. Test tap source → tap destination and cancellation before promising mobile editing.

## 10. Designer deliverables and prototype scope

### First review: connection foundations

Produce a component sheet with standard node, trigger, AI root, capability, annotation, input/output port, main edge, attachment edge, edge toolbar, and contextual picker. Show idle, focus, selection, compatible, incompatible, full, and read-only variants.

Prototype these tasks end to end:

1. Add a trigger, add a next step through its output, and connect two existing nodes.
2. Drop a wire on empty space, search for a step, add it, then undo.
3. Insert a transformation between two nodes; cancel a second insertion without changing the graph.
4. Create an If branch, connect both outcomes, and inspect different item counts.
5. Join independent branches through a Merge with named inputs and visible mode.
6. Attach a model and several tools to an Agent; reject a Memory-to-Tool connection with an understandable reason.
7. Remove a wire and recover with undo.
8. Complete an equivalent basic connection using the keyboard.

### Second review: advanced cases

Include a Switch with long route names, fallback, and matching-mode summary; Loop Over Items with return and done paths; local error output; optional AI socket removal; occupied model replacement; nested retrieval; and waiting/stale/pinned execution states.

Use realistic labels and sample results: “Fetch unpaid invoices,” “High priority,” “No matching customer,” “12 items,” and “3 tool calls.” Avoid relying exclusively on A/B/C nodes, which conceal spacing and meaning problems.

### Third review: scale and organization

Test a 30–50-node workflow with crossings, several triggers, two AI clusters, a loop, and annotations. Demonstrate fit-to-view, pan, zoom, source tracing, path selection, and read-only inspection. Evaluate grouping only after its boundary rules are settled.

### Acceptance scenarios

| Scenario | Designer acceptance criterion |
| --- | --- |
| Connect a branch | User can identify the originating output before and after adding a node. |
| Empty-canvas drop | Picker preserves origin and placement; cancelling leaves the graph unchanged. |
| Invalid attachment | User can explain the incompatibility and identify a compatible socket. |
| Dense socket layout | Target preview names the exact socket; nearby ports are not chosen silently. |
| Insert on a wire | Both replacement links are clear; one undo restores the previous graph. |
| Occupied single-provider slot | Existing provider remains until explicit replacement commits. |
| Change dynamic ports | Affected connections are previewed and recoverable. |
| Mixed If results | Both routes can display their actual selected-run counts. |
| Merge | User understands the join mode and input association. |
| Loop | User distinguishes processing, return, and completion paths. |
| Zero versus unknown | Zero output is distinguishable from a path that never executed. |
| Keyboard use | User creates, inspects, and removes a connection without dragging. |
| Read-only | Navigation and inspection work without editable affordances. |
| Distant zoom | User can find an intended step and return to working zoom. |

Suggested usability measures: successful completion without help, wrong-port attempts, time to recover from a mistake, ability to explain a selected connection, and ability to distinguish data flow from AI attachment. Establish benchmarks through testing rather than inventing success percentages.

## 11. Decisions to resolve before implementation

1. Does Domovoy execute branches in a defined order, concurrently, or according to dependencies? Can layout change that order?
2. Which contract types are real backend capabilities in the first release? Expose supported types with meaningful compatibility rules.
3. Are cycles generally supported, or only explicit loop patterns? Validation and visual guidance must agree.
4. What does multiple-source input mean without a Merge node? Do not leave synchronization implicit.
5. How should mode changes, route reordering, node deletion, and provider replacement preserve or remove edges?
6. Will the first prototype support endpoint reconnection, touch editing, or groups? Each adds interactions beyond basic wire drawing.
7. Which data does an execution count represent: latest run, selected iteration, or aggregate? Keep the answer consistent across canvas and inspector.

### Hands-on n8n follow-up

Before seeking pixel-level parity, record the deployed n8n version and renderer, then capture: output hover; a live connection drag; compatible/incompatible target behavior; blank-space drop; main-edge insertion; node deletion; an occupied AI socket; vector-store mode change; a loop; and distant zoom. Verify undo/cancel behavior and keyboard shortcuts in that same build.

Use the official connection page's animated example and the Canvas Groups page's overview image as visual reference entry points. They supplement the source findings; this research does not claim those assets are screenshots of the pinned source revision. [D1][D20]

## 12. Source register

All references below are primary sources. Official documentation was consulted on 4 November 2026. Source links are pinned to the inspected revision so that implementation observations remain reviewable.

### Official n8n documentation

- [D1 — Connect nodes together][D1]: creation, deletion, and animated visual reference.
- [D2 — Work with nodes][D2]: discovery, trigger/action operations, controls, and error settings.
- [D3 — Cluster nodes][D3]: roots and attached sub-nodes.
- [D4 — LangChain in n8n][D4]: mapping AI concepts onto node roles.
- [D5 — If][D5]: conditional routing; includes a separately labeled legacy execution caveat.
- [D6 — Switch][D6]: route names, first/all matches, fallback, and output count.
- [D7 — Merge][D7]: input combination modes and version differences.
- [D8 — Loop Over Items][D8]: batching, loop/done paths, and termination.
- [D9 — Understand execution order][D9]: branch scheduling and canvas-position implications.
- [D10 — AI Agent][D10]: tool requirement and agent-version changes.
- [D11 — OpenAI Chat Model][D11]: sub-node expression-resolution behavior.
- [D12 — Understand n8n's data structure][D12]: item lists, JSON, binary, and automatic item processing.
- [D13 — Use the UI mapper][D13]: field references and expression creation.
- [D14 — Handle errors gracefully][D14]: workflow-level error handlers.
- [D15 — Pin and mock data][D15]: saved test data and production limitations.
- [D16 — Types of executions][D16]: partial execution dependencies and production context.
- [D17 — Execute Sub-workflow][D17]: called workflows, inputs, and completion behavior.
- [D18 — Add notes and documentation][D18]: sticky notes and canvas annotation.
- [D19 — Simple Vector Store][D19]: mode-dependent roles and ports.
- [D20 — Canvas Groups][D20]: availability, grouping restrictions, collapse behavior, and visual reference.
- [D21 — Reranker Cohere][D21]: reranking relationship and purpose.
- [D22 — Keyboard shortcuts][D22]: current discovery, navigation, and editing shortcuts.

### Pinned n8n implementation

- [S1 — CanvasEdge.vue][S1]: dashed non-main edges, main arrowheads, execution color, and hover toolbar.
- [S2 — CanvasHandleRenderer.vue][S2]: direction, type, capacity, and starting a connection.
- [S3 — Main input renderer][S3] and [main output renderer][S3b]: dots, labels, counts, and output Add visibility.
- [S4 — Non-main input renderer][S4] and [non-main output renderer][S4b]: diamonds and capability controls.
- [S5 — CanvasEdgeToolbar.vue][S5]: insertion, deletion, and conditional human-review insertion.
- [S6 — Workflow interfaces][S6]: connection contracts and port metadata.
- [S7 — useNodeConnections.ts][S7]: complementary-direction and matching-type checks.
- [S8 — CanvasNodeDefault.vue][S8]: standard, trigger, and configuration node geometry.
- [S9 — CanvasNodeAgent.vue][S9]: separate Agent presentation.
- [S10 — CanvasNodeStatusIcons.vue][S10]: execution, setup, availability, pinning, and stale states.
- [S11 — useCanvasOperations.ts][S11]: connection validation, contextual creation, and insertion replacement.
- [S12 — Agent input helper][S12]: required/optional ports, provider filters, and capacity.
- [S13 — NodeView.vue][S13]: connection-drop discovery and edge insertion context.
- [S14 — Canvas.vue][S14]: drag lifecycle, acquisition radius, and canvas interactions.
- [S15 — getEdgeRenderData.ts][S15]: forward and backwards path routing.

[D1]: https://docs.n8n.io/build/understand-workflows/workflow-components/connect-nodes-together
[D2]: https://docs.n8n.io/build/understand-workflows/workflow-components/work-with-nodes
[D3]: https://docs.n8n.io/integrations/builtin/cluster-nodes
[D4]: https://docs.n8n.io/build/integrate-ai/langchain-in-n8n
[D5]: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.if
[D6]: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.switch
[D7]: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.merge
[D8]: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.splitinbatches
[D9]: https://docs.n8n.io/build/flow-logic/understand-execution-order
[D10]: https://docs.n8n.io/integrations/builtin/cluster-nodes/root-nodes/n8n-nodes-langchain.agent
[D11]: https://docs.n8n.io/integrations/builtin/cluster-nodes/sub-nodes/n8n-nodes-langchain.lmchatopenai
[D12]: https://docs.n8n.io/build/work-with-data/understand-n8ns-data-structure
[D13]: https://docs.n8n.io/build/work-with-data/reference-data/use-the-ui-mapper
[D14]: https://docs.n8n.io/build/flow-logic/handle-errors-gracefully
[D15]: https://docs.n8n.io/build/work-with-data/pin-and-mock-data
[D16]: https://docs.n8n.io/build/understand-workflows/understand-executions/types-of-executions
[D17]: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.executeworkflow
[D18]: https://docs.n8n.io/build/understand-workflows/workflow-components/add-notes-and-documentation
[D19]: https://docs.n8n.io/integrations/builtin/cluster-nodes/root-nodes/n8n-nodes-langchain.vectorstoreinmemory
[D20]: https://docs.n8n.io/build/understand-workflows/workflow-components/canvas-groups
[D21]: https://docs.n8n.io/integrations/builtin/cluster-nodes/sub-nodes/n8n-nodes-langchain.rerankercohere
[D22]: https://docs.n8n.io/build/keyboard-shortcuts
[S1]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/edges/CanvasEdge.vue
[S2]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/handles/CanvasHandleRenderer.vue
[S3]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/handles/render-types/CanvasHandleMainInput.vue
[S3b]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/handles/render-types/CanvasHandleMainOutput.vue
[S4]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/handles/render-types/CanvasHandleNonMainInput.vue
[S4b]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/handles/render-types/CanvasHandleNonMainOutput.vue
[S5]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/edges/CanvasEdgeToolbar.vue
[S6]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/workflow/src/interfaces.ts#L3088
[S7]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/app/composables/useNodeConnections.ts
[S8]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/nodes/render-types/CanvasNodeDefault.vue
[S9]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/nodes/render-types/CanvasNodeAgent.vue
[S10]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/nodes/render-types/parts/CanvasNodeStatusIcons.vue
[S11]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/app/composables/useCanvasOperations.ts
[S12]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/%40n8n/nodes-langchain/nodes/agents/Agent/utils.ts
[S13]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/app/views/NodeView.vue
[S14]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/Canvas.vue
[S15]: https://github.com/n8n-io/n8n/blob/a79aac7f9791ae9dc9d1c53a11c878521982e727/packages/frontend/editor-ui/src/features/workflows/canvas/components/elements/edges/utils/getEdgeRenderData.ts
