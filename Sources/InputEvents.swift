import AppKit
import IOKit

enum T1DeviceEvent {
    static let tag: Int64 = 0x5431435452
    static let placeholderKeys: Set<Int64> = [64, 79, 80, 90, 105, 106]
    private typealias CopyHIDEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderID = @convention(c) (CFTypeRef) -> UInt64
    private static var cachedSenders: [UInt64: T1Transport] = [:]

    private static let hidFunctions: (CopyHIDEvent, SenderID)? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let copy = dlsym(handle, "CGEventCopyIOHIDEvent"),
              let sender = dlsym(handle, "IOHIDEventGetSenderID") else { return nil }
        return (unsafeBitCast(copy, to: CopyHIDEvent.self), unsafeBitCast(sender, to: SenderID.self))
    }()

    static func transport(_ event: CGEvent) -> T1Transport? {
        guard let (copy, sender) = hidFunctions, let hid = copy(event)?.takeRetainedValue() else { return nil }
        let id = sender(hid)
        guard id != 0 else { return nil }
        if let cached = cachedSenders[id] { return cached }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        let transport: T1Transport
        switch (number("VendorID"), number("ProductID")) {
        case (0x620a, 0x0407): transport = .bluetooth
        case (0x1915, 0x1025): transport = .receiver
        default: return nil
        }
        cachedSenders[id] = transport
        return transport
    }
}

enum T1DeviceMapping {
    static let replacements: [UInt64: UInt64] = [
        0xC00000221: 0x70000006D, 0xC00000224: 0x70000006C,
        0xC00000223: 0x70000006B, 0x700000065: 0x70000006F,
        0x100000081: 0x70000006E, 0xC000000E2: 0x700000068
    ]

    static func apply(to original: [UInt64: UInt64], native: Bool,
                      replacements: [UInt64: UInt64] = replacements, keepPower: Bool = true) -> [UInt64: UInt64] {
        var mapping = original
        if mapping[0x700000065] == 0x70000006A { mapping.removeValue(forKey: 0x700000065) }
        for (source, target) in replacements {
            if native && !(keepPower && source == 0x100000081) {
                if mapping[source] == target { mapping.removeValue(forKey: source) }
            } else if mapping[source] == nil {
                mapping[source] = target
            }
        }
        return mapping
    }
}
