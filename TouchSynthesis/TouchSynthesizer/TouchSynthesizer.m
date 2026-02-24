#import "TouchSynthesizer.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <mach/mach.h>

// ============================================================
// Touch event synthesis via XCTest private API + IOKit HID.
//
// Synthesis chain (tried in order):
//   1. record.synthesizeWithError: — synchronous, in-process,
//      bypasses testmanagerd entirely. No quiescence wait. FAST.
//
//   2. XCUIDevice.eventSynthesizer.synthesizeEvent:completion:
//      WDA's synthesis path. Fallback if Path 1 fails.
//
//   3. daemonProxy._XCT_synthesizeEvent:completion:
//      Fire-and-forget via testmanagerd XPC. Has ~5s quiescence
//      wait (unavoidable). Last resort for XCTest path.
//
//   4. IOKit HID direct injection (separate methods, bypasses XCTest)
// ============================================================

// MARK: - Static State

static BOOL sFrameworkLoaded = NO;
static void *sFrameworkHandle = NULL;
static void *sAutomationHandle = NULL;

static Class cls_XCSynthesizedEventRecord = Nil;
static Class cls_XCPointerEventPath = Nil;
static Class cls_XCTRunnerDaemonSession = Nil;
static Class cls_XCUIDevice = Nil;
static Class cls_XCTRunnerAutomationSession = Nil;

static NSString *sLastPathUsed = nil;

// MARK: - IOKit HID Types

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventSystemRef;

#define kHIDDigitizerEventRange     (1 << 0)
#define kHIDDigitizerEventTouch     (1 << 1)
#define kHIDDigitizerEventPosition  (1 << 2)
#define kHIDDigitizerTransducerFinger 2
#define kHIDFieldDigitizerIsDisplayIntegrated 0xB000C
#define kHIDFieldDigitizerIsBuiltIn 0xB000D

typedef IOHIDEventSystemClientRef (*fn_HIDClientCreate)(CFAllocatorRef);
typedef void (*fn_HIDClientDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*fn_HIDCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    CGFloat, CGFloat, CGFloat, CGFloat, CGFloat,
    Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*fn_HIDCreateDigitizerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t,
    CGFloat, CGFloat, CGFloat,
    CGFloat, CGFloat,
    Boolean, Boolean, uint32_t);
typedef void (*fn_HIDSetIntegerValue)(IOHIDEventRef, uint32_t, int64_t);
typedef void (*fn_HIDAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*fn_HIDSetSenderID)(IOHIDEventRef, uint64_t);
typedef IOHIDEventSystemRef (*fn_HIDEventSystemCreate)(CFAllocatorRef);
typedef void (*fn_HIDEventSystemDispatch)(IOHIDEventSystemRef, IOHIDEventRef);

static void *sIOKitHandle = NULL;
static IOHIDEventSystemClientRef sHIDClient = NULL;
static IOHIDEventSystemRef sHIDSystem = NULL;

static fn_HIDClientCreate       p_ClientCreate = NULL;
static fn_HIDClientDispatch     p_ClientDispatch = NULL;
static fn_HIDCreateDigitizerFingerEvent p_FingerEvent = NULL;
static fn_HIDCreateDigitizerEvent       p_DigitizerEvent = NULL;
static fn_HIDSetIntegerValue    p_SetInteger = NULL;
static fn_HIDAppendEvent        p_AppendEvent = NULL;
static fn_HIDSetSenderID        p_SetSenderID = NULL;
static fn_HIDEventSystemCreate  p_SysCreate = NULL;
static fn_HIDEventSystemDispatch p_SysDispatch = NULL;

// MARK: - objc_msgSend Typed Casts

typedef id (*MsgSend_id_CGPoint_double)(id, SEL, CGPoint, double);
typedef void (*MsgSend_void_CGPoint_double)(id, SEL, CGPoint, double);
typedef void (*MsgSend_void_double)(id, SEL, double);
typedef void (*MsgSend_void_id)(id, SEL, id);
typedef void (*MsgSend_void_id_id)(id, SEL, id, id);
typedef id (*MsgSend_id_id)(id, SEL, id);
typedef id (*MsgSend_id_id_long)(id, SEL, id, long);

// New gesture support
typedef id (*MsgSend_id_void)(id, SEL);
typedef void (*MsgSend_void_id_double_long_BOOL)(id, SEL, id, double, long, BOOL);
typedef void (*MsgSend_void_id_NSUInteger_double)(id, SEL, id, NSUInteger, double);
typedef void (*MsgSend_void_NSUInteger)(id, SEL, NSUInteger);

// MARK: - Non-Fatal Assertion Handler
//
// XCTest's XCTRunnerDaemonSession throws NSInternalInconsistencyException
// when the daemon session times out. We catch that here instead of crashing.

@interface _NonFatalAssertionHandler : NSAssertionHandler
@end

@implementation _NonFatalAssertionHandler

- (void)handleFailureInMethod:(SEL)selector
                       object:(id)object
                         file:(NSString *)fileName
                   lineNumber:(NSInteger)line
                  description:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *desc = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[TouchSynthesizer] Assertion caught (non-fatal): -[%@ %@] %@:%ld %@",
          NSStringFromClass([object class]), NSStringFromSelector(selector),
          fileName, (long)line, desc);
}

- (void)handleFailureInFunction:(NSString *)functionName
                           file:(NSString *)fileName
                     lineNumber:(NSInteger)line
                    description:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *desc = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[TouchSynthesizer] Assertion caught (non-fatal): %@ %@:%ld %@",
          functionName, fileName, (long)line, desc);
}

@end

static void _installNonFatalAssertionHandler(void) {
    NSThread *thread = [NSThread currentThread];
    if (![thread.threadDictionary[NSAssertionHandlerKey] isKindOfClass:[_NonFatalAssertionHandler class]]) {
        thread.threadDictionary[NSAssertionHandlerKey] = [_NonFatalAssertionHandler new];
    }
}

static BOOL sGlobalHandlerInstalled = NO;

static void _uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[TouchSynthesizer] UNCAUGHT EXCEPTION (suppressed): %@ - %@",
          exception.name, exception.reason);
}

static void _installGlobalExceptionHandler(void) {
    if (sGlobalHandlerInstalled) return;
    sGlobalHandlerInstalled = YES;
    NSSetUncaughtExceptionHandler(&_uncaughtExceptionHandler);
}

// ============================================================
#pragma mark - Implementation
// ============================================================

@implementation TouchSynthesizer

// MARK: - Properties

+ (BOOL)isLoaded {
    return sFrameworkLoaded;
}

+ (BOOL)isDaemonSessionAvailable {
    if (!sFrameworkLoaded || !cls_XCTRunnerDaemonSession) return NO;
    _installNonFatalAssertionHandler();
    @try {
        id session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
        return session != nil;
    } @catch (NSException *e) {
        NSLog(@"[TouchSynthesizer] isDaemonSessionAvailable exception: %@", e.reason);
        return NO;
    }
}

+ (NSString *)lastPathUsed {
    return sLastPathUsed ?: @"none";
}

// MARK: - Load Framework

+ (nullable NSString *)loadFramework {
    if (sFrameworkLoaded) return nil;

    _installNonFatalAssertionHandler();
    _installGlobalExceptionHandler();

    // Try multiple XCTest.framework paths (varies by iOS version)
    const char *paths[] = {
        "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        "/System/Developer/Library/PrivateFrameworks/XCTest.framework/XCTest",
        "/System/Library/PrivateFrameworks/XCTest.framework/XCTest",
        "/Developer/Library/Frameworks/XCTest.framework/XCTest",
        NULL
    };

    for (int i = 0; paths[i] != NULL; i++) {
        sFrameworkHandle = dlopen(paths[i], RTLD_NOW);
        if (sFrameworkHandle) {
            NSLog(@"[TouchSynthesizer] Loaded from: %s", paths[i]);
            break;
        }
    }

    if (!sFrameworkHandle) {
        return [NSString stringWithFormat:@"Failed to load XCTest.framework: %s", dlerror()];
    }

    // Also load automation support frameworks
    const char *automationPaths[] = {
        "/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
        "/System/Developer/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation",
        "/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
        NULL
    };

    for (int i = 0; automationPaths[i] != NULL; i++) {
        void *handle = dlopen(automationPaths[i], RTLD_NOW);
        if (handle) {
            NSLog(@"[TouchSynthesizer] Loaded automation: %s", automationPaths[i]);
            if (!sAutomationHandle) sAutomationHandle = handle;
        }
    }

    // Resolve XCTest classes we need
    cls_XCSynthesizedEventRecord = NSClassFromString(@"XCSynthesizedEventRecord");
    cls_XCPointerEventPath = NSClassFromString(@"XCPointerEventPath");
    cls_XCTRunnerDaemonSession = NSClassFromString(@"XCTRunnerDaemonSession");
    cls_XCUIDevice = NSClassFromString(@"XCUIDevice");
    cls_XCTRunnerAutomationSession = NSClassFromString(@"XCTRunnerAutomationSession");

    NSLog(@"[TouchSynthesizer] Classes: Record=%@ Path=%@ Session=%@ Device=%@ AutoSession=%@",
          cls_XCSynthesizedEventRecord ? @"Y" : @"N",
          cls_XCPointerEventPath ? @"Y" : @"N",
          cls_XCTRunnerDaemonSession ? @"Y" : @"N",
          cls_XCUIDevice ? @"Y" : @"N",
          cls_XCTRunnerAutomationSession ? @"Y" : @"N");

    if (!cls_XCSynthesizedEventRecord || !cls_XCPointerEventPath) {
        return @"XCTest loaded but required classes not found";
    }

    sFrameworkLoaded = YES;

    // Dump all available XCTest methods for diagnostics
    [self _dumpXCTestDiagnostics];

    // Disable quiescence waiting — prevents testmanagerd from polling our process
    [self _disableQuiescenceWaiting];

    return nil;
}

// MARK: - Disable Quiescence Waiting
//
// Even though we use synthesizeWithError: (which bypasses the daemon),
// testmanagerd may still poll our process for quiescence status via XPC.
// These swizzles immediately respond "idle" to prevent CPU overhead.

+ (void)_disableQuiescenceWaiting {
    NSLog(@"[TouchSynthesizer] Disabling quiescence waiting...");
    int fixed = 0;

    // 1. XCTRunnerAutomationSession — immediately report idle
    Class runnerAutoSession = NSClassFromString(@"XCTRunnerAutomationSession");
    if (runnerAutoSession) {
        Method m;
        m = class_getInstanceMethod(runnerAutoSession, @selector(notifyWhenMainRunLoopIsIdle:));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id self, id block) {
                if (block) ((void(^)(void))block)();
            }));
            fixed++;
        }
        m = class_getInstanceMethod(runnerAutoSession, @selector(notifyWhenAnimationsAreIdle:));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id self, id block) {
                if (block) ((void(^)(void))block)();
            }));
            fixed++;
        }
    }

    // 2. XCTAutomationSession — XPC callback methods
    Class autoSession = NSClassFromString(@"XCTAutomationSession");
    if (autoSession) {
        Method m;
        m = class_getInstanceMethod(autoSession, @selector(_XCT_notifyWhenMainRunLoopIsIdle));
        if (m) { method_setImplementation(m, imp_implementationWithBlock(^(id self) {})); fixed++; }
        m = class_getInstanceMethod(autoSession, @selector(_XCT_notifyWhenAnimationsAreIdle));
        if (m) { method_setImplementation(m, imp_implementationWithBlock(^(id self) {})); fixed++; }
        m = class_getInstanceMethod(autoSession, @selector(notifyWhenMainRunLoopIsIdle:));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id self, id block) {
                if (block) ((void(^)(void))block)();
            }));
            fixed++;
        }
        m = class_getInstanceMethod(autoSession, @selector(notifyWhenAnimationsAreIdle:));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id self, id block) {
                if (block) ((void(^)(void))block)();
            }));
            fixed++;
        }
    }

    // 3. XCAXClient_iOS — accessibility quiescence
    Class axClient = NSClassFromString(@"XCAXClient_iOS");
    if (axClient) {
        Method m;
        m = class_getInstanceMethod(axClient, @selector(waitForQuiescenceOnAllForegroundApplicationsAsPreEvent:));
        if (m) { method_setImplementation(m, imp_implementationWithBlock(^(id self, BOOL pre) {})); fixed++; }
        m = class_getInstanceMethod(axClient, @selector(notifyWhenEventLoopIsIdleForApplication:reply:));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id self, id app, id reply) {
                if (reply) ((void(^)(void))reply)();
            }));
            fixed++;
        }
    }

    // 4. XCUIApplicationProcess — skip quiescence checks
    Class appProcess = NSClassFromString(@"XCUIApplicationProcess");
    if (appProcess) {
        IMP yesIMP = imp_implementationWithBlock(^BOOL(id self) { return YES; });
        Method m;
        m = class_getInstanceMethod(appProcess, @selector(shouldSkipPreEventQuiescence));
        if (m) { method_setImplementation(m, yesIMP); fixed++; }
        m = class_getInstanceMethod(appProcess, @selector(shouldSkipPostEventQuiescence));
        if (m) { method_setImplementation(m, yesIMP); fixed++; }
        m = class_getInstanceMethod(appProcess, @selector(isQuiescent));
        if (m) { method_setImplementation(m, yesIMP); fixed++; }
        m = class_getInstanceMethod(appProcess, @selector(eventLoopHasIdled));
        if (m) { method_setImplementation(m, yesIMP); fixed++; }
    }

    // 5. Set implicitEventConfirmationInterval to 0
    @try {
        id session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
        if (session) {
            SEL s1 = @selector(setImplicitEventConfirmationIntervalForCurrentContextWithoutSideEffects:);
            if ([session respondsToSelector:s1]) {
                ((void (*)(id, SEL, double))objc_msgSend)(session, s1, 0.0);
                fixed++;
            }
            SEL s2 = @selector(setImplicitEventConfirmationIntervalForCurrentContext:);
            if ([session respondsToSelector:s2]) {
                ((void (*)(id, SEL, double))objc_msgSend)(session, s2, 0.0);
                fixed++;
            }
        }
    } @catch (NSException *e) {}

    NSLog(@"[TouchSynthesizer] Quiescence disable: %d fixes applied", fixed);
}

// MARK: - XCTest Diagnostics

/// Enumerate all methods on key XCTest objects to find quiescence/configuration options.
/// Writes output to a file (os_log redacts dynamic strings as <private>).
+ (void)_dumpXCTestDiagnostics {
    NSMutableString *out = [NSMutableString stringWithString:@"=== XCTest API Enumeration ===\n\n"];

    // 1. Enumerate methods on the session class
    [self _appendMethodsForClass:cls_XCTRunnerDaemonSession label:@"XCTRunnerDaemonSession" to:out];

    // 2. Get the shared session instance and check its class hierarchy
    @try {
        id session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
        if (session) {
            [out appendFormat:@"\nSession instance class: %@\n", NSStringFromClass([session class])];
            [self _appendMethodsForClass:[session class] label:@"session_instance" to:out];

            // 3. Get daemon proxy and enumerate its methods
            if ([session respondsToSelector:@selector(daemonProxy)]) {
                id proxy = [session performSelector:@selector(daemonProxy)];
                if (proxy) {
                    [out appendFormat:@"\nDaemonProxy class: %@\n", NSStringFromClass([proxy class])];
                    [self _appendMethodsForClass:[proxy class] label:@"daemonProxy" to:out];

                    if ([proxy isKindOfClass:[NSProxy class]]) {
                        [out appendString:@"  (NSProxy — methods come from XPC protocol)\n"];
                    }
                } else {
                    [out appendString:@"\nDaemonProxy is nil\n"];
                }
            }
        } else {
            [out appendString:@"\nSession is nil (not yet initialized)\n"];
        }
    } @catch (NSException *e) {
        [out appendFormat:@"\nException getting session/proxy: %@\n", e.reason];
    }

    // 4. Enumerate other potentially useful classes
    NSArray *classNames = @[
        @"XCUIDevice", @"XCTRunnerAutomationSession",
        @"XCSyntheticEventGenerator", @"XCEventGenerator",
        @"XCUIApplicationProcess", @"XCUIApplication",
        @"XCUIApplicationMonitor", @"XCUIApplicationStateMonitor",
        @"XCTCapabilities", @"XCTCapabilitiesBuilder",
        @"XCPointerEventPath", @"XCSynthesizedEventRecord",
    ];
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (cls) {
            [self _appendMethodsForClass:cls label:name to:out];
        } else {
            [out appendFormat:@"\nClass %@ NOT FOUND\n", name];
        }
    }

    // 5. Search all loaded classes for quiescence/timeout methods
    [out appendString:@"\n=== Searching all XC* classes for quiescence/timeout/idle methods ===\n"];
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    int found = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        NSString *className = NSStringFromClass(allClasses[i]);
        if (![className hasPrefix:@"XC"]) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(allClasses[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            NSString *lower = selName.lowercaseString;
            if ([lower containsString:@"quiescen"] ||
                [lower containsString:@"animationidle"] ||
                [lower containsString:@"idle"] ||
                [lower containsString:@"timeout"] ||
                [lower containsString:@"disableauto"]) {
                [out appendFormat:@"  INTERESTING: -[%@ %@]\n", className, selName];
                found++;
            }
        }
        if (methods) free(methods);

        Class metaCls = object_getClass(allClasses[i]);
        methods = class_copyMethodList(metaCls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            NSString *lower = selName.lowercaseString;
            if ([lower containsString:@"quiescen"] ||
                [lower containsString:@"animationidle"] ||
                [lower containsString:@"idle"] ||
                [lower containsString:@"timeout"] ||
                [lower containsString:@"disableauto"]) {
                [out appendFormat:@"  INTERESTING: +[%@ %@]\n", className, selName];
                found++;
            }
        }
        if (methods) free(methods);
    }
    free(allClasses);
    [out appendFormat:@"\nFound %d interesting methods across all XC* classes\n", found];
    [out appendString:@"=== End Enumeration ===\n"];

    // Write to file
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xctest_diag.txt"];
    NSError *writeErr = nil;
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
    NSLog(@"[XCTDiag] Wrote %lu bytes to %@%@",
          (unsigned long)out.length, path,
          writeErr ? [NSString stringWithFormat:@" (error: %@)", writeErr] : @"");
}

+ (void)_appendMethodsForClass:(Class)cls label:(NSString *)label to:(NSMutableString *)out {
    if (!cls) return;

    // Instance methods
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    [out appendFormat:@"\n--- %@ instance methods (%u) ---\n", label, count];
    for (unsigned int i = 0; i < count; i++) {
        NSString *selName = NSStringFromSelector(method_getName(methods[i]));
        [out appendFormat:@"  -[%@ %@]\n", label, selName];
    }
    if (methods) free(methods);

    // Class methods
    Class metaCls = object_getClass(cls);
    methods = class_copyMethodList(metaCls, &count);
    [out appendFormat:@"--- %@ class methods (%u) ---\n", label, count];
    for (unsigned int i = 0; i < count; i++) {
        NSString *selName = NSStringFromSelector(method_getName(methods[i]));
        [out appendFormat:@"  +[%@ %@]\n", label, selName];
    }
    if (methods) free(methods);

    // Properties
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    if (propCount > 0) {
        [out appendFormat:@"--- %@ properties (%u) ---\n", label, propCount];
        for (unsigned int i = 0; i < propCount; i++) {
            [out appendFormat:@"  @property %s (%s)\n", property_getName(props[i]), property_getAttributes(props[i])];
        }
    }
    if (props) free(props);
}

// MARK: - Session Initialization

+ (void)reinitializeSession {
    if (!cls_XCTRunnerDaemonSession) return;
    NSLog(@"[TouchSynthesizer] Re-initializing session...");

    _installNonFatalAssertionHandler();

    @try {
        SEL initSel = @selector(initiateSharedSessionWithCompletion:);
        if ([cls_XCTRunnerDaemonSession respondsToSelector:initSel]) {
            typedef void (*MsgSend_void_id_block)(id, SEL, void(^)(id));
            ((MsgSend_void_id_block)objc_msgSend)(
                cls_XCTRunnerDaemonSession, initSel,
                ^(id sessionOrError) {
                    _installNonFatalAssertionHandler();
                    NSLog(@"[TouchSynthesizer] Re-init completed: %@ (%@)",
                          sessionOrError ? @"got session" : @"nil",
                          sessionOrError ? NSStringFromClass([sessionOrError class]) : @"");
                }
            );
        }
    } @catch (NSException *exception) {
        NSLog(@"[TouchSynthesizer] reinitializeSession exception (non-fatal): %@ - %@",
              exception.name, exception.reason);
    }
}

// MARK: - Enable Automation Mode
//
// CRITICAL: Only calls enableAutomationModeWithError: on the shared session.
// Do NOT call finishInitializationForUIAutomation, requestAutomationSession,
// _XCT_enableAutomationModeWithReply:, or exchangeCapabilities here —
// those KILL the automation overlay after a split second.

+ (void)enableAutomationModeWithCompletion:(void (^)(NSString *_Nullable info))completion {
    if (!sFrameworkLoaded || !cls_XCTRunnerDaemonSession) {
        completion(@"Framework or session class not loaded");
        return;
    }

    _installNonFatalAssertionHandler();
    NSMutableString *results = [NSMutableString new];
    NSLog(@"[TouchSynthesizer] Enabling automation mode (minimal)...");

    id session = nil;
    @try {
        session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
    } @catch (NSException *e) {
        completion([NSString stringWithFormat:@"sharedSession threw: %@", e.reason]);
        return;
    }
    if (!session) {
        completion(@"sharedSession returned nil");
        return;
    }

    // ONLY call enableAutomationModeWithError: — nothing else.
    {
        SEL sel = @selector(enableAutomationModeWithError:);
        if ([session respondsToSelector:sel]) {
            NSLog(@"[TouchSynthesizer] Calling enableAutomationModeWithError:...");
            @try {
                NSError *err = nil;
                typedef BOOL (*MsgSend_BOOL_err)(id, SEL, NSError **);
                BOOL result = ((MsgSend_BOOL_err)objc_msgSend)(session, sel, &err);
                if (err) {
                    NSLog(@"[TouchSynthesizer] enableAutomationMode error: %@", err.localizedDescription);
                    [results appendFormat:@"enableAutomationMode: ERROR %@\n", err.localizedDescription];
                } else {
                    NSLog(@"[TouchSynthesizer] enableAutomationMode returned: %@", result ? @"YES" : @"NO");
                    [results appendFormat:@"enableAutomationMode: %@\n", result ? @"YES" : @"NO"];
                }
            } @catch (NSException *e) {
                NSLog(@"[TouchSynthesizer] enableAutomationMode threw: %@", e.reason);
                [results appendFormat:@"enableAutomationMode threw: %@\n", e.reason];
            }
        } else {
            [results appendString:@"enableAutomationModeWithError: not available\n"];
        }
    }

    // Brief wait for the automation overlay to stabilize, then test synthesis
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        id proxy = nil;
        if ([session respondsToSelector:@selector(daemonProxy)]) {
            proxy = [session performSelector:@selector(daemonProxy)];
        }

        NSString *buildErr = nil;
        id record = [self _buildTapEventAtPoint:CGPointMake(195, 400) error:&buildErr];
        if (record && proxy) {
            SEL synthSel = @selector(_XCT_synthesizeEvent:completion:);
            if ([proxy respondsToSelector:synthSel]) {
                NSLog(@"[TouchSynthesizer] Post-enable test: sending tap via proxy...");
                ((MsgSend_void_id_id)objc_msgSend)(
                    proxy, synthSel, record,
                    ^(NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (error) {
                                [results appendFormat:@"Test synthesis: FAILED %@\n", error.localizedDescription];
                                NSLog(@"[TouchSynthesizer] Post-enable test FAILED: %@", error);
                            } else {
                                [results appendString:@"Test synthesis: SUCCEEDED!\n"];
                                NSLog(@"[TouchSynthesizer] Post-enable test SUCCEEDED!");
                                sLastPathUsed = @"daemonProxy";
                            }
                            completion(results);
                        });
                    }
                );
                return;
            }
        }

        completion(results);
    });
}

// MARK: - Public Touch Methods

+ (void)tapAtPoint:(CGPoint)point
        completion:(void (^)(NSString *_Nullable))completion {
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildTapEventAtPoint:point error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

+ (void)longPressAtPoint:(CGPoint)point
                duration:(NSTimeInterval)duration
              completion:(void (^)(NSString *_Nullable))completion {
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildLongPressEventAtPoint:point duration:duration error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

+ (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration
            completion:(void (^)(NSString *_Nullable))completion {
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildSwipeEventFrom:from to:to duration:duration error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Event Construction (XCSynthesizedEventRecord + XCPointerEventPath)

+ (nullable id)_createEventRecordWithName:(NSString *)name {
    id record = [cls_XCSynthesizedEventRecord alloc];
    SEL initSel = @selector(initWithName:interfaceOrientation:);
    if ([record respondsToSelector:initSel]) {
        record = ((MsgSend_id_id_long)objc_msgSend)(record, initSel, name, 1);
    } else {
        record = ((MsgSend_id_id)objc_msgSend)(record, @selector(initWithName:), name);
    }
    return record;
}

+ (nullable id)_buildTapEventAtPoint:(CGPoint)point error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"tap"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_CGPoint_double)objc_msgSend)(path, @selector(initForTouchAtPoint:offset:), point, 0.0);
    if (!path) { if (outError) *outError = @"Failed to create event path"; return nil; }

    ((MsgSend_void_double)objc_msgSend)(path, @selector(liftUpAtOffset:), 0.125);
    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    return record;
}

+ (nullable id)_buildLongPressEventAtPoint:(CGPoint)point duration:(NSTimeInterval)duration error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"long press"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_CGPoint_double)objc_msgSend)(path, @selector(initForTouchAtPoint:offset:), point, 0.0);
    if (!path) { if (outError) *outError = @"Failed to create event path"; return nil; }

    ((MsgSend_void_double)objc_msgSend)(path, @selector(liftUpAtOffset:), duration);
    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    return record;
}

+ (nullable id)_buildSwipeEventFrom:(CGPoint)from to:(CGPoint)to
                           duration:(NSTimeInterval)duration error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"swipe"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_CGPoint_double)objc_msgSend)(path, @selector(initForTouchAtPoint:offset:), from, 0.0);
    if (!path) { if (outError) *outError = @"Failed to create event path"; return nil; }

    // Interpolate intermediate points for a smooth swipe
    int steps = 10;
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        ((MsgSend_void_CGPoint_double)objc_msgSend)(path, @selector(moveToPoint:atOffset:), p, duration * t);
    }
    ((MsgSend_void_double)objc_msgSend)(path, @selector(liftUpAtOffset:), duration + 0.05);
    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    return record;
}

+ (nullable id)_buildPinchEventAtCenter:(CGPoint)center
                                 radius:(CGFloat)radius
                                  scale:(CGFloat)scale
                               duration:(NSTimeInterval)duration
                                  error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"pinch"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    CGFloat endRadius = radius * scale;
    CGPoint f1Start = CGPointMake(center.x, center.y - radius);
    CGPoint f1End   = CGPointMake(center.x, center.y - endRadius);
    CGPoint f2Start = CGPointMake(center.x, center.y + radius);
    CGPoint f2End   = CGPointMake(center.x, center.y + endRadius);

    // Finger 1
    id path1 = [cls_XCPointerEventPath alloc];
    path1 = ((MsgSend_id_CGPoint_double)objc_msgSend)(path1, @selector(initForTouchAtPoint:offset:), f1Start, 0.0);
    if (!path1) { if (outError) *outError = @"Failed to create path1"; return nil; }

    int steps = 10;
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        CGPoint p = CGPointMake(f1Start.x + (f1End.x - f1Start.x) * t,
                                f1Start.y + (f1End.y - f1Start.y) * t);
        ((MsgSend_void_CGPoint_double)objc_msgSend)(path1, @selector(moveToPoint:atOffset:), p, duration * t);
    }
    ((MsgSend_void_double)objc_msgSend)(path1, @selector(liftUpAtOffset:), duration + 0.05);

    // Finger 2
    id path2 = [cls_XCPointerEventPath alloc];
    path2 = ((MsgSend_id_CGPoint_double)objc_msgSend)(path2, @selector(initForTouchAtPoint:offset:), f2Start, 0.0);
    if (!path2) { if (outError) *outError = @"Failed to create path2"; return nil; }

    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        CGPoint p = CGPointMake(f2Start.x + (f2End.x - f2Start.x) * t,
                                f2Start.y + (f2End.y - f2Start.y) * t);
        ((MsgSend_void_CGPoint_double)objc_msgSend)(path2, @selector(moveToPoint:atOffset:), p, duration * t);
    }
    ((MsgSend_void_double)objc_msgSend)(path2, @selector(liftUpAtOffset:), duration + 0.05);

    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path1);
    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path2);
    return record;
}

+ (nullable id)_buildMultiFingerTapEventAtPoints:(NSArray<NSValue *> *)points
                                           error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"multi-finger tap"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    for (NSValue *val in points) {
        CGPoint point = [val CGPointValue];
        id path = [cls_XCPointerEventPath alloc];
        path = ((MsgSend_id_CGPoint_double)objc_msgSend)(path, @selector(initForTouchAtPoint:offset:), point, 0.0);
        if (!path) { if (outError) *outError = @"Failed to create event path"; return nil; }
        ((MsgSend_void_double)objc_msgSend)(path, @selector(liftUpAtOffset:), 0.125);
        ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    }
    return record;
}

+ (nullable id)_buildBezierSwipeEventFrom:(CGPoint)start
                            controlPoint1:(CGPoint)cp1
                            controlPoint2:(CGPoint)cp2
                                       to:(CGPoint)end
                                 duration:(NSTimeInterval)duration
                                    error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"bezier swipe"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_CGPoint_double)objc_msgSend)(path, @selector(initForTouchAtPoint:offset:), start, 0.0);
    if (!path) { if (outError) *outError = @"Failed to create event path"; return nil; }

    int steps = 20;
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        double u = 1.0 - t;
        double uu = u * u;
        double uuu = uu * u;
        double tt = t * t;
        double ttt = tt * t;
        CGPoint p = CGPointMake(
            uuu * start.x + 3.0 * uu * t * cp1.x + 3.0 * u * tt * cp2.x + ttt * end.x,
            uuu * start.y + 3.0 * uu * t * cp1.y + 3.0 * u * tt * cp2.y + ttt * end.y);
        ((MsgSend_void_CGPoint_double)objc_msgSend)(path, @selector(moveToPoint:atOffset:), p, duration * t);
    }
    ((MsgSend_void_double)objc_msgSend)(path, @selector(liftUpAtOffset:), duration + 0.05);
    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    return record;
}

+ (nullable id)_buildTypeTextEvent:(NSString *)text
                       typingSpeed:(NSInteger)speed
                             error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"type text"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_void)objc_msgSend)(path, @selector(initForTextInput));
    if (!path) { if (outError) *outError = @"Failed to create text input path"; return nil; }

    ((MsgSend_void_id_double_long_BOOL)objc_msgSend)(
        path, @selector(typeText:atOffset:typingSpeed:shouldRedact:),
        text, 0.0, (long)speed, NO);

    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    return record;
}

+ (nullable id)_buildTypeKeyEvent:(NSString *)key
                        modifiers:(NSUInteger)modifiers
                            error:(NSString **)outError {
    id record = [self _createEventRecordWithName:@"key combo"];
    if (!record) { if (outError) *outError = @"Failed to create event record"; return nil; }

    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_void)objc_msgSend)(path, @selector(initForTextInput));
    if (!path) { if (outError) *outError = @"Failed to create text input path"; return nil; }

    ((MsgSend_void_id_NSUInteger_double)objc_msgSend)(
        path, @selector(typeKey:modifiers:atOffset:),
        key, modifiers, 0.0);

    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    return record;
}

// MARK: - Synthesis Chain
//
// Synthesis priority (trying to avoid testmanagerd's ~5s quiescence wait):
//   1. record.synthesizeWithError: — synchronous, may bypass daemon entirely
//   2. XCUIDevice.eventSynthesizer.synthesizeEvent: — WDA's path
//   3. daemonProxy._XCT_synthesizeEvent: — fire-and-forget (5s quiescence, unavoidable)

+ (void)_synthesizeEvent:(id)record completion:(void (^)(NSString *_Nullable))completion {
    _installNonFatalAssertionHandler();

    // Path 1: record.synthesizeWithError: — synchronous, may bypass daemon
    @try {
        SEL synthSel = @selector(synthesizeWithError:);
        if ([record respondsToSelector:synthSel]) {
            NSError *error = nil;
            typedef BOOL (*MsgSend_BOOL_err)(id, SEL, NSError **);
            BOOL result = ((MsgSend_BOOL_err)objc_msgSend)(record, synthSel, &error);
            if (result && !error) {
                sLastPathUsed = @"record.synthesizeWithError";
                completion(nil);
                return;
            }
            NSLog(@"[TouchSynthesizer] Path 1 (synthesizeWithError:) failed: result=%d err=%@",
                  result, error ? error.localizedDescription : @"nil");
        }
    } @catch (NSException *e) {
        NSLog(@"[TouchSynthesizer] Path 1 exception: %@", e.reason);
    }

    // Path 2: XCUIDevice.eventSynthesizer — WDA's path
    if (cls_XCUIDevice) {
        @try {
            id device = [cls_XCUIDevice performSelector:@selector(sharedDevice)];
            if (device) {
                SEL esSel = @selector(eventSynthesizer);
                if ([device respondsToSelector:esSel]) {
                    id synthesizer = [device performSelector:esSel];
                    if (synthesizer) {
                        SEL synthSel = @selector(synthesizeEvent:completion:);
                        if ([synthesizer respondsToSelector:synthSel]) {
                            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                            ((MsgSend_void_id_id)objc_msgSend)(
                                synthesizer, synthSel, record,
                                ^(NSError *error) {
                                    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - t0;
                                    NSLog(@"[TouchSynthesizer] Path 2 (eventSynthesizer) completed: %.3fs err=%@",
                                          elapsed, error ? error.localizedDescription : @"nil");
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        sLastPathUsed = @"eventSynthesizer";
                                        completion(error ? error.localizedDescription : nil);
                                    });
                                }
                            );
                            return;
                        }
                    } else {
                        NSLog(@"[TouchSynthesizer] Path 2: eventSynthesizer is nil");
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[TouchSynthesizer] Path 2 exception: %@", e.reason);
        }
    }

    // Path 3: daemonProxy — fire-and-forget (5s quiescence unavoidable)
    if (cls_XCTRunnerDaemonSession) {
        @try {
            id session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
            if (session) {
                id proxy = nil;
                if ([session respondsToSelector:@selector(daemonProxy)]) {
                    proxy = [session performSelector:@selector(daemonProxy)];
                }
                if (proxy) {
                    SEL xctSel = @selector(_XCT_synthesizeEvent:completion:);
                    if ([proxy respondsToSelector:xctSel]) {
                        // Fire-and-forget: send event, don't wait for completion
                        ((MsgSend_void_id_id)objc_msgSend)(
                            proxy, xctSel, record,
                            ^(NSError *error) {
                                sLastPathUsed = @"daemonProxy";
                            }
                        );
                        completion(nil); // Return immediately
                        return;
                    }
                }

                // Fallback: session.synthesizeEvent
                if ([session respondsToSelector:@selector(synthesizeEvent:completion:)]) {
                    ((MsgSend_void_id_id)objc_msgSend)(
                        session, @selector(synthesizeEvent:completion:), record,
                        ^(NSError *error) {
                            sLastPathUsed = @"session";
                        }
                    );
                    completion(nil);
                    return;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[TouchSynthesizer] Path 3 exception: %@", e.reason);
        }
    }

    completion(@"No synthesis path available");
}

// MARK: - Pinch

+ (void)pinchAtCenter:(CGPoint)center
               radius:(CGFloat)radius
                scale:(CGFloat)scale
             duration:(NSTimeInterval)duration
           completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] pinch center=(%.0f,%.0f) radius=%.0f scale=%.2f", center.x, center.y, radius, scale);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildPinchEventAtCenter:center radius:radius scale:scale duration:duration error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Multi-Finger Tap

+ (void)multiFingerTapAtPoints:(NSArray<NSValue *> *)points
                    completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] multiFingerTap with %lu points", (unsigned long)points.count);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }
    if (points.count == 0) { completion(@"No points provided"); return; }

    NSString *err = nil;
    id record = [self _buildMultiFingerTapEventAtPoints:points error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Bezier Curve Swipe

+ (void)bezierSwipeFrom:(CGPoint)start
          controlPoint1:(CGPoint)cp1
          controlPoint2:(CGPoint)cp2
                     to:(CGPoint)end
               duration:(NSTimeInterval)duration
             completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] bezierSwipe (%.0f,%.0f)->(%.0f,%.0f)", start.x, start.y, end.x, end.y);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildBezierSwipeEventFrom:start controlPoint1:cp1 controlPoint2:cp2 to:end duration:duration error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Multi-Point Gesture (streamed touch)

+ (void)synthesizeMultiPointGestureWithPoints:(NSArray<NSValue *> *)points
                                      offsets:(NSArray<NSNumber *> *)offsets
                                     endPoint:(CGPoint)endPoint
                                   liftOffset:(NSTimeInterval)liftOffset
                                   completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] multiPointGesture: %lu points, duration=%.3f",
          (unsigned long)points.count, liftOffset);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }
    if (points.count == 0) { completion(@"No points"); return; }

    id record = [self _createEventRecordWithName:@"streamed gesture"];
    if (!record) { completion(@"Failed to create event record"); return; }

    // First point is the touch-down
    CGPoint startPt = [points[0] CGPointValue];
    id path = [cls_XCPointerEventPath alloc];
    path = ((MsgSend_id_CGPoint_double)objc_msgSend)(
        path, @selector(initForTouchAtPoint:offset:), startPt, 0.0);
    if (!path) { completion(@"Failed to create event path"); return; }

    // Add all subsequent points with their timing offsets
    for (NSUInteger i = 1; i < points.count; i++) {
        CGPoint pt = [points[i] CGPointValue];
        double offset = [offsets[i] doubleValue];
        ((MsgSend_void_CGPoint_double)objc_msgSend)(
            path, @selector(moveToPoint:atOffset:), pt, offset);
    }

    // Move to the final end point
    ((MsgSend_void_CGPoint_double)objc_msgSend)(
        path, @selector(moveToPoint:atOffset:), endPoint, liftOffset - 0.01);

    // Lift up
    ((MsgSend_void_double)objc_msgSend)(path, @selector(liftUpAtOffset:), liftOffset);

    ((MsgSend_void_id)objc_msgSend)(record, @selector(addPointerEventPath:), path);
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Keyboard Text Input

+ (void)typeText:(NSString *)text
     typingSpeed:(NSInteger)speed
      completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] typeText: '%@' speed=%ld", text, (long)speed);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildTypeTextEvent:text typingSpeed:speed error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Key Combos

+ (void)typeKey:(NSString *)key
      modifiers:(NSUInteger)modifiers
     completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] typeKey: '%@' modifiers=%lu", key, (unsigned long)modifiers);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }

    NSString *err = nil;
    id record = [self _buildTypeKeyEvent:key modifiers:modifiers error:&err];
    if (!record) { completion(err); return; }
    [self _synthesizeEvent:record completion:completion];
}

// MARK: - Hardware Buttons

+ (void)pressButton:(NSUInteger)button
         completion:(void (^)(NSString *_Nullable))completion {
    NSLog(@"[TouchSynthesizer] pressButton: %lu", (unsigned long)button);
    if (!sFrameworkLoaded) { completion(@"Not loaded"); return; }
    if (!cls_XCUIDevice) { completion(@"XCUIDevice not available"); return; }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        _installNonFatalAssertionHandler();
        @try {
            id device = [cls_XCUIDevice performSelector:@selector(sharedDevice)];
            if (!device) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(@"XCUIDevice.sharedDevice returned nil"); });
                return;
            }
            ((MsgSend_void_NSUInteger)objc_msgSend)(device, @selector(pressButton:), button);
            sLastPathUsed = @"XCUIDevice.pressButton";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([NSString stringWithFormat:@"pressButton threw: %@", e.reason]);
            });
        }
    });
}

// MARK: - Screenshot via XCTest Daemon Proxy
//
// Takes screenshots through the already-connected testmanagerd XPC session.
// Avoids creating a new CDTunnel per frame. Can request JPEG directly.

+ (void)takeScreenshotWithQuality:(CGFloat)quality
                       completion:(void (^)(NSData *_Nullable, NSString *_Nullable))completion {
    if (!sFrameworkLoaded || !cls_XCTRunnerDaemonSession) {
        completion(nil, @"Framework or session not loaded");
        return;
    }

    _installNonFatalAssertionHandler();

    @try {
        id session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
        if (!session) { completion(nil, @"No shared session"); return; }

        id proxy = nil;
        if ([session respondsToSelector:@selector(daemonProxy)]) {
            proxy = [session performSelector:@selector(daemonProxy)];
        }
        if (!proxy) { completion(nil, @"No daemon proxy"); return; }

        // Try the parameterized path first: _XCT_requestScreenshot:withReply:
        // This lets us specify JPEG encoding directly.
        SEL requestSel = @selector(_XCT_requestScreenshot:withReply:);
        if ([proxy respondsToSelector:requestSel]) {
            // Build XCTScreenshotRequest with JPEG encoding
            Class cls_Request = NSClassFromString(@"XCTScreenshotRequest");
            Class cls_Encoding = NSClassFromString(@"XCTImageEncoding");

            if (cls_Request && cls_Encoding) {
                // Create encoding: JPEG at specified quality
                id encoding = nil;
                SEL encInitSel = @selector(initWithUniformTypeIdentifier:compressionQuality:);
                if ([cls_Encoding instancesRespondToSelector:encInitSel]) {
                    encoding = [cls_Encoding alloc];
                    typedef id (*MsgSend_id_id_CGFloat)(id, SEL, id, CGFloat);
                    encoding = ((MsgSend_id_id_CGFloat)objc_msgSend)(
                        encoding, encInitSel, @"public.jpeg", quality);
                }

                if (encoding) {
                    // Create request: screen 1 (main), full rect, JPEG encoding
                    id request = nil;
                    // Try initWithScreenID:rect:encoding:
                    SEL reqInitSel = @selector(initWithScreenID:rect:encoding:);
                    if ([cls_Request instancesRespondToSelector:reqInitSel]) {
                        request = [cls_Request alloc];
                        typedef id (*MsgSend_id_long_CGRect_id)(id, SEL, long, CGRect, id);
                        request = ((MsgSend_id_long_CGRect_id)objc_msgSend)(
                            request, reqInitSel, 1, CGRectNull, encoding);
                    }
                    // Fallback: try initWithEncoding:
                    if (!request) {
                        SEL reqInit2 = @selector(initWithEncoding:);
                        if ([cls_Request instancesRespondToSelector:reqInit2]) {
                            request = [cls_Request alloc];
                            request = ((MsgSend_id_id)objc_msgSend)(request, reqInit2, encoding);
                        }
                    }

                    if (request) {
                        // Call _XCT_requestScreenshot:withReply:
                        typedef void (*MsgSend_void_id_block)(id, SEL, id, void(^)(id, NSError *));
                        ((MsgSend_void_id_block)objc_msgSend)(
                            proxy, requestSel, request,
                            ^(id image, NSError *error) {
                                if (error || !image) {
                                    completion(nil, error ? error.localizedDescription : @"No image returned");
                                    return;
                                }
                                // Extract data from XCTImage
                                NSData *data = nil;
                                if ([image respondsToSelector:@selector(data)]) {
                                    data = [image performSelector:@selector(data)];
                                } else if ([image isKindOfClass:[NSData class]]) {
                                    data = (NSData *)image;
                                }
                                if (data) {
                                    completion(data, nil);
                                } else {
                                    completion(nil, @"Could not extract image data");
                                }
                            }
                        );
                        return;
                    }
                }
            }
        }

        // Fallback: simple _XCT_requestScreenshotWithReply: (no encoding params)
        SEL simpleSel = @selector(_XCT_requestScreenshotWithReply:);
        if ([proxy respondsToSelector:simpleSel]) {
            typedef void (*MsgSend_void_block)(id, SEL, void(^)(id, NSError *));
            ((MsgSend_void_block)objc_msgSend)(
                proxy, simpleSel,
                ^(id image, NSError *error) {
                    if (error || !image) {
                        completion(nil, error ? error.localizedDescription : @"No image (simple path)");
                        return;
                    }
                    NSData *data = nil;
                    if ([image respondsToSelector:@selector(data)]) {
                        data = [image performSelector:@selector(data)];
                    } else if ([image respondsToSelector:@selector(pngRepresentation)]) {
                        data = [image performSelector:@selector(pngRepresentation)];
                    } else if ([image isKindOfClass:[NSData class]]) {
                        data = (NSData *)image;
                    }
                    if (data) {
                        completion(data, nil);
                    } else {
                        // Log what we got back for debugging
                        NSLog(@"[TouchSynthesizer] Screenshot reply class: %@, responds data=%d pngRep=%d",
                              NSStringFromClass([image class]),
                              [image respondsToSelector:@selector(data)],
                              [image respondsToSelector:@selector(pngRepresentation)]);
                        completion(nil, [NSString stringWithFormat:@"Unknown image type: %@",
                                        NSStringFromClass([image class])]);
                    }
                }
            );
            return;
        }

        completion(nil, @"No screenshot method available on daemon proxy");

    } @catch (NSException *e) {
        completion(nil, [NSString stringWithFormat:@"Screenshot exception: %@", e.reason]);
    }
}

// MARK: - IOKit HID Bundle ID Spoofing

static BOOL sBundleIDSwizzled = NO;
static IMP sOriginalBundleIdentifierIMP = NULL;

static NSString *_spoofedBundleIdentifier(id self, SEL _cmd) {
    return @"com.apple.springboard";
}

+ (void)_installBundleIDSpoof {
    if (sBundleIDSwizzled) return;
    sBundleIDSwizzled = YES;

    Method m = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
    if (m) {
        sOriginalBundleIdentifierIMP = method_getImplementation(m);
        method_setImplementation(m, (IMP)_spoofedBundleIdentifier);
        NSLog(@"[HID] Bundle ID spoofed to com.apple.springboard");
        NSLog(@"[HID] Verify: mainBundle.bundleIdentifier = %@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}

+ (void)_removeBundleIDSpoof {
    if (!sBundleIDSwizzled || !sOriginalBundleIdentifierIMP) return;

    Method m = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
    if (m) {
        method_setImplementation(m, sOriginalBundleIdentifierIMP);
        sOriginalBundleIdentifierIMP = NULL;
        sBundleIDSwizzled = NO;
        NSLog(@"[HID] Bundle ID spoof removed, restored: %@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}

// MARK: - IOKit HID Status

+ (NSString *)hidStatus {
    NSMutableString *status = [NSMutableString string];
    [status appendFormat:@"IOKit handle: %@\n", sIOKitHandle ? @"loaded" : @"not loaded"];
    [status appendFormat:@"HID client: %@\n", sHIDClient ? [NSString stringWithFormat:@"%p", sHIDClient] : @"NULL"];
    [status appendFormat:@"HID system: %@\n", sHIDSystem ? [NSString stringWithFormat:@"%p", sHIDSystem] : @"NULL"];
    [status appendFormat:@"FingerEvent fn: %@\n", p_FingerEvent ? @"found" : @"missing"];
    [status appendFormat:@"DigitizerEvent fn: %@\n", p_DigitizerEvent ? @"found" : @"missing"];
    [status appendFormat:@"ClientDispatch fn: %@\n", p_ClientDispatch ? @"found" : @"missing"];
    [status appendFormat:@"SysDispatch fn: %@\n", p_SysDispatch ? @"found" : @"missing"];
    [status appendFormat:@"SetInteger fn: %@\n", p_SetInteger ? @"found" : @"missing"];
    [status appendFormat:@"SetSenderID fn: %@\n", p_SetSenderID ? @"found" : @"missing"];
    [status appendFormat:@"Bundle ID swizzled: %@", sBundleIDSwizzled ? @"YES" : @"NO"];
    return status;
}

// MARK: - IOKit HID Loading

+ (BOOL)_loadIOKit {
    if (sIOKitHandle && sHIDClient) return YES;

    // Spoof bundle ID to com.apple.springboard before IOKit init
    [self _installBundleIDSpoof];

    NSLog(@"[HID] Loading IOKit.framework (bundleID=%@)...", [[NSBundle mainBundle] bundleIdentifier]);
    sIOKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!sIOKitHandle) {
        NSLog(@"[HID] Failed to load IOKit: %s", dlerror());
        return NO;
    }

    p_ClientCreate   = (fn_HIDClientCreate)dlsym(sIOKitHandle, "IOHIDEventSystemClientCreate");
    p_ClientDispatch  = (fn_HIDClientDispatch)dlsym(sIOKitHandle, "IOHIDEventSystemClientDispatchEvent");
    p_FingerEvent     = (fn_HIDCreateDigitizerFingerEvent)dlsym(sIOKitHandle, "IOHIDEventCreateDigitizerFingerEvent");
    p_DigitizerEvent  = (fn_HIDCreateDigitizerEvent)dlsym(sIOKitHandle, "IOHIDEventCreateDigitizerEvent");
    p_SetInteger      = (fn_HIDSetIntegerValue)dlsym(sIOKitHandle, "IOHIDEventSetIntegerValue");
    p_AppendEvent     = (fn_HIDAppendEvent)dlsym(sIOKitHandle, "IOHIDEventAppendEvent");
    p_SetSenderID     = (fn_HIDSetSenderID)dlsym(sIOKitHandle, "IOHIDEventSetSenderID");

    if (!p_ClientCreate || !p_ClientDispatch) {
        NSLog(@"[HID] Missing critical IOKit symbols");
        return NO;
    }

    if (!p_FingerEvent && !p_DigitizerEvent) {
        NSLog(@"[HID] No digitizer event creation function");
        return NO;
    }

    sHIDClient = p_ClientCreate(kCFAllocatorDefault);
    if (!sHIDClient) {
        NSLog(@"[HID] IOHIDEventSystemClientCreate returned NULL");
        return NO;
    }

    NSLog(@"[HID] HID system client created: %p", sHIDClient);

    // Also try IOHIDEventSystem (system-level dispatch)
    p_SysCreate = (fn_HIDEventSystemCreate)dlsym(sIOKitHandle, "IOHIDEventSystemCreate");
    p_SysDispatch = (fn_HIDEventSystemDispatch)dlsym(sIOKitHandle, "IOHIDEventSystemDispatchEvent");
    if (p_SysCreate) {
        @try {
            sHIDSystem = p_SysCreate(kCFAllocatorDefault);
            NSLog(@"[HID] IOHIDEventSystem created: %p", sHIDSystem);
        } @catch (NSException *e) {
            NSLog(@"[HID] IOHIDEventSystemCreate threw: %@", e);
        }
    }

    // Restore real bundle ID now that IOKit is initialized
    [self _removeBundleIDSpoof];

    NSLog(@"[HID] Load complete. client=%p system=%p", sHIDClient, sHIDSystem);
    return YES;
}

// MARK: - IOKit HID Event Dispatch

+ (BOOL)_dispatchFingerAtPoint:(CGPoint)point
                       touching:(BOOL)touching
                        inRange:(BOOL)inRange
                          error:(NSString **)outError {
    if (!sHIDClient) {
        if (outError) *outError = @"HID client not initialized";
        return NO;
    }

    uint64_t ts = mach_absolute_time();

    // iPhone 13 Pro: 390x844 points — IOKit HID uses normalized [0.0, 1.0]
    CGFloat screenW = 390.0;
    CGFloat screenH = 844.0;
    CGFloat nx = fmin(fmax(point.x / screenW, 0.0), 1.0);
    CGFloat ny = fmin(fmax(point.y / screenH, 0.0), 1.0);

    uint32_t eventMask = kHIDDigitizerEventPosition;
    if (touching) eventMask |= kHIDDigitizerEventTouch;
    eventMask |= kHIDDigitizerEventRange;

    CGFloat pressure = touching ? 1.0 : 0.0;
    IOHIDEventRef event = NULL;

    if (p_FingerEvent) {
        event = p_FingerEvent(
            kCFAllocatorDefault, ts,
            0, 2, eventMask,         // index, identity, mask
            nx, ny, 0.0,             // x, y, z (normalized)
            pressure, 0.0,           // tipPressure, twist
            inRange, touching, 0);
    } else if (p_DigitizerEvent) {
        event = p_DigitizerEvent(
            kCFAllocatorDefault, ts,
            kHIDDigitizerTransducerFinger,
            0, 2, eventMask, 0,      // index, identity, mask, buttonMask
            nx, ny, 0.0,             // x, y, z
            pressure, 0.0,           // tipPressure, barrelPressure
            inRange, touching, 0);
    }

    if (!event) {
        if (outError) *outError = @"Failed to create IOHIDEvent";
        return NO;
    }

    // Mark as built-in touchscreen
    if (p_SetInteger) {
        p_SetInteger(event, kHIDFieldDigitizerIsDisplayIntegrated, 1);
        p_SetInteger(event, kHIDFieldDigitizerIsBuiltIn, 1);
    }
    if (p_SetSenderID) {
        p_SetSenderID(event, 0xDEFACEDBEEFCAFE);
    }

    BOOL dispatched = NO;

    // Try IOHIDEventSystem first (system-level), then client
    if (sHIDSystem && p_SysDispatch) {
        @try {
            p_SysDispatch(sHIDSystem, event);
            dispatched = YES;
        } @catch (NSException *e) {
            NSLog(@"[HID] EventSystem dispatch threw: %@", e.reason);
        }
    }
    if (!dispatched && sHIDClient && p_ClientDispatch) {
        @try {
            p_ClientDispatch(sHIDClient, event);
            dispatched = YES;
        } @catch (NSException *e) {
            NSLog(@"[HID] Client dispatch threw: %@", e.reason);
        }
    }

    CFRelease(event);

    if (!dispatched) {
        if (outError) *outError = @"No dispatch path succeeded";
        return NO;
    }
    return YES;
}

// MARK: - HID Single-Phase Dispatch (for real-time streaming)

+ (BOOL)hidDispatchFingerAtPoint:(CGPoint)point
                        touching:(BOOL)touching
                         inRange:(BOOL)inRange {
    if (![self _loadIOKit]) return NO;
    return [self _dispatchFingerAtPoint:point touching:touching inRange:inRange error:nil];
}

// MARK: - HID Tap

+ (void)hidTapAtPoint:(CGPoint)point
           completion:(void (^)(NSString *_Nullable error))completion {
    NSLog(@"[HID] Tap at (%.1f, %.1f)...", point.x, point.y);

    if (![self _loadIOKit]) {
        completion(@"Failed to load IOKit HID");
        return;
    }

    NSString *err = nil;
    if (![self _dispatchFingerAtPoint:point touching:YES inRange:YES error:&err]) {
        completion([NSString stringWithFormat:@"Touch down failed: %@", err]);
        return;
    }

    // Brief hold then lift
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        NSString *upErr = nil;
        if (![self _dispatchFingerAtPoint:point touching:NO inRange:NO error:&upErr]) {
            completion([NSString stringWithFormat:@"Touch up failed: %@", upErr]);
            return;
        }
        sLastPathUsed = @"IOKit-HID";
        completion(nil);
    });
}

// MARK: - HID Swipe

+ (void)hidSwipeFromPoint:(CGPoint)from
                  toPoint:(CGPoint)to
                 duration:(NSTimeInterval)duration
               completion:(void (^)(NSString *_Nullable error))completion {
    NSLog(@"[HID] Swipe from (%.1f, %.1f) to (%.1f, %.1f) over %.2fs...",
          from.x, from.y, to.x, to.y, duration);

    if (![self _loadIOKit]) {
        completion(@"Failed to load IOKit HID");
        return;
    }

    // Touch down at start
    NSString *err = nil;
    if (![self _dispatchFingerAtPoint:from touching:YES inRange:YES error:&err]) {
        completion([NSString stringWithFormat:@"Swipe start failed: %@", err]);
        return;
    }

    // Interpolate points on a background queue
    int steps = 20;
    NSTimeInterval stepDelay = duration / (NSTimeInterval)steps;

    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    dispatch_async(q, ^{
        for (int i = 1; i <= steps; i++) {
            double t = (double)i / (double)steps;
            CGPoint p = CGPointMake(
                from.x + (to.x - from.x) * t,
                from.y + (to.y - from.y) * t
            );
            [self _dispatchFingerAtPoint:p touching:YES inRange:YES error:nil];
            [NSThread sleepForTimeInterval:stepDelay];
        }

        // Lift at end
        NSString *upErr = nil;
        [self _dispatchFingerAtPoint:to touching:NO inRange:NO error:&upErr];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (upErr) {
                completion([NSString stringWithFormat:@"Swipe end failed: %@", upErr]);
            } else {
                sLastPathUsed = @"IOKit-HID";
                completion(nil);
            }
        });
    });
}

@end
