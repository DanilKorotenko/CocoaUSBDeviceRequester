#import <Cocoa/Cocoa.h>

@interface USBDeviceRequesterAppDelegate : NSObject <NSApplicationDelegate>
{
	io_iterator_t			gNewDeviceAddedIter;
	io_iterator_t			gNewDeviceRemovedIter;
	IONotificationPortRef		gNotifyPort;
	CFMutableDictionaryRef		classToMatch;
}

@end
