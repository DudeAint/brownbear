//
//  BBWebKitBridge.m
//  BrownBear
//
//  See BBWebKitBridge.h. This calls the Objective-C WKWebView method directly, so the build
//  links WebKit.framework rather than the Swift overlay (libswiftWebKit.dylib).
//

#import "BBWebKitBridge.h"

void BBEvaluateJavaScript(WKWebView *webView, NSString *script, WKContentWorld *world) {
    [webView evaluateJavaScript:script
                        inFrame:nil
                 inContentWorld:world
              completionHandler:nil];
}

void BBEvaluateJavaScriptInFrame(WKWebView *webView, NSString *script,
                                 WKFrameInfo *_Nullable frame, WKContentWorld *world) {
    [webView evaluateJavaScript:script
                        inFrame:frame
                 inContentWorld:world
              completionHandler:nil];
}
