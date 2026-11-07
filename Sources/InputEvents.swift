import AppKit
import IOKit

enum T1DeviceEvent {
    static let tag: Int64 = 0x5431435452
    static let placeholderKeys: Set<Int64> = [64, 79, 80, 90, 105, 106]
    private typealias CopyHIDEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderID = @convention(c) (CFTypeRef) -> UInt64
    private static var cachedSender: UInt64?

    private static let hidFunctions: (CopyHIDEvent, SenderID)? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let copy = dlsym(handle, "CGEventCopyIOHIDEvent"),
              let sender = dlsym(handle, "IOHIDEventGetSenderID") else { return nil }
        return (unsafeBitCast(copy, to: CopyHIDEvent.self), unsafeBitCast(sender, to: SenderID.self))
    }()

    static func isT1(_ event: CGEvent) -> Bool {
        guard let (copy, sender) = hidFunctions, let hid = copy(event)?.takeRetainedValue() else { return false }
        let id = sender(hid)
        guard id != 0 else { return false }
        if id == cachedSender { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        guard number("VendorID") == 25098, number("ProductID") == 1031 else { return false }
        cachedSender = id
        return true
    }
}

enum T1DeviceMapping {
    static let replacements: [UInt64: UInt64] = [
        0xC00000221: 0x70000006D, 0xC00000224: 0x70000006C,
        0xC00000223: 0x70000006B, 0x700000065: 0x70000006F,
        0x100000081: 0x70000006E, 0xC000000E2: 0x700000068
    ]

    static func apply(to original: [UInt64: UInt64], native: Bool) -> [UInt64: UInt64] {
        var mapping = original
        if mapping[0x700000065] == 0x70000006A { mapping.removeValue(forKey: 0x700000065) }
        for (source, target) in replacements {
            if native && source != 0x100000081 {
                if mapping[source] == target { mapping.removeValue(forKey: source) }
            } else if mapping[source] == nil {
                mapping[source] = target
            }
        }
        return mapping
    }
}
