//
//  BBWebKitBridge.h
//  BrownBear
//
//  A minimal Objective-C shim over one WKWebView method. Calling
//  `evaluateJavaScript(_:in:in:)` from Swift links the Swift WebKit overlay
//  (libswiftWebKit.dylib), which Apple removed from the iOS 18 runtime — so an app deploying to
//  iOS 16.4 aborts at launch with "Library not loaded: /usr/lib/swift/libswiftWebKit.dylib".
//  Routing this one call through Objective-C uses WebKit.framework directly and drops the
//  overlay dependency entirely, letting us keep the 16.4 deployment target.
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Evaluate `script` in the given content world of `webView`'s main frame. Fire-and-forget.
void BBEvaluateJavaScript(WKWebView *webView, NSString *script, WKContentWorld *world);

/// Evaluate `script` in the given content world of a SPECIFIC frame (pass nil for the main frame).
/// Used to push state — e.g. a GM value change — into the exact iframe a script runs in, so the
/// same script's instances across frames and tabs stay in sync. Fire-and-forget.
void BBEvaluateJavaScriptInFrame(WKWebView *webView, NSString *script,
                                 WKFrameInfo *_Nullable frame, WKContentWorld *world);

NS_ASSUME_NONNULL_END
