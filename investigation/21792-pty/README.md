# fastlane#21792: lost output from FastlanePty

Investigation notes and prototype fixes, not meant for upstream as they are. Measured 2026-11-08/09 against
master's `FastlanePty.spawn` (`fastlane_core/lib/fastlane_core/fastlane_pty.rb`).

## Two problems

**1. Linux drops a last line that has no newline, every time.** A Linux PTY read ends with `Errno::EIO`, and
`IO#each` discards the line it had not finished. `printf foo` came back empty in 20,000 of 20,000 runs on
ubuntu-24.04; reading with `readpartial` keeps it (0 lost). macOS ends the read with end-of-file and is not affected.
Fix proposed on branch `fastlane_core/execute-keep-last-line` (E): `execute` reads with `readpartial`.

**2. macOS loses the whole output of a program that prints and exits right away.** The read gets nothing and ends with
end-of-file about 600 ms later. `readpartial` does not help.

| Command, macOS runners, 20,000 runs per variant | Lost |
|---|---|
| `echo foo`, `printf foo`, `#!/usr/bin/perl` script, run directly | up to 0.3% with 1 process, 0.2–1.2% with 4 |
| the perl script pausing 10 ms or 100 ms after printing | 0 in 76,800 |
| `FASTLANE_EXEC_FLUSH_PTY_WORKAROUND` (`cmd;`, so `/bin/sh` runs it) | 1 in 480,000 |
| `#!/bin/sh` script, with `echo` or with `exec /bin/echo foo` | 0 in 480,000 |

Locally (M4 Pro) bare `echo foo` lost 1 in 67,000 with 8 processes and 1 in 3,900 with 28.

**Cause.** The command is the session leader and owns the PTY as its controlling terminal. When a session leader
exits, the kernel takes the terminal away from every process that has it open, the parent included; output the parent
has not read by then is gone. Shown by `hold_pty.rb`: holding the parent's slave open is not enough when the child is
a session leader with the PTY as controlling terminal (`HOLD_CTTY=1`: short outputs came back empty, 200,000 lines
lost the last 4), and is enough without one
(0 lost). It also fits the table: a pause after printing gives the parent time to read; with `/bin/sh` first, the
shell is the leader and exits a moment after the program, which narrows the window without closing it.

## Prototypes

All three keep `FastlanePty.spawn`'s contract (yield stdout, stdin, pid; return the exit status; raise when killed).
They hand the caller a pipe filled up to an end marker, so `IO#each` also keeps an unterminated last line (problem 1).

- `hold-slave.rb`: the first test, `PTY.open` + `Process.spawn`, slave closed at once (as `PTY.spawn`) or held until
  the child is reaped. 28 processes, 399,980 runs each: closed lost 5,233, held lost 0.
- `hold_pty.rb`: holds the slave, no controlling terminal. 0 lost on macOS and Linux, but `/dev/tty` is not available
  to the command ("Device not configured").
- `helper_pty.rb`: a forked helper is the session leader and owns the terminal, starts the command in its session,
  writes the marker once it exits, and exits only after the parent has read up to the marker, ending as the command
  did (same exit status, or the same signal). The candidate fix.

`compare.rb` runs 11 behaviour cases and a stress test through master's spawn and the prototypes, reading as
`execute` does: `ruby compare.rb fastlane_core/lib/fastlane_core/fastlane_pty.rb [runs] [processes]`.

| `compare.rb` | master | `helper_pty.rb` |
|---|---|---|
| macOS, 28 processes, bare `echo foo` | 165 / 199,976 lost | 0 / 199,976 |
| Linux (`ruby:3.2` Docker), 8 processes | 1 / 40,000 lost | 0 / 40,000 |
| Linux, `printf foo` | empty | `foo` |
| behaviour cases (UTF-8, 200,000 lines, exit 3, killed, missing program, tty?, `/dev/tty`, background child, caller stops early) | | all match, macOS and Linux |
| cost, 2,000 runs in a row, 30 MB heap | 2.3 ms | 3.8 ms |

Fixed in the helper while testing: `Signal.trap` refuses SIGKILL (a killed command came back as exit 1), and closing
the terminal while the helper still waited hung it up (SIGHUP, 2 in 2,000 runs; 0 in 20,000 after the fix).

## What `helper_pty.rb` would change in fastlane

- Callers get a pipe, not the PTY. fastlane's three callers (`execute`, two in `itunes_transporter.rb`) only call
  `each`; a plugin calling `FastlanePty.spawn` itself no longer gets a terminal object.
- One more forked process per command, about 1.5 ms; its memory is shared with fastlane's until either writes to it.
- The helper runs Ruby code after `fork` in a process that may have threads, where `PTY.spawn` goes straight to `exec`.
- Not done: wrapping errors in `FastlanePtyError` with 127 and the signal name, as `spawn_with_pty` does; Windows
  (popen) is unaffected.

## Measurements

Probe script and CI workflows: https://github.com/lacostej/simctl-first-call-repro (`pty-short-output.rb`,
`spec-repeat.yml`). Runs: 42498051790, 42500274891, 42529369643 (probes); 42500277308, 42506476177 (fastlane specs
repeated 10,000 times: none failed, as they run through `/bin/sh`).
