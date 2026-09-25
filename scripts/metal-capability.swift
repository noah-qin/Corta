// Reports the GPU families this machine's default Metal device supports,
// as one line, and optionally fails when Metal 4 is missing.
//
// The one implementation of that question (issue #107): `ci.yml` prints it
// on the hosted runner, `render.yml` requires it on the self-hosted one,
// and a maintainer runs it before a local render-test pass —
// `docs/TESTING.md`. Two copies of it in two workflows is how the answer
// starts differing by where it was asked.
//
//   swift scripts/metal-capability.swift [--require-metal4]
//
// Exit status is 0, or 1 with `--require-metal4` on a device that does not
// report `MTLGPUFamily.metal4` (and always 1 when there is no device at
// all, which no environment this project supports should produce).

import Metal

let requireMetal4 = CommandLine.arguments.contains("--require-metal4")

guard let device = MTLCreateSystemDefaultDevice() else {
    print(
        "metal-capability: device=none metal4=unknown "
            + "(MTLCreateSystemDefaultDevice returned nil)")
    exit(1)
}

// Newest first, so the printed list reads as a capability ceiling.
let families: [(String, MTLGPUFamily)] = [
    ("metal4", .metal4), ("apple9", .apple9), ("apple8", .apple8),
    ("apple7", .apple7), ("apple5", .apple5),
]
let supported = families.filter { device.supportsFamily($0.1) }.map(\.0)
let hasMetal4 = device.supportsFamily(.metal4)

print(
    "metal-capability: device=\"\(device.name)\" metal4=\(hasMetal4) "
        + "families=[\(supported.joined(separator: ","))]")

if requireMetal4 && !hasMetal4 {
    print(
        "metal-capability: this job needs MTLGPUFamily.metal4 and this "
            + "device does not report it — see docs/TESTING.md")
    exit(1)
}
