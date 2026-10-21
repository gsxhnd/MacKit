//
//  VolumeMonitor.swift
//  MacKit
//
//  输出音量监控与调节（CoreAudio）。
//
//  对齐 status-trio：
//    - 读默认输出设备的音量（主元素优先，退回各声道平均）与静音状态
//    - 识别蓝牙输出，供菜单栏图标与音量配色使用
//    - 支持设置音量 / 切换静音
//

import AudioToolbox
import Combine
import CoreAudio
import Foundation

nonisolated enum AudioOutputKind: Equatable, Sendable {
    case builtIn
    case bluetooth
    case airPlay
    case usb
    case hdmi
    case virtual
    case other

    var symbolName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "headphones"
        case .airPlay: return "airplayaudio"
        case .usb: return "cable.connector"
        case .hdmi: return "tv"
        case .virtual: return "waveform"
        case .other: return "hifispeaker"
        }
    }

    var title: String {
        switch self {
        case .builtIn: return "内建"
        case .bluetooth: return "蓝牙"
        case .airPlay: return "AirPlay"
        case .usb: return "USB"
        case .hdmi: return "HDMI"
        case .virtual: return "虚拟"
        case .other: return "其他"
        }
    }
}

nonisolated struct AudioOutputDeviceInfo: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let kind: AudioOutputKind
    let isCurrent: Bool
}

nonisolated struct VolumeSnapshot: Equatable, Sendable {
    var scalar: Double?
    var isMuted = false
    var deviceName: String?
    var isBluetooth = false
    var canSetVolume = false
}

@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var snapshot = VolumeSnapshot()
    /// 所有可选输出设备（内置 / 蓝牙 / AirPlay 等），当前设备排在最前。
    @Published private(set) var outputDevices: [AudioOutputDeviceInfo] = []

    private var timer: Timer?
    private var lastDeviceID: AudioDeviceID?
    private let deviceQueue = DispatchQueue(label: "MacKit.VolumeMonitor.devices", qos: .utility)
    private var isEnumerating = false

    func start() {
        refresh()
        enumerateDevices()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 控制

    func setVolume(_ value: Double) {
        guard let deviceID = CoreAudioVolume.defaultOutputDevice() else { return }
        let volume = Float32(min(1, max(0, value)))

        var didSet = CoreAudioVolume.setFloat32(
            volume,
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )
        if !didSet {
            for element in CoreAudioVolume.channelElements(for: deviceID) {
                if CoreAudioVolume.setFloat32(
                    volume,
                    objectID: deviceID,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioObjectPropertyScopeOutput,
                    element: element
                ) {
                    didSet = true
                }
            }
        }
        guard didSet else { return }

        if CoreAudioVolume.isMuted(for: deviceID), volume > 0 {
            _ = CoreAudioVolume.setMute(false, for: deviceID)
        }
        refresh()
    }

    func toggleMute() {
        guard let deviceID = CoreAudioVolume.defaultOutputDevice() else { return }
        let muted = CoreAudioVolume.isMuted(for: deviceID)
        _ = CoreAudioVolume.setMute(!muted, for: deviceID)
        refresh()
    }

    /// 切换系统默认输出设备（蓝牙、AirPlay/Wi-Fi 音箱等都在列表里）。
    func selectDevice(_ deviceID: AudioDeviceID) {
        guard CoreAudioVolume.selectOutputDevice(deviceID) else { return }
        refresh()
    }

    /// 重新枚举输出设备；打开面板时调用，避免列表滞后。
    func refreshDevices() {
        enumerateDevices()
    }

    /// 按名称选中输出设备（用于蓝牙连接后自动切换过去）。
    func selectDevice(matchingName name: String) {
        let normalized = name.lowercased()
        let match = outputDevices.first { $0.name.lowercased() == normalized }
            ?? outputDevices.first { $0.name.lowercased().contains(normalized) }
            ?? outputDevices.first { normalized.contains($0.name.lowercased()) }
        guard let match else { return }
        selectDevice(match.id)
    }

    /// 设备枚举放到后台队列：CoreAudio 查询在多设备 / AirPlay 场景下可能变慢。
    private func enumerateDevices() {
        guard !isEnumerating else { return }
        isEnumerating = true
        deviceQueue.async { [weak self] in
            let current = CoreAudioVolume.defaultOutputDevice()
            let devices = CoreAudioVolume.outputDevices(current: current)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnumerating = false
                self.outputDevices = devices
            }
        }
    }

    // MARK: - 读取

    func refresh() {
        guard let deviceID = CoreAudioVolume.defaultOutputDevice() else {
            if snapshot != VolumeSnapshot() {
                snapshot = VolumeSnapshot()
            }
            if lastDeviceID != nil {
                lastDeviceID = nil
                outputDevices = []
            }
            return
        }

        if deviceID != lastDeviceID {
            lastDeviceID = deviceID
            enumerateDevices()
        }

        let next = VolumeSnapshot(
            scalar: CoreAudioVolume.volumeScalar(for: deviceID).map(Double.init),
            isMuted: CoreAudioVolume.isMuted(for: deviceID),
            deviceName: CoreAudioVolume.deviceName(for: deviceID),
            isBluetooth: CoreAudioVolume.isBluetooth(deviceID),
            canSetVolume: CoreAudioVolume.canSetVolume(deviceID)
        )
        if next != snapshot {
            snapshot = next
        }
    }
}

// MARK: - CoreAudio 封装

nonisolated enum CoreAudioVolume {
    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr,
              size == MemoryLayout<AudioDeviceID>.size,
              deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    static func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    static func readFloat32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    static func readString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &name) == noErr,
              let name else {
            return nil
        }
        let value = name.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    static func isSettable(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    @discardableResult
    static func setFloat32(
        _ value: Float32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &mutableValue) == noErr
    }

    @discardableResult
    static func setUInt32(
        _ value: UInt32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutableValue = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &mutableValue) == noErr
    }

    // MARK: - 音量 / 静音

    static func volumeScalar(for deviceID: AudioDeviceID) -> Float32? {
        if let main = readFloat32(
            deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ), isSettable(
            deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return clampScalar(main)
        }

        let channels = channelElements(for: deviceID).compactMap { element -> Float32? in
            guard isSettable(
                deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) else { return nil }
            return readFloat32(
                deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ).map(clampScalar)
        }

        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float32(channels.count)
    }

    static func isMuted(for deviceID: AudioDeviceID) -> Bool {
        if let main = readUInt32(
            deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return main != 0
        }
        for element in channelElements(for: deviceID) {
            if let value = readUInt32(
                deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) {
                return value != 0
            }
        }
        return false
    }

    static func canSetVolume(_ deviceID: AudioDeviceID) -> Bool {
        let elements = [kAudioObjectPropertyElementMain] + channelElements(for: deviceID)
        return elements.contains {
            isSettable(
                deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: $0
            )
        }
    }

    @discardableResult
    static func setMute(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        let value: UInt32 = muted ? 1 : 0
        if setUInt32(
            value,
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return true
        }
        var didSet = false
        for element in channelElements(for: deviceID) {
            if setUInt32(
                value,
                objectID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) {
                didSet = true
            }
        }
        return didSet
    }

    // MARK: - 设备信息

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        readString(deviceID, selector: kAudioObjectPropertyName)
    }

    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        guard let transport = readUInt32(deviceID, selector: kAudioDevicePropertyTransportType) else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - 输出设备列表 / 切换

    /// 枚举所有可输出的设备；当前默认设备标记 isCurrent 并排在最前。
    static func outputDevices(current: AudioDeviceID?) -> [AudioOutputDeviceInfo] {
        guard let ids = allDeviceIDs() else { return [] }

        var devices: [AudioOutputDeviceInfo] = []
        for id in ids {
            guard outputChannelCount(for: id) > 0 else { continue }
            guard !isHiddenDevice(id) else { continue }
            guard let name = deviceName(for: id), !name.isEmpty else { continue }
            // 与 status-trio 一致：不能作为默认输出的设备不列出来，
            // 避免出现点了却切不过去的条目。
            guard canBeDefaultOutputDevice(id) else { continue }
            devices.append(AudioOutputDeviceInfo(
                id: id,
                name: name,
                kind: transportKind(id),
                isCurrent: id == current
            ))
        }

        let order: [AudioOutputKind] = [.builtIn, .bluetooth, .airPlay, .usb, .hdmi, .virtual, .other]
        return devices.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            let left = order.firstIndex(of: lhs.kind) ?? order.count
            let right = order.firstIndex(of: rhs.kind) ?? order.count
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 切换系统默认输出设备。
    ///
    /// 对齐 status-trio 的 CoreAudioOutputController：
    /// macOS 15+ 用 `AudioHardwareSystem.setDefaultOutputDevice`（同时设置提示音输出），
    /// 失败时回退到旧的 `kAudioHardwarePropertyDefaultOutputDevice`。
    @MainActor
    @discardableResult
    static func selectOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown,
              canBeDefaultOutputDevice(deviceID) else {
            return false
        }

        if #available(macOS 15.0, *) {
            let device = AudioHardwareDevice(id: deviceID)
            do {
                try AudioHardwareSystem.shared.setDefaultOutputDevice(device)
                try AudioHardwareSystem.shared.setDefaultSoundEffectsDevice(device)
                return true
            } catch {
                return setLegacyDefaultOutputDevice(deviceID)
            }
        }

        return setLegacyDefaultOutputDevice(deviceID)
    }

    /// 设备是否允许作为默认输出（蓝牙 / AirPlay 设备也可能不允许）。
    static func canBeDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        if #available(macOS 15.0, *) {
            let device = AudioHardwareDevice(id: deviceID)
            if let canBeDefault = try? device.canBeDefaultOutputDevice {
                return canBeDefault
            }
        }
        return audioDeviceCanBeDefault(deviceID)
    }

    @MainActor
    private static func setLegacyDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        setDefaultAudioDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
            && setDefaultAudioDevice(deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    private static func setDefaultAudioDevice(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &value
        ) == noErr
    }

    static func audioDeviceCanBeDefault(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var canBeDefault: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &canBeDefault
        )
        return status == noErr && canBeDefault != 0
    }

    /// 系统隐藏的设备不列出来（对齐 status-trio）。
    static func isHiddenDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    static func allDeviceIDs() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return nil
        }
        return ids
    }

    static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var returnedSize = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &returnedSize, bufferList) == noErr,
              returnedSize <= size else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportKind(_ deviceID: AudioDeviceID) -> AudioOutputKind {
        guard let transport = readUInt32(
            deviceID,
            selector: kAudioDevicePropertyTransportType
        ) else {
            return .other
        }

        if transport == kAudioDeviceTransportTypeBuiltIn { return .builtIn }
        if transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE { return .bluetooth }
        if transport == kAudioDeviceTransportTypeAirPlay { return .airPlay }
        if transport == kAudioDeviceTransportTypeUSB { return .usb }
        if transport == kAudioDeviceTransportTypeHDMI { return .hdmi }
        if transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate { return .virtual }
        return .other
    }

    static func channelElements(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return [1, 2]
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var returnedSize = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &returnedSize, bufferList) == noErr,
              returnedSize <= size else {
            return [1, 2]
        }

        let channelCount = UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channelCount > 0 else { return [1, 2] }
        return (1...channelCount).map { AudioObjectPropertyElement($0) }
    }

    private static func clampScalar(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
