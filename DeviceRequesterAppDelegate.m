//
//  Controller.m
//  DFUTool
//
//  Copyright 2010 caiaq. All rights reserved.
//

#include <IOKit/IOKitLib.h>
#include <IOKit/IODataQueueShared.h>
#include <IOKit/IODataQueueClient.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#include <pthread.h>
#include <mach/mach_port.h>

#import <CoreFoundation/CFMachPort.h>
#import <CoreFoundation/CFNumber.h>
#import <CoreFoundation/CoreFoundation.h>

__BEGIN_DECLS
#include <mach/mach.h>
#include <IOKit/iokitmig.h>
__END_DECLS

#import "DeviceRequesterAppDelegate.h"

@implementation UAC2MemoryAccessAppDelegate

@synthesize window;
@synthesize deviceTable;
@synthesize deviceVID;
@synthesize devicePID;
@synthesize requestType;
@synthesize requestRecipient;
@synthesize bRequest;
@synthesize wValue;
@synthesize wIndex;
@synthesize memData;
@synthesize requestBox;
@synthesize setButton;
@synthesize getButton;
@synthesize dataSize;

#pragma mark ######### static wrappers #########

static void 
staticDeviceAdded (void *refCon, io_iterator_t iterator)
{
	UAC2MemoryAccessAppDelegate *del = refCon;
	
	if (del)
		[del deviceAdded : iterator];
}

static void 
staticDeviceRemoved (void *refCon, io_iterator_t iterator)
{
	UAC2MemoryAccessAppDelegate *del = refCon;
	
	if (del)
		[del deviceRemoved : iterator];
}

#pragma mark ######### hotplug callbacks #########

- (void) deviceAdded: (io_iterator_t) iterator
{
	io_service_t		serviceObject;
	IOCFPlugInInterface	**plugInInterface = NULL;
	IOUSBDeviceInterface	**dev = NULL;
	SInt32			score;
	kern_return_t		kr;
	HRESULT			result;
	CFMutableDictionaryRef	entryProperties = NULL;
	
	while ((serviceObject = IOIteratorNext(iterator))) {
		printf("factory: device added %d.\n", (int) serviceObject);
		IORegistryEntryCreateCFProperties(serviceObject, &entryProperties, NULL, 0);
		
		kr = IOCreatePlugInInterfaceForService(serviceObject,
						       kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
						       &plugInInterface, &score);
		
		if ((kr != kIOReturnSuccess) || !plugInInterface) {
			printf("Unable to create a plug-in (%08x)\n", kr);
			continue;
		}
		
		// create the device interface
		result = (*plugInInterface)->QueryInterface(plugInInterface,
							    CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
							    (LPVOID *)&dev);
		
		// don’t need the intermediate plug-in after device interface is created
		(*plugInInterface)->Release(plugInInterface);
		
		if (result || !dev) {
			printf("Couldn’t create a device interface (%08x)\n", (int) result);
			continue;
		}
		
		NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity: 0];
		
		UInt16 vendorID, productID;
		(*dev)->GetDeviceVendor(dev, &vendorID);
		(*dev)->GetDeviceProduct(dev, &productID);
		
		printf(" *dev = %p\n", *dev);
		
		[dict setObject: [NSString stringWithFormat: @"0x%04x", vendorID]
			 forKey: @"VID"];
		[dict setObject: [NSString stringWithFormat: @"0x%04x", productID]
			 forKey: @"PID"];
		[dict setObject: [NSString stringWithString: CFDictionaryGetValue(entryProperties, CFSTR(kUSBProductString))]
			 forKey: @"name"];
		[dict setObject: [NSValue valueWithPointer: dev]
			 forKey: @"dev"];
		[dict setObject: [NSNumber numberWithInt: serviceObject]
			 forKey: @"service"];
		
		[deviceArray addObject: dict];
	}
	
	[deviceTable reloadData];
}

- (void) deviceRemoved: (io_iterator_t) iterator
{
	io_service_t serviceObject;
	
	while ((serviceObject = IOIteratorNext(iterator))) {
		NSEnumerator *enumerator = [deviceArray objectEnumerator];
		printf("%s(): device removed %d.\n", __func__, (int) serviceObject);
		NSDictionary *dict;
		
		while (dict = [enumerator nextObject]) {
			if ((io_service_t) [[dict valueForKey: @"service"] intValue] == serviceObject) {
				[deviceArray removeObject: dict];
				break;
			}
		}
		
		IOObjectRelease(serviceObject);
	}
	
	[deviceTable reloadData];
	
	if ([deviceTable selectedRow] < 0)
		[self setDeviceEnabled: NO];	
}

#pragma mark ######### GUI related #########

- (void) listenForDevices
{
	OSStatus ret;
	CFRunLoopSourceRef runLoopSource;
	mach_port_t masterPort;
	kern_return_t kernResult;
	
	deviceArray = [[NSMutableArray alloc] initWithCapacity: 0];
	
	// Returns the mach port used to initiate communication with IOKit.
	kernResult = IOMasterPort(MACH_PORT_NULL, &masterPort);
	
	if (kernResult != kIOReturnSuccess) {
		printf("%s(): IOMasterPort() returned %08x\n", __func__, kernResult);
		return;
	}
	
	classToMatch = IOServiceMatching(kIOUSBDeviceClassName);
	if (!classToMatch) {
		printf("%s(): IOServiceMatching returned a NULL dictionary.\n", __func__);
		return;
	}
	
	// increase the reference count by 1 since die dict is used twice.
	CFRetain(classToMatch);
	
	gNotifyPort = IONotificationPortCreate(masterPort);
	runLoopSource = IONotificationPortGetRunLoopSource(gNotifyPort);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopDefaultMode);
	
	ret = IOServiceAddMatchingNotification(gNotifyPort,
					       kIOFirstMatchNotification,
					       classToMatch,
					       staticDeviceAdded,
					       self,
					       &gNewDeviceAddedIter);
	
	// Iterate once to get already-present devices and arm the notification
	[self deviceAdded: gNewDeviceAddedIter];
	
	ret = IOServiceAddMatchingNotification(gNotifyPort,
					       kIOTerminatedNotification,
					       classToMatch,
					       staticDeviceRemoved,
					       self,
					       &gNewDeviceRemovedIter);
	
	// Iterate once to get already-present devices and arm the notification
	[self deviceRemoved : gNewDeviceRemovedIter];
	
	// done with the masterport
	mach_port_deallocate(mach_task_self(), masterPort);
}

#pragma mark ######### table view data source protocol ############

- (void)tableView:(NSTableView *)aTableView
   setObjectValue:obj
   forTableColumn:(NSTableColumn *)col
	      row:(NSInteger)rowIndex
{
}

- (id)tableView:(NSTableView *)aTableView
objectValueForTableColumn:(NSTableColumn *)col
	    row:(NSInteger)rowIndex
{
	NSDictionary *dict = [deviceArray objectAtIndex: rowIndex];
	return [dict valueForKey: [col identifier]];
}

- (NSInteger) numberOfRowsInTableView:(NSTableView *)aTableView
{
	return [deviceArray count];
}

- (void) tableView: (NSTableView *) aTableView
   willDisplayCell: (id) aCell
    forTableColumn: (NSTableColumn *) aTableColumn
	       row: (NSInteger) rowIndex
{
	//NSDictionary *dict = [deviceArray objectAtIndex: rowIndex];
}

- (void) setDeviceEnabled: (BOOL) en
{
	[setButton setEnabled: en];
	[getButton setEnabled: en];
	[memData setEditable: en];
	[bRequest setEditable: en];
	[wIndex setEditable: en];
	[wValue setEditable: en];
	[dataSize setEnabled: en];
	[requestType setEnabled: en];
	[requestRecipient setEnabled: en];
	
	if (!en) {
		[deviceVID setStringValue: @"-"];
		[devicePID setStringValue: @"-"];
	}
}

#pragma mark ############ IBActions #############

- (IBAction) selectDevice: (id) sender
{
	NSInteger selectedRow = [sender selectedRow];
	
	if (selectedRow < 0) {
		[self setDeviceEnabled: NO];
		return;
	}

	[self setDeviceEnabled: YES];

	NSDictionary *dict = [deviceArray objectAtIndex: selectedRow];
	[deviceVID setStringValue: [dict valueForKey: @"VID"]];
	[devicePID setStringValue: [dict valueForKey: @"PID"]];
}


#pragma mark ############ NSApplication delegate protocol #############

- (BOOL) application: (NSApplication *) theApplication openFile:(NSString *)filename
{
	return NO;
}

- (UInt) convertData: (unsigned char *) dest maxLength: (UInt) len
{
	char tmp[1024];
	int n = 0;
	char *next;

	[[memData stringValue] getCString: tmp
				maxLength: sizeof(tmp)
				 encoding: NSASCIIStringEncoding];
        next = strtok(tmp, " ");
        while (next && n < len) {
		dest[n++] = strtol(next, NULL, 0);
		next = strtok(NULL, " ");
	}

	return n;
}

- (IBAction) dataChanged: (id) sender
{
	unsigned char tmp[1024];
	UInt count = [self convertData: tmp
			     maxLength: sizeof(tmp)];
	[dataSize setIntValue: count];
	printf("count %d\n", count);
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	[memData setFont: [NSFont fontWithName: @"Courier New" size: 11]];
	[self listenForDevices];
	[self setDeviceEnabled: NO];
}

- (IBAction) getData: (id) sender
{
	NSInteger selectedRow = [deviceTable selectedRow];
	NSDictionary *dict = [deviceArray objectAtIndex: selectedRow];
	IOUSBDeviceInterface **dev = [[dict valueForKey: @"dev"] pointerValue];
	UInt count = [dataSize intValue];
	HRESULT kr;
	unsigned char tmp[1024];
	char tmpstr[5 * 1024];
	int i;

	[memData setStringValue: @""];
	
	IOUSBDevRequest req;
	req.bmRequestType = USBmakebmRequestType(kUSBIn,
						 [requestType indexOfSelectedItem],
						 [requestRecipient indexOfSelectedItem]);
	req.bRequest = [bRequest intValue];
	req.wValue = [wValue intValue];
	req.wIndex = [wIndex intValue];
	req.pData = tmp;
	req.wLength = count;
	
	kr = (*dev)->DeviceRequest(dev, &req);
	printf("kr = %08x\n", kr);

	if (kr == 0) {
		memset(tmpstr, 0, sizeof(tmpstr));
		for (i = 0; i < count; i++)
			snprintf(tmpstr + (i * 5), 5, "0x%02x ", tmp[i]);
		
		[memData setStringValue: [NSString stringWithCString: tmpstr
							    encoding: NSASCIIStringEncoding]];
	} else {
		NSBeginCriticalAlertSheet (@"Get request failed",
					   @"Oh, well.",
					   nil, nil,
					   [NSApp mainWindow],
					   nil, nil, nil, NULL,
					   @"OS reported error code %08x", kr);
	}
}

- (IBAction) setData: (id) sender
{
	NSInteger selectedRow = [deviceTable selectedRow];
	NSDictionary *dict = [deviceArray objectAtIndex: selectedRow];
	IOUSBDeviceInterface **dev = [[dict valueForKey: @"dev"] pointerValue];
	HRESULT kr;
	
	unsigned char tmp[1024];
	UInt count = [self convertData: tmp
			     maxLength: sizeof(tmp)];
	[dataSize setIntValue: count];
	
	/*
	int i;
	for (i = 0; i < count; i++)
		printf("tmp[%d] = %02x\n", i, tmp[i]);
	*/
	
	IOUSBDevRequest req;
	req.bmRequestType = USBmakebmRequestType(kUSBOut,
						 [requestType indexOfSelectedItem],
						 [requestRecipient indexOfSelectedItem]);
	req.bRequest = [bRequest intValue];
	req.wValue = [wValue intValue];
	req.wIndex = [wIndex intValue];
	
	kr = (*dev)->DeviceRequest(dev, &req);
	
	if (kr != 0)
		NSBeginCriticalAlertSheet (@"Set request failed",
					   @"Oh, well.",
					   nil, nil,
					   [NSApp mainWindow],
					   nil, nil, nil, NULL,
					   @"OS reported error code %08x", kr);
}

@end
