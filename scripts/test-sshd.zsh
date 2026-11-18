#!/bin/zsh
# A private SSH server for the package's tests, run as the current user from a directory of its own,
# on 127.0.0.1 port 22220 (or $SSH_TEST_PORT when the directory is made; the directory remembers it),
# with its own host key and an authorized-keys file of its own, so it touches nothing else on the
# machine. An unprivileged sshd logs in only as the user running it, without PAM, so it takes keys and
# refuses every password.
#
#   scripts/test-sshd.zsh start [dir]   makes the keys and the configuration on first use, then starts
#                                       the server and a private ssh-agent holding the client key
#   scripts/test-sshd.zsh stop [dir]    stops both
#   scripts/test-sshd.zsh env [dir]     prints the variables the tests read
#
# The directory defaults to $SSH_TEST_DIR, or .sshd-test in the package. `start` prints the variables
# to export: SSH_TEST_DIR, SSH_TEST_PORT, SSH_TEST_USER, and SSH_AUTH_SOCK naming the private agent,
# which the README's examples log in with. The tests skip, saying so, where
# SSH_TEST_DIR is unset. In the directory:
#
#   client          the key the server authorizes, with no passphrase (and client.pub)
#   locked          a key the server authorizes, under the passphrase `sesame` (and locked.pub)
#   stranger        a key the server does not authorize (and stranger.pub)
#   known_hosts     the server's host key under [127.0.0.1]:PORT and [localhost]:PORT
#   other_hosts     another key under the same names, as a host whose key changed
#   agent.sock      the private ssh-agent, holding `client`

set -e
setopt NO_NOMATCH

action=${1:-start}
root=${2:-${SSH_TEST_DIR:-${0:A:h:h}/.sshd-test}}
if [[ -f $root/port ]]; then
  port=$(<$root/port)
else
  port=${SSH_TEST_PORT:-22220}
fi
user=$(id -un)

print_env() {
  print -r -- "export SSH_TEST_DIR=$root"
  print -r -- "export SSH_TEST_PORT=$port"
  print -r -- "export SSH_TEST_USER=$user"
  print -r -- "export SSH_AUTH_SOCK=$root/agent.sock"
}

running() {
  [[ -f $root/sshd.pid ]] && kill -0 $(<$root/sshd.pid) 2> /dev/null
}

agent_running() {
  [[ -f $root/agent.pid ]] && kill -0 $(<$root/agent.pid) 2> /dev/null
}

case $action in
  start)
    mkdir -p $root
    root=${root:A}
    if [[ ! -f $root/sshd_config ]]; then
      print -r -- $port > $root/port
      ssh-keygen -q -t ed25519 -N '' -C 'avin ssh test host' -f $root/host_ed25519
      ssh-keygen -q -t ed25519 -N '' -C 'avin ssh test other host' -f $root/other_host
      ssh-keygen -q -t ed25519 -N '' -C 'avin ssh test client' -f $root/client
      ssh-keygen -q -t ed25519 -N 'sesame' -C 'avin ssh test locked' -f $root/locked
      ssh-keygen -q -t ed25519 -N '' -C 'avin ssh test stranger' -f $root/stranger
      cat $root/client.pub $root/locked.pub > $root/authorized_keys
      chmod 600 $root/authorized_keys
      hostkey=$(cut -d' ' -f1,2 $root/host_ed25519.pub)
      otherkey=$(cut -d' ' -f1,2 $root/other_host.pub)
      print -r -- "[127.0.0.1]:$port $hostkey" > $root/known_hosts
      print -r -- "[localhost]:$port $hostkey" >> $root/known_hosts
      print -r -- "[127.0.0.1]:$port $otherkey" > $root/other_hosts
      print -r -- "[localhost]:$port $otherkey" >> $root/other_hosts
      cat > $root/sshd_config <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $root/host_ed25519
PidFile $root/sshd.pid
AuthorizedKeysFile $root/authorized_keys
AllowUsers $user
UsePAM no
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
MaxStartups 1000
MaxSessions 1000
MaxAuthTries 20
PerSourceMaxStartups none
PerSourcePenalties no
LoginGraceTime 60
ClientAliveInterval 0
Subsystem sftp /usr/libexec/sftp-server
LogLevel INFO
EOF
    fi
    if ! running; then
      /usr/sbin/sshd -f $root/sshd_config -E $root/sshd.log
      for i in {1..50}; do
        running && break
        sleep 0.1
      done
      if ! running; then
        print -u2 "sshd did not start; see $root/sshd.log"
        exit 1
      fi
    fi
    if ! agent_running; then
      rm -f $root/agent.sock
      ssh-agent -a $root/agent.sock > $root/agent.env
      grep -o 'SSH_AGENT_PID=[0-9]*' $root/agent.env | cut -d= -f2 > $root/agent.pid
      SSH_AUTH_SOCK=$root/agent.sock ssh-add -q $root/client 2> /dev/null
    fi
    print_env
    ;;
  stop)
    if running; then
      kill $(<$root/sshd.pid)
      rm -f $root/sshd.pid
    fi
    if agent_running; then
      kill $(<$root/agent.pid)
      rm -f $root/agent.pid $root/agent.sock
    fi
    ;;
  env)
    root=${root:A}
    print_env
    ;;
  *)
    print -u2 "usage: scripts/test-sshd.zsh start|stop|env [dir]"
    exit 2
    ;;
esac
