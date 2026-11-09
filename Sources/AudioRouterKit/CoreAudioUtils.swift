import CoreAudio
import Foundation

public struct CoreAudioError: Error, LocalizedError, CustomStringConvertible {
    public let status: OSStatus
    public let context: String

    public init(_ status: OSStatus, _ context: String) {
        self.status = status
        self.context = context
    }

    public var description: String { "\(context) (\(osStatusString(status)))" }
    public var errorDescription: String? { description }
}

/// Human readable OSStatus: four-char code when printable, otherwise the number.
public func osStatusString(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return "\(status)"
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status, context()) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func hasProperty(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    return AudioObjectHasProperty(obj, &a)
}

func getScalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = addr
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    return st == noErr ? value : nil
}

func getString(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
    var a = addr
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    guard st == noErr, let s = cf?.takeRetainedValue() else { return nil }
    return s as String
}

func getArray<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
    var a = addr
    guard AudioObjectHasProperty(obj, &a) else { return [] }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    var arr = [T](repeating: zero, count: count)
    let st = arr.withUnsafeMutableBytes { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0.baseAddress!) }
    return st == noErr ? Array(arr.prefix(Int(size) / MemoryLayout<T>.stride)) : []
}

func setScalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
    var a = addr
    var v = value
    return withUnsafePointer(to: &v) {
        AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
    }
}

/// Total channels of a device in a scope (input/output), from its stream configuration.
func channelCount(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
}
