# Workflow composer for Domovoy Core

Designer handoff, researched **4 November 2026**. Target engine: **Domovoy Core v0.3.2**, the [latest published release](https://github.com/theoneandonlywoj/Domovoy-Core/releases/tag/v0.3.2), verified through GitHub's release API. This adapts [the n8n research](DESIGN.md) to the actual Core and plugin contracts.

## 1. Product direction

Let a user **compose stages and decisions, choose runners, supply typed inputs, attach validations, validate the definition, and start an inspectable run**.

The central design change from n8n is a two-level composer:

- **Workflow view:** Stages and Decisions connected by control routes.
- **Stage view:** Runner nodes connected through typed input bindings and ordering-only dependencies.

A stage's graph is acyclic. Workflow decisions can revisit stages and open new generations. A runner produces one complete typed value, and each of its input fields has its own contract. Model selection, validators, and runner selection must reflect these rules rather than n8n's AI attachment model. [C1][C2][C3][C4][C6]

**Evidence labels:** “Core behavior” and “Plugin behavior” mean inspected implementation. “Design requirement” describes the proposed editor. A proposed catalog, bridge, codec, or UI is host application work, not an existing Core feature. No plugin operations or example workflows were executed for this research.

## 2. Core version target and plugin mismatch report

Use **one Core v0.3.2 dependency for the entire host**. Runner selection is not a way to select a separate Core version for each node. The table reports the main local checkouts in `~/Desktop/Repos/`; each plugin's `mix.exs` and `mix.lock` agree on the version shown.

| Plugin | Declared and locked Core | Relative to v0.3.2 | Dependency evidence |
| --- | --- | --- | --- |
| Claude Code | **v0.3.0** | Older; migration and compatibility checks needed | [Declaration][VA] · [Lock][VAl] |
| Git | **v0.3.0** | Older; migration and compatibility checks needed | [Declaration][VG] · [Lock][VGl] |
| GitHub | **v0.2.1** | Older; migration and compatibility checks needed | [Declaration][VH] · [Lock][VHl] |
| Linear | **v0.2.1**, with `override: true` | Older; also review the forced dependency selection | [Declaration][VL] · [Lock][VLl] |
| Mise | **v0.3.0** | Older; migration and compatibility checks needed | [Declaration][VM] · [Lock][VMl] |
| Slack | **v0.3.2** | Matches the target pin | [Declaration][VS] · [Lock][VSl] |

**Five plugins target an older Core.** A matching pin is not proof of complete integration compatibility, and an older pin is not proof that every runner is broken. Update the dependency declarations, resolve the host against v0.3.2, and run the relevant plugin and composition checks before presenting a verified runnable catalog. Changing a tag or adding an override alone does not establish compatibility.

The lockfile revisions are `21008fe30d3081d37d688515a8e96bdba9d9375b` for v0.3.0, `115769b68c2b062240c61847eb08ebec4da906de` for v0.2.1, and `db7289577d27451748e323df18de6383853e531c` for v0.3.2. This research changes the design target; it does not change those plugin repositories.

The current Phoenix prototype has no Core or Domovoy plugin dependencies in its `mix.exs`. Installing and integrating the aligned dependency set remains implementation work. Catalog designs below describe the intended experience once that integration exists.

### Source snapshots

All inspected repositories were clean. Core's local source matches v0.3.2 apart from a Makefile change; implementation files cited here therefore represent the target release.

| Repository | Inspected HEAD |
| --- | --- |
| Domovoy-Core | `4d98db4996097d31fbf84ee757b780e6f8ad08d7` |
| Domovoy-Claude-Code-Plugin | `43eada85291888c9068b5c397c20edd817ab6d45` |
| Domovoy-Git-Plugin | `5de98084adaa7b807bb904bfc7b3f46059333209` |
| Domovoy-Github-Plugin | `0f826632f5a0df70bac3f5706fd4ae00d5094220` |
| Domovoy-Linear-Plugin | `7d78281efbe91bdf17731befc2ad721e7efe0d2e` |
| Domovoy-Mise-Plugin | `62f7277062fc040fc4505e2359e5db00e2a907d3` |
| Domovoy-Slack-Plugin | `27c17b6d84aa27bb24fe6f1549390c54b0533110` |

## 3. Where the n8n design must diverge

| n8n-inspired assumption | Domovoy rule | Design consequence |
| --- | --- | --- |
| One canvas of equivalent steps | Workflows contain Stages and Decisions; Stages contain runner graphs. | Offer overview and stage detail with clear breadcrumbs. |
| A trigger is the first executable node | A workflow has `start`; the host starts runs and owns listeners. | Show launch configuration separately from the stage graph. |
| One generic data inlet | Runners declare named, typed input fields. | Expose field-level sockets and source configuration. |
| Data is an automatically iterated item list | Each runner returns one typed value, which may itself be a list. | Do not invent implicit per-item iteration or item-count semantics. |
| Drag a nested output field into a consumer | Bindings consume a complete named value; dotted sources are rejected. | Use a real extraction/conversion runner where necessary. |
| Change an output type in a dropdown | Node output must equal its runner's declared output. | Lock the output after choosing a runner. |
| Any map-shaped outputs are compatible | Type identity is the module, not structural similarity. | Compare actual types and identify needed adapters. |
| A loop wire is valid anywhere | Graph cycles fail; repetition belongs in workflow routing. | Reject stage cycles and explain generation-based reruns. |
| Branches run in canvas-position order | Ready graph nodes run when predecessors succeed and capacity is available. | Moving nodes must not alter scheduling semantics. |
| A stage can fan out to several next stages | `Stage.next` is one vertex or nil. | Use a Decision for routing; parallelize within a stage graph. |
| A validator is a pass/fail branch node | Validators check inputs before the runner and emit no value. | Show an ordered validation stack, not output sockets. |
| AI model/memory/tool attachments are universal | Claude Code runners use typed fields and SDK option documents. | Configure runner options and explicit session bindings. |
| Every node has an error output | Terminal graph failure winds down active/unstarted work. | Do not invent generic error-route ports. |
| Turning off Store means no persistence | `store?: false` suppresses the projection, not canonical history. | Label it “Include in Store projection”; retain the Journal caveat. |
| A successful run has only green steps | Domain-level failure may be encoded in a successful typed result. | Separate engine status from domain status. |

Core evidence: [C1][C2][C3][C6][C7][C9][C18][C22]. Claude-specific evidence: [A1][A2].

Keep the useful n8n interaction ideas: contextual add, compatible-target guidance, insertion previews, clear port labels, undo, keyboard alternatives, and path tracing. Adapt their meaning to the contracts below.

## 4. Composer layout and visual language

### Workflow view

Header: workflow title, engine target **Core 0.3.2**, definition validation state, **Validate workflow**, and **Start run**. Keep a saved definition distinct from a running execution; Core has no n8n-style publish switch in this model.

The canvas contains Stage cards, Decision cards, a Start marker referencing an existing vertex, and finish markers representing nil successors or halt choices. Start/finish markers are editor representations, not extra Core vertex kinds.

A Stage card shows its title, stable engine name, node count, validation summary, and single next route. A Decision shows its prompt, chosen decider, and named choices with their route kinds. Double-click or Enter opens a stage. The inspector exposes workflow inputs, routes, and host execution settings in separate sections.

### Stage view

Breadcrumb: **Workflow / prepare / Stage graph**. Show workflow inputs and prior-stage sources in an input rail. Nodes show the operation, plugin, input fields, output type, validation count, and execution policy summary. The inspector has **Runner**, **Inputs**, **Validations**, **Execution**, and **Advanced** sections.

Design runner cards wider than n8n's compact icon nodes: begin around 280–340 px so field names and type labels can be read. Collapse optional inputs behind a count, while keeping configured and required inputs visible. These dimensions are prototype proposals, not engine requirements.

### Four relationship styles

| Relationship | Proposed appearance | Actual definition |
| --- | --- | --- |
| Value binding | Solid directional wire into a named field | `bind[field] = {source_name, expected_type}` |
| Ordering only | Dashed directional wire between dedicated order handles, labeled “After” | Consumer's `after` list |
| Workflow route | Prominent arrow between Stage/Decision cards | `Stage.next` or Choice target |
| External value reference | Input-rail entry with source badge and field binding | A binding whose source is outside this graph |

Use a type chip rather than a different edge color for every type. Selection, focus, execution, and type compatibility are separate visual layers. Diamonds may identify Decisions; they must not imply n8n AI capability connections here.

## 5. Choosing types

### Where a type is selectable

| Location | User control |
| --- | --- |
| Workflow input | Choose an installed Type module, required behavior, and optional default. |
| Rerun-choice input | Choose a Type module; shared input names must retain a consistent type. |
| Runner input field | Type comes from the runner schema; choose a source or literal rather than retagging the field. |
| Runner node output | Read-only declaration from the selected runner. |
| Extra field | Only available for an `extra?: true` runner; requires an explicit type. |
| Custom type | Select a host-installed implementation; the browser does not define an arbitrary new Core Type by naming it. |

The user's type-first workflow should also work: choose “I have a Git Worktree” or “I need a Directory,” then browse runners with compatible inputs/outputs. Type selection helps discover operations; it does not rewrite their contracts. [C1][C6]

### Type picker groups and form behavior

| Group | Actual Core types | Important form behavior |
| --- | --- | --- |
| Text / bytes | String, Binary | UTF-8 text and arbitrary bytes need different editors/codecs. |
| Numbers | Integer, Float, Number, Decimal | Integer and Float are distinct; numeric strings are not automatically integers. |
| Boolean | Boolean | Preserve false as a supplied value. |
| Identity / address | UUID, URI, Email | Use type-specific checking; preserve the module identity. |
| Filesystem | Path, File, Directory | Path expands without checking existence; File and Directory require existing objects on the execution host. |
| Calendar | Date, Time, NaiveDateTime, DateTime | Browser strings need a host codec before casting where the Type requires an Elixir temporal value. |
| Structured | Map, Any | Map excludes structs; Any still has persistence and semantic limits. |
| Domain | Plugin types, custom enum types | Show plugin, description, shape documentation, and available editor support. |

`Type.Enum` is a helper for defining an enum module rather than a concrete type to offer as a usable input. `Type.Choice` is primarily the engine's decision-answer representation, not a generic replacement for a user's domain enum. [C10]

**Required/default distinctions:** a workflow input can be required, optional and absent, or optional with a default. Required plus default is rejected. An absent default and an explicit null default differ; null works only for a type that accepts nil. Do not add null defaults to every optional field. [C3][C16]

String type accepts the empty string, while runner required-field checks reject blank required text. Type-valid and input-valid are different states. The filesystem writers also have presence validators for binary data, so “not listed as required” does not guarantee a field may be omitted. [C6][C7]

### Compatibility rules

1. Match producer type to the field's declared type using **exact module identity**.
2. Within one stage graph, a field declared `Type.Any` can accept another producer type. Mark this as “Accepted by Any; runtime checks may still apply.”
3. Across stages, Core's workflow source check requires exact equality, including for Any: **Any matches only Any**.
4. Similar representations do not imply compatibility: String is not Path, Git Worktree is not Map, and a custom Integer-like type is not Core Integer.
5. When types differ, offer an installed adapter runner if one exists. Otherwise explain the gap; do not silently cast, retag, or generate an imaginary conversion node. [C2][C3][C9]

Example: Git `WorktreeResolve` emits `DomovoyGitPlugin.Type.Worktree`; `WorktreeDirectory` consumes that whole value and emits Core Directory. This is an actual extraction runner, so the composer can offer it when a Directory is required. [G1][G2]

## 6. Choosing and replacing runners

### Catalog requirements

Group operations by Core, Git, GitHub, Linear, Mise, and Claude Code/Slack. Search by friendly operation, exact module, input type, output type, and plugin. Keep the distinction between installed, unavailable, and verified against Core 0.3.2.

Each runner entry should expose:

- Friendly operation and module name; plugin identity and installed revision.
- Named input fields with types, required markers, defaults, and extra-field support.
- Exactly one declared output type.
- Runner-provided validators in order.
- Inherited retry policy, runner semantic version, and declared effect policy.
- Relevant setup requirements: directory, service configuration, executable, or host supervisor.

Core already exposes `runner.__domovoy_core__/1` for `:input`, `:output`, `:required`, `:validators`, `:retry`, `:extra?`, `:version`, and `:effect`. The generated input schema exposes fields, field types, and defaults. **A designer-friendly catalog with descriptions, secret markers, validator compatibility, and custom form adapters still needs to be built by the host.** Do not interpret `DomovoyCore.Capabilities` as such a catalog; that module describes Journal/Store guarantees. [C6][C24]

### Node creation

1. Choose a runner, either from the general catalog or from a compatible-port context.
2. Create a draft card with its output type fixed and its required inputs visible.
3. For each input, choose **Bind value**, **Literal**, or **Use default / leave absent** as allowed.
4. Show inherited validators and execution defaults immediately.
5. Validate the completed node and graph using Core's constructors through the host.

Allow incomplete drafts while editing. Do not force every keystroke through a constructor that raises on missing required inputs. Separate draft form state from the validated Core definition.

### Replacement versus execution override

**Replace runner in the definition:** show the new schema, output type, validators, and policy. Preview every input, outgoing binding, or downstream consumer that becomes incompatible. Commit replacement and rewiring as one undoable editor action.

**Override runner for a run:** keep this in advanced run settings. Core validates matching input fields, field types, required fields, and extras support. The inspected override check does not compare every semantic detail or the override's declared output. The host should additionally surface output/policy differences, and test compatibility with the node's effective output checks. An override is not an unrestricted drop-in replacement or a safe mock by default. [C21]

Persisted overrides belong to run configuration, while editing the runner changes the definition. Show declared and effective runner identities in run inspection. [C11][C20]

## 7. Wiring runner inputs

### One field, one explicit source

Every configured field is supplied by a binding or a typed literal. Core rejects supplying both. Required inputs need a binding, literal, or usable schema default. One output may feed several compatible fields/nodes, but one field cannot take several independent sources. A combining runner needs separate declared fields and explicit combination semantics. [C1]

The UI should show input rows such as:

```text
working_directory   Directory   Bind: worktree_directory
context             String      Bind: prompt
options             Map         Literal: { model: "sonnet" }
executable          Executable  Default / auto-detect
```

The options sketch is friendly UI notation, not the exact exported JSON. Keep a source summary visible even when a wire leaves the viewport.

### Add and connect

Dragging a value output onto an input field proposes a binding. The target preview names the field and both types. Dropping on empty stage canvas opens runners that accept the source; if several fields match, ask which field before committing the connection.

Clicking Add from a required input opens compatible producers and eligible workflow/prior-stage sources. When the user chooses a literal instead, replace the binding explicitly and retain undo. An **After** connection uses its own handles/action and never fills an input field.

### Deletion and insertion caveats

- Deleting a binding clears that field's source, leaving a visible missing-input state where required.
- Deleting a producer must not silently convert its name into a workflow input. Core treats unknown graph data sources as external inputs; the editor must retain the unresolved reference until the user deliberately replaces it.
- Deleting a dashed After edge removes only the ordering requirement. It must not remove any data bindings between the same nodes.
- Several field bindings can connect the same pair of nodes, and After may coexist with them. Render an expandable bundle/count if needed, but keep each editable relationship distinct.
- Inserting a node is valid only if both resulting bindings can be expressed with real fields and types. A constant-producing runner with no appropriate input cannot generically splice into a data wire.
- Reject a new stage-graph cycle, identifying the cycle. Suggest a workflow Decision/rerun when repetition is intended.
- Renaming an engine identifier must update bindings, After references, and affected source references throughout the workflow atomically. [C1][C2]

### Cross-stage values

Show a prior-stage value as **From stage: prepare / node: worktree_directory / Directory**, then bind the receiving field to that source name. This is a stored committed value reference, not a workflow control edge and not a new stage output declaration.

Core resolves current successful graph records and otherwise reads committed values through `Context.read/2`, including eligible earlier generations. Canonical history is authoritative; the Store projection is not what v0.3.2's resolver relies on. Some learning prose still describes older Store-based resolution, so use the implementation for this design. [C9][C18]

**Design requirement:** show source generation and provenance in the inspector. Do not imply the source always ran in the currently selected generation.

## 8. Choosing and understanding validations

### Three different kinds of validation

| Kind | Meaning | Appropriate UI |
| --- | --- | --- |
| Type cast / value contract | Can the raw value become the declared Type? | Field validity and type-specific errors. |
| Definition validation | Are names, bindings, types, graphs, routes, and sources structurally valid? | Workflow issue list linked to the affected field/edge. |
| Runner/node validators | Checks on the resolved input changeset before the runner executes. | Ordered stack on the node, with field-level errors. |

A node validator is not a post-output assertion, a reusable stage gate, or a branch. It produces no value and has no generic target-field/options configuration in the Core node model: the node stores an ordered list of validator modules. [C7]

### Validation-stack inspector

Show the actual execution sequence:

1. Resolve bound values and literals.
2. Build/cast the runner input changeset and check required fields.
3. Run the runner's built-in validators in declaration order.
4. Run user-selected node validators in declaration order.
5. Run the runner only if the input remains valid.
6. Check/cast the runner's successful output through the node output Type. [C7][C8][C18]

Built-in runner validators are read-only in this editor. Users can add, remove, and reorder the node's additional validators. If initial input casting/required checks fail, custom validators do not run. Otherwise execution stops at the first validator returning an invalid changeset; later entries should show **Not evaluated**, not Passed. Input failure is non-retryable and prevents the runner call. [C7]

### Validator discovery and compatibility

The Core Validator behavior exposes `validate(changeset, context)` rather than a machine-readable input schema. The host needs curated metadata or an adapter stating required fields, compatible runner families, descriptions, and whether a preview is safe. Do not offer every installed validator as interchangeable. Node construction checks that the list holds atoms; that alone does not establish callback availability or schema compatibility. [C1][C7]

Concrete examples:

| Validator | Useful context | Design note |
| --- | --- | --- |
| Git `WorktreeNameIsSafe` | Worktree-name fields on Git operations | Already inherited by WorktreeResolve; show its origin. [G1][G4] |
| Claude `AskOptionsAreValid` | AskClaude options | Show the supported option contract and key-specific errors. [A1] |
| Claude `SessionMatchesWorktree` | Stateful session runner | Validate session identity against worktree, branch, and directory. [A2] |
| Slack `MessageArgumentsPresent` | Message/channel/thread inputs | Any-typed ports still have semantic requirements. [S1][S2] |
| Linear `IssueTargetPresent` | UpdateIssue's issue/identifier alternatives | The rule checks alternatives, not a universally required single field. [L3] |

An output condition such as “Claude result is not an error” needs an actual typed checking/extraction runner or a workflow decider that reads the result. Adding an input validator to AskClaude cannot inspect the future answer.

**Validate workflow** should perform structural checks without running business operations. Do not call arbitrary validators, custom casts, or `run/2` as a hidden side effect of hovering a port. Offer explicit sample-input validation through an isolated host preparation path when the inputs, context, and callback behavior support it.

## 9. Workflow decisions, choices, and repetition

### Decision editor

Expose a stable name, prompt, decider, decider options, and ordered choice cards. A choice has a name, nonempty description, target kind, and typed inputs where allowed.

| Choice target | Meaning | Input support |
| --- | --- | --- |
| Run vertex | Continue at a Stage or Decision, same generation | No choice inputs. |
| Rerun stage | Open generation + 1, write supplied inputs, run the Stage | Typed choice inputs allowed. |
| Halt successfully | Finish with succeeded outcome | No choice inputs. |

Use these exact distinctions in the UI. A rerun target must be a Stage. It may be the stage's first visit: the important behavior is the new generation. A friendly label such as **Run with new inputs — new generation** can explain this when “rerun” would be confusing. Halt is not Cancel. [C3][C4][C11]

`Decider.Person` waits for an answer. A custom decider can await, select a choice, select a choice with inputs, or fail. The default Person behavior should be a complete first-class path; automated deciders require host-installed modules and suitable options editors. [C5][C23]

### Repetition and budgets

Draw return routes at workflow level and label them **Rerun / next generation** where that is the target kind. Do not represent an ordinary same-generation Run route as if it guarantees fresh computation. Committed outcomes in a generation can be reused. [C11][C18]

Show run limits prominently when a loop exists: `max_generations` defaults to 10 and `max_steps` to 1000. The latter counts stage starts and automated decisions between human waits. Bounds and their refusal states belong in prototype scenarios. Concurrency is a separate owner setting; it is not a serialized workflow edge property. [C11][C20]

### Source availability is more than type matching

Core verifies eligible workflow/prior-vertex sources and their types. The inspected workflow check gathers reachable preceding producers; it is not proof that every possible selected route will actually have produced every bound value. Optional inputs can also be declared but absent. A complete composer should add route-specific availability analysis or clearly identify uncertain sources rather than calling every type-correct diagram guaranteed runnable. [C3][C16]

## 10. Plugin-specific design caveats

### Git

Offer repository inspection, branch operations, worktree creation/resolution/removal, changes/diffs, commits, merges, rebases, and remote operations from the installed catalog. These are runner choices, not universal built-in stage types.

WorktreeResolve returns a valid Worktree with `exists?: false` when nothing exists. Engine success therefore does not establish that WorktreeDirectory will find an existing directory. Show the result flag and use a real Decision/decider to choose creation versus reuse. WorktreeDirectory is the explicit Worktree → Directory extractor. [G1][G2][G3]

**Design requirement:** operation descriptions should distinguish reading state, changing the checkout, and publishing remotely. Recovery policy comes from runner metadata; do not infer it solely from the verb.

### Mise

Offer Detect, Trust, Install, ListAvailableVersions, and SearchTools. In the inspected source, **Trust accepts Any worktree input and emits Core Map**, and Detect emits Mise Executable. [M1][M2]

The README contains conflicting sections describing a dedicated Worktree contract and explicit pure/version policies. The inspected runner declarations do not implement all of those claims: Trust uses Map/Any, and Detect/Trust use the default Runner declaration, which v0.3.2 treats as non-idempotent with nil semantic version. Generate the catalog from compiled contracts and verify behavior against the target host, not from the summary table. [M1][M2][M3][C6]

Within a single graph, Git Worktree → Mise Trust.worktree is allowed because the destination is Any. Across stages the exact-type rule rejects that same direct source reference. Trust's Map output also cannot directly feed Git's WorktreeDirectory. Keep a typed Git source available, add a real adapter, or restructure the stage; do not change the displayed output type to conceal the mismatch.

Trust can succeed as a no-op when Mise is unavailable. Distinguish **Completed: tool unavailable / skipped by operation** from **Tools installed**. Do not advertise `mise current` as an installed Mise runner: Core's example notebook implements it with a custom runner.

### Claude Code

Offer AskClaude, CreateOrContinueClaudeSession, CloseClaudeSession, Detect, DescribeClaudeCode, ReadConversation, ListSessions, and SessionSummary where loaded. Distinguish stateless questions from stateful sessions in the picker.

AskClaude consumes `context: String`, optional Directory, Executable, and Map options; output is ClaudeAnswer. Stateful execution additionally needs worktree and branch identity and can bind a ConversationSession to continue it. Model, effort, tool permissions, agents, and output-format choices belong to the runner's validated option documents; there are no generic n8n `ai_memory` or `ai_tool` attachment contracts here. [A1][A2][A3]

A stateful host must start Sessions.Supervisor before Core Runtime. Configuration validity and host readiness need distinct badges. A matching schema cannot prove that the executable, credentials, working directory, and live session are ready. [A2]

AskClaude declares pure recovery, yet a crash can ask again and incur another charge. Stateful sessions declare non-idempotent recovery, but configured retries after returned retryable errors can still resend a prompt. **Pure** is a declared engine recovery policy, not a general promise of determinism, no billing, no edits, or no external activity. Show the operational explanation alongside the raw policy. [A1][A2][C15]

Claude error results can be successful Core values with `error?: true`. Engine status **Succeeded** must coexist with a domain warning such as **Claude reported error_max_turns**. Structured-output options do not guarantee structured output is present. [A1][A2]

### Slack

The concrete runner operations are PostMessage, PostMessageInThread, ReadChannelHistory, and ReadThread. The `Runner.Arguments` file is a helper, not another operation. Listener is host infrastructure, not a Core runner node. [S1][S2][S3][S5]

Channel/thread fields use Any because a plugin message/channel value or string may be accepted. MessageArgumentsPresent and argument parsing still enforce the actual semantics. PostMessageInThread requires a thread and must not silently fall back to a top-level post. Post operations are non-idempotent; interrupted uncertain posts require reconciliation rather than an automatic repeat. [S1][S2]

**Cross-stage trap:** a Message output cannot directly bind to an Any input in a later stage. The tested Slack approval example carries an `answer: Any` through a rerun choice, then uses it in the reply stage. That choice opens a generation even though the reply stage has never run before. This is an excellent designer test case. [S4]

The Slack listener/approval bridge handles correlation, approver identity, occurrence, and incoming-message routing. Drawing a “Slack approval” card alone does not implement that bridge. Its UI may wrap the real Stage + Decision + listener integration, while keeping the underlying control model inspectable.

### GitHub

Expose PRs, issues, reviews/comments, checks, workflow runs, releases, and repository operations as catalog families. The current pin is v0.2.1 and needs alignment before verification under v0.3.2.

GetPr emits PullRequest and represents absence with `state: :not_found`, not an engine failure. CreateOrUpdatePr emits a different type, PullRequestChange. Similar visible fields such as number and URL do not make these types interchangeable. Working-directory and repository/config discovery must remain visible. ReadConfig can return configuration containing an access token; treat its value presentation accordingly. [H1][H2][H3]

### Linear

Expose issue, team, project, label, milestone, status, relation, membership, and update operations. This checkout pins v0.2.1 with `override: true`; resolve that conflict as part of the single-v0.3.2 integration.

GetIssue expects IssueIdentifier and LinearAPIKey and emits Issue. CreateIssue also emits Issue, but has a different field schema, configuration dependency, alternative object/name inputs, and precedence rules. Offer separate operations rather than assuming common output means identical configuration. [L1][L2]

Linear's schema-backed types have their own input-object/enum validation and conversion. Preserve their known schema adapters where available; fall back to a structured editor with server validation rather than treating every custom type as an unvalidated Map. IssueTargetPresent illustrates why required markers alone cannot describe alternative-field requirements. [L3][L4]

## 11. Validation feedback and readiness

Use separate indicators for **Definition valid**, **Host ready**, and **Execution result**. A valid document may refer to an unavailable executable or expired credentials; an older plugin pin is a dependency concern rather than a red type-mismatch wire.

| Layer | Example | Recommended presentation |
| --- | --- | --- |
| Dependency/catalog | Plugin has not been verified against Core 0.3.2 | Plugin/version badge; explain verification gap. |
| Node construction | Missing field, bind plus args, output mismatch | Inline field issue and linked issue-list entry. |
| Graph | Cycle, wrong producer type, missing After source | Highlight exact edge(s) and affected nodes. |
| Workflow | Unknown vertex, invalid choice input, unavailable source, name collision | Workflow-view issue linked to detail. |
| Supplied values | Required absent, failed type cast, non-serializable value | Run/default/literal form error, with values redacted where sensitive. |
| Prepared inputs | Validator rejects options/session/channel | Ordered stack and field message; runner not called. |
| Runner/result | Command fails or output Type rejects result | Actual node failure and retryability. |
| Domain result | Worktree absent, PR absent, Claude answer contains error | Successful engine record with an explicit domain outcome. |
| Recovery | An external effect may have happened | Blocked run with uncertainty and reconciliation action. |

Use the actual Core error identifiers in an expandable details area, including `binding_type_mismatch`, `graph_has_cycle`, `after_source_not_found`, `stage_input_type_mismatch`, `stage_input_unbound`, `choice_inputs_not_rerun`, and `invalid_input`. Friendly messages should identify the node, field, expected type, and possible fix without embedding secrets. [C1][C2][C3][C7]

## 12. Running and inspecting composed workflows

The primary production path should use `Runs.start/4`, not a bare `Engine.run` presented as a durable workflow execution. A standalone Engine call gives graph records without the same persisted run contract. The host owns Runtime and the selected Journal/Store adapters. [C18][C20]

### Start-run panel

Show typed workflow inputs, selected host runtime/profile, persistence guarantee, limits, and advanced overrides. Resolve Directory/File values on the execution host. Keep Core version v0.3.2 visible in details and in the plugin readiness panel.

`max_concurrency` limits active runner tasks and defaults to the owner's online schedulers; it is not persisted as workflow configuration. `max_steps`, `max_generations`, and runner overrides are persisted run configuration. Preserve these categories in the UI. [C20]

Use stable command IDs to retry an uncertain acknowledgement. Do not generate a new Start or Decide command merely because the browser timed out. A command acceptance receipt and its completed operation are different states. [C11]

### Run-state model

Show phase, outcome, and availability independently:

- Phase includes starting, running, waiting, pausing/paused, stopping/stopped, resuming, cancelling/finishing/finished, and blocked.
- Outcome is nil while live, then succeeded, failed, or cancelled.
- Availability is available, degraded, or offline; a Journal problem is not automatically a business failure.

Expose pause/unpause, stop/resume, cancel, decide, and reconciliation only in appropriate states. A halt choice finishes successfully. A stopped run remains resumable. Reconciliation needs operator evidence for a specific uncertainty; it is not the normal Retry button. [C11][C15]

Node inspection should identify stage, stable node name, generation, attempt, actual runner/version, input sources, output Type, record status, and committed sequence. Show queued/running/preparing/retrying/blocked states where observable; do not fabricate iteration counts from list-shaped values.

Drive durable history from `Events.read/subscribe` and reconcile with `Runs.view`. Public events are redacted and carry facts rather than input/output values; fetch authorized record details separately. Raw PubSub is best-effort, so a disconnected browser should resume from a cursor instead of assuming it saw every fact. [C14]

### Persistence caveat for the designer

The inspected Workflow defaults include a filesystem Store and **canonical ETS Journal**. Do not assume “filesystem Store” means crash-durable authoritative history; the host should explicitly configure a durable Journal profile when needed. Some guide prose still describes older defaults. Show guarantees from the actual adapter capabilities. [C3][C24]

`store?: false` does not suppress canonical outputs. Configuration nodes and Claude transcripts can therefore persist sensitive material even when omitted from the Store projection. Secret masking is an inspector presentation feature, not a promise that the value was never persisted. [C1][A1][H3]

## 13. Saving, export, and definition identity

Use Core's format-version-1 Workflow JSON as the executable document. Save bindings and After lists as source declarations; graph arrows are derived. Workflow vertices serialize as Stage or Decision; Choices serialize their Run/Rerun/Halt targets. [C13]

Keep editor positions, human-friendly labels, collapsed sections, notes, and colors in a namespaced metadata area or a sidecar. Core rejects unknown executable keys; do not add top-level `edges`, `position`, `label`, or arbitrary validation specifications and expect Core to accept them. Metadata is excluded from definition fingerprints. [C1][C3][C12][C13]

Engine names must match `[A-Za-z0-9_-]{1,128}`. Use an editable display title separate from a stable engine identifier. Node names are unique across stages and cannot collide with workflow/choice inputs; Decision names also have collision checks. Auto-generated identifiers and rename previews need to respect those rules. [C3][C17]

Changing runner, bindings, literals, types, validators, choice semantics, or declared semantic versions can change the definition fingerprint. Layout metadata does not. Retry policy and Store projection flags are excluded, which does not make them operationally unimportant. Show behavioral edits separately from presentation edits, and keep an existing run associated with its original definition. A live run can reject replay/open under a changed fingerprint. [C11][C12]

### Serialization and form-codec limitations

Core Type persistence and workflow-definition term encoding are separate contracts. Values may have type-specific dump/load behavior, while literal/default/options fields in Workflow JSON use its general term encoder. Do not claim every Type has a ready-made JSON literal editor. [C13]

One concrete mismatch needs an implementation decision: Core Date.cast accepts a Date struct, not an ISO string, while Workflow JSON's general term encoder rejects structs. The JSON module's suggestion to use an ISO date default conflicts with the Date implementation's casting behavior. Do not ship a calendar literal/default as exportable until a supported conversion/representation strategy is verified. Host-decoded run inputs and installed producer runners are separate possible paths. Similar codec review is needed for temporal values, enums, Decimal, and arbitrary binary literals. [C13][C19]

Offer **Validate export** as a real round-trip check: serialize through Core, decode with the target installed modules, validate the reconstructed definition, and compare fingerprints. Keep unsupported editor drafts saveable separately, without calling them executable Workflow JSON.

The host catalog must resolve approved compiled module names and known fields. Core's decoder loads existing compiled modules and rejects unknown modules/atoms; it is not a plugin installer and is not itself the host's complete module-authorization policy. [C13]

## 14. Prototype scenarios using real contracts

### A. Worktree + Mise + Claude, one stage

Build a stage for an existing worktree with these real runner nodes:

| Node | Runner | Output | Important inputs |
| --- | --- | --- | --- |
| `resolve_worktree` | Git.WorktreeResolve | Git Worktree | `worktree_name: String`, `working_directory: Directory` |
| `worktree_directory` | Git.WorktreeDirectory | Directory | `worktree: Git Worktree` from resolve |
| `detect_mise` | Mise.Detect | Mise Executable | None |
| `trust_mise` | Mise.Trust | Map | `worktree: Any` from resolve, `mise: Mise Executable` |
| `ask_claude` | Claude.AskClaude | ClaudeAnswer | `context: String`, `working_directory: Directory`, `options: Map` |

Bind AskClaude's working_directory from `worktree_directory`, and add **After trust_mise** so toolchain trust completes first. Do not bind Trust's Map output to the Directory field. Git Worktree → Any is allowed here because both nodes are in one stage. Show runner-inherited validators and declared policies on each card. [G1][G2][M1][M2][A1]

Wrap the stage in a workflow with a Person review Decision. Approve may Halt; Revise may Rerun the stage with a new `prompt: String` matching the workflow input type. Display the new generation and the actual engine/domain outcomes. If the worktree might be missing, add an earlier routing/creation design; this scenario does not pretend WorktreeResolve creates it.

This is a composition specification grounded in the inspected schemas, not an executed compatibility test. The Git, Mise, and Claude plugins still need the version alignment reported above.

### B. Type-first runner discovery and validations

Start from Git Worktree and search for a Directory producer. Offer installed WorktreeDirectory. Connect its result to AskClaude's Directory field, choose options through the supported Claude options editor, and inspect inherited SessionDirectoryIsValid/AskOptionsAreValid. Reject a direct Worktree → Directory wire with a useful adapter suggestion.

Add a host-installed node validator compatible with AskClaude's input schema; preserve built-in validation order and show **Not evaluated** for later validators after failure. A custom validator must actually exist in the host; the prototype should label any catalog placeholder accordingly.

### C. Slack approval with a supplied answer

Use the plugin's approval example as the behavioral reference: ask Stage → approval Decision → approved/rejected Stage. The choices use **Rerun with answer: Any**. Show why Run-with-inputs is invalid and why a Message → Any cross-stage binding is not accepted. Include the host listener/bridge readiness state and the selected decision occurrence. [S4]

### D. GitHub and Linear extensions

After aligning their dependencies, prototype choosing Linear.GetIssue, its identifier/key sources, and the Issue output. Separately choose GitHub.GetPr and handle not_found as a domain outcome. Demonstrate that a nested field such as an issue's description or PR URL requires a real typed extractor before wiring it to an unrelated String field. Mark missing extractor operations as implementation gaps rather than silently enabling field projection. [L1][H1]

## 15. Designer acceptance criteria

| Task / edge case | Required outcome |
| --- | --- |
| Compose workflow and drill into a stage | User understands which view edits routing and which edits dependencies. |
| Choose a runner | Inputs, fixed output, inherited validators, and policy become visible. |
| Choose a workflow input type | Correct form support, required/default/absent behavior, and installed-module status are clear. |
| Connect mismatched types | Explanation names both types and suggests an actual adapter when available. |
| Connect to Any | UI distinguishes same-graph acceptance from cross-stage rejection. |
| Bind a field already holding a literal | Explicit replacement; undo restores the previous literal. |
| Add order without data | After edge changes scheduling requirements without filling an input. |
| Several bindings between two nodes | User can identify and delete each field binding independently. |
| Delete producer | No accidental conversion into a new external input. |
| Create stage cycle | Reject and identify the cycle; explain workflow-level repetition. |
| Add validator | Built-in and node validators remain distinct and correctly ordered. |
| Fail early validation | Runner never shown as executed; later validators are Not evaluated. |
| Pass data through stages | Source name, type, stage, and generation are inspectable. |
| Supply decision inputs | Only a Rerun choice accepts them; new generation is explicit. |
| Inspect engine-success/domain-error | Both outcomes are visible without contradiction. |
| Start under an older plugin pin | The target is still Core 0.3.2 and verification status is explained. |
| Change runner on an existing definition | Preview incompatible fields and downstream connections. |
| Reopen an execution after a disconnect | Resume durable facts by cursor; do not rerun business work. |
| Change only layout | Definition fingerprint remains the same. |
| Export typed defaults/literals | Unsupported codecs are reported before claiming executable export. |
| Inspect uncertain effect | Distinguish Blocked/reconcile from normal retryable failure. |

Preserve keyboard access from the earlier research: searchable Connect-to and After actions, visible focus, contextual Add on focus, Escape cancellation, and undo. Label relationships by purpose as well as shape/color. A screen-reader name should say “Bind resolve_worktree output to trust_mise.worktree; accepted by Any,” rather than only “connection.”

## 16. Integration work the design depends on

These are concrete host requirements, not claims that Core is missing its execution features:

1. Align all six plugin dependencies and the Phoenix host on **Core v0.3.2**; verify them together. Resolve Linear's older override explicitly.
2. Build an installed-module catalog from runner reflection plus curated type, validator, decider, setup, and editor metadata.
3. Provide a draft-to-Core conversion layer, structural validation, redacted error mapping, and JSON round-trip checking.
4. Supply type-specific browser/host codecs and explicitly handle unsupported definition literals/defaults.
5. Keep workflow control editing separate from stage bindings, After dependencies, and external-value references.
6. Implement run launch/commands/views/events with stable command IDs, durable cursor catch-up, and a defined runtime/persistence profile.
7. Add source-availability analysis, dependency readiness, and declared-versus-effective runner inspection.
8. Implement optional listener/approval bridges and custom extractors/deciders as real installed components before advertising them as runnable palette entries.

## 17. Evidence register

References are local source files from the snapshots in section 2. Core implementation takes precedence where guide prose conflicts. The only remote check in this adaptation was the latest Core release lookup; no changes were made to sibling repositories.

### Core

- [C1 — Node contracts][C1]; [C2 — Graph validation][C2]; [C3 — Workflow checks and defaults][C3].
- [C4 — Choice][C4]; [C5 — Decision][C5]; [C22 — Stage][C22]; [C23 — Decider][C23].
- [C6 — Runner reflection, input schema, defaults][C6]; [C7 — Validator behavior][C7]; [C8 — Input preparation][C8].
- [C9 — Binding resolution][C9]; [C10 — Types guide][C10]; [C16 — Input preparation/defaults][C16]; [C19 — Date implementation][C19].
- [C11 — Runs guide][C11]; [C20 — Run public API/options][C20]; [C18 — Engine scheduling and execution][C18]; [C21 — Override checks][C21].
- [C12 — Definition fingerprint][C12]; [C13 — Workflow JSON][C13]; [C14 — Events][C14]; [C15 — Effect contracts][C15].
- [C17 — Name rules][C17]; [C24 — Adapter capabilities][C24].

### Plugins

- Git: [WorktreeResolve][G1], [WorktreeDirectory][G2], [Worktree Type][G3], [WorktreeNameIsSafe][G4].
- Mise: [Trust][M1], [Detect][M2], [README with conflicting contract summaries][M3].
- Claude Code: [AskClaude][A1], [CreateOrContinueClaudeSession][A2], [SessionOptions][A3].
- Slack: [PostMessage][S1], [PostMessageInThread][S2], [ReadThread][S3], [approval example][S4], [host/listener setup][S5].
- GitHub: [GetPr][H1], [CreateOrUpdatePr][H2], [ReadConfig][H3].
- Linear: [GetIssue][L1], [CreateIssue][L2], [IssueTargetPresent][L3], [schema-backed object type helper][L4].

[C1]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/node.ex
[C2]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/graph.ex
[C3]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/workflow.ex
[C4]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/choice.ex
[C5]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/decision.ex
[C6]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/runner.ex
[C7]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/validator.ex
[C8]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/engine/preparation.ex
[C9]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/engine/resolve.ex
[C10]: /Users/woj/Desktop/Repos/Domovoy-Core/guides/learning/values_and_types.md
[C11]: /Users/woj/Desktop/Repos/Domovoy-Core/guides/learning/runs.md
[C12]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/definition.ex
[C13]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/workflow/json.ex
[C14]: /Users/woj/Desktop/Repos/Domovoy-Core/guides/learning/events.md
[C15]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/runner/effect.ex
[C16]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/inputs.ex
[C17]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/name.ex
[C18]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/engine.ex
[C19]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/type/date.ex
[C20]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/runs.ex
[C21]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/run/owner/dispatch/hits.ex
[G1]: /Users/woj/Desktop/Repos/Domovoy-Git-Plugin/lib/domovoy_git_plugin/runner/worktree_resolve.ex
[G2]: /Users/woj/Desktop/Repos/Domovoy-Git-Plugin/lib/domovoy_git_plugin/runner/worktree_directory.ex
[G3]: /Users/woj/Desktop/Repos/Domovoy-Git-Plugin/lib/domovoy_git_plugin/type/worktree.ex
[G4]: /Users/woj/Desktop/Repos/Domovoy-Git-Plugin/lib/domovoy_git_plugin/validator/worktree_name_is_safe.ex
[M1]: /Users/woj/Desktop/Repos/Domovoy-Mise-Plugin/lib/domovoy_mise_plugin/runner/trust.ex
[M2]: /Users/woj/Desktop/Repos/Domovoy-Mise-Plugin/lib/domovoy_mise_plugin/runner/detect.ex
[M3]: /Users/woj/Desktop/Repos/Domovoy-Mise-Plugin/README.md
[A1]: /Users/woj/Desktop/Repos/Domovoy-Claude-Code-Plugin/lib/domovoy_claude_code_plugin/runner/ask_claude.ex
[A2]: /Users/woj/Desktop/Repos/Domovoy-Claude-Code-Plugin/lib/domovoy_claude_code_plugin/runner/create_or_continue_claude_session.ex
[A3]: /Users/woj/Desktop/Repos/Domovoy-Claude-Code-Plugin/lib/domovoy_claude_code_plugin/session_options.ex
[S1]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/lib/domovoy_slack_plugin/runner/post_message.ex
[S2]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/lib/domovoy_slack_plugin/runner/post_message_in_thread.ex
[S3]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/lib/domovoy_slack_plugin/runner/read_thread.ex
[S4]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/docs/slack/example_approval_in_thread.md
[S5]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/README.md
[H1]: /Users/woj/Desktop/Repos/Domovoy-Github-Plugin/lib/domovoy_github_plugin/runner/get_pr.ex
[H2]: /Users/woj/Desktop/Repos/Domovoy-Github-Plugin/lib/domovoy_github_plugin/runner/create_or_update_pr.ex
[H3]: /Users/woj/Desktop/Repos/Domovoy-Github-Plugin/lib/domovoy_github_plugin/runner/read_config.ex
[L1]: /Users/woj/Desktop/Repos/Domovoy-Linear-Plugin/lib/domovoy_linear_plugin/runner/get_issue.ex
[L2]: /Users/woj/Desktop/Repos/Domovoy-Linear-Plugin/lib/domovoy_linear_plugin/runner/create_issue.ex
[L3]: /Users/woj/Desktop/Repos/Domovoy-Linear-Plugin/lib/domovoy_linear_plugin/validator/issue_target_present.ex
[L4]: /Users/woj/Desktop/Repos/Domovoy-Linear-Plugin/lib/domovoy_linear_plugin/type/schema_object.ex
[C22]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/stage.ex
[C23]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/decider.ex
[C24]: /Users/woj/Desktop/Repos/Domovoy-Core/lib/domovoy_core/capabilities.ex
[VA]: /Users/woj/Desktop/Repos/Domovoy-Claude-Code-Plugin/mix.exs:43
[VAl]: /Users/woj/Desktop/Repos/Domovoy-Claude-Code-Plugin/mix.lock:9
[VG]: /Users/woj/Desktop/Repos/Domovoy-Git-Plugin/mix.exs:41
[VGl]: /Users/woj/Desktop/Repos/Domovoy-Git-Plugin/mix.lock:7
[VH]: /Users/woj/Desktop/Repos/Domovoy-Github-Plugin/mix.exs:33
[VHl]: /Users/woj/Desktop/Repos/Domovoy-Github-Plugin/mix.lock:7
[VL]: /Users/woj/Desktop/Repos/Domovoy-Linear-Plugin/mix.exs:34
[VLl]: /Users/woj/Desktop/Repos/Domovoy-Linear-Plugin/mix.lock:7
[VM]: /Users/woj/Desktop/Repos/Domovoy-Mise-Plugin/mix.exs:33
[VMl]: /Users/woj/Desktop/Repos/Domovoy-Mise-Plugin/mix.lock:7
[VS]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/mix.exs:35
[VSl]: /Users/woj/Desktop/Repos/Domovoy-Slack-Plugin/mix.lock:7
