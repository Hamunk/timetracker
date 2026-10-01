// TimeTracker.app — the window, for whoever would rather click than type.
//
// Everything the launcher does can be done here: start, stop, switch, look
// back, fix a session, manage subjects and friends, change settings. It is a
// shell around one page. On launch it starts dashboard.py --app, which prints
// "<port> <token>" and serves app.html and its JSON on 127.0.0.1; this loads
// the page and gets out of the way. All the logic is in the page and the
// scripts behind it, so the window and the browser fallback cannot disagree.
//
// What the shell adds is what a page cannot have: a Dock icon, a real menu
// bar (and so Copy and Paste, which a web view only gets through an Edit
// menu), ⌘1–⌘4 for the views, and a window that remembers where it was.
//
//   ttapp                 the app. Launched by LaunchServices, never by hand.
//   ttapp --icon <dir>    draw the icon into <dir> as an .iconset, for
//                         install.sh to hand to iconutil
//
// Files: install.sh writes Contents/Resources/env, one KEY=VALUE per line —
// the folders and the verb this install was built for, the same four values
// every launcher bundle carries in its run script, plus where the scripts are.
// The app reads <data>/.app-page when it is activated: a launcher verb ("time
// settings") writes the page it wants there and opens the app, which goes to
// that page and deletes the file. It writes nothing else.
//
// The server is this process's child and leaves when it does. When the server
// leaves first, that is an update: the installer stops it and replaces this
// bundle. If the installed VERSION has moved on, the app opens its new self and
// quits; if not, it starts the server again.

import AppKit
import WebKit

let args = CommandLine.arguments

// --- the icon ------------------------------------------------------------------
// Drawn rather than shipped, so the repository holds no binary and the icon
// is one more thing built from source at install. A tomato on warm paper, in
// the grid macOS uses for its own icons: an 824-point rounded square, centred
// in 1024.

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

func drawIcon(_ px: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        return NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    rgb(242, 238, 230).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(248, 245, 239), ending: rgb(234, 228, 218))?.draw(in: tile, angle: -90)

    let body = NSBezierPath(ovalIn: r(262, 228, 500, 470))
    NSGradient(colors: [rgb(232, 98, 72), rgb(200, 66, 45), rgb(170, 50, 36)])?
        .draw(in: body, relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
    // A highlight, kept small: the tomato is flat paint, not a photograph.
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: r(352, 520, 120, 70)).fill()

    // The calyx: five leaves around the top, and a stem.
    let green = rgb(78, 122, 78)
    green.setFill()
    let cx = 512 * s, cy = 676 * s
    for i in 0..<5 {
        let a = CGFloat(i) * 2 * .pi / 5 + .pi / 2
        let leaf = NSBezierPath(ovalIn: NSRect(x: -28 * s, y: 0, width: 56 * s, height: 120 * s))
        var t = AffineTransform(translationByX: cx, byY: cy)
        t.rotate(byRadians: a - .pi / 2)
        t.scale(x: 1, y: i == 0 ? 0.7 : 1)
        leaf.transform(using: t)
        leaf.fill()
    }
    rgb(64, 102, 64).setFill()
    NSBezierPath(roundedRect: r(500, 676, 24, 92), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if args.count == 3 && args[1] == "--icon" {
    let dir = args[2]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                       ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                       ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        guard let png = drawIcon(px)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
    }
    exit(0)
}

// --- the app ---------------------------------------------------------------------

// The environment install.sh wrote for this install, set on this process so
// the server and everything it starts inherit it.
var env: [String: String] = [:]
if let res = Bundle.main.resourcePath,
   let raw = try? String(contentsOfFile: res + "/env", encoding: .utf8) {
    for line in raw.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
        guard k.hasPrefix("TIMETRACK_") || k == "TT_BIN" else { continue }
        env[k] = v
        setenv(k, v, 1)
    }
}
let home = FileManager.default.homeDirectoryForCurrentUser.path
let dataDir = env["TIMETRACK_DIR"] ?? home + "/.timetrack"
let binDir = env["TT_BIN"] ?? dataDir + "/bin"

func installedVersion() -> String {
    return ((try? String(contentsOfFile: binDir + "/VERSION", encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// The title bar, given back. The page runs under a transparent title bar so
// the window is one surface, and a web view takes every click it is under —
// so the top of the window looked like a title bar and could not be dragged.
// This strip lies over the top of the page, where the page puts nothing to
// click, and hands a drag to the window and a double-click to whatever the
// system's title-bar setting says. The close, minimise and zoom buttons sit
// above it and are untouched.
final class DragStrip: NSView {
    weak var under: NSView?
    override var mouseDownCanMoveWindow: Bool { true }
    // A scroll that starts over the strip still scrolls the page below it.
    override func scrollWheel(with e: NSEvent) { under?.scrollWheel(with: e) }
    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        if e.clickCount == 2 {
            let act = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if act == "Minimize" { w.performMiniaturize(nil) }
            else if act != "None" { w.performZoom(nil) }
            return
        }
        w.performDrag(with: e)
    }
}

final class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var win: NSWindow!
    var web: WKWebView!
    var server: Process?
    var origin = ""
    var leaving = false
    var failures = 0
    let version = installedVersion()

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        // No white flash before the page has painted: the web view shows
        // the window's colour, which is the page's.
        web.setValue(false, forKey: "drawsBackground")
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                   .fullSizeContentView],
                       backing: .buffered, defer: false)
        win.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TimeTracker"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 600, height: 440)
        win.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(22, 22, 21) : rgb(246, 245, 242)
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
        web.frame = root.bounds
        web.autoresizingMask = [.width, .height]
        root.addSubview(web)
        // As tall as a title bar, across the whole width. The page keeps
        // its first 40 points clear for this and the window's buttons.
        let strip = DragStrip(frame: NSRect(x: 0, y: root.bounds.height - 30,
                                            width: root.bounds.width, height: 30))
        strip.autoresizingMask = [.width, .minYMargin]
        strip.under = web
        root.addSubview(strip)
        win.contentView = root
        win.center()
        win.setFrameAutosaveName("main")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        win.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ n: Notification) { followRequest() }

    func applicationWillTerminate(_ n: Notification) {
        leaving = true
        server?.terminate()
    }

    // --- the server ---

    func startServer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [binDir + "/dashboard.py", "--app"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.serverEnded() }
        }
        do { try p.run() } catch { return showError("TimeTracker could not start.") }
        server = p
        DispatchQueue.global().async { [weak self] in
            // One line, then the pipe is left alone: the server writes nothing
            // after it.
            var line = Data()
            while true {
                let b = out.fileHandleForReading.readData(ofLength: 1)
                if b.isEmpty || b == Data([0x0A]) { break }
                line.append(b)
                if line.count > 200 { break }
            }
            let f = String(decoding: line, as: UTF8.self).split(separator: " ")
            DispatchQueue.main.async {
                guard let self = self, f.count == 2, let port = Int(f[0]) else { return }
                self.failures = 0
                self.origin = "http://127.0.0.1:\(port)"
                let page = self.takeRequest() ?? "now"
                let url = URL(string: "\(self.origin)/?t=\(f[1])#\(page)")!
                self.web.load(URLRequest(url: url))
            }
        }
    }

    func serverEnded() {
        if leaving { return }
        server = nil
        if installedVersion() != version && !version.isEmpty {
            // Updated underneath us. The installer may still be finishing
            // the bundles, so give it a moment, then open the new app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.relaunch() }
            return
        }
        failures += 1
        if failures > 3 { return showError("TimeTracker stopped. Quit it and open it again.") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startServer() }
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { self.leaving = true; NSApp.terminate(nil) }
        }
    }

    func showError(_ text: String) {
        let html = "<body style='font:15px -apple-system;color:#888;display:flex;"
            + "align-items:center;justify-content:center;height:90vh'>\(text)</body>"
        web.loadHTMLString(html, baseURL: nil)
    }

    // --- the page a launcher verb asked for ---

    func takeRequest() -> String? {
        let p = dataDir + "/.app-page"
        guard let raw = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        unlink(p)
        let page = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["now", "history", "subjects", "friends", "settings", "help"].contains(page) ? page : nil
    }

    func followRequest() {
        guard !origin.isEmpty, let page = takeRequest() else { return }
        go(page)
    }

    func go(_ page: String) {
        web.evaluateJavaScript("window.ttGo&&window.ttGo('\(page)')", completionHandler: nil)
        win.makeKeyAndOrderFront(nil)
    }

    // --- the web view ---

    // The page's own address, and nothing else, stays in the window. A link
    // anywhere else (a calendar's sync settings, say) goes to the browser.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = a.request.url else { return decisionHandler(.cancel) }
        if url.absoluteString.hasPrefix(origin + "/") || url.scheme == "about" {
            return decisionHandler(.allow)
        }
        if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let url = a.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler()
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    // --- the menu bar ---

    @objc func page(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { go(p) }
    }

    @objc func reload(_ sender: Any?) { web.reload() }

    func buildMenu() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TimeTracker"
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            let holder = NSMenuItem(); holder.submenu = m; bar.addItem(holder)
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "",
                  _ mods: NSEvent.ModifierFlags = [.command], page: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            if let p = page { i.representedObject = p; i.target = self }
            return i
        }
        menu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(page(_:)), ",", page: "settings"),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let reload = item("Reload", #selector(reload(_:)), "r")
        reload.target = self
        menu("View", [
            item("Now", #selector(page(_:)), "1", page: "now"),
            item("History", #selector(page(_:)), "2", page: "history"),
            item("Subjects", #selector(page(_:)), "3", page: "subjects"),
            item("Friends", #selector(page(_:)), "4", page: "friends"),
            .separator(),
            reload,
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Help", [item("\(name) Help", #selector(page(_:)), "?", page: "help")])
        NSApp.mainMenu = bar
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App()
app.delegate = delegate
app.run()
