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
  ssh { git = "github.com/avin-lang/ssh", version = "0.0.1" }
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

## What is bound

- **Sessions**: `Session.connect(host, port, options)` makes the TCP connection, shakes hands and
  checks the host key; `Options` set the connect timeout (connection, handshake and host key
  together), the timeout of every later wait, the host-key policy, the known-hosts file, keepalives
  and how long `close` waits. A session is an `io.Close`: `close()` closes every command still open,
  says goodbye and gives the connection back.
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
- **Errors**: every failure is an `SshError`; `safeToRetry` says which came before anything but the
  connection's own setting up reached the server.

A session and its commands belong to the thread that made them: libssh2 lets one thread at a time
use a session, and using either from another thread traps. A wait that a timeout or a cancellation
cuts off leaves the protocol half way through something, so the session then answers `Interrupted`
until it is closed.

## Testing

The tests run against a private, unprivileged `sshd` of their own, on 127.0.0.1 port 22220, with its
own host key, authorized keys and SSH agent:

```sh
scripts/test-sshd.zsh start
eval "$(scripts/test-sshd.zsh env)"
avin test
scripts/test-sshd.zsh stop
```

A test that needs the server and finds no `SSH_TEST_DIR` says it is skipped and passes.
