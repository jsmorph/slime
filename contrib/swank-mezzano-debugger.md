# Retained Mezzano debugger protocol

The `swank-mezzano-debugger` contrib transports requests to Mezzano's guest-owned stop service.  A target thread enters that service through `mezzano.debug:call-with-debugger-service`.  Ordinary SWANK evaluation uses SLDB.

The [debugger design](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md) specifies execution, ownership, and lifetime semantics.  The [user guide](https://github.com/jsmorph/Mezzano/blob/debugging/tools/swank/README.md) contains a working session example.  [Build and test instructions](https://github.com/jsmorph/Mezzano/blob/debugging/tools/swank/minideb2/README.md) identify the tested revisions and commands.

## Compatibility and transport

The implementation described here is Slime `2b2086a9951f7b18dc0b88e32729224ba1485029` with the Mezzano service at `37dbb34912616d85f6207edaa5161fa6e410c56a`.  Documentation and test commits can follow those implementation revisions.  The protocol has no version negotiation.  A client requires the listed operations and result fields, including `:operation`.

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

SWANK permits arbitrary guest Lisp evaluation.  Session names and tokens identify debugger objects within that already-authorized connection.  The tested deployment uses loopback forwarding and SSH access.

## Sessions and tokens

The client creates a fresh name from 256 random bits outside the guest, encoded as 64 lowercase hexadecimal digits.  The guest records the current boot-event object with the session.  Creating and resuming a session are distinct operations.

One connection can attach to one session, and one session can attach to one connection.  When SWANK closes the connection, its hook closes the session's guest controller and clears the connection association.  Token tables survive that disconnect.  Resuming creates a new controller, so the client reacquires a lease before submitting another command.

Explicit session release clears its controller, connection, and token tables.  The first adapter operation after a boot change releases all old sessions.  The adapter retains used names, including released names, to reject reuse.  Stop records and their command history have independent guest lifetimes.

Tokens are proper three-element lists:

```lisp
(:stop session-name integer)
(:lease session-name integer)
(:frame session-name integer)
```

The integer indexes the session's token table.  Its numeric value conveys no authority outside that session.  Kind and session membership are checked before the guest validates boot identity and object lifetime.  A stop has a stable token within its session.  Each frame-list command creates fresh guest frame references and therefore new frame tokens.

A client that loses the reply to `open-session` must resume that name.  An absent session produces `:expired-session`.  A new attempt uses a fresh name.  Reusing the uncertain name for another open would obscure whether the earlier request succeeded.

## RPCs

These functions are exported from `SWANK/MEZZANO-DEBUGGER`.

| Function | Successful value |
|---|---|
| `open-session name` | The name of the newly created session. |
| `resume-session name` | The name of the existing session attached to this connection. |
| `request name operation &rest arguments` | The operation-specific value below. |

The attached connection sends `request` operations:

| Operation | Arguments | Successful value |
|---|---|---|
| `:stops` | Optional `include-closed`, default `NIL`. | A list of stop tokens.  Ordering is unspecified. |
| `:information` | Stop token. | Stop information. |
| `:attach` | Stop token. | A new exclusive control-lease token.  Closed stops can be attached for release. |
| `:submit` | Lease token, command ID, command operation, optional argument. | The accepted or previously accepted command ID. |
| `:result` | Stop token, command ID. | The command record.  Control ownership is unnecessary for this query. |
| `:release-stop` | Lease token. | `NIL`.  Removes a closed stop and its command history. |
| `:release-session` | None. | `NIL`.  Releases session storage and control. |

Stop information has this shape:

```lisp
(:id integer
 :state stop-state
 :thread thread-name
 :parent-id integer-or-nil
 :parent stop-token-or-nil
 :child stop-token-or-nil
 :generation integer
 :next-command-id integer)
```

Here `stop-state` is `:stopped` or `:closed`.  The thread field comes from the guest thread's name.  Parent ID remains descriptive after parent release.  Parent and child tokens refer to retained records.  Command IDs start at zero and increase within a stop.

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
 :current-boot-p boolean
 :result operation-result)
```

`:current-boot-p` compares the command's acceptance boot with the current boot.  A restored running command can finish while this field remains `NIL`.  The states and their transitions are defined in [stop and command lifetimes](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#stop-and-command-lifetimes).

| Command operation | Argument | Result when state is `:returned` |
|---|---|---|
| `:condition` | `NIL` or omitted. | Printed condition string. |
| `:restarts` | `NIL` or omitted. | List of `(:index integer :name string :description string)`. |
| `:frames` | `NIL` or omitted. | List of `(:frame frame-token :function string)`, from the service activation toward older callers. |
| `:locals` | A frame token from this stop. | List of `(:index integer :name string :available-p boolean :value string-or-nil)`. |
| `:invoke-restart` | Restart index. | List of printed values if the restart returns to the command.  Invocation supplies zero arguments. |

A printed Lisp `NIL` is the string `"NIL"`.  An unavailable local has `:available-p NIL` and `:value NIL`.  Restart names and local names are printed representations and can include package prefixes.  Local indices identify entries within that returned list.  The current API accepts frame tokens for inspection and exposes no local-write operation.

A nonlocal restart exit produces `:unwound`.  The application result must be observed separately.  `:pending` and `:running` indicate incomplete execution.  `:cancelled` and `:expired` are terminal states with no operation result.  A `NIL` result alone is insufficient to determine command state.

Printing runs on the stopped thread and can enter a child stop.  The parent remains busy until the child resolves.  The protocol currently requires polling to discover command completion and child stops.

### Reconnection and duplicate submission

After a lost reply, resume the session, reacquire control, and query the original command ID.  Repeating an accepted submission in the same boot returns its ID without executing it again if the operation and argument match.  Guest comparison uses `EQ` for the operation and `EQL` for the argument.  For `:locals`, the original token must resolve to the original frame-reference object.

Duplicate recognition still requires a valid lease.  A new command uses `:next-command-id`, and a busy stop rejects it.  Closed stops retain outcomes and recognize matching prior submissions until explicit release.

After image restore, create a fresh session.  Old session tokens are invalid.  Historical command results can be queried through newly discovered stops.  A frame from a historical result remains expired even if it receives a new session token.  Prior-boot commands reject resubmission.  The [design](https://github.com/jsmorph/Mezzano/blob/debugging/doc/debugger.md#disconnect-and-restore) states the tested restore cases and limits.

## Rejection reasons

The following reasons appear in `(:error reason)`.  Earlier validation can determine which error is reported.  For example, an old lease's stop handle can cause `:expired-stop` before controller validation.

| Reason | Meaning |
|---|---|
| `:invalid-session-name` | An open request supplied a name outside the required format. |
| `:session-name-used` | A session record already uses that name, including a released record. |
| `:expired-session` | The session is absent, released, or from an earlier boot. |
| `:closed-connection` | The opening/resuming connection is absent from SWANK's live connection list. |
| `:connection-attached` | The opening/resuming connection already has a session. |
| `:session-attached` | Another connection remains attached to the requested session. |
| `:wrong-connection` | A request arrived through a connection other than the session's attached connection. |
| `:invalid-handle` | The token's shape, kind, session, or table entry is invalid. |
| `:unexpected-arguments` | Session release received arguments. |
| `:expired-stop` | The guest stop handle has the wrong kind or boot identity. |
| `:released-stop` | The guest stop record has been removed. |
| `:expired-controller` | The controller has the wrong kind, was closed, or belongs to an earlier boot. |
| `:expired-control` | The lease has the wrong kind or no longer owns the stop. |
| `:expired-frame` | The frame has the wrong kind, stop, generation, or active lifetime. |
| `:already-controlled` | A current-boot lease already owns the stop. |
| `:stop-active` | Release was requested for an active stop. |
| `:request-conflict` | A reused command ID has another operation/argument or belongs to an earlier boot. |
| `:request-order` | A new command ID differs from the stop's next ID. |
| `:stop-closed` | A new command targets a closed stop. |
| `:stop-busy` | A pending command, active command, or child stop prevents a new command. |
| `:unexpected-argument` | A condition, restart-list, or frame-list command received a non-`NIL` argument. |
| `:invalid-restart` | The command argument is outside the retained restart-index range. |
| `:unknown-operation` | The submitted guest command operation is unsupported. |
| `:unknown-command` | No command with that ID is recorded for the stop. |

The host client retries `:session-attached` until its connection deadline, allowing the previous connection's close hook to finish.  Other rejections are reported as `lispm-debugger-client:request-error`, whose reason is available through `request-error-reason`.
