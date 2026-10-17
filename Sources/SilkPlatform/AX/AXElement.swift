import ApplicationServices
import SilkPrivateAPI

/// Attribute names not exported as constants by the SDK.
enum AXAttribute {
    static let fullScreen = "AXFullScreen"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

/// The per-element AX messaging timeout (default is 6 s): a beachballing app stalls only its own thread, briefly.
let axMessagingTimeout: Float = 1

/// Thin typed wrappers over the AX C API. Must be called on the thread that owns the element.
extension AXUIElement {
    func copyValue(_ attribute: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, attribute as CFString, &value)
        return (error, value)
    }

    func string(_ attribute: String) -> String? {
        copyValue(attribute).value as? String
    }

    func bool(_ attribute: String) -> Bool? {
        (copyValue(attribute).value as? NSNumber)?.boolValue
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = copyValue(attribute).value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> (error: AXError, elements: [AXUIElement]) {
        let (error, value) = copyValue(attribute)
        guard error == .success, let array = value as? [AnyObject] else { return (error == .success ? .noValue : error, []) }
        return (.success, array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        })
    }

    /// Reads several attributes in one round trip. Failed attributes come back as `.failure(error)`.
    func copyValues(_ attributes: [String]) -> (error: AXError, values: [AXAttributeValue]) {
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard error == .success, let array = raw as [AnyObject]?, array.count == attributes.count else {
            return (error == .success ? .failure : error, [])
        }
        return (.success, array.map(AXAttributeValue.init))
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return set(kAXPositionAttribute, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return set(kAXSizeAttribute, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    /// The backing CGWindowID; nil for elements without one (e.g. Finder's desktop).
    var windowID: UInt32? {
        var id = CGWindowID()
        return _AXUIElementGetWindow(self, &id) == .success && id != kCGNullWindowID ? id : nil
    }

    /// Position and size in one round trip.
    func frame() -> (error: AXError, frame: CGRect?) {
        let (error, values) = copyValues([kAXPositionAttribute, kAXSizeAttribute])
        guard error == .success else { return (error, nil) }
        if case .failure(let positionError) = values[0], positionError == .invalidUIElement { return (.invalidUIElement, nil) }
        guard let origin = values[0].point, let size = values[1].size else { return (.success, nil) }
        return (.success, CGRect(origin: origin, size: size))
    }
}

/// One value from `AXUIElementCopyMultipleAttributeValues`.
enum AXAttributeValue {
    case value(AnyObject)
    case failure(AXError)
    case null

    init(_ raw: AnyObject) {
        if raw is NSNull {
            self = .null
        } else if CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError {
            var error = AXError.success
            AXValueGetValue(raw as! AXValue, .axError, &error)
            self = .failure(error)
        } else {
            self = .value(raw)
        }
    }

    var object: AnyObject? {
        if case .value(let object) = self { object } else { nil }
    }

    var string: String? { object as? String }
    var bool: Bool? { (object as? NSNumber)?.boolValue }

    var element: AXUIElement? {
        guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }

    var point: CGPoint? {
        guard let value = axValue(.cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = axValue(.cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func axValue(_ type: AXValueType) -> AXValue? {
        guard let object, CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = object as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }
}
