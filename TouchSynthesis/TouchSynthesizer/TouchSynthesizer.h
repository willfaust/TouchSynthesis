#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads XCTest.framework via dlopen and synthesizes touch events
/// using XCSynthesizedEventRecord + XCTRunnerDaemonSession.
///
/// Requires DDI to be mounted (XCTest.framework lives in /System/Developer/).
///
/// Synthesis priority:
///   1. daemonProxy._XCT_synthesizeEvent:completion: (system-level, works across all apps)
///   2. session.synthesizeEvent:completion: (fallback)
///   3. IOKit HID (last resort, doesn't actually deliver system touches)
@interface TouchSynthesizer : NSObject

/// Whether XCTest.framework has been loaded.
@property (class, nonatomic, readonly) BOOL isLoaded;

/// Whether the daemon session is available for event synthesis.
@property (class, nonatomic, readonly) BOOL isDaemonSessionAvailable;

/// Which synthesis path was last used (for diagnostics).
@property (class, nonatomic, readonly) NSString *lastPathUsed;

/// Load XCTest.framework via dlopen.
/// Returns nil on success, or an error string on failure.
+ (nullable NSString *)loadFramework;

/// Re-initialize the daemon session (XPC to testmanagerd.runner).
/// Call after setting XCTestSessionIdentifier env var and loading the framework.
+ (void)reinitializeSession;

/// Enable automation mode. Call AFTER loadFramework and reinitializeSession.
/// ONLY calls enableAutomationModeWithError: — calling any other initialization
/// methods (finishInitializationForUIAutomation, requestAutomationSession, etc.)
/// KILLS the automation overlay.
/// Completion called on main thread with nil on success, or an info string.
+ (void)enableAutomationModeWithCompletion:(void (^)(NSString *_Nullable info))completion;

// MARK: - Touch Synthesis (XCTest daemon proxy chain)

/// Tap at a point. Completion called on main thread with nil on success, or error string.
+ (void)tapAtPoint:(CGPoint)point
        completion:(void (^)(NSString *_Nullable error))completion;

/// Long press at a point.
+ (void)longPressAtPoint:(CGPoint)point
                duration:(NSTimeInterval)duration
              completion:(void (^)(NSString *_Nullable error))completion;

/// Swipe from one point to another.
+ (void)swipeFromPoint:(CGPoint)from
               toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration
            completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - IOKit HID Fallback

/// Inject a tap via IOKit HID (bypasses XCTest/testmanagerd).
+ (void)hidTapAtPoint:(CGPoint)point
           completion:(void (^)(NSString *_Nullable error))completion;

/// Inject a swipe via IOKit HID.
+ (void)hidSwipeFromPoint:(CGPoint)from
                  toPoint:(CGPoint)to
                 duration:(NSTimeInterval)duration
               completion:(void (^)(NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
