//
//  MenuBarIcon.swift
//  MacKit
//
//  菜单栏自绘电池图标（模板图，随系统菜单栏明暗自动着色）。
//

import AppKit

enum MenuBarBatteryIcon {
    static func image(percent: Int, charging: Bool, available: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 27, height: 14), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let body = NSBezierPath(
                roundedRect: NSRect(x: 1.2, y: 1.5, width: 20.3, height: 11),
                xRadius: 3,
                yRadius: 3
            )
            body.lineWidth = 1.3
            body.stroke()

            let cap = NSBezierPath(
                roundedRect: NSRect(x: 22.5, y: 5.1, width: 2.2, height: 3.8),
                xRadius: 0.8,
                yRadius: 0.8
            )
            cap.fill()

            if available {
                let clamped = min(100, max(0, percent))
                let fillWidth = 16.5 * CGFloat(clamped) / 100
                if fillWidth > 1 {
                    let fill = NSBezierPath(
                        roundedRect: NSRect(x: 3.2, y: 3.4, width: fillWidth, height: 7.2),
                        xRadius: 1.4,
                        yRadius: 1.4
                    )
                    fill.fill()
                }
            } else {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 4, y: 2.2))
                slash.line(to: NSPoint(x: 21, y: 11.8))
                slash.lineWidth = 1.3
                slash.stroke()
            }

            if charging && available {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 16.2, y: 11.4))
                bolt.line(to: NSPoint(x: 11.5, y: 6.6))
                bolt.line(to: NSPoint(x: 14.7, y: 6.6))
                bolt.line(to: NSPoint(x: 12.9, y: 2.6))
                bolt.line(to: NSPoint(x: 18.2, y: 8.1))
                bolt.line(to: NSPoint(x: 15.0, y: 8.1))
                bolt.close()

                NSGraphicsContext.current?.compositingOperation = .destinationOut
                bolt.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
