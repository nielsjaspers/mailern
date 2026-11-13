import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let symbol = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 550, weight: .regular))!
let rect = NSRect(x: 212, y: 225, width: 600, height: 540)
symbol.draw(in: rect)
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill(using: .sourceIn)
image.unlockFocus()
// Render the symbol separately so the background stays opaque.
let final = NSImage(size: size)
final.lockFocus()
NSColor(red: 0.04, green: 0.43, blue: 0.43, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
image.draw(in: NSRect(origin: .zero, size: size))
final.unlockFocus()
let bitmap = NSBitmapImageRep(data: final.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Mailern/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
let resize = Process()
resize.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
resize.arguments = ["-z", "1024", "1024", "Mailern/Assets.xcassets/AppIcon.appiconset/AppIcon.png"]
try resize.run()
resize.waitUntilExit()
