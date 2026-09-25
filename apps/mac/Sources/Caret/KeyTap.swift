import AppKit

/// Global key-down tap on its own thread, so a slow Accessibility read on the main thread can never
/// delay the decision and let the host app (a browser's DOM, say) consume Tab first.
/// The decision is made from a small lock-protected `KeyState` that the controller keeps current;
/// the resulting action is delivered on the main thread.
final class KeyTap {
  enum Key: Int64 {
    case tab = 48, escape = 53, space = 49, `return` = 36, right = 124, up = 126, down = 125, n = 45
  }
  struct Event {
    let key: Key?
    let control: Bool
    let option: Bool
    let shift: Bool
    let command: Bool
  }
  /// What the overlay currently offers. Only these facts matter for swallowing a key.
  struct State {
    var active = false  // a field is focused, no preview open, not busy
    var hasGhost = false
    var chipCount = 0
    var tabSafe = true
    var canPropose = false
  }
  enum Action {
    case accept, dismiss, ghostWord, cycle(Int), propose
  }

  var onAction: (Action) -> Void = { _ in }
  /// Called on the main thread for every key-down that was not swallowed.
  var passthrough: () -> Void = {}

  private let lock = NSLock()
  private var _state = State()
  var state: State {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _state
    }
    set {
      lock.lock()
      _state = newValue
      lock.unlock()
    }
  }

  private var port: CFMachPort?
  private var thread: Thread?
  var isRunning: Bool { port != nil }

  static func decide(_ e: Event, _ s: State) -> Action? {
    guard s.active, let key = e.key else { return nil }
    // ⌘⇧N proposes a skill; it is the only command-key combination Caret ever takes.
    if key == .n && e.command && e.shift && !e.control && !e.option { return s.canPropose ? .propose : nil }
    guard s.hasGhost || s.chipCount > 0, !e.command else { return nil }
    switch key {
    case .escape: return .dismiss
    case .tab where s.tabSafe && !e.shift && !e.control && !e.option: return .accept
    case .space where !s.tabSafe && e.control: return .accept
    case .right where (e.control || e.option) && s.hasGhost: return .ghostWord
    case .up where s.chipCount > 1: return .cycle(-1)
    case .down where s.chipCount > 1: return .cycle(1)
    default: return nil
    }
  }

  /// Creates the tap on a dedicated thread. Returns false when macOS refuses (no Accessibility trust).
  @discardableResult
  func start() -> Bool {
    guard thread == nil else { return port != nil }
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in
      let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
      let refcon = Unmanaged.passUnretained(self).toOpaque()
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: { _, type, event, refcon in
          let tap = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
          }
          let flags = event.flags
          let info = Event(
            key: Key(rawValue: event.getIntegerValueField(.keyboardEventKeycode)),
            control: flags.contains(.maskControl), option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift), command: flags.contains(.maskCommand))
          if let action = KeyTap.decide(info, tap.state) {
            DispatchQueue.main.async { tap.onAction(action) }
            return nil
          }
          DispatchQueue.main.async { tap.passthrough() }
          return Unmanaged.passUnretained(event)
        }, userInfo: refcon)
      self.port = created
      ready.signal()
      guard let created else { return }
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CGEvent.tapEnable(tap: created, enable: true)
      CFRunLoopRun()
    }
    thread.name = "caret.keytap"
    thread.qualityOfService = .userInteractive
    self.thread = thread
    thread.start()
    _ = ready.wait(timeout: .now() + 2)
    if port == nil { self.thread = nil }
    return port != nil
  }
}
