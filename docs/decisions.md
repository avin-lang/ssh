# Design decisions

Each entry is **Proposed** (2026-11-17, branch `binding`), for the director to settle on the user's
delegation. Entries marked **Review with the user** are the debatable ones.

## libssh2 runs non-blocking, and every wait is a `select` on the session's descriptor

Every session is set non-blocking. A call that would wait answers `LIBSSH2_ERROR_EAGAIN`; the package
asks `libssh2_session_block_directions` which way libssh2 waits and waits for that in a `select`
with a `readable()` arm, a `writable()` arm or both, over a small `Readiness`/`Writability` of its
own on the descriptor (`poll` with a zero timeout says whether it is ready now). The runtime's poller
watches the descriptor, so a lightweight thread parks without holding its worker, the wait is a
cancellation point (a `withTimeout`, `withDeadline` or a cancelled scope ends it), and an `after`
arm carries the session's own timeout and the keepalive's next due time. *Alternatives*: blocking
libssh2 calls marked `blocking` (one worker held per waiting session: 200 sessions would want 200
workers, and nothing could cancel a wait); shelling out to `ssh` (the user chose libssh2).

## The session owns a descriptor of its own

`Session.connect` makes the connection with `TcpStream.connect` (so name lookup and connecting are
the runtime's, cancellable), `dup`s its descriptor, and closes the stream at once. The session
`holds:` the duplicate from the handshake on, and its release shuts it down, frees the session
blocking, and closes it: a socket already shut down answers at once, so `libssh2_session_free` can
never wait on a silent server inside a finalizer. *Alternatives*: keeping the `TcpStream` open beside
the session (two owners of one socket; the stream's finalizer and the session's release in either
order); handing libssh2 the stream's own descriptor (closed under it by the stream, and its number
reused). **Review with the user**: the release says nothing to the server; `close()` is where the
goodbye is said.

## A wait cut off leaves the session `Interrupted`

A wait that runs past the session's `timeout`, or whose thread is cancelled, leaves the operation it
was part of half done: libssh2's state machines (a login, a channel request, a write already
partly sent) can only be continued with the same call. So every later operation on the session
answers `Interrupted` (or the `TimedOut` that caused it, once), and `close()` gives everything back
without waiting on the server. A cancelled thread is noticed through a flag set around each park,
which the cancellation leaves set. *Alternatives*: resuming the cut-off call on the next operation
(the program would have to repeat exactly what it was doing); treating a read's timeout as harmless
(true of reads alone, and a rule per operation is easy to get wrong). **Review with the user**: a
read that times out also ends the session.

## Output comes as chunks from `next()`, not as two `Reader`s

`Exec.next()` answers the next piece of output from whichever stream has one, `Stdout(bytes)` or
`Stderr(bytes)`, each at most one 32 KiB read, so a program follows both streams as they arrive with
bounded memory and cannot deadlock on the stream it is not reading. `StderrMode.Merge` and `Discard`
give one stream (libssh2's own merge or drop). Standard input is `stdin(bytes)` and `closeStdin()`,
and `Exec` is an `io.ByteWriter` through `write`. *Alternatives*: a `Reader` per stream (a program
reading standard output to its end while standard error fills the channel's 2 MB window stops for
ever); a channel of chunks fed by a thread of its own (a second thread per command, and the session
would have to be shared between the two). **Review with the user**: whether `Exec` should also be a
`Reader` of the merged stream.

## `run` keeps the first `limit` bytes of each stream and reads the rest

`run(command, limit = 16 MiB)` answers `Output(status, stdout, stderr, truncated)`, keeping at most
`limit` bytes of each stream, reading and dropping the rest so the command can finish, and saying
whether it dropped any. *Alternatives*: failing past the limit (the exit status is still wanted);
keeping the last bytes (the first usually say what went wrong first).

## Host keys: `Strict` by default, `AcceptNew`, `Pinned`; nothing accepts any key

`Strict` checks `~/.ssh/known_hosts` (or the file the options name) with `libssh2_knownhost_checkp`,
which matches `[host]:port` entries and hashed ones. `AcceptNew` appends the new host's line itself
(`[host]:port type base64`), adding a line end first where the file's last line has none, rather
than `libssh2_knownhost_writefile`, which would rewrite the whole file from what libssh2 parsed and
drop lines it does not understand. `Pinned(fingerprint)` compares the SHA-256 fingerprint as
`ssh-keygen -l` writes it and reads no file. A file that does not exist lists nothing. *Alternatives*:
an `AcceptAny` policy (left out: a runner that wants it can pin); failing on a missing file under
`Strict` (it is a host not listed, the same decision). **Review with the user**: no accept-any.

## Logins: agent, key file, password; keyboard-interactive is not bound

`authMethods(user)` asks once per user (`libssh2_userauth_list`, which is itself a `none` login, so a
server that needs none logs in there). Every login first checks the method is offered and answers
`AuthFailed(method, offered)` otherwise. The agent tries each key it holds in turn; its keys are
handles kept by the agent that never leave the one call. A wrong passphrase or unreadable key file is
`KeyFile`. *Alternatives*: keyboard-interactive (a callback answering an array of prompts; OpenSSH
takes passwords through `password` too, so it adds little now).

## Errors: one `SshError`; `safeToRetry` only where nothing reached the server

`Connect`, `Handshake` and `ChannelRefused` came before any command or transfer reached the server,
so trying again cannot run anything twice; nothing else is marked safe. `SftpFailed` and `Local` are
not marked either, though an SFTP refusal usually changed nothing: whether a retry is sound depends on
what the program was transferring.

## A session closes its commands first; a command after its session closed answers `Closed`

`libssh2_session_free` frees every channel still open, so a channel used after its session was closed
would be used after it was freed. The session keeps every channel its commands opened until the
command closes it, closes them all (the protocol's close, at most `closeTimeout` each) before saying
goodbye, and every operation of a command checks its session first. A command's channel is kept by
its session until one of them is closed, not collected on its own while the session lives.
**Review with the user**: a program that drops commands without closing them holds their channels
until the session closes.

## SFTP transfers stream through `io.Reader` and `io.ByteWriter`, 64 KiB at a time

`upload(reader, remote, mode)` and `download(remote, writer)` move one piece of at most 64 KiB at a
time, so a transfer of any size holds one piece; `putFile` and `getFile` wrap them around local files.
An upload creates or empties the remote file (`CREAT | TRUNC`). Around them only what a runner needs:
`stat`, `mkdir`, `remove`, `removeDir`. The server's refusal is `SftpFailed(path, status, reason)`
with the SFTP status code; the local side's failure is `Local(IoError)`. *Alternatives*: a remote
`File` handle that is itself a `Reader`/`ByteWriter` (more surface, and every handle a program holds is
one more thing the session must close); SCP (the server here runs SFTP, and SCP gives no status).
**Review with the user**: whether a remote file handle, rename, symlinks and directory listing belong
in the package now or when the runner needs them.

## Remote files and SFTP subsystems are freed by the session, never by the collector

libssh2 frees an SFTP file handle only in `libssh2_sftp_close_handle`, which talks to the server, and
an SFTP subsystem's state goes with its channel when the session is freed. So neither handle's release
frees anything: every transfer closes its file the protocol's way (at most `closeTimeout`), and a file
whose close was cut off, by a timeout or a cancellation, stays on the session's list. The session's
`close` then shuts the socket down and makes libssh2 blocking before closing it, so the call fails at
once and frees the file; an SFTP subsystem left open is freed with the session. The same cut makes
an interrupted session's channels free at once rather than wait. *Alternatives*: closing the handle in
the release (a finalizer that waits on the server, or one that cannot finish non-blocking and leaks);
freeing nothing until the session is collected (a closed session would leak its interrupted files).

## Closing a running command sends it `TERM`, and nothing waits for the server's close

A closed channel stops only a command that writes (it meets a closed pipe); `sleep 30` would run on.
So closing a command whose output has not ended, by `Exec.close` or by the session's `close`, first
sends the `signal` request `TERM`, then the protocol's close, and frees the channel without waiting
for the server's own close, which comes only once the command has exited and which libssh2 drops for
a freed channel. `Exec.signal(name)` sends any signal. *Alternatives*: waiting for the server's
close (a command that ignores the channel kept `close` waiting its whole `closeTimeout`, and then
left the session interrupted); `KILL` (gives the command no chance to clean up). **Review with the
user**: `TERM` reaches the process the server started, the user's shell; a shell that does not hand
it on leaves its children running.

## A command or SFTP before logging in is `NotAuthenticated`, at once

OpenSSH answers a channel opened before a login with nothing at all, so the request waited out the
session's whole timeout. `exec`, `run` and `sftp` check `libssh2_userauth_authenticated` first.

## Every failure of the handshake is `Handshake`, safe to retry

A connection reset before the server's banner arrived (a listening queue overflowing drops
connections that way) failed as `Disconnected`, which is not safe to retry, though nothing but the
connection had reached the server. Every failure inside the handshake but a timeout is now
`Handshake(reason)`, the reason keeping libssh2's words. The 200-session test retries such failures
as a fan-out would: two hundred connections at once to one `sshd` overflow its listen queue of 128.

## The session and its commands share a module-private `Link`

A class's private members are private to it, and a command needs the session's waits and state; the
two public classes share a private class holding them, so nothing of it is visible outside the
module.
