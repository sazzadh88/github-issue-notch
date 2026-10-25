// Issue Island: a Dynamic Island-style pill around the MacBook notch that watches a GitHub repository's open
// issues. A new issue expands the island and posts a notification; clicking opens it. Sign-in and API calls go
// through the GitHub CLI (`gh`), so no token is stored here. Settings pick the account and the repository.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

let syncChoices: [(seconds: TimeInterval, label: String)] = [(15, "15s"), (30, "30s"), (60, "1m"), (300, "5m"), (900, "15m"), (1800, "30m"), (3600, "1h")]
// Looked up on every use, so installing gh while the app runs is picked up by "Check again".
var ghPath: String? { ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) } }
var brewPath: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }

struct Label2 { let name: String; let color: Color } // a GitHub label (SwiftUI already has a Label)

struct Issue: Identifiable {
    let id: Int
    let number: Int
    let title: String
    let body: String
    let author: String
    let labels: [Label2]
    let assignees: [String]
    let created: Date
    let url: String
    let comments: Int

    init?(_ d: [String: Any]) {
        guard d["pull_request"] == nil, // the issues API also returns pull requests
              let id = d["id"] as? Int, let number = d["number"] as? Int else { return nil }
        self.id = id
        self.number = number
        title = d["title"] as? String ?? ""
        body = d["body"] as? String ?? ""
        author = (d["user"] as? [String: Any])?["login"] as? String ?? ""
        labels = (d["labels"] as? [[String: Any]] ?? []).map { Label2(name: $0["name"] as? String ?? "", color: Color(hex: $0["color"] as? String ?? "888888")) }
        assignees = (d["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
        created = isoDates.date(from: d["created_at"] as? String ?? "") ?? Date()
        url = d["html_url"] as? String ?? ""
        comments = d["comments"] as? Int ?? 0
    }
    var age: String { RelativeDateTimeFormatter().localizedString(for: created, relativeTo: Date()) }
}

let isoDates = ISO8601DateFormatter()

struct Repo: Identifiable { let id: String; let isPrivate: Bool; let openIssues: Int }

extension Color {
    init(hex: String) {
        let v = Int(hex, radix: 16) ?? 0x888888
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// Runs `gh` off the main thread and hands back its stdout as JSON, or the error it printed.
func gh(_ args: [String], done: @escaping (Any?, String?) -> Void) {
    guard let ghPath else { return done(nil, "GitHub CLI not found. Install it with: brew install gh") }
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return DispatchQueue.main.async { done(nil, error.localizedDescription) } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let json = try? JSONSerialization.jsonObject(with: data)
        DispatchQueue.main.async {
            p.terminationStatus == 0 ? done(json, nil) : done(nil, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum Mode { case idle, alert, open }

final class Island: ObservableObject {
    @Published var issues: [Issue] = []
    @Published var mode: Mode = .idle
    @Published var selected: Int?
    @Published var alertId: Int?
    @Published var unread = Set<Int>()
    @Published var checkedAt: Date?
    @Published var error: String?
    @Published var polling = false
    @Published var notice: String?
    @Published var pointerNear = false // the pointer is close to the pill, so the character is worth animating smoothly
    @Published var showSettings = false
    @Published var login: String?
    @Published var accountKnown = false // false until the first `gh api user` answer
    @Published var repos: [Repo] = []
    @Published var repo = UserDefaults.standard.string(forKey: "repo") ?? ""
    @Published var buddy = Buddy(rawValue: UserDefaults.standard.string(forKey: "buddy") ?? "") ?? .robot {
        didSet { UserDefaults.standard.set(buddy.rawValue, forKey: "buddy") }
    }
    @Published var pollEvery = UserDefaults.standard.object(forKey: "pollEvery") as? TimeInterval ?? 60 {
        didSet { UserDefaults.standard.set(pollEvery, forKey: "pollEvery"); schedule() }
    }
    private var timer: Timer?

    func issue(_ id: Int?) -> Issue? { issues.first { $0.id == id } }

    // The repository's issues haven't arrived yet.
    var loading: Bool { !repo.isEmpty && issues.isEmpty && error == nil && (polling || checkedAt == nil) }

    // Checks every `pollEvery` seconds; while signed out it re-checks the account instead.
    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollEvery, repeats: true) { [weak self] _ in
            guard let self else { return }
            if login == nil { refreshAccount() } else { poll() }
        }
    }

    // Who is signed in to `gh`; then the issues, and the repositories for Settings.
    func refreshAccount() {
        gh(["api", "user"]) { json, err in
            self.login = (json as? [String: Any])?["login"] as? String
            self.accountKnown = true
            if self.login == nil {
                self.error = ghPath == nil ? "GitHub CLI (gh) isn't installed" : "Not signed in to GitHub"
                return
            }
            self.error = nil
            self.loadRepos()
            self.poll()
        }
    }

    func loadRepos() {
        // ponytail: the 100 most recently updated repositories; add paging if the one you want is missing.
        gh(["api", "user/repos?per_page=100&sort=updated"]) { json, _ in
            self.repos = (json as? [[String: Any]] ?? []).compactMap { d in
                guard let name = d["full_name"] as? String else { return nil }
                return Repo(id: name, isPrivate: d["private"] as? Bool ?? false, openIssues: d["open_issues_count"] as? Int ?? 0)
            }
        }
    }

    // Picking a repository closes the island and loads its issues (the top row shows a spinner meanwhile).
    func select(_ name: String) {
        mode = .idle
        guard name != repo else { return }
        // Only the active repository is tracked: forget what was seen in the old one, and start the new one fresh
        // (its first load only records), so switching back doesn't alert for everything opened in between.
        UserDefaults.standard.removeObject(forKey: "seen.\(repo)")
        UserDefaults.standard.removeObject(forKey: "seen.\(name)")
        repo = name
        UserDefaults.standard.set(name, forKey: "repo")
        issues = []
        unread = []
        selected = nil
        alertId = nil
        checkedAt = nil
        error = nil
        showSettings = false
        // Only the active repository notifies: clear banners left over from the previous one.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        poll()
    }

    // Opens Terminal on `gh auth login`, which signs in through the browser; the island re-checks afterwards.
    func signIn() {
        runInTerminal("'\(ghPath ?? "gh")' auth login --hostname github.com --git-protocol https --web", name: "sign-in")
    }

    // Installs gh with Homebrew in Terminal, or opens the gh download page when Homebrew isn't there either.
    func installGh() {
        if let brewPath { runInTerminal("'\(brewPath)' install gh", name: "install-gh") }
        else if let url = URL(string: "https://cli.github.com") { NSWorkspace.shared.open(url) }
    }

    private func runInTerminal(_ command: String, name: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("issue-island-\(name).command")
        let text = "#!/bin/sh\n\(command)\necho\necho 'Done. Go back to Issue Island and click Check again.'\n"
        try? text.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    func poll() {
        guard !polling, login != nil, !repo.isEmpty else { return }
        polling = true
        let repo = self.repo
        // ponytail: the 100 newest open issues; enough to spot new ones, page further if a repo needs it.
        gh(["api", "repos/\(repo)/issues?state=open&per_page=100"]) { json, err in
            self.polling = false
            self.checkedAt = Date()
            guard repo == self.repo else { return self.poll() } // the repository changed while this was loading
            guard let list = json as? [[String: Any]] else { self.error = err ?? "Couldn't load issues"; return }
            self.error = nil
            self.issues = list.compactMap(Issue.init)
            // The first load of a repository only records what's there; later loads announce what's new.
            let key = "seen.\(repo)"
            let firstLoad = UserDefaults.standard.array(forKey: key) == nil
            var seen = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
            let fresh = firstLoad ? [] : self.issues.filter { !seen.contains($0.id) }
            self.issues.forEach { seen.insert($0.id) }
            UserDefaults.standard.set(Array(seen), forKey: key)
            fresh.reversed().forEach(self.announce) // oldest first, so the newest ends up on the island
        }
    }

    private func announce(_ issue: Issue) {
        unread.insert(issue.id)
        alertId = issue.id
        if mode != .open { mode = .alert }
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "New issue in \(repo)"
        content.subtitle = "#\(issue.number) by \(issue.author)"
        content.body = issue.title
        content.userInfo = ["issueId": issue.id, "repo": repo]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(issue.id)", content: content, trigger: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if self.mode == .alert && self.alertId == issue.id { self.mode = .idle }
        }
    }

    func open(_ id: Int) {
        selected = id
        showSettings = false
        unread.remove(id)
        mode = .open
    }

    // Copies a planning request and brings Terminal forward, to paste into Claude Code (⌘V, Return).
    // The issue goes by number for Claude to read with gh, so other people's text isn't pasted in as a prompt.
    func planInClaude(_ issue: Issue) {
        let request = "Plan how to fix GitHub issue \(repo)#\(issue.number): read it with `gh issue view \(issue.number) --repo \(repo) --comments`, find the code involved, and give me a step-by-step plan before changing anything."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request, forType: .string)
        mode = .idle
        notice = "Copied. Paste it into Claude Code (⌘V)"
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.notice = nil }
    }
}

// MARK: - Views

// The characters that can sit in the island. All are original drawings made of SwiftUI shapes.
enum Buddy: String, CaseIterable, Identifiable {
    case robot, cat, ghost, owl, frog, alien, bunny, penguin, slime, octopus
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

let ink = Color(red: 0.04, green: 0.06, blue: 0.11)
let blush = Color(red: 1, green: 0.5, blue: 0.6).opacity(0.55)

func fill(_ a: Color, _ b: Color) -> LinearGradient { LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing) }

// The island's character. It stays put; its eyes follow the pointer and blink, and it reacts (waves, hops,
// flaps) when a new issue arrives. Drawn in a 40×48 box, then scaled.
struct Bot: View {
    var kind: Buddy
    var excited = false
    var scale: CGFloat = 0.56
    // Smooth animation only while someone is likely looking (pointer near, alert, island open). Otherwise it rests:
    // holds still, blinks and glances, updating twice a second. Any faster and AppKit keeps its display cycle
    // running every frame, which took idle CPU from under 1% to 3-5%.
    var lively = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if lively || reduceMotion {
                TimelineView(.animation(paused: reduceMotion)) { pose($0.date) }
            } else {
                // Not .animation(minimumInterval:): that still wakes the app every display frame. A timer doesn't.
                TimelineView(.periodic(from: .distantPast, by: 0.5)) { pose($0.date) } // shared start: resting characters tick together
            }
        }
        .frame(width: 40 * scale, height: 48 * scale)
        .accessibilityLabel(kind.name)
    }

    func pose(_ date: Date) -> some View {
        GeometryReader { geo in
            let clock = date.timeIntervalSinceReferenceDate
            let t = lively && !reduceMotion ? clock : 2 // resting pose (not 0: the bunny's ear twitch starts at 0)
            // Resting blinks are one slow tick long, so they come half as often.
            let blink = !reduceMotion && clock.truncatingRemainder(dividingBy: lively ? 3.7 : 7.4) < (lively ? 0.13 : 0.5)
            figure(t, gaze(geo.frame(in: .global)), blink)
                .frame(width: 40, height: 48)
                .offset(y: excited && kind != .robot ? -abs(sin(t * 8)) * 3 : 0) // the robot waves instead
                .scaleEffect(scale)
                .frame(width: 40 * scale, height: 48 * scale)
        }
    }

    // Which way the pointer is from the character's eyes, as x and y in -1...1 (y points down). Close to the face
    // the eyes look less far. `box` is the character's frame in the island window.
    func gaze(_ box: CGRect) -> CGPoint {
        guard let window = NSApp.windows.first(where: { $0 is IslandPanel }) else { return .zero }
        let p = NSEvent.mouseLocation // screen points, y up
        let dx = p.x - (window.frame.minX + box.midX)
        let dy = (window.frame.maxY - box.minY - box.height * 0.3) - p.y
        let d = max(hypot(dx, dy), 1), reach = min(d / 80, 1)
        return CGPoint(x: dx / d * reach, y: dy / d * reach)
    }

    @ViewBuilder func figure(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        switch kind {
        case .robot: robot(t, gaze, blink)
        case .cat: cat(t, gaze, blink)
        case .ghost: ghost(t, gaze, blink)
        case .owl: owl(t, gaze, blink)
        case .frog: frog(t, gaze, blink)
        case .alien: alien(t, gaze, blink)
        case .bunny: bunny(t, gaze, blink)
        case .penguin: penguin(t, gaze, blink)
        case .slime: slime(t, gaze, blink)
        case .octopus: octopus(t, gaze, blink)
        }
    }

    func eyes(_ xs: [Double], y: Double, w: Double, h: Double, look: Double, lift: Double, blink: Bool) -> some View {
        ForEach(xs, id: \.self) { x in
            Ellipse().fill(ink).frame(width: w, height: h).scaleEffect(x: 1, y: blink ? 0.12 : 1).position(x: x + look, y: y + lift)
        }
    }

    func cheeks(_ xs: [Double], y: Double) -> some View {
        ForEach(xs, id: \.self) { x in Ellipse().fill(blush).frame(width: 4, height: 2.2).position(x: x, y: y) }
    }

    func ground(_ color: Color = .white) -> some View {
        Ellipse().fill(color.opacity(0.3)).frame(width: 16, height: 3).blur(radius: 2).position(x: 20, y: 47)
    }

    // Egg-shaped shell, dark visor, glowing eyes; the right arm springs out and waves.
    func robot(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let shell = fill(Color(red: 0.98, green: 0.98, blue: 1), Color(red: 0.7, green: 0.75, blue: 0.93))
        let glow = Color(red: 0.3, green: 0.97, blue: 0.9)
        let look = excited ? 2.6 : gaze.x * 2.9 // on a new issue it looks toward its raised arm
        let wave = excited ? sin(t * 9) * 12 : 0 // a small wave while it's out
        return ZStack {
            ground(glow)
            Capsule().fill(shell).frame(width: 5, height: 15).rotationEffect(.degrees(12), anchor: .top).position(x: 7.5, y: 32)
            Capsule().fill(shell).frame(width: 5, height: 15)
                .rotationEffect(.degrees(-10 + wave), anchor: .top)
                .rotationEffect(.degrees(excited ? -90 : 0), anchor: .top) // springs out and back
                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: excited)
                .position(x: 32.5, y: 32)
            Egg().fill(shell).frame(width: 22, height: 26).position(x: 20, y: 33)
            Ellipse().fill(shell).frame(width: 28, height: 19).position(x: 20, y: 11)
            RoundedRectangle(cornerRadius: 6.5).fill(Color(red: 0.04, green: 0.06, blue: 0.11)).frame(width: 21, height: 12.5).position(x: 20, y: 11.5)
            ForEach([15.5, 24.5], id: \.self) { ex in
                Ellipse().fill(glow)
                    .frame(width: excited ? 6.5 : 5.5, height: 3.8)
                    .scaleEffect(x: 1, y: blink ? 0.12 : 1)
                    .shadow(color: glow.opacity(0.9), radius: 2)
                    .position(x: ex + look, y: 11.5 + (excited ? 0 : gaze.y * 2.2))
            }
        }
    }

    func cat(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let fur = fill(Color(red: 1, green: 0.8, blue: 0.48), Color(red: 0.93, green: 0.52, blue: 0.22))
        let look = excited ? 0 : gaze.x * 1.8
        let ear = excited ? sin(t * 14) * 10 : 0
        return ZStack {
            ground()
            Capsule().fill(fur).frame(width: 4, height: 16)
                .rotationEffect(.degrees(35 + sin(t * (excited ? 10 : 1.6)) * 18), anchor: .bottom).position(x: 31, y: 32)
            Ellipse().fill(fur).frame(width: 22, height: 20).position(x: 20, y: 37)
            Triangle().fill(fur).frame(width: 9, height: 10).rotationEffect(.degrees(-18 - ear), anchor: .bottom).position(x: 11.5, y: 9)
            Triangle().fill(fur).frame(width: 9, height: 10).rotationEffect(.degrees(18 + ear), anchor: .bottom).position(x: 28.5, y: 9)
            Ellipse().fill(fur).frame(width: 27, height: 22).position(x: 20, y: 19)
            eyes([15, 25], y: 18, w: 3.6, h: excited ? 5.5 : 4.6, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
            Ellipse().fill(Color(red: 1, green: 0.45, blue: 0.55)).frame(width: 3, height: 2).position(x: 20 + look * 0.5, y: 22.5)
            cheeks([11.5, 28.5], y: 23)
        }
    }

    // Floats up and down; shivers on a new issue.
    func ghost(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let look = excited ? 0 : gaze.x * 2
        return ZStack {
            ground()
            ZStack {
                Ghost().fill(fill(.white, Color(red: 0.78, green: 0.82, blue: 0.98))).frame(width: 26, height: 34).position(x: 20, y: 24)
                eyes([15.5, 24.5], y: 20, w: 4, h: 6, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
                Ellipse().fill(ink).frame(width: excited ? 4 : 3, height: excited ? 5 : 1.5).position(x: 20 + look * 0.5, y: 27)
                cheeks([12, 28], y: 25)
            }
            .rotationEffect(.degrees(excited ? sin(t * 18) * 7 : 0))
            .offset(y: sin(t * 2.2) * 1.8)
        }
    }

    // Flaps its wings on a new issue.
    func owl(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let feather = fill(Color(red: 0.76, green: 0.56, blue: 0.4), Color(red: 0.5, green: 0.34, blue: 0.22))
        let look = excited ? 0 : gaze.x * 1.6
        let flap = excited ? 25 + sin(t * 14) * 25 : 0
        return ZStack {
            ground()
            Ellipse().fill(feather).frame(width: 7, height: 17).rotationEffect(.degrees(8 + flap), anchor: .top).position(x: 8, y: 31)
            Ellipse().fill(feather).frame(width: 7, height: 17).rotationEffect(.degrees(-8 - flap), anchor: .top).position(x: 32, y: 31)
            Triangle().fill(feather).frame(width: 8, height: 9).rotationEffect(.degrees(-20), anchor: .bottom).position(x: 11, y: 10)
            Triangle().fill(feather).frame(width: 8, height: 9).rotationEffect(.degrees(20), anchor: .bottom).position(x: 29, y: 10)
            Ellipse().fill(feather).frame(width: 27, height: 34).position(x: 20, y: 29)
            Ellipse().fill(Color(red: 0.95, green: 0.86, blue: 0.7)).frame(width: 16, height: 17).position(x: 20, y: 36)
            ForEach([14.5, 25.5], id: \.self) { x in Circle().fill(Color(red: 1, green: 0.97, blue: 0.9)).frame(width: 11, height: 11).position(x: x, y: 21) }
            eyes([14.5, 25.5], y: 21, w: 5, h: 5, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
            Triangle().fill(Color(red: 1, green: 0.7, blue: 0.2)).frame(width: 4, height: 4).rotationEffect(.degrees(180)).position(x: 20, y: 27)
        }
    }

    func frog(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let skin = fill(Color(red: 0.6, green: 0.92, blue: 0.42), Color(red: 0.25, green: 0.65, blue: 0.3))
        let look = excited ? 0 : gaze.x * 1.3
        return ZStack {
            ground()
            Ellipse().fill(skin).frame(width: 28, height: 18).position(x: 20, y: 39)
            ForEach([12.5, 27.5], id: \.self) { x in Circle().fill(skin).frame(width: 11, height: 11).position(x: x, y: 19) }
            Ellipse().fill(skin).frame(width: 32, height: 19).position(x: 20, y: 27)
            ForEach([12.5, 27.5], id: \.self) { x in Circle().fill(.white).frame(width: 7.5, height: 7.5).position(x: x, y: 18.5) }
            eyes([12.5, 27.5], y: 18.5, w: 3.6, h: 3.6, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
            Ellipse().trim(from: 0.06, to: 0.44).stroke(ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: excited ? 15 : 12, height: excited ? 8 : 6).position(x: 20, y: 27)
            cheeks([9.5, 30.5], y: 30)
        }
    }

    // Its antenna light pulses, and flashes on a new issue.
    func alien(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let skin = fill(Color(red: 0.72, green: 1, blue: 0.56), Color(red: 0.35, green: 0.8, blue: 0.45))
        let bulb = Color(red: 1, green: 0.4, blue: 0.85)
        let look = excited ? 0 : gaze.x * 1.6
        let pulse = excited ? (sin(t * 16) > 0 ? 1 : 0.3) : 0.6 + sin(t * 3) * 0.4
        return ZStack {
            ground()
            Capsule().fill(skin).frame(width: 1.6, height: 8).position(x: 20, y: 7)
            Circle().fill(bulb).frame(width: 4.5, height: 4.5).shadow(color: bulb, radius: 3 * pulse).opacity(0.5 + pulse * 0.5).position(x: 20, y: 3)
            Ellipse().fill(skin).frame(width: 14, height: 15).position(x: 20, y: 39)
            Ellipse().fill(skin).frame(width: 31, height: 25).position(x: 20, y: 21)
            eyes([13.5, 26.5], y: 21, w: 8, h: excited ? 11 : 9.5, look: look * 0.4, lift: excited ? 0 : gaze.y * 1.2, blink: blink)
            ForEach([13.5, 26.5], id: \.self) { x in
                Circle().fill(.white).frame(width: 2.2, height: 2.2).opacity(blink ? 0 : 1).position(x: x + 1.5 + look, y: 19 + (excited ? 0 : gaze.y * 2))
            }
            Capsule().fill(ink.opacity(0.6)).frame(width: 4, height: 1.2).position(x: 20, y: 29.5)
        }
    }

    // Its ear twitches now and then, and wiggles on a new issue.
    func bunny(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let fur = fill(.white, Color(red: 0.84, green: 0.84, blue: 0.92))
        let pink = Color(red: 1, green: 0.62, blue: 0.72)
        let look = excited ? 0 : gaze.x * 1.6
        let twitch = excited ? sin(t * 16) * 14 : (t.truncatingRemainder(dividingBy: 4.3) < 0.25 ? 10 : 0)
        return ZStack {
            ground()
            ZStack { Capsule().fill(fur).frame(width: 7, height: 19); Capsule().fill(pink).frame(width: 3, height: 13) }
                .rotationEffect(.degrees(-10), anchor: .bottom).position(x: 14.5, y: 11)
            ZStack { Capsule().fill(fur).frame(width: 7, height: 19); Capsule().fill(pink).frame(width: 3, height: 13) }
                .rotationEffect(.degrees(10 + twitch), anchor: .bottom).position(x: 25.5, y: 11)
            Ellipse().fill(fur).frame(width: 22, height: 16).position(x: 20, y: 40)
            Ellipse().fill(fur).frame(width: 25, height: 22).position(x: 20, y: 27)
            eyes([15, 25], y: 26, w: 3.4, h: 4.4, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
            Ellipse().fill(pink).frame(width: 3, height: 2).position(x: 20 + look * 0.5, y: 30)
            cheeks([11.5, 28.5], y: 31)
        }
    }

    // Flaps its flippers on a new issue.
    func penguin(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let coat = fill(Color(red: 0.38, green: 0.44, blue: 0.6), Color(red: 0.18, green: 0.22, blue: 0.34))
        let belly = Color(white: 0.97)
        let orange = Color(red: 1, green: 0.62, blue: 0.2)
        let look = excited ? 0 : gaze.x * 1.5
        let flap = excited ? 30 + sin(t * 15) * 25 : sin(t * 1.5) * 4
        return ZStack {
            ground()
            ForEach([15.0, 25.0], id: \.self) { x in Ellipse().fill(orange).frame(width: 7, height: 3).position(x: x, y: 46) }
            Ellipse().fill(coat).frame(width: 6, height: 16).rotationEffect(.degrees(12 + flap), anchor: .top).position(x: 7, y: 30)
            Ellipse().fill(coat).frame(width: 6, height: 16).rotationEffect(.degrees(-12 - flap), anchor: .top).position(x: 33, y: 30)
            Ellipse().fill(coat).frame(width: 26, height: 40).position(x: 20, y: 26)
            Ellipse().fill(belly).frame(width: 19, height: 28).position(x: 20, y: 31)
            Ellipse().fill(belly).frame(width: 18, height: 12).position(x: 20, y: 18)
            eyes([16, 24], y: 17, w: 3.2, h: 4, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
            Triangle().fill(orange).frame(width: 5, height: 4).rotationEffect(.degrees(180)).position(x: 20 + look * 0.4, y: 22)
            cheeks([12.5, 27.5], y: 21)
        }
    }

    // Wobbles gently; squishes fast on a new issue.
    func slime(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let goo = fill(Color(red: 0.78, green: 0.64, blue: 1), Color(red: 0.5, green: 0.35, blue: 0.95))
        let look = excited ? 0 : gaze.x * 2
        let squish = sin(t * (excited ? 12 : 2.5)) * (excited ? 0.14 : 0.05)
        return ZStack {
            ground()
            ZStack {
                UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 5, bottomTrailingRadius: 5, topTrailingRadius: 15)
                    .fill(goo).frame(width: 32, height: 26).position(x: 20, y: 34)
                Ellipse().fill(.white.opacity(0.55)).frame(width: 6, height: 3.5).rotationEffect(.degrees(-25)).position(x: 11, y: 26)
                eyes([15, 25], y: 33, w: 4, h: 5, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
                Ellipse().trim(from: 0.06, to: 0.44).stroke(ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: 7, height: excited ? 6 : 4).position(x: 20 + look * 0.5, y: 36)
                cheeks([11, 29], y: 37)
            }
            .scaleEffect(x: 1 + squish, y: 1 - squish, anchor: .bottom)
        }
    }

    // Its tentacles sway, and wave fast on a new issue.
    func octopus(_ t: Double, _ gaze: CGPoint, _ blink: Bool) -> some View {
        let skin = fill(Color(red: 1, green: 0.62, blue: 0.56), Color(red: 0.92, green: 0.35, blue: 0.42))
        let look = excited ? 0 : gaze.x * 1.8
        return ZStack {
            ground()
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(skin).frame(width: 4.5, height: 19)
                    .rotationEffect(.degrees(Double(i - 2) * 16 + sin(t * (excited ? 10 : 2.4) + Double(i)) * (excited ? 22 : 12)), anchor: .top)
                    .position(x: 11 + Double(i) * 4.5, y: 36)
            }
            Ellipse().fill(skin).frame(width: 28, height: 26).position(x: 20, y: 20)
            Ellipse().fill(.white.opacity(0.35)).frame(width: 6, height: 3.5).rotationEffect(.degrees(-25)).position(x: 12.5, y: 12)
            eyes([15, 25], y: 21, w: 4, h: excited ? 6 : 5, look: look, lift: excited ? 0 : gaze.y * 1.5, blink: blink)
            cheeks([11, 29], y: 25)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

// Round top, straight sides, three scallops along the bottom.
struct Ghost: Shape {
    func path(in r: CGRect) -> Path {
        let (x, y, w, h) = (r.minX, r.minY, r.width, r.height)
        var p = Path()
        p.move(to: CGPoint(x: x, y: y + h * 0.45))
        p.addCurve(to: CGPoint(x: x + w / 2, y: y), control1: CGPoint(x: x, y: y + h * 0.15), control2: CGPoint(x: x + w * 0.2, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.45), control1: CGPoint(x: x + w * 0.8, y: y), control2: CGPoint(x: x + w, y: y + h * 0.15))
        p.addLine(to: CGPoint(x: x + w, y: y + h))
        for i in 0..<3 {
            let from = x + w - Double(i) * w / 3, to = from - w / 3
            p.addQuadCurve(to: CGPoint(x: to, y: y + h), control: CGPoint(x: (from + to) / 2, y: y + h * 0.72))
        }
        p.closeSubpath()
        return p
    }
}

struct Egg: Shape {
    func path(in r: CGRect) -> Path {
        let (x, y, w, h) = (r.minX, r.minY, r.width, r.height)
        var p = Path()
        p.move(to: CGPoint(x: x + w / 2, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.38), control1: CGPoint(x: x + w * 0.85, y: y), control2: CGPoint(x: x + w, y: y + h * 0.15))
        p.addCurve(to: CGPoint(x: x + w / 2, y: y + h), control1: CGPoint(x: x + w, y: y + h * 0.72), control2: CGPoint(x: x + w * 0.72, y: y + h))
        p.addCurve(to: CGPoint(x: x, y: y + h * 0.38), control1: CGPoint(x: x + w * 0.28, y: y + h), control2: CGPoint(x: x, y: y + h * 0.72))
        p.addCurve(to: CGPoint(x: x + w / 2, y: y), control1: CGPoint(x: x, y: y + h * 0.15), control2: CGPoint(x: x + w * 0.15, y: y))
        p.closeSubpath()
        return p
    }
}

let openGreen = Color(red: 0.25, green: 0.78, blue: 0.4)

struct LabelChip: View {
    let label: Label2
    var body: some View {
        Text(label.name)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(label.color.opacity(0.28)))
            .overlay(Capsule().strokeBorder(label.color.opacity(0.7), lineWidth: 0.8))
    }
}

struct IslandView: View {
    @ObservedObject var model: Island
    let notch: CGSize
    @State private var repoQuery = ""

    var size: CGSize {
        switch model.mode {
        case .idle where model.notice != nil: return CGSize(width: max(notch.width + 136, 420), height: notch.height + 34)
        case .idle: return CGSize(width: notch.width + 136, height: notch.height)
        case .alert: return CGSize(width: max(notch.width + 136, 420), height: notch.height + 62)
        case .open: return CGSize(width: 540, height: 520)
        }
    }

    // Home shows the issues; until an account and a repository are set, Settings stands in for it.
    var onSettings: Bool { model.showSettings || model.repo.isEmpty || (model.accountKnown && model.login == nil) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: model.mode == .idle ? 12 : 26, bottomTrailingRadius: model.mode == .idle ? 12 : 26)
                    .fill(.black)
                VStack(spacing: 0) {
                    topRow.frame(height: notch.height)
                    if model.mode == .alert { alert.transition(.opacity) }
                    if model.mode == .idle, let notice = model.notice {
                        Label(notice, systemImage: "doc.on.clipboard").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .padding(.top, 2).transition(.opacity)
                    }
                    if model.mode == .open { panel.transition(.opacity) }
                }
                .clipped()
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                if model.mode == .alert, let id = model.alertId { model.open(id) }
                else if model.mode == .idle {
                    model.selected = nil
                    model.showSettings = false
                    model.mode = .open
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.mode)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.notice)
        .preferredColorScheme(.dark)
    }

    // Left wing: the character. Right wing: open issue count, a dot for unread, a spinner on the first load.
    var topRow: some View {
        HStack(spacing: 0) {
            Bot(kind: model.buddy, excited: model.mode == .alert, lively: model.mode != .idle || model.pointerNear).frame(width: 40, height: 30).padding(.leading, 4)
            Spacer(minLength: notch.width)
            HStack(spacing: 5) {
                if model.loading {
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
                } else if model.error != nil || model.repo.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                if !model.unread.isEmpty { Circle().fill(.orange).frame(width: 6, height: 6) }
                if !model.repo.isEmpty && !model.loading && model.login != nil { Text("\(model.issues.count)").monospacedDigit() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 50, alignment: .trailing)
            .padding(.trailing, 12)
        }
    }

    var alert: some View {
        let i = model.issue(model.alertId)
        return VStack(alignment: .leading, spacing: 3) {
            Text("New issue · \(model.repo)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
            Text(i?.title ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(i.map { "#\($0.number) by \($0.author)" } ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if onSettings { settings }
            else if let i = model.issue(model.selected) { detail(i) }
            else { list }
            Divider().overlay(.white.opacity(0.15))
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    // Open issues grouped by who they're assigned to, yours first.
    var groups: [(title: String, color: Color, issues: [Issue])] {
        let me = model.login ?? ""
        return [
            ("Assigned to you", Color(red: 0.38, green: 0.66, blue: 1), model.issues.filter { $0.assignees.contains(me) }),
            ("Unassigned", openGreen, model.issues.filter { $0.assignees.isEmpty }),
            ("Assigned to others", Color(white: 0.62), model.issues.filter { !$0.assignees.isEmpty && !$0.assignees.contains(me) }),
        ].filter { !$0.issues.isEmpty }
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.repo).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Spacer()
                if !model.loading {
                    Text("\(model.issues.count) open issue\(model.issues.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.yellow).lineLimit(2)
            }
            if model.loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading issues…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.issues.isEmpty && model.error == nil {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(openGreen)
                    Text("No open issues").font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.title) { group in
                            Section {
                                ForEach(group.issues) { i in
                                    IssueRow(issue: i, unread: model.unread.contains(i.id)) { model.open(i.id) }
                                }
                            } header: {
                                HStack(spacing: 7) {
                                    Circle().fill(group.color).frame(width: 7, height: 7)
                                    Text(group.title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                                    Text("\(group.issues.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(group.color.opacity(0.22)))
                                    Spacer()
                                }
                                .foregroundStyle(group.color)
                                .padding(.top, 10).padding(.bottom, 4)
                                .background(.black) // pinned headers sit over the rows scrolling beneath
                            }
                        }
                    }
                }
            }
        }
    }

    func detail(_ i: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.selected = nil } label: { Label("All issues", systemImage: "chevron.left").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            Text(i.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text("#\(i.number) · opened \(i.age) by \(i.author) · \(i.comments) comment\(i.comments == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            if !i.labels.isEmpty {
                HStack(spacing: 5) { ForEach(i.labels, id: \.name) { LabelChip(label: $0) } }
            }
            ScrollView {
                Text(i.body.isEmpty ? "No description." : i.body)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button { model.planInClaude(i) } label: { Label("Plan the fix in Claude Code", systemImage: "doc.on.clipboard") }
                    .help("Copies a planning request and opens Terminal, to paste into Claude Code")
                Button("Open on GitHub") { if let url = URL(string: i.url) { NSWorkspace.shared.open(url) } }
                Button("Copy issue") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(model.repo)#\(i.number) \(i.title)\n\(i.url)\n\n\(i.body)", forType: .string)
                }
            }
            .controlSize(.small)
        }
    }

    var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 17, weight: .bold))
            section("GitHub account") {
                HStack(spacing: 10) {
                    Image(systemName: model.login == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.fill.badge.checkmark")
                        .font(.system(size: 20)).foregroundStyle(model.login == nil ? .yellow : openGreen)
                    if ghPath == nil {
                        Text("GitHub CLI isn't installed").font(.system(size: 13))
                        Spacer()
                        Button("Install GitHub CLI") { model.installGh() }
                    } else {
                        Text(model.login.map { "Signed in as @\($0)" } ?? "Not signed in").font(.system(size: 13))
                        Spacer()
                        Button(model.login == nil ? "Sign in with GitHub" : "Switch account") { model.signIn() }
                    }
                    Button("Check again") { model.refreshAccount() }
                }
                .controlSize(.small)
            }
            section("Character") {
                HStack(spacing: 4) {
                    ForEach(Buddy.allCases) { b in
                        Button { model.buddy = b } label: {
                            Bot(kind: b, scale: 0.7, lively: b == model.buddy)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(b == model.buddy ? 0.14 : 0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(openGreen.opacity(b == model.buddy ? 1 : 0), lineWidth: 1.2))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(b.name)
                    }
                }
            }
            section("Check for new issues every") {
                Picker("Check for new issues every", selection: $model.pollEvery) {
                    ForEach(syncChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            if model.login != nil {
                section("Repository to watch") {
                    TextField("Search your repositories", text: $repoQuery).textFieldStyle(.roundedBorder).controlSize(.small)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.repos.filter { repoQuery.isEmpty || $0.id.localizedCaseInsensitiveContains(repoQuery) }) { r in
                                Button { model.select(r.id) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: r.isPrivate ? "lock.fill" : "book.closed").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(width: 16)
                                        Text(r.id).font(.system(size: 12.5)).lineLimit(1)
                                        Spacer()
                                        if r.id == model.repo { Image(systemName: "checkmark").foregroundStyle(openGreen) }
                                    }
                                    .padding(.vertical, 5).padding(.horizontal, 8)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(r.id == model.repo ? 0.1 : 0.04)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                Text(ghPath == nil
                     ? (brewPath == nil ? "Issue Island talks to GitHub through the GitHub CLI. Install it from cli.github.com, then click Check again."
                                        : "Issue Island talks to GitHub through the GitHub CLI. Install opens Terminal and runs brew install gh. Click Check again when it's done.")
                     : "Sign-in opens Terminal and your browser. Come back here and click Check again when it's done.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            Toggle("Start at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { model.error = error.localizedDescription }
                    model.objectWillChange.send()
                }))
            .toggleStyle(.checkbox).font(.system(size: 11))
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Text(model.checkedAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not checked yet")
                .foregroundStyle(.white.opacity(0.5))
            Button("Refresh") { model.poll() }.disabled(model.polling)
            Spacer()
            if onSettings {
                Button { model.showSettings = false } label: { Label("Home", systemImage: "house") }
                    .disabled(model.login == nil || model.repo.isEmpty)
                    .help(model.repo.isEmpty ? "Choose a repository first" : "Show the issues")
            } else {
                Button { model.showSettings = true; model.selected = nil } label: { Label("Settings", systemImage: "gearshape") }
            }
            Button("Close") { model.mode = .idle }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .controlSize(.small)
    }
}

struct IssueRow: View {
    let issue: Issue
    let unread: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(openGreen)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(openGreen.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("#\(issue.number) · \(issue.age) · \(issue.author)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 6)
                if unread { Circle().fill(.orange).frame(width: 7, height: 7).help("New") }
                ForEach(issue.labels.prefix(2), id: \.name) { LabelChip(label: $0) }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.1 : 0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Window

// Borderless panels can't take keyboard focus by default; the repository search field needs it.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = Island()
    var panel: IslandPanel!
    var notch = CGSize(width: 190, height: 32)

    // Show banners even though the app counts as active, and open the issue when one is clicked (if it belongs to
    // the repository being watched now).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let id = info["issueId"] as? Int, let repo = info["repo"] as? String {
            DispatchQueue.main.async { if repo == self.model.repo { self.model.open(id) } }
        }
        done()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        let size = CGSize(width: 580, height: 540)
        panel = IslandPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar, into the notch
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: IslandView(model: model, notch: notch))
        panel.orderFrontRegardless()

        // The window is larger than the pill: only the pill takes clicks, everything around it passes through.
        let clicks = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [unowned self] _ in
            let s = IslandView(model: model, notch: notch).size
            let f = panel.frame
            let pill = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
            let mouse = NSEvent.mouseLocation
            let outside = !pill.contains(mouse)
            if panel.ignoresMouseEvents != outside { panel.ignoresMouseEvents = outside }
            let near = pill.insetBy(dx: -160, dy: -160).contains(mouse)
            if model.pointerNear != near { model.pointerNear = near }
        }
        clicks.tolerance = 0.03
        // A click anywhere else closes the open island.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [unowned self] _ in
            if model.mode == .open { model.mode = .idle }
        }
        model.refreshAccount()
        if CommandLine.arguments.contains("--open") { // start expanded, for previews
            model.showSettings = CommandLine.arguments.contains("--settings")
            model.mode = .open
        }
        model.schedule()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon or menu bar
app.run()
