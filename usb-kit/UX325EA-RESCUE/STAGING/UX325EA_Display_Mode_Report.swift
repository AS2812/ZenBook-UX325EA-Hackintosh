import Foundation
import CoreGraphics

print("=== CoreGraphics Display Mode Report ===")
var displayCount: UInt32 = 0
var activeDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
CGGetActiveDisplayList(16, &activeDisplays, &displayCount)

print("Active display count: \(displayCount)")
for i in 0..<Int(displayCount) {
    let d = activeDisplays[i]
    let width = CGDisplayPixelsWide(d)
    let height = CGDisplayPixelsHigh(d)
    let mode = CGDisplayCopyDisplayMode(d)
    let refresh = mode?.refreshRate ?? 0.0
    let isMain = CGDisplayIsMain(d) != 0 ? "YES" : "NO"
    let isBuiltin = CGDisplayIsBuiltin(d) != 0 ? "YES" : "NO"
    print("Display ID: \(d)")
    print("  Main: \(isMain), Built-in: \(isBuiltin)")
    print("  Resolution: \(width)x\(height)")
    print("  Refresh Rate: \(refresh) Hz")
}
