import AppKit
import Foundation

// Package the checked-in raster master for the app; redraw its whale/captain silhouette
// as a dedicated monochrome mark so the system input menu remains legible at 16 pt.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let iconset = root.appendingPathComponent("build/Haiwang.iconset", isDirectory: true)
let branding = root.appendingPathComponent("Resources/Branding", isDirectory: true)
let appResources = root.appendingPathComponent("macOS/Resources", isDirectory: true)
let imeResources = root.appendingPathComponent("macOS/InputMethod/Resources", isDirectory: true)
let mobileResources = root.appendingPathComponent("iOS/App/Resources", isDirectory: true)
for directory in [iconset, branding, appResources, imeResources, mobileResources] {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
}
guard let master = NSImage(contentsOf: branding.appendingPathComponent("SailKing-AppIcon-Master.png")) else {
    fatalError("缺少出海王船长鲸图标母版，停止生成。")
}

func bitmap(pixels: Int, points: CGFloat, drawing: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawing()
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: points, height: points)
    return rep
}

func appIcon(pixels: Int) -> NSBitmapImageRep {
    bitmap(pixels: pixels, points: CGFloat(pixels)) {
        master.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                    from: .zero, operation: .copy, fraction: 1)
    }
}

func whale() -> NSBezierPath {
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 382, y: 514))
    body.curve(to: NSPoint(x: 835, y: 480), controlPoint1: NSPoint(x: 450, y: 660), controlPoint2: NSPoint(x: 830, y: 650))
    body.curve(to: NSPoint(x: 746, y: 230), controlPoint1: NSPoint(x: 885, y: 353), controlPoint2: NSPoint(x: 871, y: 262))
    body.curve(to: NSPoint(x: 410, y: 239), controlPoint1: NSPoint(x: 646, y: 166), controlPoint2: NSPoint(x: 494, y: 208))
    // The speech-bubble tip gives this captain whale a communication identity.
    body.curve(to: NSPoint(x: 308, y: 196), controlPoint1: NSPoint(x: 366, y: 207), controlPoint2: NSPoint(x: 324, y: 190))
    body.curve(to: NSPoint(x: 360, y: 284), controlPoint1: NSPoint(x: 340, y: 217), controlPoint2: NSPoint(x: 361, y: 251))
    body.curve(to: NSPoint(x: 221, y: 351), controlPoint1: NSPoint(x: 282, y: 295), controlPoint2: NSPoint(x: 240, y: 320))
    body.curve(to: NSPoint(x: 97, y: 510), controlPoint1: NSPoint(x: 146, y: 375), controlPoint2: NSPoint(x: 94, y: 451))
    body.curve(to: NSPoint(x: 211, y: 474), controlPoint1: NSPoint(x: 158, y: 506), controlPoint2: NSPoint(x: 193, y: 500))
    body.curve(to: NSPoint(x: 315, y: 563), controlPoint1: NSPoint(x: 239, y: 526), controlPoint2: NSPoint(x: 285, y: 557))
    body.curve(to: NSPoint(x: 289, y: 433), controlPoint1: NSPoint(x: 325, y: 514), controlPoint2: NSPoint(x: 308, y: 467))
    body.curve(to: NSPoint(x: 382, y: 514), controlPoint1: NSPoint(x: 333, y: 411), controlPoint2: NSPoint(x: 372, y: 443))
    body.close()
    return body
}

func captainHat() -> NSBezierPath {
    let hat = NSBezierPath()
    hat.move(to: NSPoint(x: 325, y: 588))
    hat.curve(to: NSPoint(x: 464, y: 804), controlPoint1: NSPoint(x: 328, y: 692), controlPoint2: NSPoint(x: 399, y: 778))
    hat.line(to: NSPoint(x: 538, y: 742))
    hat.line(to: NSPoint(x: 650, y: 886))
    hat.curve(to: NSPoint(x: 731, y: 790), controlPoint1: NSPoint(x: 657, y: 808), controlPoint2: NSPoint(x: 692, y: 758))
    hat.line(to: NSPoint(x: 787, y: 841))
    hat.line(to: NSPoint(x: 813, y: 708))
    hat.curve(to: NSPoint(x: 887, y: 722), controlPoint1: NSPoint(x: 850, y: 673), controlPoint2: NSPoint(x: 863, y: 699))
    hat.curve(to: NSPoint(x: 869, y: 575), controlPoint1: NSPoint(x: 931, y: 738), controlPoint2: NSPoint(x: 918, y: 636))
    hat.curve(to: NSPoint(x: 325, y: 588), controlPoint1: NSPoint(x: 719, y: 656), controlPoint2: NSPoint(x: 503, y: 666))
    hat.close()
    return hat
}

func menuIcon(pixels: Int, white: Bool) -> NSBitmapImageRep {
    bitmap(pixels: pixels, points: 16) {
        let transform = NSAffineTransform()
        let bounds = whale().bounds.union(captainHat().bounds)
        let fit = min(CGFloat(896) / bounds.width, CGFloat(896) / bounds.height)
        transform.translateX(by: 512 - bounds.midX * fit, yBy: 512 - bounds.midY * fit)
        transform.scale(by: fit)
        transform.concat()
        (white ? NSColor.white : NSColor.black).setFill()
        whale().fill()
        captainHat().fill()
        // Cut the expression and hat-band directly out of alpha, never using background color.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 651, y: 397, width: 78, height: 78)).fill()
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 694, y: 341))
        smile.curve(to: NSPoint(x: 792, y: 338), controlPoint1: NSPoint(x: 726, y: 304), controlPoint2: NSPoint(x: 770, y: 306))
        smile.lineWidth = 42
        smile.lineCapStyle = .round
        NSColor.white.setStroke()
        smile.stroke()
        let band = NSBezierPath()
        band.move(to: NSPoint(x: 405, y: 587))
        band.curve(to: NSPoint(x: 822, y: 576), controlPoint1: NSPoint(x: 555, y: 659), controlPoint2: NSPoint(x: 720, y: 653))
        band.lineWidth = 34
        band.stroke()
    }
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let name = "icon_\(points)x\(points)" + (multiplier == 2 ? "@2x" : "") + ".png"
        try appIcon(pixels: points * multiplier).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let masterPNG = appIcon(pixels: 1024).representation(using: .png, properties: [:])!
try masterPNG.write(to: branding.appendingPathComponent("SailKing-AppIcon.png"))
for resources in [appResources, mobileResources] {
    try masterPNG.write(to: resources.appendingPathComponent("HaiwangBrand.png"))
}
for white in [false, true] {
    let reps = [menuIcon(pixels: 16, white: white), menuIcon(pixels: 32, white: white)]
    let name = white ? "InputMethodIconAlternate.tiff" : "InputMethodIcon.tiff"
    let data = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:])!
    try data.write(to: imeResources.appendingPathComponent(name))
    if !white { try data.write(to: appResources.appendingPathComponent("HaiwangStatusTemplate.tiff")) }
    for rep in reps {
        let filename = "SailKing-Menu\(white ? "-Light" : "-Dark")-\(rep.pixelsWide).png"
        try rep.representation(using: .png, properties: [:])!
            .write(to: branding.appendingPathComponent(filename))
    }
}
print("出海王 SailKing 船长鲸：App 10尺寸；菜单16pt双分辨率，黑/白两套。")
