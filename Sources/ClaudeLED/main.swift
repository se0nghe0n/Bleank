// Bleank — drive the MagSafe 3 LED from Claude Code hooks.
//
// A root daemon polls a state file that unprivileged hooks write one word into.
// Root is unavoidable (SMC writes) and a loop is unavoidable (the LED has no
// hardware blink mode), so those two facts pick the architecture.
//
//   swiftc -O claude-led.swift -o claude-led
//   ./claude-led selftest        # no root
//   sudo ./claude-led test       # prove the hardware
//   sudo ./claude-led daemon [statefile]

import Foundation
import IOKit

// MARK: - LED values (SMC key ACLC)

let systemControl: UInt8 = 0x00 // hand the LED back to macOS
let ledOff: UInt8 = 0x01
let green: UInt8 = 0x03
let amber: UInt8 = 0x04 // ponytail: MagSafe has no red element — amber is as close as the hardware gets

// ponytail: 1.25 Hz. The SMC's tolerance for faster writes is untested; raise
// only after watching for missed writes on your own machine.
let halfPeriod = 0.4
// macOS reasserts the LED on charging-state changes, so re-write periodically
// even when nothing changed.
let refreshInterval = 5.0
// If the agent dies without running its session-end hook (crash, kill -9), the
// state file goes stale. After this long, hand the LED back to macOS instead
// of showing the last state forever.
let staleTimeout = 600.0

let defaultStatePath = "/tmp/claude-led.state"

// MARK: - Mode

enum Mode: String {
    case thinking, responding, done, waiting, off, system

    func color(phase: Bool) -> UInt8 {
        switch self {
        case .thinking: return phase ? amber : ledOff
        case .responding: return phase ? green : ledOff
        case .done: return green
        case .waiting: return amber // ponytail: no red element in the LED — solid amber is "needs you"
        case .off: return ledOff
        case .system: return systemControl
        }
    }
}

// ponytail: last writer wins across concurrent Claude Code sessions.
func readMode(_ path: String) -> Mode {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return .system }
    return Mode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .system
}

// A state file that hasn't been touched in staleTimeout means the agent that
// owns it is gone (crashed, killed, terminal closed) — or never existed.
func stateIsStale(_ path: String, now: Date = Date()) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date else { return true } // missing counts as stale
    return now.timeIntervalSince(mtime) > staleTimeout
}

// MARK: - SMC

// Layout must match C's SMCParamStruct (80 bytes). `padding` exists only to
// make Swift's field offsets line up with C's; the precondition below is the check.
struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

let kSMCHandleYPCEvent: UInt32 = 2
let kSMCWriteKey: UInt8 = 6
let kSMCGetKeyInfo: UInt8 = 9

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

let aclc = fourCC("ACLC")

struct SMCError: Error { let message: String }

final class SMC {
    private var conn: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError(message: "AppleSMC service not found") }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else {
            throw SMCError(message: "IOServiceOpen failed (0x\(String(kr, radix: 16))) — run as root")
        }
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var inCopy = input
        var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &inCopy,
                                           MemoryLayout<SMCParamStruct>.stride, &out, &outSize)
        guard kr == kIOReturnSuccess else {
            throw SMCError(message: "IOConnectCallStructMethod = 0x\(String(kr, radix: 16))")
        }
        guard out.result == 0 else {
            throw SMCError(message: "SMC result = \(out.result)"
                + (out.result == 132 ? " (key not present — no MagSafe port?)" : ""))
        }
        return out
    }

    func write(_ value: UInt8) throws {
        var probe = SMCParamStruct()
        probe.key = aclc
        probe.data8 = kSMCGetKeyInfo
        let info = try call(probe)

        var w = SMCParamStruct()
        w.key = aclc
        w.keyInfo.dataSize = info.keyInfo.dataSize
        w.data8 = kSMCWriteKey
        w.bytes.0 = value
        _ = try call(w)
    }
}

// MARK: - Commands

// Restore on the way out, including SIGTERM from launchctl.
var globalSMC: SMC?
func restoreAndExit(_ sig: Int32) {
    try? globalSMC?.write(systemControl)
    _exit(sig == 0 ? 0 : 128 + sig)
}

func daemon(statePath: String) throws {
    let smc = try SMC()
    globalSMC = smc
    for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, restoreAndExit) }

    var phase = false
    var lastValue: UInt8?
    var lastWrite = Date.distantPast

    while true {
        // A stale state file means the agent is gone — let macOS decide the LED.
        let want = (stateIsStale(statePath) ? Mode.system : readMode(statePath)).color(phase: phase)
        let now = Date()
        if want != lastValue || now.timeIntervalSince(lastWrite) > refreshInterval {
            do { try smc.write(want) } catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!) }
            lastValue = want
            lastWrite = now
        }
        phase.toggle()
        Thread.sleep(forTimeInterval: halfPeriod)
    }
}

func hardwareTest() throws {
    let smc = try SMC()
    globalSMC = smc
    for (name, value) in [("amber", amber), ("green", green), ("off", ledOff)] {
        print("\(name) …")
        try smc.write(value)
        Thread.sleep(forTimeInterval: 1.5)
    }
    print("back to system control")
    try smc.write(systemControl)
}

func selftest() {
    precondition(MemoryLayout<SMCParamStruct>.stride == 80,
                 "SMCParamStruct is \(MemoryLayout<SMCParamStruct>.stride) bytes, kernel expects 80")
    precondition(fourCC("ACLC") == 0x4143_4C43)

    precondition(Mode.thinking.color(phase: true) == amber)
    precondition(Mode.thinking.color(phase: false) == ledOff)
    precondition(Mode.responding.color(phase: true) == green)
    precondition(Mode.responding.color(phase: false) == ledOff)
    precondition(Mode.done.color(phase: true) == green && Mode.done.color(phase: false) == green)
    precondition(Mode.waiting.color(phase: true) == amber && Mode.waiting.color(phase: false) == amber)
    precondition(Mode.system.color(phase: true) == systemControl)

    let tmp = NSTemporaryDirectory() + "bleank-selftest"
    try! "  responding\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    precondition(readMode(tmp) == .responding)
    try! "garbage".write(toFile: tmp, atomically: true, encoding: .utf8)
    precondition(readMode(tmp) == .system, "unknown state must fall back to system control")
    try? FileManager.default.removeItem(atPath: tmp)
    precondition(readMode(tmp) == .system, "missing state file must fall back to system control")

    try! "done".write(toFile: tmp, atomically: true, encoding: .utf8)
    precondition(!stateIsStale(tmp, now: Date().addingTimeInterval(staleTimeout - 1)),
                 "fresh state file must not be stale")
    precondition(stateIsStale(tmp, now: Date().addingTimeInterval(staleTimeout + 1)),
                 "old state file must count as stale")
    try? FileManager.default.removeItem(atPath: tmp)
    precondition(stateIsStale(tmp), "missing state file must count as stale")

    print("selftest ok")
}

let args = CommandLine.arguments
do {
    switch args.count > 1 ? args[1] : "" {
    case "daemon": try daemon(statePath: args.count > 2 ? args[2] : defaultStatePath)
    case "test": try hardwareTest()
    case "selftest": selftest()
    default:
        print("usage: claude-led daemon [statefile] | test | selftest")
        exit(2)
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
