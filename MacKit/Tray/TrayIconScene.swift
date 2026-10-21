//
//  TrayIconScene.swift
//  MacKit
//
//  菜单栏托盘图标的场景模型。
//
//  结构与绘制思路来自 lingyired/status-trio（Apache-2.0）的
//  IconSceneState / OuterRingState / FooterState，按 MacKit 的
//  「电池 + 网络 + 音量」三信号做了精简适配：
//    - 顶部圆环：电池进度，顶部缺口放 图标/文字 指示器
//    - 中心符号：网络（Wi-Fi 信号格 / 以太网，蓝牙音频可替换）
//    - 底部：音量（圆点或弧线）
//

import Foundation

// MARK: - 颜色角色

/// 场景里每个图元用的颜色角色，渲染时按菜单栏明暗外观解析成具体颜色。
///
/// 与 status-trio 一致：常态一律用菜单栏前景色，只有电池状态
/// （低电量 / 低电量模式 / 充电）才使用彩色。
enum TrayIconColorRole: Equatable, Hashable, Sendable {
    /// 菜单栏前景色（labelColor）。
    case primary
    /// 非活动轨道（未填充部分）。
    case inactive
    /// 严重状态（电量极低）。
    case critical
    /// 低电量模式（黄色）。
    case lowPower
    /// 充电中 / 已接电源（绿色）。
    case powered
    /// 蓝牙音频（蓝色）。
    case bluetooth
}

// MARK: - 符号 / 文字

struct TrayIconSymbolState: Equatable, Hashable, Sendable {
    /// SF Symbol 名。按数组顺序取第一个系统存在的。
    let symbolNames: [String]
    /// SF Symbol 的可变值（0...1），用于 thermometer 等可变色符号。
    let variableValue: Double?
    let color: TrayIconColorRole
    let scale: Double

    init(
        symbolNames: [String],
        variableValue: Double? = nil,
        color: TrayIconColorRole,
        scale: Double = 1
    ) {
        self.symbolNames = symbolNames
        self.variableValue = variableValue.map { min(1, max(0, $0)) }
        self.color = color
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}

struct TrayIconTextState: Equatable, Hashable, Sendable {
    let text: String
    let color: TrayIconColorRole
    let scale: Double

    init(text: String, color: TrayIconColorRole, scale: Double = 1) {
        self.text = text
        self.color = color
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}

// MARK: - 顶部圆环

enum TrayRingGapStyle: Equatable, Hashable, Sendable {
    /// 无缺口。
    case closed
    /// 缺口里放充电/插电符号。
    case indicator
    /// 缺口里放电量百分比。
    case value
}

enum TrayRingAccessory: Equatable, Hashable, Sendable {
    case symbol(TrayIconSymbolState)
    case text(TrayIconTextState)
}

struct TrayRingSegment: Equatable, Hashable, Sendable {
    /// 0...1。
    let progress: Double
    let color: TrayIconColorRole

    init(progress: Double, color: TrayIconColorRole) {
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
        self.color = color
    }
}

struct TrayOuterRing: Equatable, Hashable, Sendable {
    let segments: [TrayRingSegment]
    let gap: TrayRingGapStyle
    let accessory: TrayRingAccessory?
    /// 描边粗细系数，1.25 为默认视觉重量。
    let strokeScale: Double

    init(
        segments: [TrayRingSegment],
        gap: TrayRingGapStyle = .closed,
        accessory: TrayRingAccessory? = nil,
        strokeScale: Double = 1.25
    ) {
        self.segments = segments
        self.gap = gap
        self.accessory = accessory
        self.strokeScale = strokeScale.isFinite ? min(2.5, max(0.5, strokeScale)) : 1.25
    }
}

// MARK: - 中心 / 底部

enum TrayCenter: Equatable, Hashable, Sendable {
    case symbol(TrayIconSymbolState)
    case text(TrayIconTextState)
}

struct TrayFooterDots: Equatable, Hashable, Sendable {
    let count: Int
    let activeCount: Int
    let color: TrayIconColorRole
    let strokeScale: Double

    init(count: Int, activeCount: Int, color: TrayIconColorRole, strokeScale: Double = 1.25) {
        let normalizedCount = max(0, count)
        self.count = normalizedCount
        self.activeCount = min(normalizedCount, max(0, activeCount))
        self.color = color
        self.strokeScale = strokeScale
    }
}

struct TrayFooterArc: Equatable, Hashable, Sendable {
    let progress: Double
    let color: TrayIconColorRole
    let strokeScale: Double

    init(progress: Double, color: TrayIconColorRole, strokeScale: Double = 1.25) {
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
        self.color = color
        self.strokeScale = strokeScale
    }
}

enum TrayFooter: Equatable, Hashable, Sendable {
    case dots(TrayFooterDots)
    case arc(TrayFooterArc)
}

// MARK: - 场景

/// 一次托盘图标绘制要表达的全部状态。
struct TrayIconScene: Equatable, Hashable, Sendable {
    let outerRing: TrayOuterRing?
    let center: TrayCenter?
    let footer: TrayFooter?

    init(
        outerRing: TrayOuterRing? = nil,
        center: TrayCenter? = nil,
        footer: TrayFooter? = nil
    ) {
        self.outerRing = outerRing
        self.center = center
        self.footer = footer
    }
}

extension TrayRingAccessory {
    var colorRole: TrayIconColorRole {
        switch self {
        case let .symbol(symbol): symbol.color
        case let .text(text): text.color
        }
    }
}

extension TrayCenter {
    var colorRole: TrayIconColorRole {
        switch self {
        case let .symbol(symbol): symbol.color
        case let .text(text): text.color
        }
    }
}

extension TrayFooter {
    var colorRole: TrayIconColorRole {
        switch self {
        case let .dots(dots): dots.color
        case let .arc(arc): arc.color
        }
    }
}

extension TrayIconScene {
    /// 场景用到的全部颜色角色。
    var colorRoles: [TrayIconColorRole] {
        var roles: [TrayIconColorRole] = []
        if let outerRing {
            roles.append(contentsOf: outerRing.segments.map(\.color))
            if let accessory = outerRing.accessory {
                roles.append(accessory.colorRole)
            }
        }
        if let center {
            roles.append(center.colorRole)
        }
        if let footer {
            roles.append(footer.colorRole)
        }
        return roles
    }

    /// 只用菜单栏前景色绘制时为 true。
    ///
    /// 此时整张图会作为 template image 交给系统，由系统按当前 Space
    /// 的菜单栏明暗实时着色；带状态色（低电量 / 充电等）时才退回彩色位图。
    var usesOnlyMonochromeRoles: Bool {
        colorRoles.allSatisfy { $0 == .primary || $0 == .inactive }
    }
}
