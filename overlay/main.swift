// agent-overlay-mac — a consent + control overlay for an AI agent driving this Mac.
//
// A floating, NON-ACTIVATING panel: it stays above every app and every Space but never
// steals keyboard focus from the app being driven (the old osascript dialog did both —
// it grabbed focus and sat over the middle of the screen, covering what was being driven).
//
//   agent-overlay-mac --who "<session · host>" --desc "<what it is doing>" [--consent 15] [--go 1]
//
// Phase 1 (if --consent > 0): consent countdown — "Taking control in Ns…" with a shrinking
//   bar and an "I'm busy — don't control" button. Deny → prints DENY, shows "Denied", exits 1.
//   Timeout → prints GRANT and morphs into the banner.
// Phase 2: banner — Pause/Resume, Talk (message box; opening it pauses), Cancel, minimise,
//   draggable by its background.
//
// Protocol (line-oriented, read by watch.mjs):
//   stdout:  GRANT <ts> | DENY <ts> | STOP <ts> | RESUME <ts> | CANCEL <ts> | MSG <text> | FOCUS <ts>
//   stdin:   DOING <text>   update the status line
//            PAUSED | RESUMED   reflect a pause/resume that came from elsewhere
//            HIDE           close and exit 0
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String, _ def: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--" + name), i + 1 < a.count { return a[i + 1] }
    return def
}
let who = arg("who", "an agent")
var desc = arg("desc", "working")
let consentSecs = Double(arg("consent", "0")) ?? 0
let showGo = arg("go", "0") == "1"   // "Go to session" button, only when the watcher can focus the agent
func now() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }
func emit(_ s: String) { print(s); fflush(stdout) }

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }   // so the Talk field can take typing
    override var canBecomeMain: Bool { false }
}

final class Overlay: NSObject, NSTextFieldDelegate {
    let panel: Panel
    let stack = NSStackView()
    let title = NSTextField(labelWithString: "")
    let whoLabel = NSTextField(labelWithString: "")
    let descLabel = NSTextField(wrappingLabelWithString: "")
    let countdown = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let buttons = NSStackView()
    let pauseBtn = NSButton(title: "Pause", target: nil, action: nil)
    let talkBtn = NSButton(title: "Talk", target: nil, action: nil)
    let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
    let goBtn = NSButton(title: "Go to session", target: nil, action: nil)
    let minBtn = NSButton(title: "–", target: nil, action: nil)
    let denyBtn = NSButton(title: "✋  I'm busy — don't control", target: nil, action: nil)
    let talkRow = NSStackView()
    let talkField = NSTextField()
    var paused = false
    var decided = false
    var collapsed = false
    var start = Date()
    var timer: Timer?

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 10),
                      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                      backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Agent Control"   // window title other tools can find

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        panel.contentView = fx

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            fx.widthAnchor.constraint(equalToConstant: 400),
        ])

        title.font = .boldSystemFont(ofSize: 14)
        whoLabel.font = .systemFont(ofSize: 11)
        whoLabel.textColor = .secondaryLabelColor
        descLabel.font = .systemFont(ofSize: 13)
        descLabel.preferredMaxLayoutWidth = 368
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1000
        bar.widthAnchor.constraint(equalToConstant: 368).isActive = true

        for (b, sel) in [(pauseBtn, #selector(onPause)), (talkBtn, #selector(onTalk)),
                         (cancelBtn, #selector(onCancel)), (goBtn, #selector(onGo)), (minBtn, #selector(onMin)),
                         (denyBtn, #selector(onDeny))] {
            b.target = self; b.action = sel; b.bezelStyle = .rounded
        }
        pauseBtn.keyEquivalent = ""
        pauseBtn.bezelColor = .controlAccentColor
        cancelBtn.contentTintColor = .systemRed
        buttons.orientation = .horizontal
        buttons.spacing = 8
        (showGo ? [pauseBtn, talkBtn, cancelBtn, goBtn, minBtn] : [pauseBtn, talkBtn, cancelBtn, minBtn]).forEach { buttons.addArrangedSubview($0) }

        talkField.placeholderString = "Tell the agent what to do"
        talkField.delegate = self
        talkField.widthAnchor.constraint(equalToConstant: 290).isActive = true
        let send = NSButton(title: "Send", target: self, action: #selector(onSend))
        send.bezelStyle = .rounded
        talkRow.orientation = .horizontal
        talkRow.addArrangedSubview(talkField)
        talkRow.addArrangedSubview(send)
        talkRow.isHidden = true

        whoLabel.stringValue = who
        if consentSecs > 0 { showConsent() } else { emit("GRANT \(now())"); showBanner() }   // no countdown = granted at once; the watcher waits for this line
        position()
        panel.orderFrontRegardless()
        readStdin()
    }

    func rebuild(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach { stack.addArrangedSubview($0) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 400, height: 160)
        var f = panel.frame
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        panel.setFrame(f, display: true)
    }

    // Top-right of the main screen, clear of the menu bar — NOT the centre of the screen.
    func position() {
        guard let s = NSScreen.main?.visibleFrame else { return }
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: s.maxX - f.width - 16, y: s.maxY - f.height - 16))
    }

    // MARK: consent

    func showConsent() {
        title.stringValue = "🤖  An agent wants to control this Mac"
        descLabel.stringValue = desc
        rebuild([title, whoLabel, descLabel, countdown, bar, denyBtn])
        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        let remain = consentSecs - Date().timeIntervalSince(start)
        if remain <= 0 { grant(); return }
        bar.doubleValue = remain / consentSecs * 1000
        countdown.stringValue = "Taking control in \(Int(remain.rounded(.up)))s… click below if you're busy"
    }

    func grant() {
        guard !decided else { return }
        decided = true; timer?.invalidate()
        emit("GRANT \(now())")
        showBanner()
    }

    @objc func onDeny() {
        guard !decided else { return }
        decided = true; timer?.invalidate()
        emit("DENY \(now())")
        title.stringValue = "✋  Denied — the agent will not take control"
        rebuild([title])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { exit(1) }
    }

    // MARK: banner

    func showBanner() {
        decided = true
        title.stringValue = paused ? "⏸  Paused by you" : "🤖  An agent is controlling this Mac"
        descLabel.stringValue = paused ? "The agent has stopped touching the screen." : desc
        pauseBtn.title = paused ? "Resume" : "Pause"
        rebuild(collapsed ? [title, buttons] : [title, whoLabel, descLabel, buttons, talkRow])
    }

    func setPaused(_ p: Bool) { paused = p; showBanner() }

    @objc func onPause() {
        if paused { emit("RESUME \(now())"); desc = "Resumed — the agent has control again."; setPaused(false) }
        else { emit("STOP \(now())"); setPaused(true) }
    }

    @objc func onTalk() {
        // Opening Talk pauses the agent first: you are about to tell it something.
        if !paused { emit("STOP \(now())"); paused = true }
        talkRow.isHidden = false
        showBanner()
        panel.makeKey()
        panel.makeFirstResponder(talkField)
    }

    @objc func onSend() {
        let text = talkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        emit("MSG \(text.replacingOccurrences(of: "\n", with: " "))")
        talkField.stringValue = ""
        descLabel.stringValue = "Message sent — waiting for the agent…"
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { onSend(); return true }
        return false
    }

    @objc func onCancel() {
        emit("CANCEL \(now())")
        title.stringValue = "✕  Cancelled by you"
        descLabel.stringValue = "The agent was told to abandon this task, not just pause it."
        rebuild([title, descLabel])
    }

    // Jump to the driving agent's terminal (watch.mjs runs --focus-cmd). Does NOT pause.
    @objc func onGo() { emit("FOCUS \(now())") }

    @objc func onMin() { collapsed.toggle(); minBtn.title = collapsed ? "+" : "–"; showBanner() }

    // MARK: stdin commands from the watcher

    func readStdin() {
        let h = FileHandle.standardInput
        h.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { DispatchQueue.main.async { exit(0) } ; return }   // watcher gone → never linger
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
                let s = String(line)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if s.hasPrefix("DOING ") { desc = String(s.dropFirst(6)); if self.decided && !self.paused { self.showBanner() } }
                    else if s == "PAUSED" { self.setPaused(true) }
                    else if s == "RESUMED" { self.setPaused(false) }
                    else if s == "HIDE" { exit(0) }
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
let overlay = Overlay()
signal(SIGTERM) { _ in exit(0) }
app.run()
