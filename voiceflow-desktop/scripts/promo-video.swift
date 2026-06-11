#!/usr/bin/env swift
// promo-video.swift — renders the Voiceflow teaser video programmatically.
//
// Every frame is drawn with CoreGraphics (brand gradient, typography, real UI
// screenshots, typing animation) and encoded to H.264 MP4 via AVAssetWriter.
// No external dependencies, no screen recording — fully reproducible.
//
// Usage: swift scripts/promo-video.swift <output.mp4> [previewDir]
//   previewDir: optional — dumps one PNG per storyboard beat for review.

import AppKit
import AVFoundation
import CoreText

// MARK: - Config

let W = 1920, H = 1080
let FPS = 30
let DUR: Double = 44.0
let TOTAL_FRAMES = Int(DUR * Double(FPS))

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let uiDir = repoRoot.appendingPathComponent("docs/ui")
let iconURL = repoRoot.appendingPathComponent(".build/AppIcon.prepared.png")

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift promo-video.swift <output.mp4> [previewDir]")
    exit(1)
}
let outputURL = URL(fileURLWithPath: args[1])
let previewDir: URL? = args.count >= 3 ? URL(fileURLWithPath: args[2]) : nil
if let previewDir {
    try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
}
try? FileManager.default.removeItem(at: outputURL)

// MARK: - Brand colors

let indigo  = CGColor(red: 0.24, green: 0.18, blue: 0.67, alpha: 1)
let blue    = CGColor(red: 0.29, green: 0.56, blue: 1.00, alpha: 1)
let nearBlack = CGColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1)
let offWhite  = CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1)

// MARK: - Easing & helpers

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
func easeOut(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
/// Fade in over `fi`, hold, fade out over `fo` within a [0,1] local timeline.
func fadeInOut(_ t: Double, fi: Double, fo: Double) -> Double {
    if t < fi { return easeOut(t / fi) }
    if t > 1 - fo { return clamp01((1 - t) / fo) }
    return 1
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Drawing primitives

func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws centered text. `yTop` measures from the TOP of the canvas to the
/// text's vertical center. Returns the rendered width.
@discardableResult
func drawText(_ ctx: CGContext, _ string: String, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, yTop: CGFloat, alpha: Double, centerX: CGFloat = CGFloat(W) / 2,
              mono: Bool = false, tracking: CGFloat = 0) -> CGFloat {
    guard alpha > 0.01 else { return 0 }
    let font = mono
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    var attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color.withAlphaComponent(alpha)
    ]
    if tracking != 0 { attrs[.kern] = tracking }
    let str = NSAttributedString(string: string, attributes: attrs)
    let bounds = str.size()
    let y = CGFloat(H) - yTop - bounds.height / 2
    withNSContext(ctx) {
        str.draw(at: NSPoint(x: centerX - bounds.width / 2, y: y))
    }
    return bounds.width
}

/// Draws an image centered at (centerX, yTopCenter-from-top) at `width`,
/// with rounded corners, soft shadow and optional scale (Ken Burns).
/// `backed: true` draws a white rounded card behind the image (for opaque
/// screenshots); `backed: false` draws the image directly with its own shadow —
/// required for transparent PNGs like the app icon, where a backing card would
/// show as an ugly white square.
func drawImage(_ ctx: CGContext, _ image: NSImage, width: CGFloat, yTopCenter: CGFloat,
               alpha: Double, scale: CGFloat = 1.0, cornerRadius: CGFloat = 24,
               centerX: CGFloat = CGFloat(W) / 2, backed: Bool = true) {
    guard alpha > 0.01, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let aspect = CGFloat(cg.height) / CGFloat(cg.width)
    let w = width * scale
    let h = w * aspect
    let x = centerX - w / 2
    let y = CGFloat(H) - yTopCenter - h / 2
    let rect = CGRect(x: x, y: y, width: w, height: h)

    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 50,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    if backed {
        // Shadow needs a fill pass; draw a rounded backing then clip the image.
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(cg, in: rect)
    } else {
        // Shadow follows the image's own alpha (clean for transparent icons).
        ctx.draw(cg, in: rect)
    }
    ctx.restoreGState()
}

func fillGradient(_ ctx: CGContext, from c1: CGColor, to c2: CGColor) {
    let grad = CGGradient(colorsSpace: sRGB, colors: [c1, c2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: CGFloat(H)),
                           end: CGPoint(x: CGFloat(W), y: 0),
                           options: [])
}

func fillColor(_ ctx: CGContext, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
}

/// Left-aligned text (for steps / window content). `yTop` = vertical center from top.
func drawTextLeft(_ ctx: CGContext, _ string: String, size: CGFloat, weight: NSFont.Weight,
                  color: NSColor, x: CGFloat, yTop: CGFloat, alpha: Double, mono: Bool = false) {
    guard alpha > 0.01 else { return }
    let font = mono
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    let str = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: color.withAlphaComponent(alpha)
    ])
    let y = CGFloat(H) - yTop - str.size().height / 2
    withNSContext(ctx) { str.draw(at: NSPoint(x: x, y: y)) }
}

/// Mock mail-compose window: traffic lights, To/Subject header, body text that
/// types on with a blinking cursor — the "lands in your text field" payoff.
func drawComposeWindow(_ ctx: CGContext, typedText: String, cursorOn: Bool, alpha: Double) {
    guard alpha > 0.01 else { return }
    let w: CGFloat = 1280, h: CGFloat = 520
    let x = (CGFloat(W) - w) / 2
    let topY: CGFloat = 300                       // window top, measured from canvas top
    let y = CGFloat(H) - topY - h                 // CG bottom-left origin
    let rect = CGRect(x: x, y: y, width: w, height: h)

    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 60,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    let path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(.white)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Traffic lights
    let lights: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
    for (i, c) in lights.enumerated() {
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: x + 30 + CGFloat(i) * 32, y: rect.maxY - 42, width: 16, height: 16))
    }
    ctx.restoreGState()

    // Header lines + divider + body (drawn unclipped, window-relative)
    let leftPad = x + 44
    drawTextLeft(ctx, "An:  team@firma.ch", size: 30, weight: .regular,
                 color: NSColor(white: 0.45, alpha: 1), x: leftPad, yTop: topY + 96, alpha: alpha)
    drawTextLeft(ctx, "Betreff:  Meeting morgen", size: 30, weight: .regular,
                 color: NSColor(white: 0.45, alpha: 1), x: leftPad, yTop: topY + 152, alpha: alpha)
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
    ctx.setLineWidth(1.5)
    ctx.move(to: CGPoint(x: x + 28, y: rect.maxY - 192))
    ctx.addLine(to: CGPoint(x: rect.maxX - 28, y: rect.maxY - 192))
    ctx.strokePath()
    ctx.restoreGState()

    // Body text with cursor
    let bodyFont = NSFont.systemFont(ofSize: 38, weight: .regular)
    let bodyStr = NSAttributedString(string: typedText, attributes: [
        .font: bodyFont,
        .foregroundColor: NSColor(white: 0.12, alpha: alpha)
    ])
    let bodyY = topY + 260
    withNSContext(ctx) {
        bodyStr.draw(at: NSPoint(x: leftPad, y: CGFloat(H) - bodyY - bodyStr.size().height / 2))
    }
    if cursorOn {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: leftPad + bodyStr.size().width + 4,
                        y: CGFloat(H) - bodyY - 24, width: 4, height: 48))
        ctx.restoreGState()
    }
}

/// Rounded capsule chip with icon-ish dot + label, centered at x.
func drawChip(_ ctx: CGContext, label: String, color: NSColor, centerX: CGFloat,
              yTop: CGFloat, alpha: Double) {
    guard alpha > 0.01 else { return }
    let font = NSFont.systemFont(ofSize: 34, weight: .semibold)
    let str = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
    let tw = str.size().width
    let w = tw + 76, h: CGFloat = 68
    let rect = CGRect(x: centerX - w / 2, y: CGFloat(H) - yTop - h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    let path = CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color.withAlphaComponent(0.92).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    withNSContext(ctx) {
        str.draw(at: NSPoint(x: rect.midX - tw / 2, y: rect.midY - str.size().height / 2))
    }
}

// MARK: - Assets

func loadImage(_ url: URL) -> NSImage? {
    NSImage(contentsOf: url)
}
let icon = loadImage(iconURL)
let shotRecording  = loadImage(uiDir.appendingPathComponent("panel-recording.png"))
let shotSuccess    = loadImage(uiDir.appendingPathComponent("panel-success.png"))
let shotSettings   = loadImage(uiDir.appendingPathComponent("settings-full.png"))
let shotOnboarding = loadImage(uiDir.appendingPathComponent("onboarding.png"))

// MARK: - Storyboard

let rawDictation   = "ähm Meeting morgen äh auf drei – nein, vier Uhr"
let cleanDictation = "Das Meeting morgen wird auf 16:00 Uhr verschoben."

/// Scene boundaries in seconds: [start, end)
struct Scene { let start: Double; let end: Double; let draw: (CGContext, Double) -> Void }

let scenes: [Scene] = [
    // ── S1 · 0–4 s · Brand intro ────────────────────────────────────────────
    Scene(start: 0, end: 4) { ctx, t in
        fillGradient(ctx, from: indigo, to: blue)
        if let icon {
            let pop = easeOut((t - 0.05) / 0.5)
            drawImage(ctx, icon, width: 300, yTopCenter: 400,
                      alpha: fadeInOut(t, fi: 0.12, fo: 0.1),
                      scale: 0.85 + 0.15 * CGFloat(pop), cornerRadius: 0, backed: false)
        }
        drawText(ctx, "Voiceflow", size: 120, weight: .bold, color: .white,
                 yTop: 640, alpha: fadeInOut(t - 0.08, fi: 0.15, fo: 0.1))
        drawText(ctx, "Diktieren in jeder App — in deinem Ton.", size: 46, weight: .medium,
                 color: NSColor.white.withAlphaComponent(0.88),
                 yTop: 740, alpha: fadeInOut(t - 0.18, fi: 0.15, fo: 0.1))
    },

    // ── S2 · 4–9 s · Problem ────────────────────────────────────────────────
    Scene(start: 4, end: 9) { ctx, t in
        fillColor(ctx, nearBlack)
        drawText(ctx, "Tippen ist langsam.", size: 76, weight: .bold, color: .white,
                 yTop: 420, alpha: fadeInOut(t - 0.02, fi: 0.12, fo: 0.08))
        drawText(ctx, "Diktier-Abos: 10–15 CHF.", size: 76, weight: .bold, color: .white,
                 yTop: 540, alpha: fadeInOut(t - 0.25, fi: 0.12, fo: 0.08))
        drawText(ctx, "Jeden. Monat.", size: 76, weight: .bold,
                 color: NSColor(calibratedRed: 1, green: 0.42, blue: 0.42, alpha: 1),
                 yTop: 660, alpha: fadeInOut(t - 0.45, fi: 0.12, fo: 0.08))
    },

    // ── S3 · 9–15 s · Setup: one minute ─────────────────────────────────────
    Scene(start: 9, end: 15) { ctx, t in
        fillColor(ctx, offWhite)
        drawText(ctx, "Einrichtung? Eine Minute.", size: 64, weight: .bold,
                 color: NSColor(cgColor: nearBlack)!,
                 yTop: 140, alpha: fadeInOut(t, fi: 0.1, fo: 0.08))
        if let shotOnboarding {
            drawImage(ctx, shotOnboarding, width: 470, yTopCenter: 620,
                      alpha: fadeInOut(t - 0.05, fi: 0.12, fo: 0.08),
                      cornerRadius: 18, centerX: 560)
        }
        let steps: [(String, Double)] = [
            ("1   OpenAI-Key einfügen", 0.22),
            ("2   Shortcuts wählen", 0.38),
            ("3   Fertig — kein Account, kein Abo", 0.54)
        ]
        for (i, step) in steps.enumerated() {
            drawTextLeft(ctx, step.0, size: 46, weight: .semibold,
                         color: NSColor(white: 0.15, alpha: 1),
                         x: 1020, yTop: CGFloat(480 + i * 110),
                         alpha: fadeInOut(t - step.1, fi: 0.1, fo: 0.08))
        }
    },

    // ── S4 · 15–21 s · Demo: record ─────────────────────────────────────────
    Scene(start: 15, end: 21) { ctx, t in
        fillColor(ctx, offWhite)
        drawText(ctx, "Shortcut drücken. Reden.", size: 64, weight: .bold,
                 color: NSColor(cgColor: nearBlack)!,
                 yTop: 150, alpha: fadeInOut(t, fi: 0.1, fo: 0.08))
        if let shotRecording {
            drawImage(ctx, shotRecording, width: 640, yTopCenter: 600,
                      alpha: fadeInOut(t - 0.06, fi: 0.12, fo: 0.08),
                      scale: 1.0 + 0.05 * CGFloat(easeInOut(t)))   // subtle Ken Burns
        }
        drawText(ctx, "⌥1 · ⌥2 · ⌥3 — drei Modi, drei Shortcuts", size: 38, weight: .medium,
                 color: NSColor(white: 0.35, alpha: 1),
                 yTop: 1000, alpha: fadeInOut(t - 0.2, fi: 0.15, fo: 0.08))
    },

    // ── S5 · 21–29 s · Transformation ───────────────────────────────────────
    Scene(start: 21, end: 29) { ctx, t in
        fillColor(ctx, offWhite)
        drawText(ctx, "Loslassen — Voiceflow macht Text draus.", size: 56, weight: .bold,
                 color: NSColor(cgColor: nearBlack)!,
                 yTop: 140, alpha: fadeInOut(t, fi: 0.08, fo: 0.06))

        // Raw text types on (0.04→0.42 of scene), then fades; clean result fades in.
        let typeT = clamp01((t - 0.04) / 0.38)
        let shown = String(rawDictation.prefix(Int(Double(rawDictation.count) * easeInOut(typeT))))
        let rawAlpha = t < 0.52 ? fadeInOut(t - 0.02, fi: 0.06, fo: 0.001) : clamp01((0.58 - t) / 0.06)
        drawText(ctx, "🎙  " + shown, size: 38, weight: .regular,
                 color: NSColor(white: 0.42, alpha: 1),
                 yTop: 360, alpha: rawAlpha, mono: true)

        let cleanAlpha = easeOut((t - 0.56) / 0.1)
        drawText(ctx, "✓  " + cleanDictation, size: 52, weight: .semibold,
                 color: NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.28, alpha: 1),
                 yTop: 520, alpha: cleanAlpha)
        drawText(ctx, "Füllwörter weg · Selbstkorrekturen angewendet · Du/Sie erkannt",
                 size: 34, weight: .medium, color: NSColor(white: 0.4, alpha: 1),
                 yTop: 620, alpha: easeOut((t - 0.62) / 0.1))

        // Mode chips
        let chipA = easeOut((t - 0.74) / 0.1)
        drawChip(ctx, label: "Privat",   color: NSColor.systemBlue,   centerX: CGFloat(W)/2 - 360, yTop: 800, alpha: chipA)
        drawChip(ctx, label: "Business", color: NSColor.systemIndigo, centerX: CGFloat(W)/2,        yTop: 800, alpha: easeOut((t - 0.78) / 0.1))
        drawChip(ctx, label: "Random",   color: NSColor.systemPink,   centerX: CGFloat(W)/2 + 360, yTop: 800, alpha: easeOut((t - 0.82) / 0.1))
        drawText(ctx, "… jeder Modus mit deiner eigenen Instruktion", size: 34, weight: .medium,
                 color: NSColor(white: 0.4, alpha: 1),
                 yTop: 900, alpha: easeOut((t - 0.86) / 0.1))
    },

    // ── S6 · 29–35.5 s · Payoff: text lands in your app ─────────────────────
    Scene(start: 29, end: 35.5) { ctx, t in
        fillColor(ctx, offWhite)
        drawText(ctx, "… und landet direkt in deinem Textfeld.", size: 60, weight: .bold,
                 color: NSColor(cgColor: nearBlack)!,
                 yTop: 150, alpha: fadeInOut(t, fi: 0.1, fo: 0.06))

        // The polished sentence types into a mock compose window.
        let typeT = clamp01((t - 0.12) / 0.5)
        let typed = String(cleanDictation.prefix(Int(Double(cleanDictation.count) * easeInOut(typeT))))
        let blink = Int(t * 6.5 * 2.2) % 2 == 0
        drawComposeWindow(ctx, typedText: typed, cursorOn: blink || typeT < 1,
                          alpha: fadeInOut(t - 0.04, fi: 0.1, fo: 0.06))

        drawText(ctx, "Mail · Slack · Word · Browser — überall, wo dein Cursor ist.",
                 size: 38, weight: .medium, color: NSColor(white: 0.38, alpha: 1),
                 yTop: 950, alpha: fadeInOut(t - 0.55, fi: 0.12, fo: 0.06))
    },

    // ── S7 · 35.5–40 s · Trust ──────────────────────────────────────────────
    Scene(start: 35.5, end: 40) { ctx, t in
        fillGradient(ctx, from: indigo, to: blue)
        drawText(ctx, "Kein Abo. Kein Account. Kein Server.", size: 68, weight: .bold,
                 color: .white, yTop: 380, alpha: fadeInOut(t - 0.02, fi: 0.1, fo: 0.08))
        drawText(ctx, "Dein eigener OpenAI-Key — ≈ 0.3 Rappen pro Minute.", size: 48, weight: .semibold,
                 color: NSColor.white.withAlphaComponent(0.92),
                 yTop: 520, alpha: fadeInOut(t - 0.22, fi: 0.1, fo: 0.08))
        drawText(ctx, "🇨🇭  Versteht Schweizerdeutsch — schreibt Schweizer Hochdeutsch.",
                 size: 48, weight: .semibold, color: NSColor.white.withAlphaComponent(0.92),
                 yTop: 650, alpha: fadeInOut(t - 0.42, fi: 0.1, fo: 0.08))
    },

    // ── S8 · 40–44 s · CTA ──────────────────────────────────────────────────
    Scene(start: 40, end: 44) { ctx, t in
        fillColor(ctx, nearBlack)
        if let icon {
            drawImage(ctx, icon, width: 200, yTopCenter: 330,
                      alpha: fadeInOut(t, fi: 0.12, fo: 0.001), cornerRadius: 0, backed: false)
        }
        drawText(ctx, "Gratis laden:", size: 44, weight: .medium,
                 color: NSColor(white: 0.7, alpha: 1),
                 yTop: 520, alpha: fadeInOut(t - 0.08, fi: 0.12, fo: 0.001))
        drawText(ctx, "github.com/tmurschetz/voiceflow", size: 64, weight: .bold,
                 color: .white, yTop: 610, alpha: fadeInOut(t - 0.14, fi: 0.12, fo: 0.001), mono: true)
        drawText(ctx, "Open Beta · macOS 13+ · 2 MB", size: 38, weight: .medium,
                 color: NSColor(white: 0.55, alpha: 1),
                 yTop: 720, alpha: fadeInOut(t - 0.22, fi: 0.12, fo: 0.001))
    }
]

func drawFrame(_ ctx: CGContext, time: Double) {
    fillColor(ctx, nearBlack)
    for scene in scenes where time >= scene.start && time < scene.end {
        let t = (time - scene.start) / (scene.end - scene.start)
        scene.draw(ctx, t)
    }
}

// MARK: - Encoder

let writer = try! AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W,
    AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 9_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
    ]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: W,
        kCVPixelBufferHeightKey as String: H
    ])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

// Preview beats (seconds) → dumped as PNG when previewDir is set
let previewBeats: [Double] = [2.0, 6.5, 12.0, 18.0, 25.0, 27.5, 32.5, 37.5, 42.0]
var nextPreview = 0

var frame = 0
while frame < TOTAL_FRAMES {
    if !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
        continue
    }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let pixelBuffer = pb else { fatalError("pixel buffer") }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                        width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    let time = Double(frame) / Double(FPS)
    drawFrame(ctx, time: time)

    // Dump preview frame for visual review
    if let previewDir, nextPreview < previewBeats.count, time >= previewBeats[nextPreview] {
        if let img = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: img)
            if let png = rep.representation(using: .png, properties: [:]) {
                let name = String(format: "beat-%02d-t%.1fs.png", nextPreview + 1, time)
                try? png.write(to: previewDir.appendingPathComponent(name))
            }
        }
        nextPreview += 1
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(FPS))
    adaptor.append(pixelBuffer, withPresentationTime: pts)
    frame += 1
}

input.markAsFinished()
let sema = DispatchSemaphore(value: 0)
writer.finishWriting { sema.signal() }
sema.wait()

if writer.status == .completed {
    let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
    print("VIDEO_OK:\(outputURL.path) bytes=\(size ?? 0) frames=\(TOTAL_FRAMES) dur=\(DUR)s")
} else {
    print("VIDEO_FAILED:\(String(describing: writer.error))")
    exit(1)
}
