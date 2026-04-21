import AppKit
import Foundation

struct IconTarget {
    let path: String
    let points: Int
    let scale: Int
}

func makeDirectoryIfNeeded(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func renderIcon(pixelSize: Int) -> NSImage {
    let size = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.setFillColor(NSColor(calibratedRed: 0.055, green: 0.082, blue: 0.122, alpha: 1).cgColor)
    context.fill(rect)

    let backgroundRect = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    backgroundPath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.075, green: 0.125, blue: 0.184, alpha: 1),
        NSColor(calibratedRed: 0.028, green: 0.051, blue: 0.087, alpha: 1)
    ])!
    gradient.draw(in: backgroundRect, angle: -60)

    let glowRect = CGRect(
        x: backgroundRect.minX + size * 0.06,
        y: backgroundRect.midY + size * 0.1,
        width: size * 0.72,
        height: size * 0.32
    )
    let glowGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.122, green: 0.486, blue: 0.796, alpha: 0.42),
        NSColor(calibratedRed: 0.122, green: 0.486, blue: 0.796, alpha: 0.0)
    ])!
    glowGradient.draw(in: glowRect, relativeCenterPosition: NSZeroPoint)

    let promptColor = NSColor(calibratedRed: 0.259, green: 0.902, blue: 0.710, alpha: 1)
    context.setStrokeColor(promptColor.cgColor)
    context.setLineWidth(size * 0.06)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let chevron = NSBezierPath()
    chevron.move(to: CGPoint(x: size * 0.28, y: size * 0.63))
    chevron.line(to: CGPoint(x: size * 0.43, y: size * 0.50))
    chevron.line(to: CGPoint(x: size * 0.28, y: size * 0.37))
    context.addPath(chevron.cgPath)
    context.strokePath()

    let underscoreRect = CGRect(
        x: size * 0.46,
        y: size * 0.33,
        width: size * 0.18,
        height: size * 0.07
    )
    let underscorePath = NSBezierPath(
        roundedRect: underscoreRect,
        xRadius: size * 0.03,
        yRadius: size * 0.03
    )
    promptColor.setFill()
    underscorePath.fill()

    let monogramParagraph = NSMutableParagraphStyle()
    monogramParagraph.alignment = .center
    let monogramAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.22, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.972, green: 0.980, blue: 0.996, alpha: 1),
        .paragraphStyle: monogramParagraph,
        .kern: size * 0.002
    ]
    let monogram = NSAttributedString(string: "AP", attributes: monogramAttributes)
    let monogramRect = CGRect(x: size * 0.42, y: size * 0.50, width: size * 0.36, height: size * 0.20)
    monogram.draw(in: monogramRect)

    let accentParagraph = NSMutableParagraphStyle()
    accentParagraph.alignment = .center
    let accentAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size * 0.065, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 0.541, green: 0.765, blue: 0.965, alpha: 0.95),
        .paragraphStyle: accentParagraph,
        .kern: size * 0.01
    ]
    let accent = NSAttributedString(string: "TERMINAL", attributes: accentAttributes)
    let accentRect = CGRect(x: size * 0.23, y: size * 0.18, width: size * 0.54, height: size * 0.08)
    accent.draw(in: accentRect)

    return image
}

func writePNG(_ image: NSImage, to path: String) throws {
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "APTerminalIcon", code: 1)
    }

    try pngData.write(to: URL(fileURLWithPath: path))
}

let repoRoot = FileManager.default.currentDirectoryPath
let iosAppIconPath = "\(repoRoot)/apps/ios-client/Support/Assets.xcassets/AppIcon.appiconset"
let macAppIconPath = "\(repoRoot)/apps/mac-companion/Support/Assets.xcassets/AppIcon.appiconset"
let brandingPath = "\(repoRoot)/branding"

try makeDirectoryIfNeeded(iosAppIconPath)
try makeDirectoryIfNeeded(macAppIconPath)
try makeDirectoryIfNeeded(brandingPath)

let targets: [IconTarget] = [
    .init(path: "\(brandingPath)/APTerminal-icon-1024.png", points: 1024, scale: 1),
    .init(path: "\(iosAppIconPath)/icon-20@2x.png", points: 20, scale: 2),
    .init(path: "\(iosAppIconPath)/icon-20@3x.png", points: 20, scale: 3),
    .init(path: "\(iosAppIconPath)/icon-29@2x.png", points: 29, scale: 2),
    .init(path: "\(iosAppIconPath)/icon-29@3x.png", points: 29, scale: 3),
    .init(path: "\(iosAppIconPath)/icon-40@2x.png", points: 40, scale: 2),
    .init(path: "\(iosAppIconPath)/icon-40@3x.png", points: 40, scale: 3),
    .init(path: "\(iosAppIconPath)/icon-60@2x.png", points: 60, scale: 2),
    .init(path: "\(iosAppIconPath)/icon-60@3x.png", points: 60, scale: 3),
    .init(path: "\(iosAppIconPath)/icon-1024.png", points: 1024, scale: 1),
    .init(path: "\(macAppIconPath)/icon-16.png", points: 16, scale: 1),
    .init(path: "\(macAppIconPath)/icon-16@2x.png", points: 16, scale: 2),
    .init(path: "\(macAppIconPath)/icon-32.png", points: 32, scale: 1),
    .init(path: "\(macAppIconPath)/icon-32@2x.png", points: 32, scale: 2),
    .init(path: "\(macAppIconPath)/icon-128.png", points: 128, scale: 1),
    .init(path: "\(macAppIconPath)/icon-128@2x.png", points: 128, scale: 2),
    .init(path: "\(macAppIconPath)/icon-256.png", points: 256, scale: 1),
    .init(path: "\(macAppIconPath)/icon-256@2x.png", points: 256, scale: 2),
    .init(path: "\(macAppIconPath)/icon-512.png", points: 512, scale: 1),
    .init(path: "\(macAppIconPath)/icon-512@2x.png", points: 512, scale: 2)
]

for target in targets {
    let pixelSize = target.points * target.scale
    try writePNG(renderIcon(pixelSize: pixelSize), to: target.path)
}

print("Generated APTerminal icons")
