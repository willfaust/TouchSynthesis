#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result object from the tunnel + RSD discovery flow
@interface TunnelServiceInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t port;
@end

/// Wraps the idevice FFI to talk to the device.
///
/// Architecture (matching StikDebug):
/// - A lockdownd heartbeat (marco/polo) runs permanently to keep the connection alive.
/// - Each operation creates a FRESH CDTunnel, does its work, and tears it down.
/// - The CDTunnel is NOT kept alive between operations.
@interface IdeviceTunnel : NSObject

/// Whether the heartbeat is connected and we're ready for operations.
@property (nonatomic, readonly) BOOL isConnected;

/// Whether the heartbeat is currently running.
@property (nonatomic, readonly) BOOL heartbeatRunning;

/// Connect: reads pairing file, starts lockdownd heartbeat.
/// This blocks — call from a background thread.
/// Returns nil on success, or an error string on failure.
- (nullable NSString *)connectWithPairingFile:(NSString *)pairingFilePath
                                     deviceIP:(NSString *)deviceIP
                                         port:(uint16_t)port;

/// Take a screenshot via RemoteServer + ScreenshotClient.
/// Returns PNG data on success, or nil on failure (check error).
- (nullable NSData *)takeScreenshotAndReturnError:(NSString *_Nullable *_Nullable)outError;

/// Create a local TCP proxy that bridges to an RSD service via the CDTunnel.
/// DTXConnection (or any TCP client) can connect to 127.0.0.1:<returned port>.
/// The proxy runs in background threads until stopped.
/// Returns the local port on success, or 0 on failure.
- (uint16_t)createProxyToRSDService:(NSString *)serviceName
                              error:(NSString *_Nullable *_Nullable)outError;

/// Stop all running proxies and free their resources.
- (void)stopAllProxies;

/// Lightweight check: creates a fresh CDTunnel and tears it down.
/// Returns YES if the device is reachable, NO otherwise.
- (BOOL)pingTunnel;

/// Disconnect and clean up (stops heartbeat, stops proxies).
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
