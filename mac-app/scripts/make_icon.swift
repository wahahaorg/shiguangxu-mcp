// 生成 1024x1024 应用图标 PNG：奶油色圆角底 + 🍅
// 用法: swift make_icon.swift <输出路径>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
if let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.93, alpha: 1),
    NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.73, alpha: 1),
]) {
    gradient.draw(in: path, angle: -90)
}
path.lineWidth = size * 0.012
NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.42, alpha: 1).setStroke()
path.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
paragraph.lineSpacing = 0
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size * 0.52),
    .paragraphStyle: paragraph,
]
let tomato = NSAttributedString(string: "🍅", attributes: attributes)
tomato.draw(in: rect.insetBy(dx: size * 0.02, dy: size * 0.06))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("生成图标失败\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
print("图标已生成：\(output)")
