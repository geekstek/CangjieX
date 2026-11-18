import AppKit
import CoreText

enum SystemCharacterCoverage {
    // Only globally available fonts count; app-private fallback fonts do not.
    static let bitmap: [UInt8] = {
        let coverage = CFCharacterSetCreateMutable(nil)!
        let names = CTFontManagerCopyAvailablePostScriptNames() as! [String]
        for name in names where name != "LastResort" {
            let font = CTFontCreateWithName(name as CFString, 17, nil)
            CFCharacterSetUnion(coverage, CTFontCopyCharacterSet(font))
        }
        var bytes = [UInt8](repeating: 0, count: 0x110000 / 8)
        for scalar in UInt32(0)..<0x110000 where CFCharacterSetIsLongCharacterMember(coverage, scalar) {
            let n = Int(scalar)
            bytes[n / 8] |= 1 << (n % 8)
        }
        return bytes
    }()
}
