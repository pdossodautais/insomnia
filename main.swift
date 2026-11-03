// Insomnia — keeps your Mac awake from the menu bar, even with the lid closed.
// Left click opens the menu, right click toggles. The same binary is also a
// command-line tool: `insomnia help`.
// Changing sleep needs a sudoers rule for `pmset disablesleep`, offered on first launch.

import AppKit
import Carbon.HIToolbox
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

let appID = "app.insomnia"

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// MARK: - Power

enum Power {
    @discardableResult
    private static func execute(_ path: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    /// Power-management flag read from the IOKit registry (no pmset process).
    private static func rootDomainFlag(_ key: String) -> Bool {
        IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    static var sleepDisabled: Bool { rootDomainFlag("SleepDisabled") }
    static var lidClosed: Bool { rootDomainFlag("AppleClamshellState") }

    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        execute("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
    }

    /// Whether the sudoers rule lets us change sleep without a password.
    static var canChangeSleep: Bool {
        execute("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    }

    /// Installs the sudoers rule; macOS asks for the administrator password.
    static func installSudoersRule() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = "f=/etc/sudoers.d/insomnia; echo '\(rule)' > $f && chmod 440 $f && /usr/sbin/visudo -cf $f || rm -f $f"
        NSAppleScript(source: "do shell script \"\(script)\" with administrator privileges")?.executeAndReturnError(nil)
        return canChangeSleep
    }

    static func displaySleepNow() {
        execute("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Lid closed and no external display: nothing left to stay awake for.
    static func sleepNowIfLidClosed() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        guard lidClosed, ids.prefix(Int(count)).allSatisfy({ CGDisplayIsBuiltin($0) != 0 }) else { return }
        execute("/usr/bin/pmset", ["sleepnow"])
    }

    static func lockScreen() {
        typealias Lock = @convention(c) () -> Int32
        let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        guard let symbol = dlsym(login, "SACLockScreenImmediate") else { return displaySleepNow() }
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }

    /// Battery level (%) when running on battery, nil on AC power.
    static func batteryLevelIfUnplugged() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue,
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .compactMap { $0[kIOPSCurrentCapacityKey] as? Int }
            .first
    }

    // kIOPMMessageClamshellStateChange and kClamshellStateBit (IOPM.h): macros Swift doesn't import.
    private static let clamshellStateChange: natural_t = 0xE003_4100
    private static let clamshellClosedBit = 1
    private static var lidHandler: ((Bool) -> Void)?
    private static var lidNotification: io_object_t = 0

    /// Calls `handler` whenever the lid opens or closes (true = closed).
    static func observeLid(_ handler: @escaping (Bool) -> Void) {
        lidHandler = handler
        let port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { _, _, message, argument in
            guard message == Power.clamshellStateChange else { return }
            Power.lidHandler?(Int(bitPattern: argument) & Power.clamshellClosedBit != 0)
        }, nil, &lidNotification)
    }
}

// MARK: - Backlight (private DisplayServices and CoreBrightness frameworks)

enum Backlight {
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let keyboardClient: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()

    private static var builtinDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func keyboardMethod(_ name: String) -> (NSObject, Selector, IMP)? {
        let selector = NSSelectorFromString(name)
        guard let client = keyboardClient,
              let method = class_getInstanceMethod(type(of: client), selector) else { return nil }
        return (client, selector, method_getImplementation(method))
    }

    static var screen: Float? {
        get {
            typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
            guard let id = builtinDisplay, let symbol = dlsym(displayServices, "DisplayServicesGetBrightness") else { return nil }
            var value: Float = 0
            return unsafeBitCast(symbol, to: Get.self)(id, &value) == 0 ? value : nil
        }
        set {
            typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
            guard let newValue, let id = builtinDisplay, let symbol = dlsym(displayServices, "DisplayServicesSetBrightness") else { return }
            _ = unsafeBitCast(symbol, to: Set.self)(id, newValue)
        }
    }

    static var keyboard: Float? {
        get {
            typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
            guard let (client, selector, imp) = keyboardMethod("brightnessForKeyboard:") else { return nil }
            return unsafeBitCast(imp, to: Get.self)(client, selector, 1)
        }
        set {
            typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            guard let newValue, let (client, selector, imp) = keyboardMethod("setBrightness:forKeyboard:") else { return }
            _ = unsafeBitCast(imp, to: Set.self)(client, selector, newValue, 1)
        }
    }
}

// MARK: - Settings

enum Settings {
    static let batteryFloorChoices = [5, 10, 15, 20, 30, 50, 0]  // 0 = never
    private static let defaults = UserDefaults.standard

    private static func number(_ key: String) -> NSNumber? { defaults.object(forKey: key) as? NSNumber }

    /// Battery level (%) below which sleep comes back; 0 = never.
    static var batteryFloor: Int {
        get { number("batteryFloor")?.intValue ?? 15 }
        set { defaults.set(newValue, forKey: "batteryFloor") }
    }

    /// Last normal levels, restored when leaving the black screen.
    static var screenLevel: Float {
        get { number("screenLevel")?.floatValue ?? 0.5 }
        set { defaults.set(newValue, forKey: "screenLevel") }
    }

    static var keyboardLevel: Float {
        get { number("keyboardLevel")?.floatValue ?? 0.25 }
        set { defaults.set(newValue, forKey: "keyboardLevel") }
    }

    static var lockOnLidOpen: Bool {
        get { defaults.bool(forKey: "lockOnLidOpen") }
        set { defaults.set(newValue, forKey: "lockOnLidOpen") }
    }

    static var followClaude: Bool {
        get { defaults.bool(forKey: "followClaude") }
        set { defaults.set(newValue, forKey: "followClaude") }
    }

    static let claudeDelayChoices = [0, 5, 15, 30, 60]  // minutes; 0 = the 30 seconds between two turns

    /// Minutes to stay awake after Claude finishes, to leave time for a reply.
    static var claudeDelay: Int {
        get { defaults.integer(forKey: "claudeDelay") }
        set { defaults.set(newValue, forKey: "claudeDelay") }
    }

    static var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        set { defaults.set(newValue, forKey: "welcomed") }
    }
}

/// Login item, listed in System Settings → General → Login Items.
enum LoginItem {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}

/// Global shortcut ⌃⌥⌘I.
enum HotKey {
    static let display = "⌃⌥⌘I"
    private static var action: (() -> Void)?
    private static var reference: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action?(); return noErr }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: 0x494E_534D, id: 1), GetApplicationEventTarget(), 0, &reference)
    }
}

func notify(_ body: String) {
    let content = UNMutableNotificationContent()
    content.title = "Insomnia"
    content.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .full
    return formatter.string(from: max(seconds, 60)) ?? ""
}

// MARK: - Claude Code

/// Claude Code sessions, in its desktop app or a terminal, each publish their state in
/// `sessions/<pid>.json`. Unlike the app's sleep assertion, it says who is working right now.
enum Claude {
    private static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude")
    /// Bridges the moment between two turns, or longer if chosen in the menu.
    private static var grace: TimeInterval { max(30, TimeInterval(Settings.claudeDelay * 60)) }
    private static var lastBusy = Date.distantPast
    /// Time left after the work has ended; nil while a session is working.
    static var timeLeft: TimeInterval? {
        isBusy ? nil : grace - Date().timeIntervalSince(lastBusy)
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.path) }

    private static var isBusy: Bool {
        let sessions = directory.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        return files.contains { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  session["status"] as? String == "busy", let pid = session["pid"] as? Int else { return false }
            return kill(pid_t(pid), 0) == 0  // a crashed session leaves its file behind
        }
    }

    static var isWorking: Bool {
        if isBusy { lastBusy = Date() }
        return Date().timeIntervalSince(lastBusy) < grace
    }
}

// MARK: - Sessions and messages

/// Why the Mac is being kept awake.
enum Session: Equatable {
    case manual
    case until(Date)
    case whileRunning(pid: pid_t, name: String)
    case whileClaudeWorks

    var isOver: Bool {
        switch self {
        case .manual: false
        case .until(let end): Date() >= end
        case .whileRunning(let pid, _): kill(pid, 0) == -1 && errno == ESRCH
        case .whileClaudeWorks: !Settings.followClaude || !Claude.isWorking
        }
    }

    var summary: String {
        switch self {
        case .manual: L("Awake until you turn it off")
        case .until(let end): String(format: L("Awake for %@ more"), formatDuration(end.timeIntervalSinceNow))
        case .whileRunning(_, let name): String(format: L("Awake while %@ is running"), name)
        case .whileClaudeWorks:
            Claude.timeLeft.map { String(format: L("No Claude session working: awake for %@ more"), formatDuration($0)) } ?? L("Claude is working")
        }
    }
}

/// Messages between the command-line tool and the app.
enum Message: String {
    case start, stop, dim, wake

    var name: Notification.Name { .init("\(appID).\(rawValue)") }

    func post(_ info: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }
}

// MARK: - Command line

enum CLI {
    static let usage = """
        Usage: insomnia <command>

          on [duration]   stay awake, until turned off or for a duration (30m, 2h)
          off             allow sleep again
          run <command>   stay awake while <command> runs
          dim             black screen without locking
          wake            restore the screen
          status          print "awake" or "normal"
        """

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "on":
            guard let duration = args.dropFirst().first else { return send(.start) }
            guard let minutes = minutes(duration), minutes > 0 else { print(usage); return 1 }
            return send(.start, ["minutes": minutes])
        case "off": return send(.stop)
        case "dim": return send(.dim)
        case "wake": return send(.wake)
        case "status":
            print(Power.sleepDisabled ? "awake" : "normal")
            return 0
        case "run" where args.count > 1:
            _ = send(.start, ["pid": Int(getpid()), "name": URL(fileURLWithPath: args[1]).lastPathComponent])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = Array(args.dropFirst())
            guard (try? process.run()) != nil else { return 127 }
            process.waitUntilExit()
            return process.terminationStatus  // the app notices this process ending
        default:
            print(usage)
            return args.first == "help" ? 0 : 1
        }
    }

    /// "90", "90m", "2h" → minutes.
    private static func minutes(_ text: String) -> Int? {
        if text.hasSuffix("h") { return Int(text.dropLast()).map { $0 * 60 } }
        return Int(text.hasSuffix("m") ? String(text.dropLast()) : text)
    }

    private static func send(_ message: Message, _ info: [String: Any]? = nil) -> Int32 {
        if NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-gb", appID]
            try? open.run()
            open.waitUntilExit()
            Thread.sleep(forTimeInterval: 1.5)
        }
        message.post(info)
        return 0
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var session: Session? { didSet { render() } }
    private var awake: Bool { session != nil }
    /// Awake by choice, as opposed to only because Claude is working.
    private var awakeByHand: Bool { awake && session != .whileClaudeWorks }
    private var batteryLow: Bool { Power.batteryLevelIfUnplugged().map { $0 < Settings.batteryFloor } ?? false }
    /// Critical heat always stops; serious heat stops when the lid is closed (e.g. in a bag).
    private var tooHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .critical || (state == .serious && Power.lidClosed)
    }
    /// The option applies whatever else is chosen; only the safety limits override it.
    private var claudeHolds: Bool { Settings.followClaude && Claude.isWorking && !batteryLow && !tooHot }
    /// Screen and keyboard at 0 without turning the display off: no lock, screenshots keep working.
    private var dimmed: Bool { brightnessWatcher != nil }
    /// Prevents the display from sleeping (and so from locking) while awake.
    private var displayAssertion: IOPMAssertionID = 0
    /// Keeps App Nap from delaying our checks (timer, battery, watched app) while awake.
    private var activity: NSObjectProtocol?
    /// Watches brightness during the black screen, in case it's turned back on elsewhere.
    private var brightnessWatcher: Timer?
    private var renderedAwake: Bool?
    /// Keeps App Nap from delaying the check on Claude while following it.
    private var followActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Left dark by a crash during a black screen.
        if let screen = Backlight.screen, screen < 0.01 {
            Backlight.screen = Settings.screenLevel
            Backlight.keyboard = Settings.keyboardLevel
        }

        observe()
        HotKey.register { [weak self] in self?.toggle() }
        if Power.sleepDisabled { begin(.manual) } else { render() }
        updateFollowActivity()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }.tolerance = 0.5

        DispatchQueue.main.async {
            self.welcomeIfNeeded()
            if !Power.canChangeSleep { self.offerSetup() }
        }
    }

    /// Never leave the Mac sleepless or the screen black behind us.
    func applicationWillTerminate(_ notification: Notification) {
        end()
    }

    private func observe() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Message.start.name, object: nil, queue: .main) { [weak self] note in
            guard let self, session != .manual else { return }  // a script never overrides a manual choice
            let info = note.userInfo ?? [:]
            if let minutes = info["minutes"] as? Int {
                begin(.until(Date().addingTimeInterval(TimeInterval(minutes * 60))))
            } else if let pid = info["pid"] as? Int, let name = info["name"] as? String {
                begin(.whileRunning(pid: pid_t(pid), name: name))
            } else {
                begin(.manual)
            }
        }
        center.addObserver(forName: Message.stop.name, object: nil, queue: .main) { [weak self] _ in self?.allowSleep() }
        center.addObserver(forName: Message.dim.name, object: nil, queue: .main) { [weak self] _ in self?.dim() }
        center.addObserver(forName: Message.wake.name, object: nil, queue: .main) { [weak self] _ in self?.undim() }

        // Display woken up (power button…): restore right away.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.undim() }

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.checkThermalState() }

        // Lid closed while awake: black screen instead of sleep. Otherwise macOS handles it.
        Power.observeLid { [weak self] closed in
            guard let self, awake else { return }
            if closed {
                dim()
                checkThermalState()  // already hot when the lid closes: no change notification will come
            } else {
                undim()
                if Settings.lockOnLidOpen { Power.lockScreen() }
            }
        }
    }

    // MARK: State

    private func begin(_ newSession: Session) {
        guard Power.sleepDisabled || Power.setSleepDisabled(true) else { return offerSetup() }
        if !awake {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Insomnia" as CFString, &displayAssertion)
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Insomnia")
        }
        session = newSession
    }

    private func end(notice: String? = nil) {
        undim()
        // If sleep can't be restored, stay in sync with the system rather than pretend.
        guard !Power.sleepDisabled || Power.setSleepDisabled(false), awake else { return }
        IOPMAssertionRelease(displayAssertion)
        activity.map(ProcessInfo.processInfo.endActivity)
        session = nil
        if let notice { notify(notice) }
    }

    private func tick() {
        // Sleep can also be changed outside the app (pmset on the command line).
        if Power.sleepDisabled != awake { Power.sleepDisabled ? begin(.manual) : end() }
        guard let session else {
            if claudeHolds, Power.canChangeSleep { begin(.whileClaudeWorks) }
            return
        }

        if session.isOver {
            if claudeHolds {
                begin(.whileClaudeWorks)
            } else if session == .whileClaudeWorks {
                end()
                Power.sleepNowIfLidClosed()
            } else {
                end(notice: L("Sleep is back to normal."))
            }
        } else if batteryLow, let level = Power.batteryLevelIfUnplugged() {
            end(notice: String(format: L("Battery at %d%%: sleep is back to normal."), level))
        } else {
            if !dimmed { rememberLevels() }
            render()
        }
    }

    private func checkThermalState() {
        guard awake, tooHot else { return }
        end(notice: L("Your Mac is too hot: sleep is back to normal."))
    }

    private func render() {
        if renderedAwake != awake {
            item.button?.image = NSImage(systemSymbolName: awake ? "infinity.circle.fill" : "infinity.circle",
                                         accessibilityDescription: awake ? L("Staying awake") : L("Normal sleep"))
            renderedAwake = awake
        }
        let hint = String(format: L("Right-click or %@ to toggle"), HotKey.display)
        item.button?.toolTip = "\(session?.summary ?? L("Normal sleep"))\n\(hint)"
    }

    private func rememberLevels() {
        if let screen = Backlight.screen, screen > 0.15 { Settings.screenLevel = screen }
        // macOS turns the keyboard off when idle: ignore that 0.
        if let keyboard = Backlight.keyboard, keyboard > 0.05 { Settings.keyboardLevel = keyboard }
    }

    /// First launch: show where the app lives and offer to open it at login.
    private func welcomeIfNeeded() {
        guard !Settings.welcomed else { return }
        Settings.welcomed = true
        let alert = NSAlert()
        alert.messageText = L("Insomnia is in the menu bar")
        alert.informativeText = L("Click ∞ for the menu, right-click to stay awake.")
        let openAtLogin = NSButton(checkboxWithTitle: L("Open at Login"), target: nil, action: nil)
        openAtLogin.state = .on
        alert.accessoryView = openAtLogin
        NSApp.activate()
        alert.runModal()
        LoginItem.isEnabled = openAtLogin.state == .on
    }

    private func offerSetup() {
        let alert = NSAlert()
        alert.messageText = L("Insomnia needs permission to change sleep settings")
        alert.informativeText = L("It adds a rule that allows only “pmset disablesleep” without a password. macOS will ask for your administrator password.")
        alert.addButton(withTitle: L("Allow"))
        alert.addButton(withTitle: L("Not Now"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !Power.installSudoersRule() else { return }
        let failure = NSAlert()
        failure.messageText = L("The permission could not be installed.")
        failure.runModal()
    }

    // MARK: Actions

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !rightClick {
            showMenu()
        } else if dimmed {
            undim()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        awakeByHand ? allowSleep() : begin(.manual)
    }

    /// Ends what was chosen by hand; the Claude option goes on applying.
    private func allowSleep() {
        if claudeHolds { session = .whileClaudeWorks } else { end() }
    }

    @objc private func toggleFollowClaude() {
        Settings.followClaude.toggle()
        updateFollowActivity()
    }

    private func updateFollowActivity() {
        followActivity.map(ProcessInfo.processInfo.endActivity)
        followActivity = Settings.followClaude
            ? ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Insomnia follows Claude")
            : nil
    }

    @objc private func stayAwakeFor(_ sender: NSMenuItem) {
        begin(.until(Date().addingTimeInterval(TimeInterval(sender.tag * 60))))
    }

    @objc private func stayAwakeWhileRunning(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        begin(.whileRunning(pid: app.processIdentifier, name: app.localizedName ?? "?"))
    }

    /// Awake: black screen without turning the display off. Otherwise: regular display sleep.
    @objc private func dim() {
        guard awake else { return Power.displaySleepNow() }
        guard !dimmed else { return }
        rememberLevels()
        Backlight.screen = 0
        Backlight.keyboard = 0
        // Turned back on elsewhere (☀️ key…): macOS starts from a minimal level,
        // restore the normal one at once so there's a single visible change.
        brightnessWatcher = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            if let screen = Backlight.screen, screen > 0.01 { self?.undim() }
        }
    }

    @objc private func undim() {
        guard dimmed else { return }
        brightnessWatcher?.invalidate()
        brightnessWatcher = nil
        Backlight.keyboard = Settings.keyboardLevel
        Backlight.screen = Settings.screenLevel
    }

    @objc private func setClaudeDelay(_ sender: NSMenuItem) { Settings.claudeDelay = sender.tag }
    @objc private func setBatteryFloor(_ sender: NSMenuItem) { Settings.batteryFloor = sender.tag }
    @objc private func toggleLockOnLidOpen() { Settings.lockOnLidOpen.toggle() }
    @objc private func toggleLoginItem() { LoginItem.isEnabled.toggle() }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()
        if let session {
            menu.addItem(withTitle: session.summary, action: nil, keyEquivalent: "")
            if awakeByHand, claudeHolds {
                menu.addItem(withTitle: Session.whileClaudeWorks.summary, action: nil, keyEquivalent: "")
            }
            menu.addItem(.separator())
        }
        let toggleItem = menu.add(awakeByHand ? L("Allow Sleep") : L("Stay Awake"), #selector(toggle), target: self)
        toggleItem.keyEquivalent = "i"
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]

        let durations = NSMenu()
        for hours in [1, 2, 4, 8] {
            durations.add(formatDuration(TimeInterval(hours * 3600)), #selector(stayAwakeFor(_:)), target: self).tag = hours * 60
        }
        menu.setSubmenu(durations, for: menu.addItem(withTitle: L("Stay Awake For"), action: nil, keyEquivalent: ""))

        let apps = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            let entry = apps.add(app.localizedName ?? "?", #selector(stayAwakeWhileRunning(_:)), target: self)
            entry.representedObject = app
            entry.image = app.icon?.copy() as? NSImage  // a copy: the app's own icon is shared
            entry.image?.size = NSSize(width: 16, height: 16)
        }
        menu.setSubmenu(apps, for: menu.addItem(withTitle: L("Stay Awake While App Runs"), action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        if Claude.isInstalled {
            menu.add(L("Stay Awake While Claude Works"), #selector(toggleFollowClaude), target: self, checked: Settings.followClaude)
            let delayItem = menu.addItem(withTitle: L("Stay Awake After Claude Finishes"), action: nil, keyEquivalent: "")
            if Settings.followClaude {  // without a submenu, it shows as unavailable
                let delays = NSMenu()
                for delay in Settings.claudeDelayChoices {
                    delays.add(delay == 0 ? "30 s" : formatDuration(TimeInterval(delay * 60)), #selector(setClaudeDelay(_:)), target: self,
                               checked: delay == Settings.claudeDelay).tag = delay
                }
                menu.setSubmenu(delays, for: delayItem)
            }
            menu.addItem(.separator())
        }

        if dimmed {
            menu.add(L("Turn Screen Back On"), #selector(undim), target: self)
        } else {
            menu.add(awake ? L("Black Screen (No Lock)") : L("Turn Display Off"), #selector(dim), target: self)
        }
        menu.addItem(.separator())

        let floors = NSMenu()
        for floor in Settings.batteryFloorChoices {
            floors.add(floor == 0 ? L("Never") : "\(floor) %", #selector(setBatteryFloor(_:)), target: self,
                       checked: floor == Settings.batteryFloor).tag = floor
        }
        menu.setSubmenu(floors, for: menu.addItem(withTitle: L("Allow Sleep Below"), action: nil, keyEquivalent: ""))
        menu.add(L("Lock When Lid Opens"), #selector(toggleLockOnLidOpen), target: self, checked: Settings.lockOnLidOpen)
        menu.add(L("Open at Login"), #selector(toggleLoginItem), target: self, checked: LoginItem.isEnabled)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Insomnia"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ action: Selector, target: AnyObject, checked: Bool = false) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = target
        item.state = checked ? .on : .off
        return item
    }
}

// MARK: - Entry point

// Arguments starting with "-" are system launch options, not commands.
if let command = CommandLine.arguments.dropFirst().first, !command.hasPrefix("-") {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

// `kill`/`pkill` should quit cleanly too, so sleep and brightness are restored.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { NSApp.terminate(nil) }
terminationSource.resume()

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
