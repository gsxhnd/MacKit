//
//  FanControlClient.swift
//  MacKit
//
//  与 root helper 的 Unix socket 协议，以及一次性的管理员安装/启动流程。
//

import Darwin
import Foundation

nonisolated enum FanHelperState: Equatable, Sendable {
    case inactive
    case starting
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .inactive: "未启用"
        case .starting: "等待授权"
        case .connected: "已连接"
        case .failed: "连接失败"
        }
    }
}

nonisolated struct FanCommandResult: Sendable {
    var ok: Bool
    var message: String

    static func failure(_ message: String) -> FanCommandResult {
        FanCommandResult(ok: false, message: message)
    }
}

actor FanControlClient {
    private let socketPath: String
    private var fd: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }

    func connect() -> Bool {
        if fd >= 0 { return true }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(descriptor)
            return false
        }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strlcpy(destination, source, capacity)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return false
        }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = descriptor
        return true
    }

    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    func ping() -> FanCommandResult {
        perform(cmd: "ping")
    }

    func apply(index: Int, rpm: Double) -> FanCommandResult {
        perform(cmd: "apply", index: index, rpm: rpm)
    }

    func auto(index: Int) -> FanCommandResult {
        perform(cmd: "auto", index: index)
    }

    func autoAll() -> FanCommandResult {
        perform(cmd: "autoAll")
    }

    func quit() -> FanCommandResult {
        perform(cmd: "quit")
    }

    private func perform(cmd: String, index: Int? = nil, rpm: Double? = nil) -> FanCommandResult {
        guard fd >= 0 else {
            return .failure("风扇控制 helper 未连接")
        }

        let request = Request(cmd: cmd, index: index, rpm: rpm)
        guard let body = try? JSONEncoder().encode(request) else {
            return .failure("无法编码请求")
        }
        var data = body
        data.append(0x0a)

        let sent = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let count = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if count <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard sent else {
            disconnect()
            return .failure("发送风扇指令失败")
        }

        guard let line = readLine() else {
            disconnect()
            return .failure("风扇控制 helper 无响应")
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: line) else {
            disconnect()
            return .failure("无法解析 helper 响应")
        }
        if response.ok {
            return FanCommandResult(ok: true, message: response.message ?? "ok")
        }
        return .failure(response.error ?? "风扇控制失败")
    }

    private func readLine() -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = recv(fd, &byte, 1, 0)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 0x0a { return data }
            data.append(byte)
            if data.count > 64 * 1024 { return nil }
        }
    }

    private struct Request: Encodable {
        let cmd: String
        let index: Int?
        let rpm: Double?
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let message: String?
    }
}

nonisolated enum FanHelperInstaller {
    static let installedHelperPath = "/Library/PrivilegedHelperTools/MacKitFanHelper"
    static let logPath = "/tmp/mackit-fanhelper.log"

    static var bundledHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("MacKitFanHelper")
    }

    static func socketPath(uid: uid_t = getuid()) -> String {
        "/tmp/mackit-fan-\(uid).sock"
    }

    static func installAndStart(socketPath: String) async throws {
        let helperURL = bundledHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw FanHelperInstallError("App 内缺少 MacKitFanHelper，请重新构建")
        }

        let source = shellQuote(helperURL.path)
        let destination = shellQuote(installedHelperPath)
        let socket = shellQuote(socketPath)
        let uid = getuid()
        let gid = getgid()

        let command = [
            "/usr/bin/pkill -x MacKitFanHelper >/dev/null 2>&1 || true",
            "/bin/rm -f \(socket)",
            "/usr/bin/install -m 0755 -o root -g wheel \(source) \(destination)",
            "/usr/bin/nohup \(destination) --uid \(uid) --gid \(gid) --socket \(socket) > \(logPath) 2>&1 &"
        ].joined(separator: "; ")

        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        try await Task.detached(priority: .userInitiated) {
            try runOSAScript(script)
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runOSAScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw FanHelperInstallError("无法启动授权流程：\(error.localizedDescription)")
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if output.localizedCaseInsensitiveContains("cancel") || output.contains("-128") {
                throw FanHelperInstallError("已取消管理员授权")
            }
            throw FanHelperInstallError(output.isEmpty ? "管理员授权失败" : output)
        }
    }
}

struct FanHelperInstallError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
