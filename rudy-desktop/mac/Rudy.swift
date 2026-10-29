// Rudy — a little walking robot for your desktop.
//
// A transparent, always-on-top, click-through window that walks the sprite
// from the portfolio site back and forth along the bottom of the main screen.
//
// It does no networking, writes no files, installs nothing, needs no admin
// rights, and quits completely from the menu bar.
//
// Build: ./build.sh  (needs Xcode Command Line Tools: xcode-select --install)

import AppKit
import QuartzCore

// ---------------------------------------------------------------------------
//  Art / animation constants.
//
//  Spritesheet: 768 x 128, six 128 x 128 cells (spritesheetV2).
//  Drawn content inside a cell spans x 11..115, y 8..118, and the silhouette
//  already carries a 1 px pink outline, which is why this build does not add
//  a rim of its own any more.
//
//  Insets are the worst case over all six frames and both facings, so the
//  turn-around never clips him.
//
//  These mirror index.html (LEFT_TX / RIGHT_TX / 60 s crossing / 6 fps walk
//  cycle) and win/Rudy.cs — keep the three in sync.
// ---------------------------------------------------------------------------
private let CELL: CGFloat = 128
private let FRAME_COUNT = 6
private let FRAME_FPS: Double = 6
private let CROSS_SECONDS: Double = 60
private let INSET_L: CGFloat = 11
private let INSET_R: CGFloat = 12
private let PAD_BOTTOM: CGFloat = 9

// 128 image px at 96 dpi is what the sprite looks like on Windows at 100%
// scaling; using points keeps him the same physical size on a Mac.
private let SPRITE_POINTS: CGFloat = CELL * 96 / 128
private let K: CGFloat = SPRITE_POINTS / CELL

// A click has to wait out the double-click interval before it pauses him,
// otherwise every double-click would also toggle the pause on its way to
// quitting.
private let CLICK_DELAY: TimeInterval = 0.25

/// A borderless window that never becomes key or main, so clicking Rudy cannot
/// pull focus away from whatever the user is working in.
final class SpriteWindow: NSWindow {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

/// Click = pause/resume, double-click = quit.
///
/// Note: AppKit has no per-pixel click-through for a normal window, so the
/// whole sprite box swallows clicks on macOS (on Windows only the drawn
/// silhouette does, because layered windows hit-test by alpha).
final class SpriteView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pending: DispatchWorkItem?

    // Behave on the very first click, even though this app is never active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pending?.cancel()
            pending = nil
            onDoubleClick?()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onClick?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CLICK_DELAY, execute: work)
    }
}

final class Walker: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var sprite: CALayer!
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var x: CGFloat = 0
    private var dir: CGFloat = -1
    private var speed: CGFloat = 1
    private var minX: CGFloat = 0
    private var maxX: CGFloat = 0
    private var baseY: CGFloat = 0
    private var lastX = Int.min
    private var lastFrame = -1
    private var lastTick: Double = 0
    private var animTime: Double = 0
    private var userPaused = false
    private var sessionPaused = false

    private var isPaused: Bool { return userPaused || sessionPaused }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main,
              let url = Bundle.main.url(forResource: "spritesheet", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let sheet = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { NSApp.terminate(nil); return }

        let visible = screen.visibleFrame
        let side = SPRITE_POINTS

        let win = SpriteWindow(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .statusBar
        // Receives clicks on his body (see SpriteView); AppKit cannot do
        // per-pixel click-through, so his whole box is clickable here.
        win.ignoresMouseEvents = false
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.animationBehavior = .none
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = SpriteView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        view.onClick = { [weak self] in self?.togglePause() }
        view.onDoubleClick = { NSApp.terminate(nil) }
        win.contentView = view

        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.contents = sheet
        layer.contentsGravity = .resize
        layer.contentsRect = CGRect(x: 0, y: 0, width: 1.0 / CGFloat(FRAME_COUNT), height: 1)
        layer.contentsScale = screen.backingScaleFactor
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        view.layer?.addSublayer(layer)

        window = win
        sprite = layer

        // Sits above the Dock: visibleFrame already excludes it.
        minX = visible.minX - INSET_L * K
        maxX = visible.maxX - (CELL - INSET_R) * K
        baseY = visible.minY - PAD_BOTTOM * K
        speed = (maxX - minX) / CGFloat(CROSS_SECONDS)

        x = maxX // start at the right edge, walking left (matches the site)
        dir = -1

        win.setFrameOrigin(NSPoint(x: maxX, y: baseY))
        win.orderFrontRegardless()

        buildStatusItem()

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = CACurrentMediaTime()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(sessionResigned),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionBecameActive),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Rudy"

        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Rudy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func tick() {
        if isPaused { return }

        let now = CACurrentMediaTime()
        var dt = now - lastTick
        lastTick = now
        if dt <= 0 { return }
        if dt > 0.05 { dt = 0.05 } // don't jump after a stall

        x += dir * speed * CGFloat(dt)
        if x <= minX { x = minX; dir = 1 }
        else if x >= maxX { x = maxX; dir = -1 }

        // Walk cycle runs off animation time, which freezes while paused.
        animTime += dt
        let frame = Int(animTime * FRAME_FPS) % FRAME_COUNT
        let ix = Int(x.rounded())
        if ix == lastX && frame == lastFrame { return }
        lastX = ix
        lastFrame = frame

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contentsRect = CGRect(
            x: CGFloat(frame) / CGFloat(FRAME_COUNT), y: 0,
            width: 1.0 / CGFloat(FRAME_COUNT), height: 1)
        // The art faces left; mirror it when walking right.
        sprite.transform = CATransform3DMakeScale(dir > 0 ? -1 : 1, 1, 1)
        window.setFrameOrigin(NSPoint(x: CGFloat(ix), y: baseY))
        CATransaction.commit()
    }

    private func togglePause() {
        userPaused.toggle()
        if !isPaused { lastTick = CACurrentMediaTime() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func sessionResigned(_ note: Notification) {
        sessionPaused = true
    }

    @objc private func sessionBecameActive(_ note: Notification) {
        sessionPaused = false
        lastTick = CACurrentMediaTime()
    }
}

let app = NSApplication.shared
_ = app.setActivationPolicy(.accessory) // no Dock icon, no Cmd-Tab entry
let walker = Walker()
app.delegate = walker
app.run()
