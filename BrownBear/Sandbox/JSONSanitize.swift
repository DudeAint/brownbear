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

    /// Recursively normalise a JS-bridged value into something `JSONSerialization` can always write:
    /// non-finite floating-point numbers (NaN, +/-Infinity) become NSNull, and any value that is not a
    /// JSON-representable type at all (Data, Date, a custom object …) also fails closed to NSNull. The
    /// latter matters because `data(withJSONObject:)` raises an *uncatchable* Obj-C exception on invalid
    /// objects, not a Swift error — so we must never hand it one. Containers are rebuilt; bools/ints/
    /// strings/null pass through; the validity check is per-value, so one bad leaf can't void its siblings.
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
        case is String, is NSNull:
            return value
        default:
            // Anything else: keep it only if it is genuinely JSON-representable, else fail closed to
            // null. `isValidJSONObject` only inspects structure and never raises (unlike the serializer),
            // so wrapping the leaf in an array lets us probe a bare value without risking the exception.
            return JSONSerialization.isValidJSONObject([value]) ? value : NSNull()
        }
    }

    /// Serialize to a JSON string after sanitizing the value. Fails closed to "null". The default
    /// `.fragmentsAllowed` matches the bridge serializers (a bare string/number is valid here).
    static func string(_ value: Any,
                       options: JSONSerialization.WritingOptions = [.fragmentsAllowed]) -> String {
        let sanitized = finite(value)
        // Final gate before the serializer: wrap in an array so bare fragments validate too
        // (`isValidJSONObject` rejects a bare string/number at top level). This catches anything
        // `finite` could not normalise without ever risking the Obj-C exception we guard against.
        guard JSONSerialization.isValidJSONObject([sanitized]) else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: sanitized, options: options),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }
}
