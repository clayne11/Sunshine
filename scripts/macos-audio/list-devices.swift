#!/usr/bin/env swift
//
// List Core Audio devices and their stable UIDs without changing audio state.
//

import CoreAudio
import Foundation

/// Return an owned Core Audio string property and release it after bridging.
private func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { output in
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, output)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

/// Return the total number of channels exposed by a device in one scope.
private func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
        return 0
    }

    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }

    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
        return 0
    }
    let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + $1.mNumberChannels }
}

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var size: UInt32 = 0
let systemObject = AudioObjectID(kAudioObjectSystemObject)
guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
    fputs("Unable to query Core Audio devices.\n", stderr)
    exit(1)
}

var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
if !devices.isEmpty {
    let status = devices.withUnsafeMutableBytes { bytes -> OSStatus in
        guard let baseAddress = bytes.baseAddress else { return -1 }
        return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, baseAddress)
    }
    guard status == noErr else {
        fputs("Unable to read Core Audio devices.\n", stderr)
        exit(1)
    }
}

let result: [[String: Any]] = devices.map { device in
    [
        "id": device,
        "name": stringProperty(device, kAudioObjectPropertyName) ?? "",
        "uid": stringProperty(device, kAudioDevicePropertyDeviceUID) ?? "",
        "inputChannels": channels(device, kAudioDevicePropertyScopeInput),
        "outputChannels": channels(device, kAudioDevicePropertyScopeOutput),
    ]
}

let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
