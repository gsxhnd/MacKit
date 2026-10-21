//
//  ChargeLimitReader.swift
//  MacKit
//
//  读取 macOS 设置的电池充电上限。
//
//  macOS 没有公开 API：pmset、system_profiler 与 IOKit 都拿不到，
//  powerd 在设置变化时写 /Library/Preferences/com.apple.powerd.charging.plist。
//  该文件世界可读，解析方式与 status-trio 的 SystemChargeLimitReader 一致：
//  外层 plist 的 policies 是 NSKeyedArchiver 数据，其中的 ChargeCtrlPolicy
//  类只存在于 powerd 进程里，需要注册占位类后再解码。
//

import Foundation

enum ChargeLimitReader {
    /// powerd 在充电上限变化时重写的 plist。
    static let defaultURL = URL(
        fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist"
    )

    private static var cache: (date: Date, value: Int?)?

    /// - Parameter url: 可注入，便于用录制的数据做解析。
    /// - Returns: 充电上限百分比；未设置或读取失败时为 nil。
    static func chargeLimit(from url: URL = defaultURL) -> Int? {
        if let cache, Date().timeIntervalSince(cache.date) < 30 {
            return cache.value
        }
        let value = (try? Data(contentsOf: url)).flatMap { chargeLimit(in: $0) }
        cache = (Date(), value)
        return value
    }

    static func chargeLimit(in data: Data) -> Int? {
        guard let policies = policiesData(in: data) else { return nil }

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: policies)
            // ChargeCtrlPolicy 不是 NSSecureCoding，且不在本进程内，两处都要放宽。
            unarchiver.requiresSecureCoding = false
            unarchiver.setClass(
                ChargeCtrlPolicyPlaceholder.self,
                forClassName: "ChargeCtrlPolicy"
            )
            let decoded = unarchiver.decodeObject(
                forKey: NSKeyedArchiveRootObjectKey
            ) as? [ChargeCtrlPolicyPlaceholder]
            return decoded?.compactMap(\.limit).first
        } catch {
            return nil
        }
    }

    private static func policiesData(in data: Data) -> Data? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }

        guard let policies = plist["policies"] as? Data, !policies.isEmpty else {
            return nil
        }
        return policies
    }
}

/// powerd 私有类 `ChargeCtrlPolicy` 的占位实现。
///
/// NSKeyedUnarchiver 解码时用它代替真实类，因此归档里的字段名就是契约；
/// 任何字段解不出都保留默认值，读取方按「未设置」处理。
final class ChargeCtrlPolicyPlaceholder: NSObject, NSCoding {
    let limit: Int

    init(limit: Int) {
        self.limit = limit
        super.init()
    }

    required init?(coder: NSCoder) {
        limit = coder.decodeInteger(forKey: "soclimit")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(limit, forKey: "soclimit")
    }
}
