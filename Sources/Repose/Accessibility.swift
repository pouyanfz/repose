import AppKit
import ApplicationServices

/// Thin wrappers around the Accessibility (AX) API. This is the complete list of
/// attributes the app ever reads or writes:
///   kAXWindowsAttribute, kAXRoleAttribute, kAXTitleAttribute,
///   kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen".
enum AX {
    static let fullScreenAttribute = "AXFullScreen"

    /// Seconds to wait for an unresponsive app before giving up on it.
    static let messagingTimeout: Float = 0.5

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the "Repose would like to control this computer"
    /// prompt if the app is not yet trusted. Returns the current trust state.
    @discardableResult
    static func requestTrust() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        guard let value = copyValue(app, kAXWindowsAttribute as String) else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        let count = CFArrayGetCount(array)
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, i) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            if CFGetTypeID(item) == AXUIElementGetTypeID() {
                result.append(item as! AXUIElement)
            }
        }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}
