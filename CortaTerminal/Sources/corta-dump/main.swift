import CortaTerminal
import Darwin

/// `corta-dump` — feed bytes on stdin to a terminal, print the grid.
///
/// The point of it is that the core can be checked by hand, against a real
/// program's output, without a window:
///
///     printf 'a\tb\e[31mred\e[m' | corta-dump --rows 4 --columns 20
///     ls --color=always | corta-dump
///     script -q /dev/null vim  # … and feed the capture in
///
/// It reads in chunks, so a UTF-8 character or an escape sequence split
/// across a read boundary is exercised rather than hidden.

let usage = """
    usage: corta-dump [options] < bytes

    Reads a byte stream on stdin, feeds it to a terminal, and prints the
    resulting grid.

      --rows N          screen height (default 24)
      --columns N       screen width (default 80)
      --scrollback N    history line cap (default 1000)
      --history         print the scrollback above the screen
      --help            this message
    """

func fail(_ message: String) -> Never {
    FileHandle.write(message + "\n", to: STDERR_FILENO)
    exit(2)
}

enum FileHandle {
    static func write(_ text: String, to descriptor: Int32) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBufferPointer { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
    }
}

var rows = 24
var columns = 80
var scrollbackLimit = 1_000
var showHistory = false

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    func number() -> Int {
        guard let raw = arguments.next(), let value = Int(raw), value > 0 else {
            fail("\(argument) needs a positive number")
        }
        return value
    }
    switch argument {
    case "--rows": rows = number()
    case "--columns": columns = number()
    case "--scrollback": scrollbackLimit = number()
    case "--history": showHistory = true
    case "--help", "-h":
        FileHandle.write(usage, to: STDOUT_FILENO)
        exit(0)
    default:
        fail("unknown option \(argument)\n\n\(usage)")
    }
}

var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)

// 64 KiB at a time. Chunk boundaries fall wherever they fall, which is the
// same thing the PTY reader will do.
let chunkSize = 64 * 1024
var buffer = [UInt8](repeating: 0, count: chunkSize)
while true {
    let count = buffer.withUnsafeMutableBufferPointer { pointer in
        read(STDIN_FILENO, pointer.baseAddress, chunkSize)
    }
    if count < 0 {
        if errno == EINTR { continue }
        fail("read: \(String(cString: strerror(errno)))")
    }
    if count == 0 { break }
    terminal.feed(buffer[0..<count])
}

FileHandle.write(
    terminal.dump(options: DumpOptions(includeScrollback: showHistory)),
    to: STDOUT_FILENO
)
