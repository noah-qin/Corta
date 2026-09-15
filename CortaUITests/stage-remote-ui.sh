#!/bin/sh
# Builds the stage `RemoteWorkflowUITests` drives the live app against, at
# the directory given as $1, then writes `ready-$2` so the test can tell
# *this* run's stage from a previous run's leftovers. Run by the app's own shell in the test's first
# launch — the sandboxed UI-test runner can read all of `/` but write only
# its container, which the app cannot read. Everything here is local: the
# "remote" shell is a script named `ssh`, the SFTP peer is the real
# `/usr/libexec/sftp-server`, the "editor" rewrites the file it is handed.
set -e
s="$1"
nonce="$2"
[ -n "$s" ] && [ -n "$nonce" ] || exit 2
remote_app="$s/remote/srv/app"
rm -rf "$s"
mkdir -p "$s/bin" "$remote_app/src" "$s/ApplicationSupport"
printf 'hello\n' > "$remote_app/README.md"
head -c 300000 /dev/zero > "$remote_app/big.bin"
printf 'fn main() {}\n' > "$remote_app/src/main.rs"

cat > "$s/bin/ssh" <<EOS
#!/bin/sh
echo "Welcome to fakebox (staged remote, args: \$*)"
printf '\\033]7;file://fakebox$remote_app\\007'
export PS1='fakebox:\$ '
exec /bin/sh -i
EOS

cat > "$s/bin/sftp-ssh" <<EOS
#!/bin/sh
echo "argv: \$*" >> '$s/sftp-ssh.log'
exec /usr/libexec/sftp-server -d '$s/remote'
EOS

cat > "$s/bin/editor" <<EOS
#!/bin/sh
echo "editor: \$*" >> '$s/editor.log'
sleep 1
printf 'hello, edited\\n' > "\$1"
EOS

chmod 755 "$s/bin/ssh" "$s/bin/sftp-ssh" "$s/bin/editor"

cat > "$s/config" <<EOS
suggest-applications-folder = false
preset.fakebox.shell = $s/bin/ssh
preset.fakebox.arguments = fakebox
open-file-command = $s/bin/editor {file} {line} {column}
EOS
touch "$s/ready-$nonce"
