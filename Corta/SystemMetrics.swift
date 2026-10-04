// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import SystemConfiguration

nonisolated struct SystemMetrics: Equatable, Sendable {
    enum Item: String, CaseIterable, Sendable {
        case cpu, load, memory, network, disk, thermal
    }
    var cpuPercent: Double?
    var load: [Double] = []
    var memoryUsed: UInt64?
    var memoryCompressed: UInt64?
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var networkInterface: String?
    var downloadRate: Double?
    var uploadRate: Double?
    var diskAvailable: Int64?
    var diskTotal: Int64?
    var thermal: ProcessInfo.ThermalState?
}

/// State belongs to an actor, so sampling never blocks the UI or overlaps.
actor SystemMetricsSampler {
    private var previousCPU: [UInt32]?
    private var previousNetwork: (name: String, index: UInt32, input: UInt32, output: UInt32, time: TimeInterval)?
    private var diskSample: (available: Int64?, total: Int64?, time: TimeInterval)?

    func reset() {
        previousCPU = nil
        previousNetwork = nil
    }

    func sample(items: Set<SystemMetrics.Item>, interface: String) -> SystemMetrics {
        var result = SystemMetrics()
        let now = ProcessInfo.processInfo.systemUptime
        if items.contains(.cpu) {
            if let ticks = Self.cpuTicks() {
                if let previousCPU { result.cpuPercent = Self.cpuUsage(previous: previousCPU, current: ticks) }
                previousCPU = ticks
            } else { previousCPU = nil }
        } else { previousCPU = nil }
        if items.contains(.load) {
            var values = [Double](repeating: 0, count: 3)
            if getloadavg(&values, 3) == 3 { result.load = values }
        }
        if items.contains(.memory), let memory = Self.memoryUsage() {
            result.memoryUsed = memory.used
            result.memoryCompressed = memory.compressed
        }
        if items.contains(.network) {
            let candidates = Self.networkCounters()
            let primary = Self.primaryInterface()
            if let selected = Self.selectInterface(candidates.map(\.name), requested: interface, primary: primary),
                let counter = candidates.first(where: { $0.name == selected }) {
                result.networkInterface = counter.name
                if let previousNetwork, previousNetwork.name == counter.name, previousNetwork.index == counter.index {
                    let elapsed = now - previousNetwork.time
                    if elapsed > 0 && elapsed <= 5 {
                        result.downloadRate = Double(Self.counterDelta(previousNetwork.input, counter.input)) / elapsed
                        result.uploadRate = Double(Self.counterDelta(previousNetwork.output, counter.output)) / elapsed
                    }
                }
                previousNetwork = (counter.name, counter.index, counter.input, counter.output, now)
            } else { previousNetwork = nil }
        } else { previousNetwork = nil }
        if items.contains(.disk) {
            if diskSample == nil || now - diskSample!.time >= 30 {
                let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
                    forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                diskSample = (values?.volumeAvailableCapacity.map(Int64.init), values?.volumeTotalCapacity.map(Int64.init), now)
            }
            result.diskAvailable = diskSample?.available
            result.diskTotal = diskSample?.total
        }
        if items.contains(.thermal) { result.thermal = ProcessInfo.processInfo.thermalState }
        return result
    }

    nonisolated static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100
    }

    /// if_data byte counters are 32-bit. Handle a wrap near the boundary,
    /// but treat ordinary decreases as an interface reset, not a traffic spike.
    nonisolated static func counterDelta(_ previous: UInt32, _ current: UInt32) -> UInt32 {
        if current >= previous { return current - previous }
        if previous > 0xf0000000 && current < 0x10000000 { return current &- previous }
        return 0
    }

    nonisolated static func selectInterface(_ names: [String], requested: String, primary: String?) -> String? {
        if requested != "auto" { return names.contains(requested) ? requested : nil }
        if let primary, names.contains(primary) { return primary }
        let ordered = names.sorted()
        return ordered.first(where: { $0.hasPrefix("en") })
            ?? ordered.first(where: { !$0.hasPrefix("utun") && !$0.hasPrefix("awdl") && !$0.hasPrefix("llw") })
            ?? ordered.first
    }

    nonisolated private static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    nonisolated private static func memoryUsage() -> (used: UInt64, compressed: UInt64)? {
        var info = vm_statistics64_data_t()
        // REV1 includes wired, anonymous and compressed pages, and remains
        // compatible with the minimum macOS 26 target and newer revisions.
        let revisionBytes = MemoryLayout<vm_statistics64_data_t>.offset(of: \.swapped_count) ?? MemoryLayout<vm_statistics64_data_t>.size
        var count = mach_msg_type_number_t(revisionBytes / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let compressed = UInt64(info.compressor_page_count) * UInt64(pageSize)
        let used = (UInt64(info.wire_count) + UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))) * UInt64(pageSize) + compressed
        return (min(used, ProcessInfo.processInfo.physicalMemory), compressed)
    }

    nonisolated private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Corta status" as CFString, nil, nil) else { return nil }
        for family in ["IPv4", "IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
                let name = value["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    nonisolated private static func networkCounters() -> [(name: String, index: UInt32, input: UInt32, output: UInt32)] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(first) }
        var result: [(String, UInt32, UInt32, UInt32)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            pointer = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                let data = entry.ifa_data, let name = entry.ifa_name else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result.append((String(cString: name), if_nametoindex(name), stats.ifi_ibytes, stats.ifi_obytes))
        }
        return result
    }
}
