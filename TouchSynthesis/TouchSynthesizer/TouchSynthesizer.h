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

// MARK: - Pinch (Zoom In/Out)

/// Pinch gesture centered at a point. scale > 1.0 = zoom in, < 1.0 = zoom out.
+ (void)pinchAtCenter:(CGPoint)center
               radius:(CGFloat)radius
                scale:(CGFloat)scale
             duration:(NSTimeInterval)duration
           completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - Multi-Finger Tap

/// Tap with multiple fingers simultaneously. Points are NSValue-wrapped CGPoints.
+ (void)multiFingerTapAtPoints:(NSArray<NSValue *> *)points
                    completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - Bezier Curve Swipe

/// Swipe along a cubic bezier curve.
+ (void)bezierSwipeFrom:(CGPoint)start
          controlPoint1:(CGPoint)cp1
          controlPoint2:(CGPoint)cp2
                     to:(CGPoint)end
               duration:(NSTimeInterval)duration
             completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - Keyboard Text Input

/// Type text. Requires a text field to be focused.
+ (void)typeText:(NSString *)text
     typingSpeed:(NSInteger)speed
      completion:(void (^)(NSString *_Nullable error))completion;

/// Press a key combination (e.g. Cmd+A). Modifiers: Caps=1, Shift=2, Ctrl=4, Alt=8, Cmd=16.
+ (void)typeKey:(NSString *)key
      modifiers:(NSUInteger)modifiers
     completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - Hardware Buttons

/// Press a hardware button. 1=Home, 2=VolumeUp, 3=VolumeDown.
+ (void)pressButton:(NSUInteger)button
         completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - Multi-Point Gesture (streamed touch)

/// Synthesize a gesture from accumulated streamed touch points.
/// Each point has a corresponding time offset from the gesture start.
+ (void)synthesizeMultiPointGestureWithPoints:(NSArray<NSValue *> *)points
                                      offsets:(NSArray<NSNumber *> *)offsets
                                     endPoint:(CGPoint)endPoint
                                   liftOffset:(NSTimeInterval)liftOffset
                                   completion:(void (^)(NSString *_Nullable error))completion;

// MARK: - Screenshot via XCTest Daemon Proxy

/// Take a screenshot via testmanagerd XPC (reuses existing daemon session).
/// Much faster than CDTunnel — no tunnel creation per frame.
/// Returns JPEG data at the specified quality, or nil on error.
/// Completion called on the calling thread/queue.
+ (void)takeScreenshotWithQuality:(CGFloat)quality
                       completion:(void (^)(NSData *_Nullable jpegData, NSString *_Nullable error))completion;

// MARK: - IOKit HID Fallback

/// Returns a diagnostic string describing IOKit HID state (client, system, symbols loaded).
+ (NSString *)hidStatus;

/// Dispatch a single finger event via IOKit HID. For real-time streaming.
/// Returns YES on success. Loads IOKit lazily on first call.
+ (BOOL)hidDispatchFingerAtPoint:(CGPoint)point
                        touching:(BOOL)touching
                         inRange:(BOOL)inRange;

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
