//
//  BBJSModuleBridge.h
//  BrownBear
//
//  An Objective-C shim over JavaScriptCore's ES-module loader, used to run MV3 service workers
//  declared with `"type": "module"` (e.g. uBlock Origin Lite). JSC's `evaluateScript:` parses input
//  as a classic script, so a module's top-level `import`/`export` is a SyntaxError ("import call
//  expects one or two arguments"). The module API (`JSScript` of type module, `-evaluateJSScript:`,
//  the `moduleLoaderDelegate`) is Objective-C-only and absent from the Swift JavaScriptCore overlay,
//  so — like BBWebKitBridge — it lives here and is exposed via the bridging header.
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

/// Evaluate `source` as an ES module in `context`. JSC resolves each `import` specifier (URL-relative
/// to the importing module's source URL) into an absolute identifier, then calls `resolveSource` with
/// that identifier; return the module's source text, or nil if the package has no such file (the import
/// then rejects). `sourceURL` is the entry module's own URL (e.g. chrome-extension://<id>/sw.js), the
/// base for resolving its relative imports.
///
/// Returns NO and sets `error` if the entry module fails to COMPILE. Module evaluation is asynchronous
/// (the dependency graph loads, then bodies run); a runtime error surfaces through `context`'s
/// exceptionHandler, as with evaluateScript. The loader is retained for the context's lifetime.
BOOL BBEvaluateModuleScript(JSContext *context, NSString *source, NSURL *sourceURL,
                            NSString *_Nullable (^resolveSource)(NSString *identifier),
                            NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
