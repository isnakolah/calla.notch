#!/usr/bin/env python3
"""Render the branding inventory with macOS AppKit; no Python packages needed."""
import pathlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[2]
thumbnails = tempfile.TemporaryDirectory(prefix="calla-branding-")
for svg in (root / "Branding/Archive").rglob("*.svg"):
    tree = ET.parse(svg)
    background = ET.Element("{http://www.w3.org/2000/svg}rect", {"width": "100%", "height": "100%", "fill": "#26212e"})
    tree.getroot().insert(0, background)
    preview = pathlib.Path(thumbnails.name) / svg.name
    tree.write(preview, encoding="utf-8", xml_declaration=True)
    subprocess.run(["qlmanage", "-t", "-s", "600", "-o", thumbnails.name, str(preview)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["swift", "-", str(root), thumbnails.name], input=r'''
import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Branding/manifest.json"))) as! [String: Any]
let assets = (manifest["assets"] as! [[String: Any]]).filter {
    guard let path = $0["path"] as? String else { return false }
    return ["png", "svg", "tiff"].contains(URL(fileURLWithPath: path).pathExtension)
}
let columns = 4, cardWidth = 240, cardHeight = 260
let rows = (assets.count + columns - 1) / columns
let width = columns * cardWidth, height = rows * cardHeight + 70
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
let title: NSString = "calla.notch — collected artwork"
title.draw(at: NSPoint(x: 22, y: height - 45), withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.black])
for (index, asset) in assets.enumerated() {
    let path = asset["path"] as! String
    let x = (index % columns) * cardWidth + 12
    let y = height - 70 - (index / columns + 1) * cardHeight + 12
    let card = NSRect(x: x, y: y, width: cardWidth - 24, height: cardHeight - 24)
    NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
    let imageURL = path.hasSuffix(".svg")
        ? URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + ".png")
        : root.appendingPathComponent(path)
    if let image = NSImage(contentsOf: imageURL) {
        let scale = min(184 / image.size.width, 176 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: CGFloat(x) + (card.width - size.width) / 2,
                            y: CGFloat(y) + 50 + (176 - size.height) / 2,
                            width: size.width, height: size.height))
    }
    let label = (asset["asset"] as? String ?? URL(fileURLWithPath: path).lastPathComponent)
    let detail = [asset["size"], asset["scale"], asset["status"]].compactMap { $0 as? String }.joined(separator: " · ")
    (label as NSString).draw(in: NSRect(x: x + 10, y: y + 25, width: cardWidth - 44, height: 21), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
    (detail as NSString).draw(in: NSRect(x: x + 10, y: y + 7, width: cardWidth - 44, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Branding/contact-sheet.png"))
''', text=True, check=True)
thumbnails.cleanup()
print("Updated Branding/contact-sheet.png")
