#!/usr/bin/env swift
// Checks that the private framework symbols BrightBoi loads at runtime still
// exist on this macOS, so a new macOS release that removes or renames one is
// caught by CI before users hit it.
//
// Usage: swift Packaging/check-private-symbols.swift
//
// This only proves the symbols can be found with dlopen/dlsym. It says
// nothing about whether they still behave the same way, which needs a real
// XDR display. Keep the list in step with DisplayServicesSymbols.swift and
// RealAutoBrightnessToggle.swift.
import Foundation

let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
let coreBrightness = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

let required: [(framework: String, symbols: [String])] = [
    (displayServices, [
        "DisplayServicesSetBrightness",
        "DisplayServicesGetBrightness",
        "DisplayServicesCanChangeBrightness"
    ]),
    (coreBrightness, [
        "CBALCSetDisplayAutoBrightnessEnabled"
    ])
]

var missing = 0
for entry in required {
    guard let handle = dlopen(entry.framework, RTLD_NOW) else {
        print("MISSING framework: \(entry.framework)")
        missing += entry.symbols.count
        continue
    }
    for symbol in entry.symbols {
        if dlsym(handle, symbol) == nil {
            print("MISSING symbol: \(symbol) in \(entry.framework)")
            missing += 1
        } else {
            print("ok: \(symbol)")
        }
    }
}

if missing > 0 {
    FileHandle.standardError.write(Data("error: \(missing) private symbol(s) missing\n".utf8))
    exit(1)
}
