# Retained Mezzano debugger stops

This contrib transports requests to Mezzano's guest debugger service.  It requires the service API from the Mezzano `debugging` branch, including the `:operation` field in command results.  Load it with `(swank:swank-require :swank-mezzano-debugger)`.

A target thread enters the service through `mezzano.debug:call-with-debugger-service`.  The contrib controls and inspects those stops through separate SWANK requests.  Ordinary SWANK evaluation continues to use SLDB.  [The Mezzano client instructions](https://github.com/jsmorph/Mezzano/blob/debugging/tools/swank/README.md) describe the host Lisp client and tests.

## Sessions and handles

The client generates a fresh 256-bit session name outside the guest.  `open-session` accepts its 64 lowercase hexadecimal digits once and records the current boot-event object.  `resume-session` attaches a new connection to that existing record.  Resume rejects an absent, released, or prior-boot session.  A failed resume never creates a replacement session.

Each handle is `(kind session-name integer)`, where kind is `:stop`, `:lease`, or `:frame`.  The session table resolves these tokens to opaque guest objects.  The guest service validates their boot identity and lifetime.  A fresh session uses a fresh client-generated name, including after image restore.  Clients must preserve this distinction between creating and resuming a session.

One connection controls a session at a time.  SWANK's connection-closed hook closes its guest controller and clears the session's connection.  A reconnect creates a new controller.  The old leases remain invalid, and accepted commands retain their guest records.  Session release clears the handle tables and retains the used name to reject reuse.

## RPC API

The exported RPCs are in `SWANK/MEZZANO-DEBUGGER`.  Each returns `(:ok value)` or `(:error reason)` for a service or protocol rejection.  Unexpected implementation errors follow SWANK's debugger path.

`open-session name` creates a session.  `resume-session name` resumes one.  Both return the session name on success.  `request name operation &rest arguments` accepts these operations:

| Operation | Arguments | Result |
|---|---|---|
| `:stops` | Optional include-closed flag | Stop tokens. |
| `:information` | Stop token | Stop metadata. |
| `:attach` | Stop token | New control-lease token. |
| `:submit` | Lease token, command ID, command operation, optional argument | Accepted or previously accepted command ID. |
| `:result` | Stop token, command ID | Retained command state and result. |
| `:release-stop` | Lease token | Releases a closed stop's record. |
| `:release-session` | None | Closes the controller and releases session handles. |

Command operations are `:condition`, `:restarts`, `:frames`, `:locals`, and `:invoke-restart`.  `:locals` takes a frame token.  `:invoke-restart` takes an index and supplies zero restart arguments.  Command results report whether the command belongs to the current boot.  Frame tokens obtained from a prior-boot command result remain expired.

## Tests

The Mezzano repository contains host SBCL tests using its shared SWANK transport.  `test-debugger-reconnect.lisp` checks connection closure, exclusive control, stale leases, foreign-session tokens, and lost restart replies followed by outcome queries and duplicate submissions.  `test-debugger-remote-restore.lisp` has preparation and completion phases around a VM restart.  It tests sessions present in the saved image and sessions created afterward.
