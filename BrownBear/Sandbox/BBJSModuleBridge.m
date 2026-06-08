//
//  BBJSModuleBridge.m
//  BrownBear
//
//  See BBJSModuleBridge.h. Uses JavaScriptCore's Objective-C module API directly so the Swift overlay
//  isn't relied on for it.
//

#import "BBJSModuleBridge.h"
#import <objc/runtime.h>

/// The module-loader delegate JSC calls to fetch each imported module's source. It turns the source
/// into a `JSScript` of type module and hands it back via the resolve handler (or rejects on miss).
@interface BBJSModuleLoader : NSObject <JSModuleLoaderDelegate>
@property (nonatomic, copy, nullable) NSString *(^resolveSource)(NSString *identifier);
@end

@implementation BBJSModuleLoader

- (void)context:(JSContext *)context
    fetchModuleForIdentifier:(JSValue *)identifier
          withResolveHandler:(JSValue *)resolve
               rejectHandler:(JSValue *)reject {
    NSString *idString = [identifier toString];
    NSString *src = self.resolveSource ? self.resolveSource(idString) : nil;
    if (src == nil) {
        NSString *msg = [NSString stringWithFormat:@"module not found: %@", idString];
        [reject callWithArguments:@[ [JSValue valueWithNewErrorFromMessage:msg inContext:context] ]];
        return;
    }
    NSURL *url = [NSURL URLWithString:idString];
    NSError *err = nil;
    JSScript *script = [JSScript scriptOfType:kJSScriptTypeModule
                                   withSource:src
                                 andSourceURL:url
                             andBytecodeCache:nil
                             inVirtualMachine:context.virtualMachine
                                        error:&err];
    if (script == nil) {
        NSString *msg = err.localizedDescription ?: @"module compile failed";
        [reject callWithArguments:@[ [JSValue valueWithNewErrorFromMessage:msg inContext:context] ]];
        return;
    }
    [resolve callWithArguments:@[ script ]];
}

@end

static const void *kBBModuleLoaderKey = &kBBModuleLoaderKey;

BOOL BBEvaluateModuleScript(JSContext *context, NSString *source, NSURL *sourceURL,
                            NSString *_Nullable (^resolveSource)(NSString *identifier),
                            NSError *_Nullable *_Nullable error) {
    BBJSModuleLoader *loader = [[BBJSModuleLoader alloc] init];
    loader.resolveSource = resolveSource;
    // moduleLoaderDelegate is weak; retain the loader for the context's lifetime so it survives the
    // asynchronous module-graph load + evaluation that outlives this call.
    context.moduleLoaderDelegate = loader;
    objc_setAssociatedObject(context, kBBModuleLoaderKey, loader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSError *err = nil;
    JSScript *entry = [JSScript scriptOfType:kJSScriptTypeModule
                                  withSource:source
                                andSourceURL:sourceURL
                            andBytecodeCache:nil
                            inVirtualMachine:context.virtualMachine
                                       error:&err];
    if (entry == nil) {
        if (error) { *error = err; }
        return NO;
    }
    [context evaluateJSScript:entry];
    return YES;
}
