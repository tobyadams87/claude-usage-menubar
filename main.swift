import AppKit
import Security
import ServiceManagement
import WebKit

// Menu bar app showing Claude weekly usage.
// First launch: sign in to claude.ai in a small window. The session cookies are
// stored in the user's own Keychain and used to poll the usage endpoint.
// The web view exists only while signing in; between polls the app is idle.

struct Usage {
    var weekly: Double
    var weeklyReset: Date?
    var session: Double?
    var sessionReset: Date?
}

enum UsageError: Error {
    case signedOut, unauthorized, network, parse
    var message: String {
        switch self {
        case .signedOut: return "Not signed in"
        case .unauthorized: return "Session expired — sign in again"
        case .network: return "Can't reach claude.ai"
        case .parse: return "Unexpected response"
        }
    }
}

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
let base = "https://claude.ai"

// MARK: Keychain storage for the session cookies

enum Store {
    static let service = "ClaudeUsageMenuBar"
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service]
    static func load() -> [HTTPCookie] {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { a in
            var p: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in a where k != "expires" { p[HTTPCookiePropertyKey(k)] = v }
            if let e = a["expires"] as? Double { p[.expires] = Date(timeIntervalSince1970: e) }
            return HTTPCookie(properties: p)
        }
    }
    static func save(_ cookies: [HTTPCookie]) {
        let arr: [[String: Any]] = cookies.map { c in
            var a: [String: Any] = ["Name": c.name, "Value": c.value, "Domain": c.domain, "Path": c.path]
            if c.isSecure { a["Secure"] = "TRUE" }
            if let e = c.expiresDate { a["expires"] = e.timeIntervalSince1970 }
            return a
        }
        guard let d = try? JSONSerialization.data(withJSONObject: arr) else { return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = d
        SecItemAdd(q as CFDictionary, nil)
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

// Newest first. Keep the top entry in sync with CFBundleShortVersionString in build.sh.
let changelog: [(version: String, notes: [String])] = [
    ("1.1.0", ["Dropdown now predicts how your usage is going, like the Claude app: \"At this pace you'll run out Monday morning, before Tuesday's reset\", or how much you're on pace to use by reset", "Works for both the weekly and 5-hour limits"]),
    ("1.0.1", ["Separator dots now line up exactly between the two rows", "Menu bar item is never wider than before; drawing code moved to MenuBarArt.swift"]),
    ("1.0", ["Added About page with changelog and credits", "Menu shows when usage last refreshed and when the next refresh is",
             "New app icon"]),
    ("0.8", ["Weekly reset countdown now shown in the menu bar", "Dropdown shows one line per limit"]),
    ("0.7", ["Mascot idles: occasional blink, double blink, leg shuffle and arm wave"]),
    ("0.6", ["Compact two-line menu bar layout: weekly on top, 5-hour and its countdown below",
             "5-hour usage and time until it resets"]),
    ("0.5", ["Pixel mascot added to the menu bar"]),
    ("0.4", ["Percentages change color as limits near: yellow at 60%, orange at 80%, red at 90%"]),
    ("0.3", ["Google sign-in now works (popup handling)", "Fallback: sign in with a session key"]),
    ("0.2", ["Sign in with your claude.ai account inside the app; session stored in your Keychain",
             "No longer requires the Claude Code CLI"]),
    ("0.1", ["First version: weekly usage in the menu bar", "Launch at Login, Refresh, Quit"]),
]

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let weeklyItem = NSMenuItem(title: "Weekly: …", action: nil, keyEquivalent: "")
    let resetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let weeklyProjItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sessionProjItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let signInItem = NSMenuItem(title: "Sign In…", action: #selector(showLogin), keyEquivalent: "")
    let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "")
    let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let keyItem = NSMenuItem(title: "Sign In with Session Key…", action: #selector(promptSessionKey), keyEquivalent: "")
    let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
    let aboutItem = NSMenuItem(title: "About ClaudeUsage", action: #selector(showAbout), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    let interval: TimeInterval = 300
    var timer: Timer?
    var cookies: [HTTPCookie] = []
    var orgID: String? = UserDefaults.standard.string(forKey: "orgID")
    var inFlight = false

    var loginWindow: NSWindow?
    var aboutWindow: NSWindow?
    var webView: WKWebView?
    var checkingLogin = false
    var loginPoll: Timer?
    var last: Usage?
    var lastAttempt: Date?
    var lastOK = true
    var pose: Pose = .rest
    var lastRows: [BarRow]?
    var plainText: String?
    var tick: Timer?
    var popups: [NSWindow] = []

    let http = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpShouldSetCookies = false
        return c
    }())

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMainMenu()
        item.autosaveName = "ClaudeUsageMenuBar"   // own stable slot, not a generic "Item-N"
        item.isVisible = true
        item.button?.image = mascotImage()
        item.button?.imagePosition = .imageLeft
        item.button?.imageHugsTitle = true
        item.button?.title = "…"
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        for i in [weeklyItem, weeklyProjItem, resetItem, sessionItem, sessionProjItem] { i.isEnabled = false; menu.addItem(i) }
        weeklyProjItem.isHidden = true
        sessionProjItem.isHidden = true
        menu.addItem(.separator())
        updatedItem.isEnabled = false; menu.addItem(updatedItem)
        menu.addItem(.separator())
        for i in [signInItem, keyItem, refreshItem, signOutItem, loginItem, aboutItem] { i.target = self; menu.addItem(i) }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu

        cookies = Store.load()
        scheduleIdle()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 60
        // Cheap local re-render (no network) so the countdown stays current.
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.render() }
        tick?.tolerance = 10
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)

        if cookies.isEmpty { showSignedOut(); showLogin() } else { refresh() }
    }

    // Accessory apps have no menu bar, but the web view needs Edit shortcuts (paste etc).
    func setupMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) {
        react()
        updateUpdatedItem()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { s.status == .enabled ? try s.unregister() : try s.register() } catch { NSSound.beep() }
    }

    // MARK: About

    @objc func showAbout() {
        if let w = aboutWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        func label(_ t: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = font; l.textColor = color; l.alignment = .center
            l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0
            l.preferredMaxLayoutWidth = 380
            return l
        }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12), head = NSFont.boldSystemFont(ofSize: 13)
        let headStyle = NSMutableParagraphStyle(); headStyle.paragraphSpacing = 4
        let bulletStyle = NSMutableParagraphStyle()       // wrapped lines line up under the text, not the bullet
        bulletStyle.firstLineHeadIndent = 2; bulletStyle.headIndent = 16
        bulletStyle.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        bulletStyle.paragraphSpacing = 3
        for (i, e) in changelog.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])) }
            text.append(NSAttributedString(string: "Version \(e.version)\n",
                                           attributes: [.font: head, .foregroundColor: NSColor.labelColor, .paragraphStyle: headStyle]))
            for n in e.notes {
                text.append(NSAttributedString(string: "•\t\(n)\n", attributes: [
                    .font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: bulletStyle]))
            }
        }
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false; tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textStorage?.setAttributedString(text)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        tv.autoresizingMask = [.width]
        scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true

        // Credit line with a clickable X handle.
        let credit = NSTextField(labelWithAttributedString: {
            let f = NSFont.systemFont(ofSize: 11)
            let dim: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.secondaryLabelColor]
            let a = NSMutableAttributedString(string: "Made by ", attributes: dim)
            a.append(NSAttributedString(string: "@tobyadams", attributes: [
                .font: f, .link: URL(string: "https://x.com/tobyadams")!]))
            a.append(NSAttributedString(string: " and Claude Code (Sonnet 5.5)", attributes: dim))
            a.addAttribute(.paragraphStyle, value: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
                           range: NSRange(location: 0, length: a.length))
            return a
        }())
        credit.allowsEditingTextAttributes = true
        credit.isSelectable = true
        credit.preferredMaxLayoutWidth = 380; credit.lineBreakMode = .byWordWrapping; credit.maximumNumberOfLines = 0

        // Link to the repository (source, issues, releases).
        let repo = NSTextField(labelWithAttributedString: {
            let f = NSFont.systemFont(ofSize: 11)
            let dim: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.secondaryLabelColor]
            let a = NSMutableAttributedString(string: "", attributes: dim)
            a.append(NSAttributedString(string: "github.com/tobyadams87/claude-usage-menubar", attributes: [
                .font: f, .link: URL(string: "https://github.com/tobyadams87/claude-usage-menubar")!]))
            a.addAttribute(.paragraphStyle, value: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
                           range: NSRange(location: 0, length: a.length))
            return a
        }())
        repo.allowsEditingTextAttributes = true
        repo.isSelectable = true
        repo.preferredMaxLayoutWidth = 380; repo.lineBreakMode = .byWordWrapping; repo.maximumNumberOfLines = 0

        let stack = NSStackView(views: [icon,
            label("ClaudeUsage", .boldSystemFont(ofSize: 18)),
            label("Version \(version)", .systemFont(ofSize: 12), .secondaryLabelColor),
            label("Shows your Claude weekly and 5-hour usage limits in the menu bar. Uses an unofficial claude.ai endpoint and is not affiliated with Anthropic.", .systemFont(ofSize: 11), .secondaryLabelColor),
            credit,
            repo,
            label("Changelog", .boldSystemFont(ofSize: 12)),
            scroll])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 24, right: 20)
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true     // fixed, so nothing can push the edges out
        stack.setCustomSpacing(14, after: stack.views[0])   // icon
        stack.setCustomSpacing(4, after: stack.views[1])    // name
        stack.setCustomSpacing(14, after: stack.views[2])   // version
        stack.setCustomSpacing(14, after: stack.views[3])   // description
        stack.setCustomSpacing(4, after: stack.views[4])    // credit
        stack.setCustomSpacing(22, after: stack.views[5])   // repo link
        stack.setCustomSpacing(8, after: stack.views[6])    // "Changelog"

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About ClaudeUsage"
        w.contentView = stack
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(stack.fittingSize)
        w.center()
        aboutWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Sign in / out

    @objc func showLogin() {
        if let w = loginWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()   // nothing lingers on disk; we keep only our Keychain copy
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: cfg)
        wv.customUserAgent = userAgent
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.load(URLRequest(url: URL(string: "\(base)/login")!))

        let w = NSWindow(contentRect: wv.frame, styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in to Claude"
        w.contentView = wv
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        webView = wv
        loginWindow = w
        loginPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkCookies() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        if let w = n.object as? NSWindow, w === aboutWindow { w.contentView = nil; aboutWindow = nil; return }
        if let w = n.object as? NSWindow, w !== loginWindow {
            (w.contentView as? WKWebView)?.navigationDelegate = nil
            w.contentView = nil
            popups.removeAll { $0 === w }
            return
        }
        loginPoll?.invalidate(); loginPoll = nil
        popups.forEach { $0.close() }
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        loginWindow?.contentView = nil
        loginWindow = nil
        checkingLogin = false
    }

    // Google / SSO popups: open them in their own small window sharing the same session.
    func webView(_ wv: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let pv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        pv.customUserAgent = userAgent
        pv.uiDelegate = self
        let w = NSWindow(contentRect: pv.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentView = pv
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        popups.append(w)
        w.makeKeyAndOrderFront(nil)
        return pv
    }

    func webViewDidClose(_ wv: WKWebView) { popups.first { $0.contentView === wv }?.close() }

    func checkCookies() {
        guard !checkingLogin, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        store.getAllCookies { [weak self] all in
            guard let self, !self.checkingLogin else { return }
            let mine = all.filter { $0.domain.hasSuffix("claude.ai") }
            guard mine.contains(where: { $0.name == "sessionKey" }) else { return }
            self.checkingLogin = true
            self.cookies = mine
            self.orgID = nil
            self.doRefresh { ok in
                if ok {
                    Store.save(mine)
                    self.loginWindow?.close()
                } else {
                    self.cookies = Store.load()
                    self.updateAuthItems()
                    self.checkingLogin = false   // still mid-flow; keep polling
                }
            }
        }
    }

    // Fallback for when Google refuses embedded sign-in: paste the sessionKey cookie from a normal browser.
    @objc func promptSessionKey() {
        let a = NSAlert()
        a.messageText = "Sign in with session key"
        a.informativeText = "Sign in to claude.ai in your browser, open Developer Tools → Application (Chrome) or Storage (Safari/Firefox) → Cookies → claude.ai, and copy the value of “sessionKey”."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.placeholderString = "sk-ant-sid…"
        a.accessoryView = f
        a.addButton(withTitle: "Sign In"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, let c = HTTPCookie(properties: [.name: "sessionKey", .value: v, .domain: ".claude.ai",
                                                          .path: "/", .secure: "TRUE"]) else { return }
        cookies = [c]; orgID = nil
        doRefresh { [weak self] ok in
            guard let self else { return }
            if ok { Store.save([c]) } else { self.cookies = Store.load(); self.updateAuthItems() }
        }
    }

    @objc func signOut() {
        Store.clear()
        cookies = []
        orgID = nil
        UserDefaults.standard.removeObject(forKey: "orgID")
        showSignedOut()
    }

    func showSignedOut() {
        setPlain("Sign in")
        weeklyItem.title = "Not signed in"
        resetItem.isHidden = true
        sessionItem.isHidden = true
        weeklyProjItem.isHidden = true
        sessionProjItem.isHidden = true
        updateAuthItems()
    }

    func updateUpdatedItem() {
        guard let t = lastAttempt, !cookies.isEmpty else { updatedItem.isHidden = true; return }
        updatedItem.isHidden = false
        let ago = Date().timeIntervalSince(t)
        let next = (timer?.fireDate ?? Date()).timeIntervalSinceNow
        let agoText = ago < 60 ? "just now" : "\(Self.countdown(ago)) ago"
        let nextText = next < 60 ? "<1m" : Self.countdown(next)
        updatedItem.title = (lastOK ? "Updated " : "Update failed ") + agoText + " · next in " + nextText
    }

    func updateAuthItems() {
        signInItem.isHidden = !cookies.isEmpty
        keyItem.isHidden = !cookies.isEmpty
        signOutItem.isHidden = cookies.isEmpty
        refreshItem.isHidden = cookies.isEmpty
    }

    // MARK: Fetching

    func get(_ path: String, _ done: @escaping (Result<Data, UsageError>) -> Void) {
        let now = Date()
        let header = cookies.filter { ($0.expiresDate ?? .distantFuture) > now }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: URL(string: base + path)!)
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        http.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let r: Result<Data, UsageError>
            if code == 401 || code == 403 { r = .failure(.unauthorized) }
            else if let data, err == nil, (200..<300).contains(code) { r = .success(data) }
            else { r = .failure(.network) }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    @objc func refresh() { doRefresh(nil) }

    func doRefresh(_ completion: ((Bool) -> Void)?) {
        guard !cookies.isEmpty else { showSignedOut(); completion?(false); return }
        guard !inFlight else { completion?(false); return }
        inFlight = true
        let finish: (Result<Usage, UsageError>) -> Void = { [weak self] r in
            guard let self else { return }
            self.inFlight = false
            self.lastAttempt = Date()
            if case .success = r { self.lastOK = true } else { self.lastOK = false }
            self.timer?.fireDate = Date().addingTimeInterval(self.interval)   // next poll counts from this fetch
            self.display(r)
            if case .success = r { completion?(true) } else { completion?(false) }
        }
        if let org = orgID { fetchUsage(org, finish) } else {
            get("/api/organizations") { [weak self] r in
                guard let self else { return }
                switch r {
                case .failure(let e): finish(.failure(e))
                case .success(let d):
                    guard let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], !arr.isEmpty else {
                        return finish(.failure(.parse))
                    }
                    // Prefer an org that has chat capability (personal / team plan).
                    let pick = arr.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? arr[0]
                    guard let id = pick["uuid"] as? String else { return finish(.failure(.parse)) }
                    self.orgID = id
                    UserDefaults.standard.set(id, forKey: "orgID")
                    self.fetchUsage(id, finish)
                }
            }
        }
    }

    func fetchUsage(_ org: String, _ finish: @escaping (Result<Usage, UsageError>) -> Void) {
        get("/api/organizations/\(org)/usage") { r in
            switch r {
            case .failure(let e): finish(.failure(e))
            case .success(let d): finish(Self.parse(d))
            }
        }
    }

    static func parse(_ data: Data) -> Result<Usage, UsageError> {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let week = j["seven_day"] as? [String: Any],
              let w = (week["utilization"] as? NSNumber)?.doubleValue else { return .failure(.parse) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        func date(_ d: [String: Any]?) -> Date? {
            guard let s = d?["resets_at"] as? String else { return nil }
            // API times are like 03:59:59.7; round to the nearest minute so they read like the Claude app (4:00).
            guard let t = iso.date(from: s) ?? iso2.date(from: s) else { return nil }
            return Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 60).rounded() * 60)
        }
        let five = j["five_hour"] as? [String: Any]
        return .success(Usage(weekly: w, weeklyReset: date(week),
                              session: (five?["utilization"] as? NSNumber)?.doubleValue, sessionReset: date(five)))
    }

    // MARK: Display

    func display(_ r: Result<Usage, UsageError>) {
        updateAuthItems()
        switch r {
        case .success(let u):
            last = u
            render()
        case .failure(let e):
            // Keep the last known value in the bar if we have one; just explain in the menu.
            if last == nil { setPlain("!") }
            weeklyItem.title = e.message
            resetItem.isHidden = true
            sessionItem.isHidden = true
            weeklyProjItem.isHidden = true
            sessionProjItem.isHidden = true
            if case .unauthorized = e { signInItem.isHidden = false }
        }
    }

    // MARK: Idle animation — occasional one-shot sequences, no continuous loop.

    func scheduleIdle() {
        let t = Timer(timeInterval: .random(in: 25...75), repeats: false) { [weak self] _ in self?.playIdle() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
    }

    var animGen = 0   // bumps on every new sequence so an older one can't stomp on it

    func playIdle() {
        let r = Int.random(in: 0..<100)
        play(r < 60 ? .blink : r < 75 ? .double : r < 90 ? .shuffle : .wave)
        // reschedule after the sequence finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.scheduleIdle() }
    }

    enum Action { case blink, double, shuffle, wave }

    // Click on the item: always a visible reaction (never a plain blink).
    func react() { play([.double, .shuffle, .wave].randomElement()!) }

    func play(_ a: Action) {
        let seq: [(Pose, TimeInterval)]
        switch a {
        case .blink: seq = [(.blink, 0.16)]
        case .double: seq = [(.blink, 0.14), (.rest, 0.12), (.blink, 0.14)]
        case .shuffle: seq = [(.step, 0.18), (.rest, 0.18), (.step, 0.18), (.rest, 0.18)]
        case .wave: seq = [(.waveL, 0.2), (.waveR, 0.2), (.waveL, 0.2), (.waveR, 0.2)]
        }
        animGen += 1
        let gen = animGen
        var t = 0.0
        for (p, d) in seq {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                if self?.animGen == gen { self?.setPose(p) }
            }
            t += d
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            if self?.animGen == gen { self?.setPose(.rest) }
        }
    }

    func setPose(_ p: Pose) {
        pose = p
        if let rows = lastRows, plainText == nil { setStacked(rows) }
        else if let txt = plainText { setPlain(txt) }
    }

    func render() {
        guard let u = last else { return }
        let now = Date()
        // Reset time has passed: numbers are stale, fetch fresh ones.
        if let r = u.sessionReset, r < now, !inFlight { refresh() }

        // Menu bar: mascot + two aligned rows (weekly on top; 5-hour below), each with its countdown.
        func cd(_ d: Date?) -> String? {
            guard let d, d > now else { return nil }
            return Self.countdown(d.timeIntervalSince(now), compact: true)
        }
        var rows = [BarRow(label: "wk", pct: "\(Int(u.weekly.rounded()))%", color: Self.color(for: u.weekly), time: cd(u.weeklyReset))]
        if let s = u.session {
            rows.append(BarRow(label: "5h", pct: "\(Int(s.rounded()))%", color: Self.color(for: s), time: cd(u.sessionReset)))
        }
        setStacked(rows)

        // Menu detail
        var w = "Weekly: \(Int(u.weekly.rounded()))% used"
        if let r = u.weeklyReset, r > now { w += " · resets in \(Self.countdown(r.timeIntervalSince(now))) (\(Self.fmt(r)))" }
        setMain(weeklyItem, w)
        resetItem.isHidden = true
        if let s = u.session {
            var t = "5-hour: \(Int(s.rounded()))% used"
            if let r = u.sessionReset, r > now { t += " · resets in \(Self.countdown(r.timeIntervalSince(now))) (\(Self.timeFmt.string(from: r)))" }
            setMain(sessionItem, t)
            sessionItem.isHidden = false
        } else { sessionItem.isHidden = true }

        // "At this pace..." predictions (same idea as the Claude app's usage page)
        let wp = Projection.make(utilization: u.weekly, resetsAt: u.weeklyReset, window: 7 * 86400, now: now)
        setProjection(weeklyProjItem, wp.weeklyText(resetsAt: u.weeklyReset, now: now), warn: wp.runsOutSoon)
        if let s = u.session {
            let sp = Projection.make(utilization: s, resetsAt: u.sessionReset, window: 5 * 3600, now: now)
            setProjection(sessionProjItem, sp.sessionText(resetsAt: u.sessionReset, now: now), warn: sp.runsOutSoon)
        } else { sessionProjItem.isHidden = true }
    }

    // Info lines are custom views rather than plain menu items: macOS dims disabled items (which would
    // wash out the bold usage lines), but leaves custom views alone. Left inset matches the text of the
    // regular items, which leave room for the checkmark column.
    static let infoInset: CGFloat = 28

    func infoView(_ text: NSAttributedString, height: CGFloat) -> NSView {
        let label = NSTextField(labelWithAttributedString: text)
        label.sizeToFit()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.infoInset + label.frame.width + 16, height: height))
        label.frame.origin = NSPoint(x: Self.infoInset, y: (height - label.frame.height) / 2)
        view.addSubview(label)
        view.autoresizingMask = [.width]
        return view
    }

    // The facts (usage, limit, reset time): bold and full strength.
    func setMain(_ item: NSMenuItem, _ text: String) {
        item.title = text
        item.view = infoView(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor]), height: 24)
    }

    // The forecast: smaller and lighter, so it reads as secondary to the line above it.
    func setProjection(_ item: NSMenuItem, _ text: String?, warn: Bool) {
        guard let text else { item.isHidden = true; return }
        item.isHidden = false
        item.title = text
        item.view = infoView(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: warn ? NSColor.systemOrange : NSColor.secondaryLabelColor]), height: 18)
    }

    static func countdown(_ secs: TimeInterval, compact: Bool = false) -> String {
        let sp = compact ? "" : " "
        let m = max(0, Int(secs / 60))
        if m < 60 { return "\(m)m" }
        if m < 60 * 24 { return "\(m / 60)h\(sp)\(m % 60)m" }
        return "\(m / 1440)d\(sp)\((m % 1440) / 60)h"
    }

    // Composite image: mascot + aligned text rows (see MenuBarArt.swift). Dynamic colors follow light/dark mode.
    func setStacked(_ rows: [BarRow]) {
        lastRows = rows; plainText = nil
        item.button?.attributedTitle = NSAttributedString(string: "")
        item.button?.image = BarLayout.image(rows: rows, pose: pose)
        item.button?.imagePosition = .imageOnly
    }

    // Plain text state ("Sign in", "!", "…") next to the mascot.
    func setPlain(_ text: String) {
        plainText = text
        item.button?.image = mascotImage(pose: pose)
        item.button?.imagePosition = .imageLeft
        item.button?.title = text
    }

    static let timeFmt: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    // Default (adaptive) until 60%, then yellow → orange → red as you near the limit.
    static func color(for pct: Double) -> NSColor? {
        switch pct {
        case ..<60: return nil
        case ..<80: return .systemYellow
        case ..<90: return .systemOrange
        default: return .systemRed
        }
    }

    func setBarTitle(_ text: String, color: NSColor?) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: color == nil ? .regular : .semibold)]
        if let color { attrs[.foregroundColor] = color }
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    static func fmt(_ d: Date) -> String { dayFmt.string(from: d) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
