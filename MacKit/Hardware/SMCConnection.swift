//
//  SMCConnection.swift
//  MacKit
//
//  AppleSMC 只读连接。风扇写入由特权 helper 完成。
//

import Darwin
import Foundation
import IOKit

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

nonisolated struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
}

nonisolated struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

nonisolated struct SMCParamStruct {
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
}

nonisolated final class SMCConnection: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let selector: UInt32 = 2

    init() throws {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            throw SMCError("SMCParamStruct 布局错误：\(MemoryLayout<SMCParamStruct>.stride)")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError("找不到 AppleSMC") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw SMCError("打开 AppleSMC 失败：\(result)")
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        var input = SMCParamStruct()
        input.key = Self.fourCC(key)
        input.data8 = 9
        return try call(input).keyInfo
    }

    func hasKey(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func read(_ key: String) throws -> (SMCKeyInfo, [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = Self.fourCC(key)
        input.keyInfo = info
        input.data8 = 5
        let output = try call(input)
        return (info, output.byteArray(Int(info.dataSize)))
    }

    func readUInt8(_ key: String) throws -> UInt8 {
        let (_, bytes) = try read(key)
        guard let value = bytes.first else { throw SMCError("\(key) 无数据") }
        return value
    }

    func readUInt32BigEndian(_ key: String) throws -> UInt32 {
        let (_, bytes) = try read(key)
        guard bytes.count >= 4 else { throw SMCError("\(key) 不是 4 字节整数") }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    func readFloat(_ key: String) throws -> Double {
        let (info, bytes) = try read(key)
        guard info.dataSize >= 4, bytes.count >= 4 else {
            throw SMCError("\(key) 不是 4 字节浮点")
        }
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var mutableInput = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = withUnsafePointer(to: &mutableInput) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    selector,
                    inputPointer,
                    MemoryLayout<SMCParamStruct>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw SMCError("SMC 调用失败 kern=\(result) key=\(Self.fourCCString(input.key))")
        }
        guard output.result == 0 else {
            throw SMCError("SMC 返回错误 result=\(output.result) key=\(Self.fourCCString(input.key))")
        }
        return output
    }

    private static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func fourCCString(_ value: UInt32) -> String {
        String(decoding: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ], as: UTF8.self)
    }
}

struct SMCError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
