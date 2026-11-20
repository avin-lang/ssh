# ssh

An SSH client for [Avin](https://github.com/avin-lang/avin), binding [libssh2](https://libssh2.org)
directly through Avin's C bindings, which check every binding against libssh2's own headers when the
program is built.

Every session runs libssh2 non-blocking: a call that would wait for the server parks the calling
thread on the runtime's poller instead, so hundreds of sessions run at once on lightweight threads, one
each, without holding a worker apiece. Every wait is a cancellation point, so a `withTimeout` or
`withDeadline` around the work bounds it.

Needs Avin 0.0.32 or later.

## Installing libssh2

The package finds libssh2 with `pkg-config` (the module `libssh2`), version 1.11 or later:

- macOS: `brew install libssh2`
- Debian and Ubuntu: `apt install libssh2-1-dev`

## Using it

Name it in your package's `avin.hocon`:

```hocon
dependencies {
  ssh { git = "github.com/avin-lang/ssh", version = "0.0.2" }
}
```

and import from the module `dev.avinlang.ssh`.

## An example

Runs `uname -a` on a host, logged in with the SSH agent, the host key checked against
`~/.ssh/known_hosts`:

```avin
import avin.time.seconds
import dev.avinlang.ssh.{Options, Session, SshError}

uname(
  host: string,
  user: string,
  port: int = 22,
  options: Options = Options(connectTimeout = Some(10.seconds))
) -> Result[string, SshError] =
  val session = Session.connect(host, port, options)?
  defer _ = session.close()
  session.authAgent(user)?
  val out = session.run("uname -a")?
  Ok(out.stdoutText.trim)

main(args: Vector[string])
  uname(args(0), args(1)) match
    Ok(text) -> println(text)
    Err(e) -> println(s"${args(0)}: ${e.message}")
```

Output streamed as it arrives, standard output and standard error apart, and the exit status after:

```avin
import dev.avinlang.ssh.{Exited, Session, Signalled, SshError, Stderr, Stdout}

follow(session: Session, command: string) -> Result[int, SshError] =
  val running = session.exec(command)?
  defer _ = running.close()
  loop
    running.next()? match
      Some(Stdout(bytes)) -> print(string.fromUtf8Lossy(bytes))
      Some(Stderr(bytes)) -> print(s"! ${string.fromUtf8Lossy(bytes)}")
      None -> break
  running.wait()? match
    Exited(code) -> Ok(code)
    Signalled(signal, _) -> Ok(128)
```

The same command on many hosts at once, each on a lightweight thread of its own, each given ten
seconds:

```avin
import avin.threads.{scope, withTimeout}
import avin.time.seconds
import dev.avinlang.ssh.{Options, Session, SshError}

onEach(
  hosts: Vector[string],
  user: string,
  command: string,
  port: int = 22,
  options: Options = Options()
) -> Vector[(string, string)] =
  scope(sc ->
    val threads = hosts.map(host -> sc.spawn(() ->
      val answer = withTimeout(10.seconds, _ -> runOn(host, port, user, command, options)) match
        Some(Ok(text)) -> text
        Some(Err(e)) -> s"failed: ${e.message}"
        None -> "timed out"
      (host, answer)))
    threads.map(t -> t.join()))

runOn(host: string, port: int, user: string, command: string, options: Options) -> Result[string, SshError] =
  val session = Session.connect(host, port, options)?
  defer _ = session.close()
  session.authAgent(user)?
  Ok(session.run(command)?.stdoutText)
```

A script uploaded over SFTP, then run; a transfer holds one 64 KiB piece at a time, whatever its size:

```avin
import dev.avinlang.ssh.{Session, SshError}

deploy(session: Session, script: string, remote: string) -> Result[int, SshError] =
  val sftp = session.sftp()?
  defer _ = sftp.close()
  sftp.putFile(script, remote, 0o755)?
  val out = session.run(remote)?
  sftp.remove(remote)?
  Ok(if out.success then 0 else 1)
```

A host named in an SSH configuration, `SshConfig.load()` reading `~/.ssh/config`, reached through the
jump host the configuration gives it, and a command run there on a terminal, as `ssh -t web sudo …`
runs it for hosts whose sudoers ask for one:

```avin
import dev.avinlang.ssh.{Pty, SshConfig, SshError, Stdout}

onTerminal(config: SshConfig, alias: string, command: string) -> Result[string, SshError] =
  val session = config.connect(alias)?
  defer _ = session.close()
  val running = session.exec(command, pty = Some(Pty("xterm", 120, 40)))?
  defer _ = running.close()
  val out = Buffer[byte]()
  loop
    running.next()? match
      Some(Stdout(bytes)) -> out.addAll(bytes)
      Some(_) -> ()
      None -> break
  Ok(string.fromUtf8Lossy(out.toArray()))
```

A local port forwarded to a database the server can reach, as `ssh -L 5433:db.internal:5432` does for
one connection at a time, each relayed both ways until both ends finish:

```avin
import avin.net.TcpListener
import dev.avinlang.ssh.{Local, Session, SshError}

forward(session: Session, localPort: int, host: string, port: int) -> Result[unit, SshError] =
  val listener = TcpListener.bind("127.0.0.1", localPort).mapErr(e -> Local(e))?
  defer _ = listener.close()
  loop
    val conn = listener.accept().mapErr(e -> Local(e))?
    val tunnel = session.tunnel(host, port)?
    _ = tunnel.relay(conn)?
    _ = tunnel.close()
    _ = conn.close()
```

## What is bound

- **Sessions**: `Session.connect(host, port, options)` makes the TCP connection, shakes hands and
  checks the host key; `Options` set the connect timeout (connection, handshake and host key
  together), the timeout of every later wait, the host-key policy, the known-hosts file, keepalives
  and how long `close` waits. A session is an `io.Close`: `close()` closes every command and SFTP
  subsystem still open, says goodbye and gives the connection back.
- **Host keys**: `HostKeys.Strict` (the default) takes only a key the known-hosts file lists for the
  host and port, `AcceptNew` adds a host it does not list to the file, and `Pinned(fingerprint)`
  takes exactly the key with that SHA-256 fingerprint. A key the file does not list is
  `UnknownHostKey`, a different one `ChangedHostKey`, each with the server's fingerprint.
  `hostKeyFingerprint()` answers it as `ssh-keygen -l` writes it.
- **Logging in**: `authAgent(user)` (the agent `SSH_AUTH_SOCK` names, or one at a path),
  `authKey(user, privateKeyPath, passphrase)` and `authPassword(user, password)`; `authMethods(user)`
  answers what the server offers. A refusal is `AuthFailed(method, offered)`; a key file that cannot
  be read or whose passphrase is wrong is `KeyFile`.
- **Commands**: `exec(command, stderr)` answers a running `Exec`: `next()` gives each piece of output
  as it arrives, `Stdout` or `Stderr` (or standard error merged or dropped), `stdin(bytes)` and
  `closeStdin()` feed its input (and it is an `io.ByteWriter`), `wait()` answers `Exited(code)` or
  `Signalled(signal, message)`, and `close()` ends it. Several run on one session at once.
  `run(command, limit)` runs one to its end and answers an `Output` with at most `limit` bytes of each
  stream kept.
- **Terminals**: `exec(command, pty = Some(Pty(term, columns, rows, modes)))` runs a command on a
  pseudo-terminal, as `ssh -t` does, the terminal modes set first (`TerminalMode.Echo` and the
  rest); `shell()` starts the login shell, interactive on a terminal by default, or reading commands
  without one; `resize(columns, rows)` tells a running one its terminal's new size. Under a terminal
  the command's standard error arrives merged into its standard output, as it does through `ssh -t`.
  A terminal the server refuses is `ChannelRefused`.
- **Tunnels**: `tunnel(host, port)` asks the server to connect to a host and port as it sees them
  (`direct-tcpip`, what `ssh -L` and `ssh -J` use) and answers a `Tunnel`, an `io.Reader` and
  `io.ByteWriter` with `receive`, `send`, `closeWrite` (a half-close) and `close`. `relay(conn)` joins
  it to a local connection both ways until both ends finish. A host or port the server cannot reach,
  or forwarding it forbids, is `ChannelRefused`. Several tunnels and commands run on one session at
  once. Listening on the server's side (`ssh -R`) is not bound.
- **`~/.ssh/config`**: `SshConfig.load()`, `read(path)` and `parse(text)` read a configuration the
  way `ssh` does (`Host` patterns with `*`, `?` and `!`, the first value winning, `Include` with
  globs, `Match host`, `user` and `all`, comments, `=` and quotes); `host(alias)` answers its
  `HostName`, `User`, `Port`, `IdentityFile`s, `ProxyJump`, `StrictHostKeyChecking`,
  `UserKnownHostsFile`, `ConnectTimeout`, `ServerAliveInterval` and `IdentitiesOnly` for a host, `~`
  and the `%` tokens expanded; `connect(alias)` makes the session, through its jump hosts, and logs
  in with the agent and then the identity files. A line it cannot use, a `Match` criterion other
  than those three among them, is `Config(path, line, reason)`.
- **SFTP**: `sftp()` starts the subsystem; `upload(reader, remotePath, mode)` and
  `download(remotePath, writer)` stream any `io.Reader` up and into any `io.ByteWriter`, and
  `putFile`/`getFile` do the same between local and remote files. `stat`, `mkdir`, `remove` and
  `removeDir` work on remote paths. The server's refusal is `SftpFailed(path, status, reason)` (a
  missing file or directory is status 2); a failing local side is `Local(ioError)`.
- **Errors**: every failure is an `SshError`; `safeToRetry` says which came before anything but the
  connection's own setting up reached the server.

A session and its commands belong to the thread that made them: libssh2 lets one thread at a time
use a session, and using either from another thread traps. A wait that a timeout or a cancellation
cuts off leaves the protocol half way through something, so the session then answers `Interrupted`
until it is closed.

Many sessions with one server are opened a bounded number at a time. A connection the server has not
accepted yet waits in its listening socket's queue, and the kernel resets one that finds the queue
full: OpenSSH's `sshd` asks for 128, and macOS caps every queue at `kern.ipc.somaxconn`, 128 by
default. Two hundred connections at once to an `sshd` on the same Mac see well over a hundred
resets, as `Connect` or `Handshake` errors. Taking a `Semaphore` permit around `Session.connect`
alone keeps the sessions themselves all open at once:

```avin
val connecting = Semaphore(64)
val s = connecting.withPermit(() -> Session.connect(host))?
```

## Testing

The tests run against a private, unprivileged `sshd` of their own, on 127.0.0.1 port 22220, with its
own host key, authorized keys and SSH agent. Start it from a directory with a short path, `/tmp/…`:
the agent's socket lives in it, and a socket's path may not be longer than about a hundred bytes.

```sh
scripts/test-sshd.zsh start
eval "$(scripts/test-sshd.zsh env)"
avin test
scripts/test-sshd.zsh stop
```

A test that needs the server and finds no `SSH_TEST_DIR` says it is skipped and passes.
