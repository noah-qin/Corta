# ``corta_exec``

The second half of a terminal child's spawn.

## Overview

`Spawn.child` starts this helper with `posix_spawn` as a session leader,
the PTY on file descriptors 0, 1 and 2 and its working directory set. It
does the one thing `posix_spawn` cannot express — `TIOCSCTTY`, making the
PTY its controlling terminal — then executes the shell. It runs in a fresh,
single-threaded image, so ordinary Swift is safe in it, and is never run
by hand.
