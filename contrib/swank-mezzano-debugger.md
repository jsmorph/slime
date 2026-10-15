# Mezzano remote API

The `swank-mezzano-debugger` contrib exposes retained evaluation jobs, debugger stops, Listener commands, and documentation operations over SWANK.  Evaluation jobs establish retained debugging for their workers.  A separately created thread enters the same service through `mezzano.debug:call-with-debugger-service`.  Ordinary SWANK evaluation uses SLDB.

The [debugger guide](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md) describes supported operations and lifetime rules.  The [remote client guide](https://github.com/jsmorph/Mezzano/blob/debugging/tools/swank/README.md) provides executable session examples.  [Installation and operation](https://github.com/jsmorph/Mezzano/blob/debugging/doc/installation.md) covers the guest and network endpoint.

## Compatibility and transport

The guest needs Mezzano's debugger, evaluation, Command Processor, and Document Examiner modules, together with this contrib.  The protocol has no version negotiation.  A client must use the operations and result fields provided by its installed server.

Load the contrib through SWANK:

```lisp
(swank:swank-require :swank-mezzano-debugger)
```

RPCs use SWANK's existing S-expression transport.  Each exported function returns `(:ok value)` or `(:error reason)` for the protocol and service conditions listed below.  A successful SWANK dispatch therefore wraps the reply again:

```lisp
(:return (:ok (:ok value)) rpc-id)
(:return (:ok (:error reason)) rpc-id)
```

Malformed argument lists, unknown dispatch operations, and other ordinary Lisp errors can enter SWANK's debugger.  The contrib catches its protocol condition and `mezzano.debug:debugger-service-error`.  The host client reports other debugger entries as errors and requests SWANK's top-level abort.

SWANK permits arbitrary Lisp evaluation with the guest's authority.  Session names and tokens identify debugger objects within that connection.

## Sessions and tokens

The client creates a fresh name from 256 random bits outside the guest, encoded as 64 lowercase hexadecimal digits.  The guest records the current boot-event object with the session.  Creating and resuming a session are distinct operations.

One connection can attach to one session, and one session can attach to one connection.  When SWANK closes the connection, its hook closes the session's guest controller and clears the connection association.  Token tables survive that disconnect.  Resuming creates a new controller, so the client reacquires a lease before submitting another command.

SWANK completes connection registration before starting request handling.  With a sentinel thread, the accepting thread waits for the sentinel to add the connection and acknowledge it.  Session attachment can then check the registered connection without racing its startup.

Explicit session release clears its controller, connection, and token tables.  The first adapter operation after a boot change releases all old sessions.  The adapter retains used names, including released names, to reject reuse.  Stop records and their command history have independent guest lifetimes.

Tokens are proper three-element lists:

```lisp
(:stop session-name integer)
(:lease session-name integer)
(:frame session-name integer)
(:object session-name integer)
(:part session-name integer)
(:job session-name integer)
```

The integer indexes the session's token table.  Its numeric value conveys no authority outside that session.  Kind and session membership are checked before the guest validates boot identity and object lifetime.  A stop or job has a stable token within its session.  Each frame-list command creates fresh guest frame references and therefore new frame tokens.

A client that loses the reply to `open-session` must resume that name.  An absent session produces `:expired-session`.  A new attempt uses a fresh name.  Reusing the uncertain name for another open would obscure whether the earlier request succeeded.

## RPCs

These functions are exported from `SWANK/MEZZANO-DEBUGGER`.

| Function | Successful value |
|---|---|
| `open-session name` | The name of the newly created session. |
| `resume-session name` | The name of the existing session attached to this connection. |
| `request name operation &rest arguments` | The operation-specific value below. |
| `transient-request name operation &rest arguments` | The operation-specific value, after detaching the session. |

`transient-request` creates or resumes an attachment for one operation and releases its controller and connection association before replying.  It uses the same session lock and checks as the persistent APIs.  `:open-session` creates a session, and `:resume-session` verifies an existing session.  Both take no arguments and return its name.  All operations below are available except `:attach`.  Transient `:submit`, `:command-input`, and `:release-stop` take a **stop token** in place of the lease token and acquire control within the operation.  The adapter retains no token for that temporary lease.

Cleanup runs on successful completion, typed rejection, and ordinary Lisp error.  A rejection before attachment preserves another client's controller.  Accepted commands continue after detachment, and session handles, Listener state, jobs, and command results persist.  A connection using this entry point can remain open between requests without holding debugger control.  The persistent APIs retain their existing attachment and lease lifetime.

The attached connection sends `request` operations:

| Operation | Arguments | Successful value |
|---|---|---|
| `:stops` | Optional `include-closed`, default `NIL`. | A list of stop tokens.  Ordering is unspecified. |
| `:processes` | None. | Processes observations described below. |
| `:monitor-state` | Optional list of `(job-name start-offset)` pairs. | Listener, jobs with output increments, and all retained stops. |
| `:information` | Stop token. | Stop information. |
| `:attach` | Stop token. | A new exclusive control-lease token.  Closed stops can be attached for release. |
| `:submit` | Lease token, command ID, command operation, optional argument. | The accepted or previously accepted command ID. |
| `:result` | Stop token, command ID. | The command record.  Control ownership is unnecessary for this query. |
| `:command-output` | Stop token, command ID, start character offset, optional end. | Copied `(:start start :text string :end offset)`. |
| `:command-input` | Lease token, command ID, offset, text, optional `:eof`. | Accepted ending character offset. |
| `:release-stop` | Lease token. | `NIL`.  Removes a closed stop and its command history. |
| `:release-session` | None. | `NIL`.  Releases session storage and control. |

Stop information has this shape:

```lisp
(:id integer
 :state stop-state
 :depth positive-integer
 :prompt string
 :evaluation-environment evaluation-environment
 :evaluation-prompt string
 :thread thread-name
 :parent-id integer-or-nil
 :parent stop-token-or-nil
 :child stop-token-or-nil
 :generation integer
 :current-frame integer-or-nil
 :next-command-id integer)
```

Here `stop-state` is `:stopped` or `:closed`.  The evaluation environment is `:lexical` or `:dynamic`.  The evaluation prompt is `Eval (program): ` or `Eval (debugger): `, respectively.  The thread field in stop and job information is a bounded display string derived from the guest thread's name, using the label rules in [Processes](#processes).  Parent ID remains descriptive after parent release.  Parent and child tokens refer to retained records.  Command IDs start at zero and increase within a stop.

An illustrative request uses quoted token data inside SWANK's RPC form:

```lisp
(swank/mezzano-debugger:request
 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
 :information
 '(:stop "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" 1))
```

The example name and token are placeholders.

### Command results

`:result` returns:

```lisp
(:state command-state
 :operation command-operation
 :source source-string-or-nil
 :current-boot-p boolean
 :result operation-result
 :input-length nonnegative-integer
 :input-eof-p boolean
 :input-waiting-p boolean
 :output-length nonnegative-integer)
```

`:source` is a separate copy of the accepted source string for :EVALUATE, and NIL for other operations.  Querying a result does not execute its command or change frame selection or evaluation history.  Retained source remains available for prior-boot evaluations.  Other command arguments are not included.

`:current-boot-p` compares the command's acceptance boot with the current boot.  A restored running command can finish while this field remains `NIL`.  The states and their transitions are defined in [stop and command lifetimes](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#stop-and-command-lifetimes).

Each accepted debugger command owns character input and output independently of an evaluation job.  Its standard input uses that input stream.  Standard, error, and trace output share its output stream.  Query, debug, and terminal I/O combine the two.  Batch jobs and threads without jobs use the same command API.  A recursive command has separate streams, and a suspended parent retains its reader and buffered input.

Input appends at the accepted character offset while the command is pending or running.  An exact retained range recognizes replay, including after completion.  Conflicting or gapped input reports `:input-conflict`.  EOF belongs to one command.  New input after EOF, closure, or completion reports `:input-closed`.  Each later command starts with fresh input.  Input requires the stop's current control lease.  Output reads require a current stop token and report `:invalid-output-range` for invalid bounds.  Stream closure retains accepted text and output until stop release.

Commands predating this API retain their results and have no stream context.  Their lengths are zero, EOF is true, waiting is false, and output is empty.  Their input reports `:input-closed`.  A fresh current-boot handle can supply input to a restored running command without replaying its submission.  Prior-boot command submission remains rejected.  Snapshot acceptance for command I/O requires the tests stated in the debugger guide.

| Command operation | Argument | Result when state is `:returned` |
|---|---|---|
| `:inspect` | NIL, or (object-token start count). | Inspector page described below. |
| `:modify` | (part-token start count). | Page after storing the primary value of an expression read through QUERY-IO. |
| `:describe-object` | Object token or NIL. | DESCRIBE output string. |
| `:clear-inspection` | NIL or omitted. | NIL after releasing retained inspection references. |
| `:evaluate` | Source string containing one Lisp form. | List of printed values from the stop's current evaluation mode. |
| `:condition` | `NIL` or omitted. | Printed condition string. |
| `:restarts` | `NIL` or omitted. | List of `(:index integer :name string :description string :default-p boolean)`. |
| `:frames` | `NIL` or omitted. | List of `(:frame frame-token :function string)`, from the service activation toward older callers. |
| `:locals` | A frame token from this stop. | List of `(:index integer :name string :available-p boolean :value string-or-nil)`. |
| `:catches` | NIL for selected frame, or T for all retained frames. | Formatted active catch tags and available destination functions and hexadecimal byte offsets. |
| `:handlers` | NIL for selected frame, or T for all retained frames. | Formatted condition types, handler functions, and active/inactive state at debugger entry. |
| `:standard-value-warnings` | NIL or omitted. | Formatted corrections to the stop's reader/printer controls.  Preserves selection and evaluation history. |
| `:special` | (symbol-source environment), where source is a string and environment is :program or :debugger. | Formatted selected-frame special value or debugger binding, including unbound/unavailable states. |
| `:lexical-environment` | NIL or omitted. | Formatted inherited lexical variable and local-function values, or explicit missing ancestry/storage.  Preserves selection and evaluation history. |
| `:use-lexical-environment` | NIL or omitted. | Selects live frame lexical evaluation and returns `Eval (program): `. |
| `:use-dynamic-environment` | NIL or omitted. | Selects null-lexical-environment evaluation and returns `Eval (debugger): `. |
| `:toggle-evaluation-environment` | NIL or omitted. | Toggles the mode once and returns its evaluation prompt. |
| `:bindings` | NIL, or (all-p matching-string), where all-p is NIL or T. | Formatted special bindings established by the selected frame or all retained frames. |
| `:function` | NIL or omitted. | Printed associated function after assigning the debugger level's * value. |
| `:compiled-code` | NIL or omitted. | Complete selected executing-function disassembly as a string. |
| `:instruction` | NIL or omitted. | Selected instruction as a string, with saved-caller or interrupted-PC header, or an unavailable message. |
| `:arglist` | NIL or omitted. | String describing the selected executing function's stored lambda list, or explicitly reporting unavailable metadata. |
| `:current-frame` | NIL or omitted. | Selected frame inspection: `(:index integer :function string :locals local-records)`. |
| `:select-frame` | Nonnegative frame index. | Selects the absolute index and returns its inspection. |
| `:next-frame` | Nonnegative count. | Moves toward older callers and returns the selected frame inspection. |
| `:previous-frame` | Nonnegative count. | Moves toward newer callees and returns the selected frame inspection. |
| `:top-frame` | NIL or omitted. | Selects index zero and returns its inspection. |
| `:bottom-frame` | NIL or omitted. | Selects the oldest retained frame and returns its inspection. |
| `:invoke-restart` | Restart index. | List of printed values if the restart returns to the command.  Invocation supplies zero arguments. |
| `:invoke-restart-interactively` | Restart index. | List of printed values if the restart returns.  Its interactive function obtains arguments through QUERY-IO. |
| `:invoke-restart-with-arguments` | Restart index, or NIL/omitted for default CONTINUE. | Prompts through QUERY-IO for one Lisp expression whose primary value is a finite proper argument list, evaluates it, and applies INVOKE-RESTART.  Returns a list of printed values if the restart returns. |
| `:abort` | NIL or omitted. | Invokes the innermost captured CL:ABORT restart.  A returning restart supplies printed values. |
| `:return` | NIL or omitted. | Prompts for an expression supplying all return values, displays them, and asks for confirmation.  Cancellation returns `"Return cancelled."`.  Successful transfer records `:UNWOUND` and closes the stop.  Native x86-64 condition-stop support and limits follow the [Frame Return reference](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#frame-return). |
| `:proceed` | NIL or omitted. | Invokes the first captured CL:CONTINUE restart interactively.  A returning restart supplies printed values. |
| `:help` | NIL or omitted. | Guest debugger command descriptions as a string. |

A printed Lisp `NIL` is the string `"NIL"`.  An unavailable local has `:available-p NIL` and `:value NIL`.  Restart names and local names are printed representations and can include package prefixes.  Local indices identify entries within that returned list.  The current API accepts frame tokens for inspection and evaluates expressions against the selected frame.  Assignment within lexical evaluation writes its live binding.

Each outer stop starts in lexical mode, and a child inherits its parent's mode.  Later choices are independent.  The three environment operations preserve frame selection and history and reject non-NIL arguments before consuming a command ID.  Accepted toggle replay returns the stored prompt without toggling again.  Mode survives controller replacement and parked image restoration.  Dynamic evaluation uses the stop's reader/printer controls and the stopped thread's other debugger-time special bindings with a null lexical environment, allowing evaluation without selected-frame scope metadata.  Lexical evaluation uses the selected established x86-64 frame's original special-binding cells, including through called compiled functions.  Dynamic evaluation retains the point-of-error bindings.  New LET/PROGV bindings shadow the selected environment normally.  A child debugger starts from its condition's active bindings.  Each command uses the standard stream bindings described above.  Streams environment inspection remains separate work.

STANDARD-VALUE-WARNINGS returns the stop's corrections to `*PACKAGE*`, `*READ-BASE*`, `*PRINT-BASE*`, and `*READ-DEFAULT-FLOAT-FORMAT*` in occurrence order.  Before each command, invalid or unbound values receive COMMON-LISP-USER, 10, 10, or SINGLE-FLOAT respectively.  Valid values and debugger edits persist within the stop.  Child edits are independent.  Command return or nonlocal exit restores program bindings, and stop closure releases the saved controls and warnings.  The display distinguishes bound NIL from [unbound].  With no corrections it returns "There were no standard values which required binding".  A non-NIL argument rejects :UNEXPECTED-ARGUMENT before acceptance.  Replay compares arguments with EQL and returns retained text without printing again.  Printer errors enter a child under the command ABORT boundary.  Selection and all nine histories remain unchanged.  Parked restoration retains the saved controls and warnings.  The [standard-value reference](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#standard-values) specifies validity rules and tested scope.

SPECIAL copies its symbol source and reads exactly one symbol under the stop's validated package, with *READ-EVAL* NIL.  Program reads the live special cell at the selected established x86-64 frame, following continuation-stack segments.  Debugger reads this level's nine retained history values for their symbols and current command bindings for other symbols, including reader/printer controls and the temporary - binding.  Bound NIL, [unbound], and [unavailable] remain distinct.  Its result names the symbol and environment and identifies the Program frame.  Selection, evaluation mode, history, and program cells remain unchanged.  Malformed options report :INVALID-SPECIAL-OPTIONS.  :STREAMS is recognized but reports :UNSUPPORTED-SPECIAL-ENVIRONMENT.  Both reject before command-ID acceptance.  Reader failures, extra forms, non-symbol input (:EXPECTED-ONE-SYMBOL), and printer errors enter a child under the existing command ABORT boundary.  Replay compares copied arguments with EQUAL and returns the retained outcome without reading or printing again.  Streams inspection and ARM64 execution remain separate work.

EVALUATE copies its accepted source.  Reading binds `*READ-EVAL*` to `NIL` and requires exactly one form.  Execution uses the selected special environment, preserving the stop's reader/printer controls, histories, streams, and disabled program condition handlers.  Lexical lookup includes variables, local functions, symbol macros, and local macros.  Lexical-variable writes check source declarations and storage types.  Special-variable writes use the runtime symbol-value setter.  Each stop owns separate standard expression/value histories.  Reader, evaluator, printer, unavailable-scope, and unavailable-binding conditions enter a child debugger.  Its command ABORT abandons the expression.

A nonstring argument rejects :INVALID-SOURCE before acceptance.  Lexical mode reports :UNAVAILABLE-LEXICAL-SCOPE for missing scope metadata during execution and :UNAVAILABLE-BINDING for missing binding storage.  An unavailable physical special-stack boundary reports :UNAVAILABLE-SPECIAL-ENVIRONMENT during execution.  It does not substitute a younger or global binding.  Unsupported source BLOCK/GO transfer reports :UNAVAILABLE-CONTROL-TARGET.  Frame-backed Lisp bindings require the same registered stop, generation, stopped activation, and owning thread.  They persist with that activation across image restoration.  Another thread reports :FOREIGN-FRAME-THREAD.  Stop exit or release retains the ordinary stop/frame errors.  Client frame references keep their boot-scoped lifetime.  See the [frame-evaluation reference](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#frame-evaluation).

FUNCTION assigns only the level's * history slot before printing its associated function.  The assignment survives printer Abort.  Selection and the other eight history slots remain unchanged.  A generated discriminator can report its associated generic function.  Genera's + locative assignment remains unsupported.

COMPILED-CODE and INSTRUCTION resolve the executing function from the retained frame PC, preserving an active definition after redefinition.  COMPILED-CODE returns the complete code with labels, hexadecimal object-relative byte offsets, instruction bytes, and annotations.  INSTRUCTION resolves the decoded span containing the saved return-PC-minus-one or exact interrupted PC and labels that distinction.  Missing locations and undecoded bytes remain explicit.  These operations preserve selection and all history.  All three operations reject non-NIL arguments with :UNEXPECTED-ARGUMENT before acceptance and compare replay arguments with EQL.  Printers run under the existing command ABORT boundary.  Explicit function/range arguments and other Genera code-display options remain unsupported.  See the [function and instruction reference](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#functions-and-instructions) for tested stopping states and invalid-argument helper identity.

ARGLIST reads the executing compiled function's metadata, preserving the active version after redefinition.  An empty lambda list prints NIL.  Missing metadata produces an unavailable message.  The operation preserves selection and expression/value history.

BINDINGS matches a case-sensitive literal substring of SYMBOL-NAME.  NIL means selected frame with an empty filter.  The service copies the matching string and compares accepted arguments with EQUAL for replay.  Malformed options reject :INVALID-BINDING-OPTIONS before acceptance.  It preserves selection and expression/value history.  Bound NIL prints NIL, and an unbound cell prints [unbound].  Repeated bindings remain visible in inner-to-outer order.  The implementation supports established x86-64 condition-stop frames and reports unsupported frame layouts as unavailable.  A printer condition enters a child debugger under the command's ABORT restart.

The retained service disables application condition handlers during command execution, including printers, input, and restart functions.  Handlers established by the command's evaluated form or called function work normally.  Unhandled conditions enter a child debugger.  Leaving the debugger restores the application's handlers before older application cleanup runs.

CATCHES lists active tags established by the selected frame or all retained frames, preserving repeated tags in inner-to-outer order.  Destinations identify the executing compiled function and a hexadecimal byte offset from the function object's start.  Code starts at offset 16.  The runtime %CATCH function receives the nonlocal transfer and returns the supplied values to its caller.  Missing control metadata prints Destination unavailable while preserving the tag.  Invalid options reject :INVALID-CATCH-OPTIONS before acceptance.  Replay compares the Boolean argument with EQL.  Selection and expression/value history remain unchanged.  Established x86-64 condition-stop frames are supported.  Interrupted frames and ARM64 report unavailable locations.  A tag printer condition enters a child debugger under the command's ABORT restart.

HANDLERS lists clusters established by the selected frame or all retained frames.  It distinguishes SIGNAL's temporary deactivation from a new binding, preserving cluster identity and source order.  It reports the program's active state at debugger entry even though command execution disables application handlers.  Invalid options reject :INVALID-HANDLER-OPTIONS before acceptance.  Replay compares the Boolean argument with EQL.  Selection and expression/value history remain unchanged.  Established x86-64 frames are supported; unsupported layouts report unavailable locations.  A printer condition enters a child debugger under the command's ABORT restart.

Each stop owns its current-frame index, initially zero.  Closed stops report NIL.  Selection survives controller replacement and image restoration.  A nested stop has independent selection.  Movement changes the index on the target thread before printing.  If printing enters a child debugger, aborting that operation preserves the parent's selected index.  Local records have the same shape as :locals results.  :locals leaves selection unchanged.

An invalid index, count, or out-of-range movement reports :invalid-frame before acceptance, preserving selection and the next command ID.  A zero movement count inspects the current frame.  Identical accepted relative-movement replay returns the original command without moving again.

At most one restart has `:default-p T`: the first captured restart named CL:CONTINUE.  If no such restart exists, `:proceed` or default `:invoke-restart-with-arguments` rejects `:no-continue-restart` before acceptance and leaves the next command ID unchanged.  An explicit restart index can still be invoked.

Explicit argument expressions read with `*READ-EVAL*` NIL and evaluate on the stopped thread in its current dynamic environment and a null lexical environment.  NIL supplies zero arguments.  The selected restart requires no interactive function for this operation.  Reader, evaluation, malformed-list, and invocation errors enter a child debugger under the command's ABORT restart.  The expression uses the existing retained input stream and offsets.  If its read unwinds, cleanup clears buffered input while preserving the accepted-input record.  Replaying an accepted command or already supplied input does not invoke it again.

A nonlocal restart exit produces `:unwound`.  The application result must be observed separately.  `:pending` and `:running` indicate incomplete execution.  `:cancelled` and `:expired` are terminal states with no operation result.  A `NIL` result alone is insufficient to determine command state.

Printing runs on the stopped thread and can enter a child stop.  The parent remains busy until the child resolves.  The protocol currently requires polling to discover command completion and child stops.

### Inspector commands

`:inspect` accepts NIL for the debugger level's * value, or `(object-token start count)`.  `:modify` accepts `(part-token start count)`.  Start is a nonnegative integer.  Count ranges from 1 through 64.  NIL inspection uses start 0 and count 32.

Both operations return a property list:

```lisp
(:object object-token :title string :type string
 :start integer :end integer :total integer :count integer
 :parts ((:label string :bound-p boolean :value string-or-nil
          :object object-token-or-nil :part part-token-or-nil) ...))
```

End is exclusive.  Count is the requested page size.  Start clamps to the observed total when the container shrinks.  Each bound value, including NIL, has an object token.  An unbound component has NIL for :VALUE and :OBJECT.  A writable component has a part token.

Modify reads its expression through the evaluation job's existing input stream, evaluates it in the selected frame, stores its primary value, and returns a fresh page.  It uses the same command IDs, retained input offsets, nested debugger, and replay rules as other debugger operations.  A successful store survives a later printer error.  Replaying that command ID preserves its recorded outcome.

`:describe-object` accepts an object token or NIL for the debugger level's * value and returns the DESCRIBE output as a string.  `:clear-inspection` accepts NIL and releases the stop's inspection values and places.  It returns NIL.  Recorded command text remains available.  Evaluation history can retain the same values independently.

The adapter validates token kind and session membership.  The guest then validates stop, generation, boot, and retained ID.  Invalid ranges reject with :INVALID-INSPECTION-RANGE before command acceptance.  A cleared reference rejects with :RELEASED-INSPECTION-REFERENCE.  A wrong stop, kind, or closed generation rejects with :EXPIRED-INSPECTION-REFERENCE.  Old-boot handles reject with :EXPIRED-STOP, and released stops reject with :RELEASED-STOP.  Stale component places and newly read-only places signal :EXPIRED-INSPECTION-PART and :READ-ONLY-INSPECTION-PART during execution.

Inspect and Modify copy their three-element arguments on acceptance and compare replayed lists with EQUAL.  Object and part references in those lists must be the same guest references.  Describe compares its reference with EQL.  Result records contain printed data and opaque references.  Raw objects and place descriptors reside in the stop's retention tables.

### Reconnection and duplicate submission

After a lost reply, resume the session, reacquire control, and query the original command ID.  Repeating an accepted submission in the same boot returns its ID without executing it again if the operation and argument match.  Guest comparison uses `EQ` for the operation, `EQUAL` for an `:evaluate` source string or an `:inspect`/`:modify` argument list, and `EQL` for other arguments.  For `:locals`, the original token must resolve to the original frame-reference object.

Duplicate recognition still requires a valid lease.  A new command uses `:next-command-id`, and a busy stop rejects it.  Closed stops retain outcomes and recognize matching prior submissions until explicit release.

After image restore, create a fresh session.  Old session tokens are invalid.  Historical command results can be queried through newly discovered stops.  A frame from a historical result remains expired even if it receives a new session token.  Prior-boot commands reject resubmission.  The [restore rules](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#disconnect-and-restore) describe object lifetimes and supported restore states.

## Monitor state

`:monitor-state` gathers the Listener information, jobs, and active and closed stops in one request.  Each supplied offset is a nonnegative Lisp character offset for the named job.  An omitted job starts at zero.  Duplicate names report `:duplicate-output-offset`.  An offset beyond that job's output length reports `:invalid-output-range`.  Offsets for jobs that have been released or do not exist are ignored.

```lisp
(:listener listener-information
 :jobs ((:token job-token :information job-information
         :output (:start integer :text string :end integer)) ...)
 :stops ((:token stop-token :information stop-information) ...))
```

Output text shares a 65,536-character budget across the response.  Each row's `:output-length` records its full sampled length.  The delivered `:end` can be smaller.  The next request supplies each returned end offset to continue reading.  Empty increments return an empty string.  A completed job can still have unread output.  Tokens retain their existing session identity.  The operation acquires no control leases and creates no evaluation jobs.

The adapter sorts unread rows by supplied offset, divides the remaining budget among the remaining unread rows, and returns rows in their original order.  A short row leaves its unused share for later rows.  When unread rows outnumber the budget, lower-offset rows receive characters first.  Advancing returned offsets allows other rows to receive output on later requests.  No output is discarded and no read cursor is retained in the guest.

The complete encoded reply must fit SWANK's six-digit hexadecimal length header, whose maximum payload is 16,777,215 bytes.  The character budget bounds output text.  Metadata, including printed values, remains subject to that message limit.  The individual job-information and ranged job-output operations remain available.

The adapter serializes the request under its session lock.  Guest service reads use their existing locks.  Jobs, output, and stops can change between reads, so the response contains observations taken during the request.  A job or stop released by a direct guest operation during enumeration is omitted.  A released related stop is omitted from its job's stop list or replaced by NIL in a parent or child field.  Other service errors propagate.  Debugger command results remain available through `:result`.

## Processes

`:processes` takes no arguments and calls `mezzano.debug:process-summary`.  Its response has this shape:

```lisp
(:title "Processes"
 :run-time-units-per-second integer
 :threads ((:name string
            :state scheduler-state
            :priority priority
            :wait-kind keyword-or-nil
            :wait string-or-nil
            :run-time nonnegative-integer
            :stops (stop-token ...)) ...))
```

The supervisor samples each row's scheduler fields under its global thread lock.  Thread enumeration and retained-stop association occur separately, so the response describes live observations rather than one atomic system snapshot.  Threads can exit while the query runs.  Rows sampled after death are omitted.  Idle threads are absent from the supervisor's live-thread list.

Scheduler states are `:active`, `:runnable`, `:sleeping`, `:stopped`, `:waiting-for-page-read`, `:waiting-for-page-write`, and `:pager-request`.  Priorities are `:supervisor`, `:high`, `:normal`, `:low`, and `:idle`.  Run time is the recorded processor-time accumulator divided by `:run-time-units-per-second` to obtain seconds.  An active scheduling interval enters that accumulator at switch-out.  CPU utilization is unavailable in this response.

Wait kinds classify sleeping wait items as `:mutex`, `:condition-variable`, `:event`, `:wait-queue`, `:reason`, or `:object`.  Paging uses `:page-read` or `:page-write`.  Pager calls use `:pager-request`.  Other states return NIL wait fields, even when an old wait item remains recorded on the thread.

Names and wait descriptions contain at most 160 characters.  Lisp formats strings, symbols, characters, fixnums, and bounded lists without invoking arbitrary object printers.  ASCII control characters become spaces.  Unsupported objects appear as `[object]`, functions in pager calls as `[function]`, and shortened descriptions end with `[truncated]`.

Thread names can coincide.  The guest associates stops by thread identity and includes every retained active stop, including nested stops, ordered by stop ID.  A retained debugger stop usually has scheduler state `:sleeping`.  Stop tokens use the existing session storage and lifetime rules.  The query creates no thread handles, evaluation jobs, or control leases.

Stop encoding validates each captured handle.  A direct guest release during encoding returns `:released-stop` for the query.  A subsequent query omits that stop.  Adapter requests serialize under the session mutex, so another adapter request cannot release a stop during encoding.

## Evaluation jobs

Job operations use the same attached session and SWANK transport.  Source forms execute in order in the requested package with a fresh standard readtable.  Package changes affect subsequent forms within that job.  Jobs belong to the guest and continue after connection loss or session release.  Any attached session can discover jobs, read their output and results, and release terminal jobs.  Associated debugger stops retain the exclusive-controller rules above.

| Operation | Arguments | Successful value |
|---|---|---|
| `:start-evaluation` | Client-generated name, source string, and optional `:package`, `:input`, and `:interactive` keywords. | Job token.  Defaults are `"CL-USER"`, an empty input string, and batch mode. |
| `:jobs` | None. | Tokens for all unreleased jobs. |
| `:job-information` | Job token. | Job information below. |
| `:job-output` | Job token, start character offset, optional end offset. | `(:text string :end integer)`.  End defaults to the current output length. |
| `:job-input` | Job token, character offset, text, and optional `:eof` flag. | Ending character offset of accepted or recognized input. |
| `:interrupt-job` | Job token and interrupt ID. | Accepted or previously accepted interrupt ID. |
| `:job-interrupt-result` | Job token and interrupt ID. | Interrupt record below. |
| `:release-job` | Job token. | `NIL`.  Releases a terminal job's data. |

Job information has this shape:

```lisp
(:name string
 :state job-state
 :thread thread-name
 :current-boot-p boolean
 :stops (stop-token ...)
 :next-interrupt-id integer
 :interruptible-p boolean
 :interrupt-id integer-or-nil
 :input-mode input-mode
 :input-length integer
 :input-eof-p boolean
 :input-waiting-p boolean
 :values (printed-value ...)
 :output-length integer)
```

States are `:running`, `:returned`, `:aborted`, and `:unwound`.  A retained condition or printer stop leaves the job `:running`.  Normal completion records `:returned`, including zero values as an empty value list.  Reaching the job's ABORT restart clause after cleanup records `:aborted`.  Cleanup can signal another condition or supersede the transfer, including returning control to the computation.  Another exit from the worker records `:unwound`.  The value list contains strings printed by the worker.  The adapter runs no application printer to construct this reply.

Input mode is `:batch` or `:interactive`.  Batch input is a supplied string followed by EOF.  Interactive input waits when its accepted text is exhausted until more text or explicit EOF arrives.  `:input-length` counts accepted characters, `:input-eof-p` records EOF after those characters, and `:input-waiting-p` indicates a pending input read.  EOF state is independent of stream closure at job completion.

Input submission appends text at the accepted length.  A range that already matches retained input succeeds without appending, including after completion.  A gap, mismatch, or partial overlap reports `:input-conflict`.  EOF can accompany appended text or an empty append at the accepted end.  Repeating EOF requires an already recorded EOF at that end.  Further appends after EOF, stream closure, or job completion report `:input-closed`.  Batch jobs reject input submission with `:input-not-interactive`.  Any attached session can supply input.

Output offsets count Lisp characters.  Reads copy retained output without consuming it, so repeated reads at the same range return the same text.  Output and results remain until release.  Both job streams close at completion.

A name contains 64 lowercase hexadecimal digits generated from 256 host random bits.  Repeating an identical creation request in the same boot returns the existing job and its stable session token.  Changing source, package object, initial input, or input mode reports `:request-conflict`.  Releasing the job retains its used name, so later creation under that name reports `:released-job`.

Restored jobs require fresh session tokens.  Information reports whether their original submission belongs to the current boot.  Replaying an earlier-boot submission reports `:request-conflict`.  The [restore rules](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#disconnect-and-restore) describe expiration and resumption.

### Interrupt records

`:job-interrupt-result` returns:

```lisp
(:state interrupt-state
 :current-boot-p boolean
 :result cancellation-reason-or-nil)
```

IDs start at zero and increase per job.  Any attached session can submit or query requests.  Same-boot replay of an accepted ID returns that ID without another delivery, including after job completion.  Earlier-boot replay reports `:request-conflict`.  One request can be pending per job.  A running interruption permits a nested request while its debugger executes a command.  Job information reports the innermost outstanding :INTERRUPT-ID and sampled :INTERRUPTIBLE-P.  Delivery validates the target's state again.

States are `:pending`, `:running`, `:returned`, `:unwound`, `:cancelled`, and `:expired`.  Delivery uses a thread foothold and respects inhibition.  The retained stop offers CONTINUE and the job's ABORT restart.  Continuing records `:returned`.  A nonlocal exit records `:unwound`, independently of the job's final outcome.

Cancellation records `:already-stopped` when delivery finds a debugger waiting for a command.  Delivery during an executing command enters a child stop inside the command's ABORT boundary.  CONTINUE resumes the operation.  Its command ABORT abandons the operation and preserves the original stop.  A preceding running interrupt becomes the reported :INTERRUPT-ID again after the nested request finishes.  Completion cancels undelivered requests with `:job-complete`.  A queued request selected after restore expires.  A restored running interrupt stop can continue while `:current-boot-p` remains NIL.  The [debugger guide](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#interruption) specifies the interruption lifetime.

## Rejection reasons

The following reasons appear in `(:error reason)`.  Earlier validation can determine which error is reported.  For example, an old lease's stop handle can cause `:expired-stop` before controller validation.

| Reason | Meaning |
|---|---|
| `:invalid-session-name` | An open request supplied a name outside the required format. |
| `:session-name-used` | A session record already uses that name, including a released record. |
| `:expired-session` | The session is absent, released, or from an earlier boot. |
| `:duplicate-output-offset` | A monitor-state request supplies more than one offset for a job name. |
| `:missing-topic` | A documentation topic is absent from the current catalog. |
| `:invalid-private-document` | A private document has invalid reader syntax, record shape, or topic-reference data. |
| `:private-document-io-error` | A private-document read reports a file or stream error. |
| `:closed-connection` | The opening/resuming connection is absent from SWANK's live connection list. |
| `:connection-attached` | The opening/resuming connection already has a session. |
| `:session-attached` | Another connection remains attached to the requested session. |
| `:wrong-connection` | A request arrived through a connection other than the session's attached connection. |
| `:invalid-handle` | The token's shape, kind, session, or table entry is invalid. |
| `:unexpected-arguments` | Session release or transient open/resume received arguments. |
| `:transient-attachment` | Transient requests cannot return a control lease through `:attach`. |
| `:expired-stop` | The guest stop handle has the wrong kind or boot identity. |
| `:released-stop` | The guest stop record has been removed. |
| `:expired-controller` | The controller has the wrong kind, was closed, or belongs to an earlier boot. |
| `:expired-control` | The lease has the wrong kind or no longer owns the stop. |
| `:expired-frame` | The frame has the wrong kind, stop, generation, or active lifetime. |
| `:already-controlled` | A current-boot lease already owns the stop. |
| `:stop-active` | Release was requested for an active stop. |
| `:request-conflict` | A reused command ID has another operation/argument or belongs to an earlier boot, an interrupt ID belongs to an earlier boot, or a job submission conflicts with its recorded source/package/input/mode or boot. |
| `:request-order` | A new command or interrupt ID differs from the corresponding next ID. |
| `:stop-closed` | A new command targets a closed stop. |
| `:stop-busy` | A pending command, active command, or child stop prevents a new command. |
| `:unexpected-argument` | A no-argument debugger command received a non-NIL argument. |
| `:invalid-frame` | The frame index, movement count, or resulting target is invalid. |
| `:invalid-restart` | The command argument is outside the retained restart-index range. |
| `:no-continue-restart` | Default Proceed has no captured CL:CONTINUE restart.  Select an explicit restart index. |
| `:unknown-operation` | The submitted guest command operation is unsupported. |
| `:unknown-command` | No command with that ID is recorded for the stop. |
| `:invalid-job-name` | A job name does not have the required format. |
| `:listener-busy` | A new Listener submission targets a Listener with a running job. |
| `:invalid-package` | The requested evaluation package does not exist. |
| `:expired-job` | The guest job handle has the wrong kind or boot identity. |
| `:released-job` | The job was released, including an attempt to reuse its name. |
| `:job-complete` | A new interruption targets a completed job. |
| `:interrupt-busy` | The job has a pending request, or its running interruption has no executing debugger command. |
| `:self-interrupt` | A new request targets the calling thread. |
| `:unknown-interrupt` | The job has no record for that interrupt ID. |
| `:job-active` | Release was requested while the job was running. |
| `:invalid-output-range` | The requested character range lies outside retained output. |
| `:input-not-interactive` | Input submission targets a batch job. |
| `:input-conflict` | The submitted offset/text/EOF conflicts with retained input. |
| `:input-closed` | New input was submitted after EOF, stream closure, or job completion. |

The host client retries `:session-attached` until its connection deadline, allowing the previous connection's close hook to finish.  Other rejections are reported as `lispm-debugger-client:request-error`, whose reason is available through `request-error-reason`.

## Lisp Listener operations

Each session creates a `MEZZANO.COMMAND-PROCESSOR` Listener on its first Listener operation.  Its package and pathname default survive connection closure.  Session release and a new boot retire that Listener identity.  Accepted jobs retain their own execution and remain discoverable independently.

| Operation | Arguments | Successful value |
|---|---|---|
| `:listener-information` | None. | A property list with `:package`, `:mode`, `:prompt`, `:busy-p`, `:active-job`, `:debugger`, `:default-pathname`, and `:herald`. |
| `:start-listener` | Name, source, and optional `:interactive`. | Ordinary retained job token. |
| `:listener-assistance` | Source, cursor, action, and optional `:context` and `:presentation`. | Classification, completion, argument context, or debugger action plan. |

Listener information reports `:active-job` as the current running evaluation's name, or NIL when the Listener is idle.  `:busy-p` and `:active-job` are sampled together under the service lock.  A retained debugger stop leaves its evaluation running and its Listener busy.

Only one Listener job may run per session.  A new submission while it runs reports `:listener-busy`.  Identical creation replay is recognized before that check.  A Listener job's identity includes its Listener, source, and interactive setting.  Replay checks Listener identity even after Set Package changes its current package.  Ordinary `:start-evaluation` remains independent.

Assistance actions are `:inspect`, `:space`, `:complete`, `:help`, `:parse`, and `:insert`.  Context defaults to `:listener` and also accepts `:debugger`.  Cursor positions count Unicode characters.  Insert takes a pathname string in `:presentation` and checks that the current argument accepts a pathname.  The reply contains `:kind`, `:text`, `:cursor`, `:prompt`, `:default`, `:expected-type`, `:help`, `:candidates`, `:complete-p`, and `:error`.  Candidate entries contain `:label`, `:text`, `:cursor`, and `:help`.  A `:parse` reply includes `:command` and `:argument`.  Debugger replies also identify `:operation` and, when needed, `:needs-frame`, `:display`, `:local-index`, and `:select-frame`.

Job information adds `:listener-result`, `NIL` for ordinary jobs.  A Listener result contains `:kind` (`:command` or `:form`), optional `:command`, `:effects`, and `:presentations`.  An input error adds `:error` and writes that message to job output.  Runtime conditions enter the retained debugger.  The clear effect is `(:operation :clear-output-history)`.  Pathname presentations contain `:start`, `:end`, `:type :pathname`, and `:value`.  Their character offsets address the job's output string.

Herald presentations contain `:start`, `:end`, `:type :herald`, and `:herald`.  The character offsets delimit the plain-text herald in job output.  The payload has `:title`, `:facts`, `:detailed-p`, `:systems`, and `:help`.  Facts and help are lists of lines.  Each line contains inline records with `:kind` (`:text`, `:emphasis`, or `:key`) and `:text`.  System records contain `:name` and `:version`, with NIL for an undeclared version.  The brief herald has NIL for `:detailed-p` and `:systems`.

Listener information returns a fresh detailed payload in `:herald`.  Show Herald records its captured payload with the retained command output.  Replaying creation or querying that job preserves the captured values.

The [Command Processor guide](https://github.com/jsmorph/Mezzano/blob/debugging/doc/command-processor.md) lists commands, argument types, completion behavior, and compatibility limits.

## Document Examiner operations

`:document-query (action &key topic (query "") (mode :substring) adjacent)` queries the guest documentation catalog.  Actions are `:catalog`, `:topic`, `:search`, `:contents`, and `:overview`.  Topic arguments accept a registered topic ID or an unambiguous title.  Search modes are `:exact`, `:initial`, and `:substring`.  Multiple terms use AND.  `:adjacent T` also requires order and adjacency within one title or keyword phrase.

Catalog, search, and contents results contain `:title` and `:topics`.  The catalog also returns `:search-options` with supported `:modes` (each containing `:value` and `:label`), default `:mode`, and `:adjacent`.  Search also reports `:mode` and `:adjacent`.  Topic summaries contain `:id`, `:title`, `:book`, `:type`, `:parent`, `:depth`, `:keywords`, and `:source`.  Contents depths are relative to the requested topic.  A topic result contains `:topic` and `:sections`, with each section carrying its summary, relative `:level`, and `:blocks`.  Overview returns the selected `:topic`, `:parent`, `:ancestors`, `:siblings`, `:children`, and `:related` topics.

Blocks use `:kind :paragraph`, `:code`, `:list`, or `:table`.  Paragraphs contain inline `:content`.  Code contains `:text` and `:language`.  Lists contain `:ordered`, inline `:items`, and source-indentation `:depths`.  Tables contain inline-cell `:header` and `:rows`.  Inline records use `:kind :text`, `:code`, `:emphasis`, `:strong`, or `:link`, with `:text`.  A link identifies a registered `:topic` or a `:url`.  A topic link also supplies its canonical `:title` and `:book`, independently of the displayed link text.

`:document-assistance (source cursor action)` accepts `:inspect`, `:space`, `:complete`, `:help`, or `:parse`.  It returns the Listener assistance replacement, prompt, candidates, completion, and error fields.  Cursor offsets count Lisp characters.  Parsed commands add string `:operation` and optional string `:argument`.  Viewer operations return browser actions.  Catalog reading, search, parsing, and topic completion execute in Lisp.

`:save-private-document (name pathname topics)` validates the pathname and shape of the ordered string-reference list, then starts a retained evaluation job that writes the private document.  `name` follows the ordinary evaluation-name format.  The result is an ordinary job token.  The worker returns the canonical pathname as its single value.  I/O errors enter the retained debugger.  Repeating the same name, canonical pathname, and original ordered reference strings in the same boot returns the original job, independently of later catalog changes.  The worker resolves topic references before opening the file.  Changed arguments report `:request-conflict`.  File writes use the guest filesystem's `:supersede` behavior.  A write interrupted by an I/O error or machine failure can leave an incomplete file.

`:read-private-document (pathname)` returns `(:pathname canonical-namestring :topics topic-summaries)`, preserving reference order.  It reads one versioned Mezzano record with reader evaluation disabled, rejects malformed and circular lists, trailing forms, and unknown topics, and retains no job.  Pathname and file-format errors follow ordinary SWANK error handling.  An empty pathname selects `SYS:HOME;PRIVATE.PSB`.  Nonempty pathnames use normal guest pathname merging.  `:document-assistance` supplies `save-private-document`, `read-private-document`, `load-private-document`, and `hardcopy-private-document` plans with their canonical pathname in `:argument`.  The browser uses the read result to display topics, add deferred bookmarks, or print unique referenced sections.  Printing preserves the viewer state.  Save retains its original request arguments and typed command through browser reload and replay after an uncertain reply.  The browser uses its print dialog for hardcopy output.

An absent topic produces `:missing-topic` from `:document-query`, and the session remains usable.

Documentation queries use the session's normal request lifetime and retain no evaluation job.  A catalog rebuild through `MEZZANO.DOCUMENT-EXAMINER:LOAD-CATALOG` replaces the catalog after all source files have been read.  Viewer state belongs to the browser.  The [Document Examiner guide](https://github.com/jsmorph/Mezzano/blob/debugging/doc/document-examiner.md) describes reading, searching, viewers, bookmarks, and private documents.

## Connection registration tests

The Mezzano test holds a registration request in an isolated sentinel and checks that MAKE-CONNECTION waits for acknowledgment.  It also tests direct registration and registration from the sentinel thread.  It keeps its connection and thread registries separate from the running server.

```lisp
(load (compile-file "SYS:HOME;SLIME;CONTRIB;SWANK-MEZZANO-REGISTRATION-TEST.LISP"))
(swank-mezzano-registration-test:run)
```

## Debugger command recovery and Listener context

Each debugger command establishes an ABORT restart.  An error during the command can enter a child stop.  Invoking that restart abandons the command and returns to the enclosing stopped computation's debugger loop.  The abandoned command records :UNWOUND.  The parent stop remains :STOPPED.

SUBMIT accepts :ABORT and :HELP without arguments.  :ABORT invokes the innermost captured CL:ABORT restart.  :HELP returns a string from the guest debugger command definitions.  :INVOKE-RESTART-INTERACTIVELY accepts the same zero-based restart index as :INVOKE-RESTART and calls the restart's interactive argument reader.  Both operations return printed multiple values when the restart returns, or record :UNWOUND on a nonlocal exit.  Existing :INVOKE-RESTART behavior supplies zero arguments.

Stop information includes one-based :DEPTH and the nesting :PROMPT.  LISTENER-INFORMATION and MONITOR-STATE's :LISTENER include :DEBUGGER.  Its value is NIL when the Listener has no retained stop, or a property list containing :STOP (a typed stop token), :DEPTH, and :PROMPT for the innermost stop belonging to its active job.  The guest selects that stop under the service lock.

For interactive evaluations, restart argument readers use retained QUERY-IO, and JOB-INPUT supplies their input.  The debugger command remains :RUNNING during the read.  Conditions in the reader enter child stops.  :INVOKE-RESTART-WITH-ARGUMENTS reads and evaluates a Lisp expression returning the argument list, including when the restart has no interactive function.

## Transient ownership tests

Compile and load `contrib/swank-mezzano-transient-test.lisp` in Mezzano, then call `swank-mezzano-transient-test:run`.  The fixture uses a private adapter session registry and simulated registered connections, plus one real retained evaluation and condition stop.  It checks persistent ownership, transient detachment after results and errors, another client's attachment and stop lease, command replay, absence of temporary lease tokens, completion after detachment, and explicit release.  Its cleanup releases only its own evaluation and stop.  The Web server's live HTTP and browser suites separately exercise real SWANK connections.
