//
//  XrayCoreProbe.swift
//  VOIDCORE VPN
//
//  Compile-time availability check for the gomobile-generated Xray framework.
//

import Foundation

enum XrayCoreProbe {
    static func isFrameworkLinked() -> Bool {
        #if canImport(Xray)
        return true
        #else
        return false
        #endif
    }
}
