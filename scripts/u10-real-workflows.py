#!/usr/bin/env python3
"""U10 quality-plan harness: real programs on real PTYs, Corta as the audience.

Each scenario spawns a real program (zsh, tmux, less, vim, ...) on a pseudo
terminal, drives it with timed keystrokes and, where scripted, a mid-session
TIOCSWINSZ resize, and captures every byte the program emits. The capture is
then replayed through `corta-dump` — the same `Terminal` core the app renders
— and the resulting grid and `--report` state are asserted on.

What this proves: real programs' output parses into the grid the program
intended (rendering), their prompts react to injected keystrokes (input
round-trip), mode sequences land in core state (mouse/bracketed-paste
reporting), OSC 52 copy lands decoded (copy), a SIGWINCH repaint stays
coherent at the new geometry (resize), and every child exits cleanly (exit).

What it cannot prove: anything on the AppKit side of the core boundary —
keystroke encoding (`TerminalView`), actual pointer events, the pasteboard
itself, and the renderer's pixels. Those are covered by CortaTests or remain
manual.

Usage: scripts/u10-real-workflows.py [path-to-corta-dump]
Exit status is 0 when every scenario that could run passed; scenarios whose
program is not installed are reported as SKIP and do not fail the run.
"""

import base64
import fcntl
import os
import re
import shutil
import struct
import subprocess
import sys
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DUMP = os.path.join(REPO, "CortaTerminal", ".build", "debug", "corta-dump")

ROWS, COLS = 24, 80


class Failure(Exception):
    pass


class Skip(Exception):
    pass


RESULTS = []


def scenario(name):
    def decorate(fn):
        def wrapped(ctx):
            if fn.__programs__:
                missing = [p for p in fn.__programs__ if not shutil.which(p)]
                if missing:
                    RESULTS.append(("SKIP", name, f"not installed: {', '.join(missing)}"))
                    return
            try:
                fn(ctx)
                RESULTS.append(("PASS", name, ""))
            except Skip as reason:
                RESULTS.append(("SKIP", name, str(reason)))
            except Failure as error:
                RESULTS.append(("FAIL", name, str(error)))
            except Exception as error:  # a harness bug, not a product verdict
                RESULTS.append(("ERROR", name, f"{type(error).__name__}: {error}"))
        wrapped.__programs__ = getattr(fn, "__programs__", [])
        return wrapped
    return decorate


class PtySession:
    """A child process on a PTY, driven by timed actions from the master."""

    def __init__(self, argv, rows=ROWS, cols=COLS, env_extra=None, responder=None):
        # `responder`: a path to `corta-dump`, run as `--serve`. Every byte the
        # child emits is fed to it and whatever the terminal answers is written
        # back down the PTY. Without one the master is a capture device with
        # nothing behind it, and a client that blocks on a reply — fish waits
        # for Primary DA before it prints a prompt — simply hangs. With one,
        # the replies are the ones Corta actually sends.
        self.responder = None
        if responder:
            self.responder = subprocess.Popen(
                [responder, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            os.set_blocking(self.responder.stdout.fileno(), False)
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        # A clean, deterministic shell/profile environment: the audit
        # exercises the terminal, not the user's rc files.
        env.update(env_extra or {})
        self.proc = subprocess.Popen(
            argv, stdin=slave, stdout=slave, stderr=slave, env=env,
            start_new_session=True,
            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        os.set_blocking(self.master, False)
        self.chunks = []  # (monotonic timestamp, bytes), in arrival order

    def pump(self, seconds):
        """Read whatever the child emits for `seconds`, timestamped."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                data = os.read(self.master, 65536)
            except BlockingIOError:
                time.sleep(min(0.02, remaining))
                continue
            except OSError:  # EIO: the child closed its side — it exited
                return
            if not data:
                return
            self.chunks.append((time.monotonic(), data))
            self._answer(data)

    def _answer(self, data):
        """Feed `data` to the serving terminal and put its reply on the PTY."""
        if self.responder is None:
            return
        try:
            self.responder.stdin.write(data)
            self.responder.stdin.flush()
        except (BrokenPipeError, ValueError):
            self.responder = None
            return
        # The reply, if any, is produced by the time the write returns: the
        # serving process answers one chunk before it reads the next.
        deadline = time.monotonic() + 0.2
        reply = b""
        while time.monotonic() < deadline:
            try:
                piece = self.responder.stdout.read(65536)
            except BlockingIOError:
                piece = None
            if piece:
                reply += piece
                continue
            if reply:
                break
            time.sleep(0.005)
        if reply:
            os.write(self.master, reply)

    def send(self, data, settle=0.3):
        os.write(self.master, data)
        self.pump(settle)

    def mark(self):
        """A timestamp usable with bytes_before/bytes_after."""
        return time.monotonic()

    def resize(self, rows, cols, settle=0.6):
        """TIOCSWINSZ on the master: the child gets a real SIGWINCH."""
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.resized_at = time.monotonic()
        self.pump(settle)

    def bytes_before(self, timestamp):
        return b"".join(data for stamp, data in self.chunks if stamp < timestamp)

    def bytes_after(self, timestamp):
        return b"".join(data for stamp, data in self.chunks if stamp >= timestamp)

    def bytes_between(self, start, end):
        return b"".join(data for stamp, data in self.chunks if start <= stamp < end)

    def all_bytes(self):
        return b"".join(data for _, data in self.chunks)

    def finish(self, timeout=5.0):
        """Pump until the child exits; return its exit status."""
        deadline = time.monotonic() + timeout
        while self.proc.poll() is None and time.monotonic() < deadline:
            self.pump(0.1)
        if self.proc.poll() is None:
            self.proc.kill()
            raise Failure("child did not exit in time")
        self.pump(0.2)
        status = self.proc.returncode
        os.close(self.master)
        if self.responder is not None:
            self.responder.stdin.close()
            self.responder.wait(timeout=2)
            self.responder = None
        return status


class Dump:
    """One corta-dump run over a capture."""

    def __init__(self, binary, capture, rows=ROWS, cols=COLS, history=False, scrollback=None):
        command = [binary, "--rows", str(rows), "--columns", str(cols), "--report"]
        if history:
            command.append("--history")
        command += ["--scrollback", str(scrollback if scrollback is not None else 1000)]
        result = subprocess.run(command, input=capture, capture_output=True, timeout=60)
        if result.returncode != 0:
            # `errors="replace"`: corta-dump is fed hostile bytes by design,
            # and a stderr line that is not valid UTF-8 must not turn a clean
            # FAIL with diagnostics into a harness crash with none.
            detail = result.stderr.decode("utf-8", errors="replace")
            raise Failure(f"corta-dump exited {result.returncode}: {detail}")
        self.text = result.stdout.decode("utf-8", errors="replace")
        self.report = {}
        if "--- report ---" in self.text:
            grid, _, report = self.text.partition("--- report ---\n")
            self.grid = grid
            for line in report.splitlines():
                key, _, value = line.partition(" = ")
                self.report[key] = value
        else:
            self.grid = self.text

    def grid_rows(self):
        """The dump's text rows (scrollback rows numbered negative included),
        stripped of the `N |...|` framing. The trailing `styles:` section is
        framed identically, so stop there — its rows are not text."""
        rows = []
        for line in self.grid.splitlines():
            if line.startswith("styles:"):
                break
            match = re.match(r"\s*-?\d+ \|(.*)\|$", line)
            if match:
                rows.append(match.group(1))
        return rows

    def require(self, needle, where="grid"):
        haystack = self.grid if where == "grid" else self.text
        if needle not in haystack:
            raise Failure(f"expected {needle!r} in {where}\n---\n{self.text}")


def needs(*programs):
    def decorate(fn):
        fn.__programs__ = list(programs)
        return fn
    return decorate


# MARK: - scenarios


@scenario("zsh: echo, line editing with erase, clean exit")
@needs("zsh")
def zsh_workflow(ctx):
    session = PtySession(["zsh", "-f"])
    session.pump(0.6)  # prompt
    session.send(b"echo U10ZSHOK\r")
    # Type "echo aac", erase the typo, retype: the echoed command line must
    # read "echo XY" — ZLE's redraw has to land correctly in the grid.
    session.send(b"echo aac\x7f\x7f\x7fXY\r")
    before_exit = session.mark()
    session.send(b"exit\r")
    status = session.finish()
    if status != 0:
        raise Failure(f"zsh exited {status}")
    # Slice before `exit`: zsh turns bracketed paste off as it leaves, so the
    # end-of-capture state says nothing about what it asked for while running.
    dump = Dump(ctx.dump, session.bytes_before(before_exit))
    dump.require("U10ZSHOK")
    rows = dump.grid_rows()
    if not any("echo XY" in row for row in rows):
        raise Failure("edited command line never read 'echo XY':\n" + "\n".join(rows))
    if not any(row.startswith("XY") or " XY" in row for row in rows):
        raise Failure("output of the edited command ('XY') missing:\n" + "\n".join(rows))
    if dump.report.get("bracketed-paste") != "true":
        raise Failure("zsh -f did not enable bracketed paste per the core: " + str(dump.report))


@scenario("zsh: bracketed paste does not execute, return does")
@needs("zsh")
def zsh_bracketed_paste(ctx):
    session = PtySession(["zsh", "-f"])
    session.pump(0.6)
    # Pasted newlines are literal under ?2004; the command runs only on the
    # real Return that follows. If the core mishandled the brackets, the
    # paste itself would execute and the marker would appear twice.
    session.send(b"\x1b[200~echo U10PASTE\nnotacommand-at-all\x1b[201~", settle=0.4)
    session.send(b"\r")
    session.send(b"exit\r")
    session.finish()
    dump = Dump(ctx.dump, session.all_bytes())
    if dump.grid.count("U10PASTE") < 2:  # echoed command + its output
        raise Failure("pasted command did not run exactly once:\n" + dump.text)


@scenario("zsh: OSC 52 copy request decodes to clipboard text")
@needs("zsh")
def zsh_clipboard_copy(ctx):
    payload = base64.b64encode(b"U10CLIPBOARD").decode()
    session = PtySession(["zsh", "-f"])
    session.pump(0.6)
    session.send(f"printf '\\e]52;c;{payload}\\a'\r".encode())
    session.send(b"exit\r")
    session.finish()
    dump = Dump(ctx.dump, session.all_bytes())
    if dump.report.get("clipboard-copy") != "U10CLIPBOARD":
        raise Failure("OSC 52 payload did not decode: " + str(dump.report))


@scenario("tmux: full-screen client renders, status bar on the last row")
@needs("tmux")
def tmux_workflow(ctx):
    session = PtySession(["tmux", "-f", "/dev/null", "new-session", "-x", str(COLS), "-y", str(ROWS)])
    session.pump(1.0)
    session.send(b"echo U10TMUXOK\r", settle=0.6)
    before_exit = session.mark()
    session.send(b"exit\r")  # shell exits, tmux detaches-and-exits
    status = session.finish()
    if status != 0:
        raise Failure(f"tmux exited {status}")
    # tmux runs on the alternate screen and restores the primary one as it
    # detaches, so only the pre-exit slice still holds what it drew.
    dump = Dump(ctx.dump, session.bytes_before(before_exit))
    dump.require("U10TMUXOK")
    rows = dump.grid_rows()
    if "[0]" not in rows[-1]:
        raise Failure(f"status bar not on the last row: {rows[-1]!r}")


@scenario("tmux: mid-session SIGWINCH repaint stays coherent at 100x30")
@needs("tmux")
def tmux_resize(ctx):
    session = PtySession(["tmux", "-f", "/dev/null", "new-session", "-x", str(COLS), "-y", str(ROWS)])
    session.pump(1.0)
    session.send(b"echo U10BEFORE\r")
    session.resize(30, 100, settle=1.0)
    session.send(b"echo U10AFTER\r", settle=0.6)
    before_exit = session.mark()
    session.send(b"exit\r")
    session.finish()
    # The core never sees the resize — a byte stream carries no geometry —
    # so replay the post-resize repaint into a terminal of the new size.
    # tmux repaints absolutely after SIGWINCH, which is what makes this
    # slice meaningful.
    # Between the SIGWINCH and the exit: after it, tmux restores the primary
    # screen and the repaint under test is gone.
    dump = Dump(ctx.dump, session.bytes_between(session.resized_at, before_exit),
                rows=30, cols=100)
    rows = dump.grid_rows()
    if len(rows) != 30:
        raise Failure(f"expected 30 rows, got {len(rows)}")
    if not any("U10AFTER" in row for row in rows):
        raise Failure("post-resize marker missing:\n" + "\n".join(rows))
    # tmux's default status line carries the session name "[0]"; after the
    # resize it must sit on the last row of the new geometry.
    if "[0]" not in rows[-1]:
        raise Failure(f"status bar not on the last row after resize: {rows[-1]!r}")


@scenario("less: paging and search in the alternate screen")
@needs("less")
def less_workflow(ctx):
    target = os.path.join(ctx.tmp, "u10-less.txt")
    with open(target, "w") as file:
        for i in range(1, 201):
            file.write(f"log line {i} {'the needle is here' if i == 150 else 'nothing'}\n")
    session = PtySession(["less", target])
    session.pump(0.6)
    session.send(b" ", settle=0.4)  # page down
    session.send(b"/needle\r", settle=0.6)  # search lands on line 150
    found = Dump(ctx.dump, session.all_bytes())
    found.require("the needle is here")
    session.send(b"q", settle=0.4)
    status = session.finish()
    if status != 0:
        raise Failure(f"less exited {status}")


@scenario("vim: insert, save, quit end to end")
@needs("vim")
def vim_workflow(ctx):
    target = os.path.join(ctx.tmp, "u10-vim.txt")
    session = PtySession(["vim", "-u", "NONE", target])
    session.pump(1.0)
    session.send(b"iHello U10 VIM\x1b", settle=0.5)
    editing = Dump(ctx.dump, session.all_bytes())
    editing.require("Hello U10 VIM")
    session.send(b":wq\r", settle=0.6)
    status = session.finish()
    if status != 0:
        raise Failure(f"vim exited {status}")
    with open(target) as file:
        contents = file.read()
    if "Hello U10 VIM" not in contents:
        raise Failure(f"vim did not save the buffer: {contents!r}")


@scenario("fish: prompt, echo and clean exit")
@needs("fish")
def fish_workflow(ctx):
    # fish is the one client here that will not start without a terminal
    # answering it (see `PtySession.responder`).
    session = PtySession(
        ["fish", "--no-config", "--interactive"], responder=ctx.dump)
    session.pump(1.5)
    session.send(b"echo U10FISHOK\r", settle=0.6)
    before_exit = session.mark()
    session.send(b"exit\r")
    status = session.finish()
    if status != 0:
        raise Failure(f"fish exited {status}")
    dump = Dump(ctx.dump, session.bytes_before(before_exit))
    dump.require("U10FISHOK")


@scenario("nvim: insert, save, quit end to end")
@needs("nvim")
def nvim_workflow(ctx):
    target = os.path.join(ctx.tmp, "u10-nvim.txt")
    session = PtySession(["nvim", "-u", "NONE", "-i", "NONE", target])
    session.pump(1.5)
    session.send(b"iHello U10 NVIM\x1b", settle=0.6)
    editing = Dump(ctx.dump, session.all_bytes())
    editing.require("Hello U10 NVIM")
    session.send(b":wq\r", settle=0.8)
    status = session.finish()
    if status != 0:
        raise Failure(f"nvim exited {status}")
    with open(target) as file:
        contents = file.read()
    if "Hello U10 NVIM" not in contents:
        raise Failure(f"nvim did not save the buffer: {contents!r}")


@scenario("fzf: interactive filter narrows and returns a selection")
@needs("fzf", "zsh")
def fzf_workflow(ctx):
    # fzf draws on /dev/tty (the PTY) while its list arrives on a pipe, so it
    # exercises the alternate-screen-plus-cursor-addressing path a picker uses.
    session = PtySession(
        ["zsh", "-fc", "printf 'alpha\\nbeta\\ngamma\\n' | fzf --height=100% > " +
         os.path.join(ctx.tmp, "u10-fzf.out")])
    session.pump(1.0)
    session.send(b"bet", settle=0.6)
    filtering = Dump(ctx.dump, session.all_bytes())
    filtering.require("beta")
    session.send(b"\r", settle=0.5)
    status = session.finish()
    if status != 0:
        raise Failure(f"fzf pipeline exited {status}")
    with open(os.path.join(ctx.tmp, "u10-fzf.out")) as file:
        chosen = file.read().strip()
    if chosen != "beta":
        raise Failure(f"fzf returned {chosen!r}, not 'beta'")


@scenario("mouse: a real program receives SGR press, release and wheel bytes")
@needs("python3")
def mouse_reporting(ctx):
    # A minimal mouse consumer: enable ?1000+?1006, then echo every byte it
    # receives as hex. This is exactly what fzf/nvim/tmux sit behind; the
    # harness plays the terminal's encoding half (SGRMouse in the app) and
    # the core's mode tracking is asserted through corta-dump --report.
    child = (
        "import os,sys,tty,termios\n"
        "tty.setraw(0)\n"
        "sys.stdout.write('\\x1b[?1000h\\x1b[?1006hMOUSE-READY\\r\\n')\n"
        "sys.stdout.flush()\n"
        "buf=b''\n"
        "while True:\n"
        "    b=os.read(0,1)\n"
        "    if b==b'Q': break\n"
        "    buf+=b\n"
        "    if b in b'Mm':\n"
        "        sys.stdout.write('GOT '+buf.hex()+'\\r\\n'); sys.stdout.flush(); buf=b''\n"
        "os.write(1,b'\\x1b[?1006l\\x1b[?1000l')\n"
    )
    session = PtySession(["python3", "-c", child])
    session.pump(0.8)
    session.send(b"\x1b[<0;10;5M")   # left press at column 10, row 5
    session.send(b"\x1b[<0;10;5m")   # release
    session.send(b"\x1b[<64;3;1M")   # wheel up
    session.send(b"Q", settle=0.4)
    session.finish()
    dump = Dump(ctx.dump, session.all_bytes())
    dump.require("MOUSE-READY")
    for expected in ("1b5b3c303b31303b354d", "1b5b3c303b31303b356d", "1b5b3c36343b333b314d"):
        dump.require("GOT " + expected)
    if dump.report.get("sgr-mouse-encoding") != "false":
        raise Failure("?1006 still set after the child reset it: " + str(dump.report))


@scenario("sustained log output: 20k lines into a bounded scrollback")
@needs("zsh")
def sustained_log(ctx):
    session = PtySession(
        ["zsh", "-fc", "i=0; while (( i < 20000 )); do echo \"log line $i filler\"; (( i++ )); done"])
    started = time.monotonic()
    status = session.finish(timeout=120)
    elapsed = time.monotonic() - started
    if status != 0:
        raise Failure(f"logger exited {status}")
    capture = session.all_bytes()
    if len(capture) < 400_000:
        raise Failure(f"suspiciously little output: {len(capture)} bytes")
    replay = Dump(ctx.dump, capture, history=True, scrollback=5000)
    replay.require("log line 19999 filler", where="dump")
    replay.require("log line 15000 filler", where="dump")
    print(f"    (20k lines / {len(capture)} bytes captured in {elapsed:.1f}s)")


@scenario("ssh to localhost")
@needs("ssh")
def ssh_localhost(ctx):
    # `UserKnownHostsFile=/dev/null` matters more than it looks:
    # `StrictHostKeyChecking=no` alone still *appends* localhost's key to the
    # user's `~/.ssh/known_hosts`, which is a change to the machine that
    # outlives the test run — the one thing this project's rules say a test
    # may never do. Sending it to /dev/null keeps the check to a check.
    # `BatchMode` and the timeouts keep it from stopping on a prompt: this
    # scenario asks whether sshd is there, and a harness that hangs waiting
    # for a password has stopped asking that.
    options = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=3",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
    ]
    probe = subprocess.run(
        ["ssh"] + options + ["localhost", "true"], capture_output=True, timeout=15)
    if probe.returncode != 0:
        detail = probe.stderr.decode("utf-8", errors="replace").strip().splitlines()
        raise Skip("sshd unavailable: " + (detail[0][:80] if detail else "no detail"))
    session = PtySession(["ssh"] + options + ["localhost", "echo U10SSHOK"])
    session.finish(timeout=15)
    Dump(ctx.dump, session.all_bytes()).require("U10SSHOK")


class Context:
    def __init__(self, dump, tmp):
        self.dump = dump
        self.tmp = tmp


def main():
    dump_binary = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DUMP
    if not os.path.exists(dump_binary):
        print(f"corta-dump not found at {dump_binary}; build it first:", file=sys.stderr)
        print("  cd CortaTerminal && swift build", file=sys.stderr)
        return 2
    import tempfile
    with tempfile.TemporaryDirectory(prefix="u10-") as tmp:
        ctx = Context(dump_binary, tmp)
        for fn in list(globals().values()):
            if callable(fn) and hasattr(fn, "__programs__") and fn.__name__ != "scenario":
                fn(ctx)
    width = max(len(name) for _, name, _ in RESULTS)
    failed = 0
    for status, name, detail in RESULTS:
        print(f"{status:<5} {name:<{width}} {detail}")
        if status in ("FAIL", "ERROR"):
            failed += 1
    print(f"\n{sum(1 for s, _, _ in RESULTS if s == 'PASS')} passed, "
          f"{sum(1 for s, _, _ in RESULTS if s == 'SKIP')} skipped, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
