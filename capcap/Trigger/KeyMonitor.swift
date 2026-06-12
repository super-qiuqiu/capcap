import AppKit
import Carbon

class KeyMonitor {
    /// Master switch. When false, neither trigger fires (used during shortcut recording).
    var isEnabled: Bool = true {
        didSet {
            if !isEnabled { resetSequence() }
        }
    }

    /// Plain double-tap ⌘ → regular screenshot. Disabled when a custom hotkey is registered.
    var isRegularDoubleTapEnabled: Bool = true {
        didSet { if !isRegularDoubleTapEnabled { resetSequence() } }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastCommandPressTime: TimeInterval = 0
    private var lastCommandPressOption: Bool = false
    private var commandIsDown = false
    private var otherKeyPressed = false
    private let onTrigger: () -> Void
    private let onCountdownTrigger: () -> Void

    var usesEventTap: Bool {
        eventTap != nil
    }

    init(onTrigger: @escaping () -> Void,
         onCountdownTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        self.onCountdownTrigger = onCountdownTrigger
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        guard !startEventTapMonitoring() else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
    }

    private func stopMonitoring() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        if let m = keyDownMonitor {
            NSEvent.removeMonitor(m)
            keyDownMonitor = nil
        }
    }

    private func resetSequence() {
        lastCommandPressTime = 0
        commandIsDown = false
        otherKeyPressed = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        handleFlagsChanged(
            commandIsDown: event.modifierFlags.contains(.command),
            optionIsDown: event.modifierFlags.contains(.option),
            hasDisruptiveModifiers: event.modifierFlags.contains(.shift)
                || event.modifierFlags.contains(.control)
        )
    }

    @discardableResult
    private func startEventTapMonitoring() -> Bool {
        let types: [CGEventType] = [.flagsChanged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleTappedEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private func handleTappedEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        case .keyDown:
            if handleCustomScreenshotHotkey(event: event) {
                return
            }
            otherKeyPressed = true
        case .flagsChanged:
            let flags = event.flags
            handleFlagsChanged(
                commandIsDown: flags.contains(.maskCommand),
                optionIsDown: flags.contains(.maskAlternate),
                hasDisruptiveModifiers: flags.contains(.maskShift)
                    || flags.contains(.maskControl)
            )
        default:
            break
        }
    }

    private func handleFlagsChanged(
        commandIsDown cmd: Bool,
        optionIsDown opt: Bool,
        hasDisruptiveModifiers hasDisruptive: Bool
    ) {
        guard isEnabled else { return }

        if hasDisruptive {
            otherKeyPressed = true
            commandIsDown = cmd
            return
        }

        if cmd && !commandIsDown {
            let now = ProcessInfo.processInfo.systemUptime
            let withinWindow = (now - lastCommandPressTime) < Defaults.doubleTapInterval
            // Both presses must share the same Option state — a sequence that
            // mixes ⌘ then ⌥⌘ is treated as a fresh first press, not a double-tap.
            let isDoubleTap = !otherKeyPressed
                && withinWindow
                && lastCommandPressOption == opt

            if isDoubleTap {
                if opt {
                    MainRunLoopScheduler.perform { [weak self] in self?.onCountdownTrigger() }
                } else if isRegularDoubleTapEnabled {
                    MainRunLoopScheduler.perform { [weak self] in self?.onTrigger() }
                }
                lastCommandPressTime = 0
            } else {
                lastCommandPressTime = now
                lastCommandPressOption = opt
            }
            otherKeyPressed = false
        }

        commandIsDown = cmd
    }

    private func handleCustomScreenshotHotkey(event: CGEvent) -> Bool {
        guard isEnabled,
              !isAutorepeat(event),
              Defaults.hasCustomScreenshotHotkey
        else {
            return false
        }

        if let hotkey = HotkeyManager.shared.currentCountdownHotkey(),
           eventMatches(event, hotkey: hotkey) {
            MainRunLoopScheduler.perform { [weak self] in self?.onCountdownTrigger() }
            return true
        }

        if let hotkey = HotkeyManager.shared.currentHotkey(),
           eventMatches(event, hotkey: hotkey) {
            MainRunLoopScheduler.perform { [weak self] in self?.onTrigger() }
            return true
        }

        return false
    }

    private func eventMatches(_ event: CGEvent, hotkey: (keyCode: UInt32, modifiers: UInt32)) -> Bool {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == hotkey.keyCode else { return false }

        let actualFlags = event.flags.intersection(Self.hotkeyFlagMask)
        let expectedFlags = Self.cgFlags(fromCarbonModifiers: hotkey.modifiers)
        return actualFlags == expectedFlags
    }

    private func isAutorepeat(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }

    private static let hotkeyFlagMask: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskShift,
        .maskControl
    ]

    private static func cgFlags(fromCarbonModifiers modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.maskCommand)
        }
        if modifiers & UInt32(optionKey) != 0 {
            flags.insert(.maskAlternate)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.maskShift)
        }
        if modifiers & UInt32(controlKey) != 0 {
            flags.insert(.maskControl)
        }
        return flags
    }
}
