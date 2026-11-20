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

## A terminal is an option of `exec`, and a shell is an `Exec`

(Proposed 2026-11-19, branch `pty-forward`.) `exec(command, stderr, pty)` and `shell(pty, stderr)`
both answer an `Exec`, read and written as any command is; `Pty(term, columns, rows, modes)` holds the
request, its modes as `(opcode, value)` pairs with the common opcodes named on `TerminalMode`, and
`resize` is a method of `Exec` that answers `Invalid` on a command without a terminal. Under a
terminal the server sends no standard error of its own, so the `Exec` reads standard output alone,
whatever `stderr` asked. `shell()` asks for an `xterm` of 80 by 24 unless told otherwise, as an
interactive shell is what one usually wants; `shell(pty = None)` is the non-interactive one. The
`shell` request is bound with a null message, since OpenSSH ends a session whose `shell` request
carries one. *Alternatives*: a separate `Terminal` class (a second reader of output to keep in step
with `Exec`); modes as a `data` of every RFC 4254 opcode (seventy names for a rarely used field).

## A tunnel is a byte stream; `relay` joins one to a local connection, on the session's thread

(Proposed 2026-11-19, branch `pty-forward`.) `Session.tunnel(host, port)` opens a `direct-tcpip`
channel and answers a `Tunnel`, an `io.Reader` and `io.ByteWriter` with `closeWrite` as its
half-close; a tunnel is closed without the `TERM` a command is sent. `Tunnel.relay(local)` copies both
ways between it and any `ByteStream` this thread owns, holding at most one piece in each direction
so a side that does not read holds the other back through the SSH window, and passing each end on as
a half-close. It waits on the session's socket and the local stream in one `select`. Because a
`select`'s arms are fixed when it is written, the wait is spelled out for each combination of the
three it may need (local readable, local writable, the session's socket readable or writable), which
is twelve small `select`s in `Socket.waitWith`.

**No `ssh -L` convenience that serves several local connections at once.** A session belongs to one
thread, so every tunnel's bytes are read and written there; serving N connections at once would
mean one thread waiting on N local streams and the session together, which a `select` with arms
fixed in the source cannot express, and handing the bytes to per-connection threads instead is ruled
out because `Array[byte]` is not `Sendable` (only the standard library may mark a class
`@trusted_sendable`), so each piece would be copied into a `Vector[byte]`. The README shows the
one-at-a-time loop. **Review with the user**: a `select` over a collection of streams, or a
sendable byte buffer, would let the package add it.

Listening on the server's side (`ssh -R`, `tcpip-forward`) is not bound: an accepted forward needs
the same multi-connection wait.

## `~/.ssh/config` is read by a pure parser, and `connect(alias)` logs in

(Proposed 2026-11-19, branch `pty-forward`.) `SshConfig` parses the file into lines (Includes expanded
when it is read, nested as blocks so a `Host` inside an included file ends at that file's end, as in
`ssh`), and `host(alias)` replays them for the alias. Choices:

- **Only the keywords the package uses are interpreted**; every other keyword is passed over without
  a check, since real files hold dozens the package has no use for. A used keyword with a value it
  cannot take (`Port abc`) is `Config(path, line, reason)`.
- **`Match` takes `host`, `user` and `all`; any other criterion is refused** when the file is read,
  naming the criterion and its line. `Match host` fits the `HostName` set so far, else the alias, as
  in `ssh`.
- **A relative `Include` is read from the directory of the file read first** (`~/.ssh` for the
  user's file, as `ssh` does); a path matching nothing is passed over; nesting stops at 16.
- **`StrictHostKeyChecking no` and `off` are taken as `accept-new`**: the package never accepts a
  changed key (see the host-key entry above), and `ask` is `yes`, there being no one to ask.
- **`IdentitiesOnly`** is read too, so a configuration can keep the agent out of a login.
- **`connect(alias)` logs in** with the agent (unless `IdentitiesOnly yes`), then each identity file
  that exists, else the default `~/.ssh/id_*` keys; a key under a passphrase is passed over. A
  caller wanting another order connects with `Session.connect(h.hostName, h.port, h.options())` and
  logs in itself.
- **`ProxyJump` is implemented** over `direct-tcpip`: libssh2 needs a socket for a session, so a
  thread of its own makes the jump host's session (resolved through the same configuration, its own
  `ProxyJump` followed, at most 8 deep), opens a tunnel to the target, and relays it to the first
  connection to a listener on a loopback port, which the target's session then connects to; its host
  key is checked under the target's own name and port. The thread ends when the target's session
  closes. **Review with the user**: another process of the machine could connect to that loopback
  port first, in the instant before the session does; it would gain nothing, since the target's key
  is checked, but the session would then fail to connect.

*Alternatives*: refusing `ProxyJump` (fettle's jump hosts need it); libssh2's send and receive
callbacks pointed at the jump channel (C callbacks into Avin code from inside libssh2, with no way to
park the thread).

## `wait` waits for the server's close before sending its own

(Settled on the user's delegation 2026-11-20, branch `exec-close`.) A command has ended when the
server closes its channel, which the server does after `exit-status` or `exit-signal` (RFC 4254
§6.10); the end of its output (`EOF`, §5.3) says only that no more output comes. On Linux a command
on a terminal that closes its own descriptors of it and goes on running (`sudo` under `use_pty`) ends
the output at once, and `wait` closed the channel then: OpenSSH took that close as the client hanging
up, closed the terminal, and the command died of `HUP`. `wait` now reads the output to its end, waits
for the server's close, and answers it with its own. The wait is bounded as every wait of the session
is: by its `timeout`, after which it is `TimedOut` and the session `Interrupted`, and by a deadline
of the caller's. With no `timeout` and no deadline, a server that never closes holds `wait` as it
would hold `next`, as OpenSSH's own client waits. *Alternatives*: closing once `exit-status` has
arrived plus a grace of `closeTimeout` (libssh2 answers `0` both for an exit status of `0` and for
none, so the arrival of a successful one cannot be seen); a fixed limit from the end of the output (it
would hang up exactly the long-running commands this fixes). A server that closes without saying how
the command ended reads as `Exited(0)`, which is what libssh2 answers; no OpenSSH server does that.
**Review with the user**: whether `wait` should take a limit of its own, apart from the session's
`timeout`.
