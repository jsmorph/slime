# Mezzano development

After compaction, read this file again.

## Decision procedure

Simplicity is the greatest virtue.

On 2026-10-12, the user authorized the entire debugger, headless-system, and QEMU host-control agenda under this procedure.  Apply it explicitly to every further design decision and proposed approval:

1. Review the relevant implementation, authoritative documentation, prior decisions, and test evidence.
2. Prefer the simplest design that satisfies the required behavior.  Start with existing mechanisms and determine the cause of failures.
3. State a concrete recommendation and explain its consequences.
4. Record the recommendation, rationale, evidence, and required tests in the development journal before proceeding.
5. Proceed with the recommendation under the user's standing authorization.

This authorization supersedes the earlier requirement for separate user approval of each design decision within this agenda.  Essential missing information still requires a question.  Ask one question at a time, with a recommendation.

The authorized agenda continues across increments, commits, restarts, and compactions.  After testing and committing an increment, proceed to the next unfinished item.  End agenda work when its requirements are satisfied or when the user directs a pause.

Bare-metal FEP work remains deferred.

## Implementation and reporting

Development runs through `tailscale ssh minideb2`.  The Mezzano checkout is `/home/somebody/src/mezzano-boot/Mezzano`, and the Slime checkout is `/home/somebody/src/mezzano-boot/home/slime`.  Both use the `debugging` branch.  The development VM uses host port 4006.  The original VM uses port 4005.

Read the repository README and relevant documentation before changing an implementation.  Read documentation again after editing it.  Keep debugger implementation, compiler changes, clients, and new tests in Lisp where the existing system permits it.  Minimize dependencies.

Complete a bounded increment, test its behavior, document it, commit, and push.  Review the changes before committing.  Commit headlines start with a capital letter, contain fewer than 60 characters, and have no final period.

The development journal is Mezzano's `tools/swank/devnotes.md`.  Record decisions, diagnoses, failures, test scope, and evidence there.  Keep historical findings distinct from current implementation status.

A completion claim requires the implementation and the stated tests to pass.  Identify supported architectures, compilation policies, and stopping states.  Distinguish implemented behavior, source inspection, proposed behavior, and untested cases.  Report failures and unresolved work.
