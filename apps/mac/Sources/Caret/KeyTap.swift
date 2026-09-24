import AppKit

/// Global key-down tap. The handler returns true to swallow an event. Runs on the main run loop.
final class KeyTap {
  enum Key: Int64 {
    case tab = 48, escape = 53, space = 49, `return` = 36, right = 124, up = 126, down = 125
  }
  struct Event {
    let key: Key?
    let keyCode: Int64
    let control: Bool
    let option: Bool
    let shift: Bool
    let command: Bool
  }

  var handler: (Event) -> Bool = { _ in false }
  /// Called for every key-down that was not swallowed, after it has been delivered.
  var passthrough: () -> Void = {}
  private var tap: CFMachPort?

  var isRunning: Bool { tap != nil }

  @discardableResult
  func start() -> Bool {
    guard tap == nil else { return true }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: { _, type, event, refcon in
          let tap = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap.tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
          }
          let flags = event.flags
          let code = event.getIntegerValueField(.keyboardEventKeycode)
          let info = Event(
            key: Key(rawValue: code), keyCode: code, control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift),
            command: flags.contains(.maskCommand))
          if tap.handler(info) { return nil }
          DispatchQueue.main.async { tap.passthrough() }
          return Unmanaged.passUnretained(event)
        }, userInfo: refcon)
    else { return false }
    tap = port
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return true
  }
}
