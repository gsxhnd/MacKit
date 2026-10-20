//
//  main.swift
//  MacKitFanHelper
//
//  以 root 运行的风扇控制 helper。只接受风扇 RPM 控制，不暴露任意 SMC 写入。
//  通过 Unix domain socket 与 MacKit 通信；客户端断开或心跳超时后自动恢复自动模式。
//

import Darwin
import Foundation
import IOKit

// MARK: - SMC 参数结构

typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
typealias SMCBytes20 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData: SMCBytes20 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    init() {}

    func byteArray(_ count: Int) -> [UInt8] {
        withUnsafeBytes(of: bytes) { Array($0.prefix(count)) }
    }

    static func tuple(_ values: [UInt8]) -> SMCBytes32 {
        var padded = Array(values.prefix(32))
        if padded.count < 32 {
            padded.append(contentsOf: Array(repeating: 0, count: 32 - padded.count))
        }
        return (
            padded[0], padded[1], padded[2], padded[3],
            padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11],
            padded[12], padded[13], padded[14], padded[15],
            padded[16], padded[17], padded[18], padded[19],
            padded[20], padded[21], padded[22], padded[23],
            padded[24], padded[25], padded[26], padded[27],
            padded[28], padded[29], padded[30], padded[31]
        )
    }
}

// MARK: - 基础工具

nonisolated(unsafe) var stopRequested: Int32 = 0

func log(_ message: String) {
    FileHandle.standardError.write(Data(("[MacKitFanHelper] " + message + "\n").utf8))
}

func fourCC(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in string.utf8 {
        result = (result << 8) | UInt32(byte)
    }
    return result
}

func fourCCString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(decoding: bytes, as: UTF8.self)
}

func handleSignal(_ signalValue: Int32) {
    stopRequested = 1
}

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - SMC

final class SMCConnection {
    private var connection: io_connect_t = 0
    private static let selector: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9

    init() throws {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            throw HelperError("SMCParamStruct 布局错误：\(MemoryLayout<SMCParamStruct>.stride)")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw HelperError("找不到 AppleSMC") }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw HelperError("打开 AppleSMC 失败：\(result)")
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = Self.cmdReadKeyInfo
        return try call(input).keyInfo
    }

    func read(_ key: String) throws -> (SMCKeyInfo, [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo = info
        input.data8 = Self.cmdReadBytes
        let output = try call(input)
        return (info, output.byteArray(Int(info.dataSize)))
    }

    func readUInt8(_ key: String) throws -> UInt8 {
        let (info, bytes) = try read(key)
        guard info.dataSize >= 1, let first = bytes.first else {
            throw HelperError("\(key) 数据为空")
        }
        return first
    }

    func readFloat(_ key: String) throws -> Double {
        let (info, bytes) = try read(key)
        guard info.dataSize >= 4, bytes.count >= 4 else {
            throw HelperError("\(key) 不是 4 字节浮点")
        }
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count <= Int(info.dataSize) else {
            throw HelperError("\(key) 写入长度 \(bytes.count) 超过 \(info.dataSize)")
        }
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo = info
        input.data8 = Self.cmdWriteBytes
        input.bytes = SMCParamStruct.tuple(bytes)
        _ = try call(input)
    }

    func writeUInt8(_ key: String, _ value: UInt8) throws {
        try write(key, bytes: [value])
    }

    func writeFloat(_ key: String, _ value: Double) throws {
        guard value.isFinite else { throw HelperError("无效的浮点值") }
        var float = Float(value)
        let bytes = withUnsafeBytes(of: &float) { Array($0) }
        try write(key, bytes: bytes)
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var mutableInput = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = withUnsafePointer(to: &mutableInput) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.selector,
                    inputPointer,
                    MemoryLayout<SMCParamStruct>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }

        guard result == KERN_SUCCESS else {
            throw HelperError("SMC 调用失败 key=\(fourCCString(input.key)) kern=\(result)")
        }
        guard output.result == 0 else {
            throw HelperError("SMC 返回错误 key=\(fourCCString(input.key)) result=\(output.result)")
        }
        return output
    }
}

// MARK: - 风扇控制

struct FanCapability {
    let index: Int
    let actualKey: String
    let targetKey: String
    let minimumKey: String
    let maximumKey: String
    let modeKey: String?
}

struct FanReading: Encodable {
    let index: Int
    let actualRPM: Double?
    let targetRPM: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let mode: UInt8?
}

final class FanController {
    let smc: SMCConnection
    let fans: [FanCapability]
    let hasFtst: Bool
    private var manualFans = Set<Int>()
    private var ftstActive = false
    private var targets: [Int: Double] = [:]

    init(smc: SMCConnection) throws {
        self.smc = smc
        self.fans = Self.detectFans(smc: smc)
        self.hasFtst = (try? smc.keyInfo("Ftst")) != nil
        guard !fans.isEmpty else { throw HelperError("没有检测到可控风扇") }
    }

    private static func detectFans(smc: SMCConnection) -> [FanCapability] {
        var count = 0
        if let raw = try? smc.readUInt8("FNum") {
            count = Int(raw)
        } else {
            for index in 0..<4 where (try? smc.keyInfo("F\(index)Ac")) != nil {
                count = index + 1
            }
        }
        guard count > 0 else { return [] }

        return (0..<count).compactMap { index in
            guard let actualInfo = try? smc.keyInfo("F\(index)Ac") else { return nil }
            _ = actualInfo
            let modeKey = (try? smc.keyInfo("F\(index)Md")) != nil ? "F\(index)Md"
                : ((try? smc.keyInfo("F\(index)md")) != nil ? "F\(index)md" : nil)
            return FanCapability(
                index: index,
                actualKey: "F\(index)Ac",
                targetKey: "F\(index)Tg",
                minimumKey: "F\(index)Mn",
                maximumKey: "F\(index)Mx",
                modeKey: modeKey
            )
        }
    }

    func readings() -> [FanReading] {
        fans.map { fan in
            FanReading(
                index: fan.index,
                actualRPM: try? smc.readFloat(fan.actualKey),
                targetRPM: try? smc.readFloat(fan.targetKey),
                minimumRPM: try? smc.readFloat(fan.minimumKey),
                maximumRPM: try? smc.readFloat(fan.maximumKey),
                mode: fan.modeKey.flatMap { try? smc.readUInt8($0) }
            )
        }
    }

    func setManual(index: Int, requestedRPM: Double) throws {
        guard requestedRPM.isFinite, requestedRPM > 0 else {
            throw HelperError("无效的转速：\(requestedRPM)")
        }
        guard let fan = fans.first(where: { $0.index == index }) else {
            throw HelperError("风扇 \(index) 不存在")
        }
        guard let modeKey = fan.modeKey else {
            throw HelperError("风扇 \(index) 不支持手动模式")
        }

        let minRPM = (try? smc.readFloat(fan.minimumKey)) ?? 1000
        let maxRPM = (try? smc.readFloat(fan.maximumKey)) ?? 7000
        let safeMin = max(1000, minRPM)
        let safeMax = max(safeMin, maxRPM)
        let rpm = min(max(requestedRPM, safeMin), safeMax)

        try assertTemperatureSafe()

        var unlocked = false
        do {
            try smc.writeUInt8(modeKey, 1)
            unlocked = true
        } catch {
            if hasFtst {
                try smc.writeUInt8("Ftst", 1)
                ftstActive = true
                usleep(500_000)
                for _ in 0..<100 {
                    if stopRequested != 0 { break }
                    if (try? smc.writeUInt8(modeKey, 1)) != nil {
                        unlocked = true
                        break
                    }
                    usleep(100_000)
                }
            }
        }

        guard unlocked else {
            throw HelperError("无法切换到手动模式（可能被系统散热策略锁定）")
        }

        do {
            try smc.writeFloat(fan.targetKey, rpm)
        } catch {
            try? smc.writeUInt8(modeKey, 0)
            throw error
        }
        manualFans.insert(index)
        targets[index] = rpm

        // SMC 写入是异步生效的；短暂等待后检查模式，但不要因为回读延迟误报失败。
        usleep(350_000)
        for _ in 0..<4 {
            if stopRequested != 0 { break }
            if let mode = try? smc.readUInt8(modeKey), mode == 1 { break }
            try? smc.writeUInt8(modeKey, 1)
            try? smc.writeFloat(fan.targetKey, rpm)
            usleep(250_000)
        }
        if let mode = try? smc.readUInt8(modeKey), mode != 1 {
            try? smc.writeUInt8(modeKey, 0)
            manualFans.remove(index)
            targets.removeValue(forKey: index)
            clearFtstIfIdle()
            throw HelperError("风扇 \(index) 仍被系统接管（mode=\(mode)）")
        }
        log("fan \(index) manual \(Int(rpm)) RPM")
    }

    func setAuto(index: Int) throws {
        guard let fan = fans.first(where: { $0.index == index }) else {
            throw HelperError("风扇 \(index) 不存在")
        }
        if let modeKey = fan.modeKey {
            try smc.writeUInt8(modeKey, 0)
        }
        manualFans.remove(index)
        targets.removeValue(forKey: index)
        clearFtstIfIdle()
        log("fan \(index) auto")
    }

    func resetAll() {
        guard !manualFans.isEmpty || ftstActive else { return }
        for fan in fans {
            if let modeKey = fan.modeKey {
                try? smc.writeUInt8(modeKey, 0)
            }
        }
        manualFans.removeAll()
        targets.removeAll()
        clearFtstIfIdle()
        log("all fans auto")
    }

    func reassertIfNeeded() throws {
        guard !targets.isEmpty else { return }
        try assertTemperatureSafe()

        var failures: [String] = []
        for (index, target) in targets {
            guard let fan = fans.first(where: { $0.index == index }),
                  let modeKey = fan.modeKey else { continue }
            let mode = try? smc.readUInt8(modeKey)
            let currentTarget = try? smc.readFloat(fan.targetKey)
            if mode != 1 || abs((currentTarget ?? 0) - target) > 100 {
                do {
                    try smc.writeUInt8(modeKey, 1)
                    try smc.writeFloat(fan.targetKey, target)
                } catch {
                    failures.append("风扇 \(index)：\((error as? HelperError)?.description ?? String(describing: error))")
                }
            }
        }

        if !failures.isEmpty {
            resetAll()
            throw HelperError(failures.joined(separator: "；"))
        }
    }

    private func clearFtstIfIdle() {
        guard hasFtst, ftstActive, manualFans.isEmpty else { return }
        if (try? smc.readUInt8("Ftst")) == 1 {
            try? smc.writeUInt8("Ftst", 0)
        }
        ftstActive = false
    }

    private func maxTemperature() -> Double? {
        let keys = ["TCMz", "TCMb", "TRDX", "TPMP"]
        let values = keys.compactMap { key -> Double? in
            guard let value = try? smc.readFloat(key), value > 0, value < 130 else { return nil }
            return value
        }
        return values.max()
    }

    private func assertTemperatureSafe() throws {
        if let temperature = maxTemperature(), temperature > 103 {
            resetAll()
            throw HelperError("温度 \(String(format: "%.1f", temperature))°C 超过安全阈值，已恢复自动")
        }
    }
}

// MARK: - Socket 协议

struct FanRequest: Decodable {
    let cmd: String
    let index: Int?
    let rpm: Double?
}

struct FanResponse: Encodable {
    let ok: Bool
    let error: String?
    let message: String?
}

func sendResponse(_ response: FanResponse, to fd: Int32) -> Bool {
    let encoder = JSONEncoder()
    guard var data = try? encoder.encode(response) else { return false }
    data.append(0x0a)
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        var offset = 0
        while offset < raw.count {
            let written = send(fd, base.advanced(by: offset), raw.count - offset, 0)
            if written <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}

func readLine(from fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let count = recv(fd, &byte, 1, 0)
        if count == 0 { return nil }
        if count < 0 {
            if errno == EINTR {
                if stopRequested != 0 { return nil }
                continue
            }
            return nil
        }
        if byte == 0x0a { return data }
        data.append(byte)
        if data.count > 64 * 1024 { return nil }
    }
}

func makeAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
        throw HelperError("socket 路径过长")
    }
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, source, capacity)
            }
        }
    }
    return address
}

func runServer(socketPath: String, allowedUID: uid_t, allowedGID: gid_t) throws {
    let smc = try SMCConnection()
    let controller = try FanController(smc: smc)
    log("ready: \(controller.fans.count) fans, Ftst=\(controller.hasFtst)")

    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw HelperError("创建 socket 失败：\(errno)") }
    defer { close(server) }

    var address = try makeAddress(path: socketPath)
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
        }
    }
    guard bindResult == 0 else {
        throw HelperError("绑定 socket 失败：\(errno)")
    }

    guard chown(socketPath, allowedUID, allowedGID) == 0 else {
        throw HelperError("设置 socket 所有者失败：\(errno)")
    }
    chmod(socketPath, 0o600)
    guard listen(server, 1) == 0 else {
        throw HelperError("listen 失败：\(errno)")
    }

    var client: Int32 = -1
    while client < 0 && stopRequested == 0 {
        let candidate = accept(server, nil, nil)
        if candidate < 0 {
            if errno == EINTR { continue }
            throw HelperError("accept 失败：\(errno)")
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        if getpeereid(candidate, &peerUID, &peerGID) == 0, peerUID == allowedUID {
            client = candidate
        } else {
            log("拒绝来自 uid=\(peerUID) 的连接")
            close(candidate)
        }
    }
    guard client >= 0 else { throw HelperError("没有客户端连接") }
    defer {
        controller.resetAll()
        close(client)
        unlink(socketPath)
    }

    var timeout = timeval(tv_sec: 20, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let decoder = JSONDecoder()
    while stopRequested == 0 {
        guard let line = readLine(from: client), !line.isEmpty else {
            log("客户端断开或心跳超时")
            return
        }
        guard let request = try? decoder.decode(FanRequest.self, from: line) else {
            _ = sendResponse(FanResponse(ok: false, error: "无效请求", message: nil), to: client)
            continue
        }

        do {
            switch request.cmd {
            case "ping":
                try controller.reassertIfNeeded()
                _ = sendResponse(FanResponse(ok: true, error: nil, message: nil), to: client)

            case "apply":
                guard let index = request.index, let rpm = request.rpm else {
                    throw HelperError("缺少 index 或 rpm")
                }
                try controller.setManual(index: index, requestedRPM: rpm)
                _ = sendResponse(FanResponse(ok: true, error: nil, message: "ok"), to: client)

            case "auto":
                guard let index = request.index else {
                    throw HelperError("缺少 index")
                }
                try controller.setAuto(index: index)
                _ = sendResponse(FanResponse(ok: true, error: nil, message: nil), to: client)

            case "autoAll":
                controller.resetAll()
                _ = sendResponse(FanResponse(ok: true, error: nil, message: nil), to: client)

            case "quit":
                controller.resetAll()
                _ = sendResponse(FanResponse(ok: true, error: nil, message: nil), to: client)
                return

            default:
                throw HelperError("未知命令：\(request.cmd)")
            }
        } catch {
            let message = (error as? HelperError)?.description ?? String(describing: error)
            log("命令失败：\(message)")
            _ = sendResponse(FanResponse(ok: false, error: message, message: nil), to: client)
        }
    }
}

// MARK: - 入口

func probe() throws {
    let smc = try SMCConnection()
    let controller = try FanController(smc: smc)
    print("fans=\(controller.fans.count) ftst=\(controller.hasFtst)")
    for reading in controller.readings() {
        print("fan \(reading.index): actual=\(reading.actualRPM ?? -1) target=\(reading.targetRPM ?? -1) min=\(reading.minimumRPM ?? -1) max=\(reading.maximumRPM ?? -1) mode=\(reading.mode.map(String.init) ?? "-")")
    }
    for key in ["TCMz", "TCMb", "TRDX", "TVm0", "TH0x", "TB0T", "TAOL", "TW0P", "TPMP", "TVD0"] {
        if let value = try? smc.readFloat(key) {
            print("\(key)=\(String(format: "%.2f", value))")
        }
    }
}

func run() throws {
    var uid: uid_t = 0
    var gid: gid_t = 0
    var socketPath: String?
    var isProbe = false

    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        switch arguments[index] {
        case "--uid":
            index += 1
            guard index < arguments.count, let value = UInt32(arguments[index]) else {
                throw HelperError("--uid 参数错误")
            }
            uid = value
        case "--gid":
            index += 1
            guard index < arguments.count, let value = UInt32(arguments[index]) else {
                throw HelperError("--gid 参数错误")
            }
            gid = value
        case "--socket":
            index += 1
            guard index < arguments.count else { throw HelperError("--socket 参数错误") }
            socketPath = arguments[index]
        case "--probe":
            isProbe = true
        default:
            throw HelperError("未知参数：\(arguments[index])")
        }
        index += 1
    }

    if isProbe {
        try probe()
        return
    }

    guard geteuid() == 0 else {
        throw HelperError("风扇控制 helper 需要 root 权限")
    }
    guard let socketPath, uid != 0 else {
        throw HelperError("缺少 --socket 或 --uid")
    }

    signal(SIGTERM, handleSignal)
    signal(SIGINT, handleSignal)
    signal(SIGHUP, handleSignal)
    signal(SIGPIPE, SIG_IGN)
    siginterrupt(SIGTERM, 1)
    siginterrupt(SIGINT, 1)
    siginterrupt(SIGHUP, 1)
    umask(0o077)

    try runServer(socketPath: socketPath, allowedUID: uid, allowedGID: gid)
}

do {
    try run()
    exit(0)
} catch {
    let message = (error as? HelperError)?.description ?? String(describing: error)
    log("退出：\(message)")
    exit(1)
}
