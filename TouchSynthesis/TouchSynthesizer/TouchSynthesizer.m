#import "TouchSynthesizer.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <mach/mach.h>

// ============================================================
// Touch event synthesis via XCTest private API + IOKit HID.
//
// Synthesis chain (tried in order):
//   1. daemonProxy._XCT_synthesizeEvent:completion:
//      System-level synthesis via testmanagerd XPC proxy.
//      Works across all apps. Preferred path.
//
//   2. session.synthesizeEvent:completion:
//      XCTRunnerDaemonSession wrapper. May silently drop events
//      if automation mode isn't active.
//
//   3. XCUIDevice.eventSynthesizer (app-level, last resort)
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
    return nil;
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
    NSLog(@"[TouchSynthesizer] tapAtPoint:(%.0f, %.0f)", point.x, point.y);
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
    NSLog(@"[TouchSynthesizer] swipe (%.0f,%.0f)->(%.0f,%.0f)", from.x, from.y, to.x, to.y);
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

// MARK: - Synthesis Chain (daemonProxy → session → eventSynthesizer)

+ (void)_synthesizeEvent:(id)record completion:(void (^)(NSString *_Nullable))completion {
    _installNonFatalAssertionHandler();
    [self _tryDaemonProxy:record completion:completion];
}

/// Path 1: daemonProxy._XCT_synthesizeEvent:completion: (system-level, preferred)
+ (void)_tryDaemonProxy:(id)record completion:(void (^)(NSString *_Nullable))completion {
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
                        ((MsgSend_void_id_id)objc_msgSend)(
                            proxy, xctSel, record,
                            ^(NSError *error) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (error) {
                                        [self _trySessionSynthesize:record completion:completion];
                                    } else {
                                        sLastPathUsed = @"daemonProxy";
                                        completion(nil);
                                    }
                                });
                            }
                        );
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[TouchSynthesizer] daemonProxy exception: %@", e.reason);
        }
    }
    [self _trySessionSynthesize:record completion:completion];
}

/// Path 2: session.synthesizeEvent:completion: (XCTRunnerDaemonSession wrapper)
+ (void)_trySessionSynthesize:(id)record completion:(void (^)(NSString *_Nullable))completion {
    if (cls_XCTRunnerDaemonSession) {
        @try {
            id session = [cls_XCTRunnerDaemonSession performSelector:@selector(sharedSession)];
            if (session) {
                ((MsgSend_void_id_id)objc_msgSend)(
                    session, @selector(synthesizeEvent:completion:), record,
                    ^(NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (error) {
                                [self _tryEventSynthesizer:record completion:completion];
                            } else {
                                sLastPathUsed = @"session.synthesizeEvent";
                                completion(nil);
                            }
                        });
                    }
                );
                return;
            }
        } @catch (NSException *e) {
            NSLog(@"[TouchSynthesizer] session.synthesize exception: %@", e.reason);
        }
    }
    [self _tryEventSynthesizer:record completion:completion];
}

/// Path 3: XCUIDevice.eventSynthesizer (app-level, last resort)
+ (void)_tryEventSynthesizer:(id)record completion:(void (^)(NSString *_Nullable))completion {
    if (cls_XCUIDevice) {
        @try {
            id device = [cls_XCUIDevice performSelector:@selector(sharedDevice)];
            if (device) {
                SEL esSel = @selector(eventSynthesizer);
                if ([device respondsToSelector:esSel]) {
                    id synthesizer = [device performSelector:esSel];
                    if (synthesizer) {
                        ((MsgSend_void_id_id)objc_msgSend)(
                            synthesizer, @selector(synthesizeEvent:completion:), record,
                            ^(NSError *error) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (error) {
                                        completion([NSString stringWithFormat:@"All paths failed: %@", error.localizedDescription]);
                                    } else {
                                        sLastPathUsed = @"eventSynthesizer";
                                        completion(nil);
                                    }
                                });
                            }
                        );
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[TouchSynthesizer] eventSynthesizer exception: %@", e.reason);
        }
    }
    completion(@"No synthesis path available");
}

// MARK: - IOKit HID Loading

+ (BOOL)_loadIOKit {
    if (sIOKitHandle && sHIDClient) return YES;

    NSLog(@"[HID] Loading IOKit.framework...");
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
