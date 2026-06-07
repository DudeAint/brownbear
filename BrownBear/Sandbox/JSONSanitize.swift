//
//  JSONSanitize.swift
//  BrownBear
//
//  Hardening for the JS→native boundary: a value bridged from JavaScript can contain NaN or ±Infinity
//  (a `chrome.runtime.sendMessage`, a GM value, a tab record …). `JSONSerialization.data(withJSON
//  Object:)` throws an Objective-C NSException — "Invalid number value (NaN) in JSON write" — on those,
//  and an Obj-C exception is NOT caught by Swift's `try?`, so it crashes the app. Every serializer that
//  handles untrusted JS values runs it through here first, replacing non-finite numbers with null and
//  failing closed to "null" — so malformed input can never crash native (CLAUDE.md §5).
//

import Foundation

enum JSONSanitize {

    /// Recursively replace non-finite floating-point numbers (NaN, +/-Infinity) with NSNull so the
    /// value is always JSON-serializable. Containers are rebuilt; bools/ints/strings pass through.
    static func finite(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { finite($0) }
        case let array as [Any]:
            return array.map { finite($0) }
        case let number as NSNumber:
            // Bool bridges to NSNumber (kCFBoolean*); leave it. Only guard floating non-finite values.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : NSNull()
        case let double as Double:
            return double.isFinite ? double : NSNull()
        case let float as Float:
            return float.isFinite ? float : NSNull()
        default:
            return value
        }
    }

    /// Serialize to a JSON string after sanitizing non-finite numbers. Fails closed to "null". The
    /// default `.fragmentsAllowed` matches the bridge serializers (a bare string/number is valid here).
    static func string(_ value: Any,
                       options: JSONSerialization.WritingOptions = [.fragmentsAllowed]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: finite(value), options: options),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }
}
