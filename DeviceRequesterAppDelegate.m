/***
 This file is part of CocoaUSBDeviceRequester
 
 Copyright 2010 Daniel Mack <daniel@caiaq.de>
 
 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2.1 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with PulseAudio; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
 USA.
 ***/


#include <IOKit/IOKitLib.h>
#include <IOKit/IODataQueueShared.h>
#include <IOKit/IODataQueueClient.h>
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

@interface USBDeviceRequesterAppDelegate ()

@property (assign) IBOutlet NSWindow	*window;
@property (assign) IBOutlet NSTableView *deviceTable;
@property (assign) IBOutlet NSTextField *deviceVID;
@property (assign) IBOutlet NSTextField *devicePID;
@property (assign) IBOutlet NSTextField *bRequest;
@property (assign) IBOutlet NSTextField *wValue;
@property (assign) IBOutlet NSTextField *wIndex;
@property (assign) IBOutlet NSTextField *dataSize;
@property (assign) IBOutlet NSTextField	*memData;
@property (assign) IBOutlet NSBox	*requestBox;
@property (assign) IBOutlet NSButton	*setButton;
@property (assign) IBOutlet NSButton	*getButton;
@property (assign) IBOutlet NSButton	*resetButton;
@property (assign) IBOutlet NSPopUpButton *requestType;
@property (assign) IBOutlet NSPopUpButton *requestRecipient;

@property(strong) NSMutableArray *deviceArray;

@end

@implementation USBDeviceRequesterAppDelegate

#pragma mark ######### static wrappers #########

static void
staticDeviceAdded (void *refCon, io_iterator_t iterator)
{
	USBDeviceRequesterAppDelegate *del = refCon;

	if (del)
		[del deviceAdded : iterator];
}

static void
staticDeviceRemoved (void *refCon, io_iterator_t iterator)
{
	USBDeviceRequesterAppDelegate *del = refCon;

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
		printf("%s(): device added %d.\n", __func__, (int) serviceObject);
		IORegistryEntryCreateCFProperties(serviceObject, &entryProperties, NULL, 0);

		kr = IOCreatePlugInInterfaceForService(serviceObject,
						       kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
						       &plugInInterface, &score);

		if ((kr != kIOReturnSuccess) || !plugInInterface) {
			printf("%s(): Unable to create a plug-in (%08x)\n", __func__, kr);
			continue;
		}

		// create the device interface
		result = (*plugInInterface)->QueryInterface(plugInInterface,
							    CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
							    (LPVOID *)&dev);

		// don’t need the intermediate plug-in after device interface is created
		(*plugInInterface)->Release(plugInInterface);

		if (result || !dev) {
			printf("%s(): Couldn’t create a device interface (%08x)\n", __func__, (int) result);
			continue;
		}

		NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity: 0];

		UInt16 vendorID, productID;
		(*dev)->GetDeviceVendor(dev, &vendorID);
		(*dev)->GetDeviceProduct(dev, &productID);
		NSString *name = (NSString *) CFDictionaryGetValue(entryProperties, CFSTR(kUSBProductString));
		if (!name)
			continue;
		
		printf(" *dev = %p\n", *dev);

		[dict setObject: [NSString stringWithFormat: @"0x%04x", vendorID]
			 forKey: @"VID"];
		[dict setObject: [NSString stringWithFormat: @"0x%04x", productID]
			 forKey: @"PID"];
		[dict setObject: [NSString stringWithString: name]
			 forKey: @"name"];
		[dict setObject: [NSValue valueWithPointer: dev]
			 forKey: @"dev"];
		[dict setObject: [NSNumber numberWithInt: serviceObject]
			 forKey: @"service"];

        [self.deviceArray addObject: dict];
    }

    [self.deviceTable reloadData];
}

- (void) deviceRemoved: (io_iterator_t) iterator
{
    io_service_t serviceObject;

    while ((serviceObject = IOIteratorNext(iterator)))
    {
        NSEnumerator *enumerator = [self.deviceArray objectEnumerator];
        printf("%s(): device removed %d.\n", __func__, (int) serviceObject);
        NSDictionary *dict;

        while (dict = [enumerator nextObject])
        {
            if ((io_service_t) [[dict valueForKey: @"service"] intValue] == serviceObject)
            {
                [self.deviceArray removeObject: dict];
                break;
            }
        }

        IOObjectRelease(serviceObject);
    }

    [self.deviceTable reloadData];

    if ([self.deviceTable selectedRow] < 0)
    {
        [self setDeviceEnabled: NO];
    }
}

#pragma mark ######### GUI related #########

- (void)listenForDevices
{
    OSStatus ret;
    CFRunLoopSourceRef runLoopSource;

    self.deviceArray = [[NSMutableArray alloc] initWithCapacity: 0];

    classToMatch = IOServiceMatching(kIOUSBDeviceClassName);
    if (!classToMatch)
    {
        printf("%s(): IOServiceMatching returned a NULL dictionary.\n", __func__);
        return;
    }

    // increase the reference count by 1 since die dict is used twice.
    CFRetain(classToMatch);

    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
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
}

#pragma mark ######### table view data source protocol ############

- (void)tableView:(NSTableView *)aTableView
   setObjectValue:obj
   forTableColumn:(NSTableColumn *)col
	      row:(NSInteger)rowIndex
{
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)col
    row:(NSInteger)rowIndex
{
    NSDictionary *dict = [self.deviceArray objectAtIndex: rowIndex];
    return [dict valueForKey:[col identifier]];
}

- (NSInteger) numberOfRowsInTableView:(NSTableView *)aTableView
{
    return [self.deviceArray count];
}

- (void)setDeviceEnabled:(BOOL)anEnabledFlag
{
    self.requestType.enabled =      anEnabledFlag;
    self.requestRecipient.enabled = anEnabledFlag;
    self.bRequest.enabled =         anEnabledFlag;
    self.wIndex.enabled =           anEnabledFlag;
    self.wValue.enabled =           anEnabledFlag;
    self.dataSize.enabled =         anEnabledFlag;
    self.setButton.enabled =        anEnabledFlag;
    self.getButton.enabled =        anEnabledFlag;
    self.resetButton.enabled =      anEnabledFlag;
    self.memData.enabled =          anEnabledFlag;

    if (!anEnabledFlag)
    {
        [self.deviceVID setStringValue: @"-"];
        [self.devicePID setStringValue: @"-"];
    }
}

#pragma mark ############ IBActions #############

- (IBAction)selectDevice:(id)sender
{
    NSInteger selectedRow = [sender selectedRow];

    if (selectedRow < 0)
    {
        [self setDeviceEnabled: NO];
        return;
    }

    [self setDeviceEnabled: YES];

    NSDictionary *dict = [self.deviceArray objectAtIndex: selectedRow];
    [self.deviceVID setStringValue: [dict valueForKey: @"VID"]];
    [self.devicePID setStringValue: [dict valueForKey: @"PID"]];
}


#pragma mark ############ NSApplication delegate protocol #############

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [self.memData setFont: [NSFont fontWithName: @"Courier New" size: 11]];
    [self listenForDevices];
    [self setDeviceEnabled:NO];
}

- (UInt)convertData:(unsigned char *)dest maxLength:(UInt)len
{
    char tmp[1024], *next;
    UInt n = 0;

    [[self.memData stringValue] getCString: tmp
                maxLength: sizeof(tmp)
                encoding: NSASCIIStringEncoding];

    next = strtok(tmp, " ");
    while (next && n < len)
    {
        dest[n++] = strtol(next, NULL, 0);
        next = strtok(NULL, " ");
    }

    return n;
}

- (NSInteger) convertToInt: (NSString *) string
{
	char tmp[64];
	
	[string getCString: tmp
		 maxLength: sizeof(tmp)
		  encoding: NSASCIIStringEncoding];

	if (tmp[0] == '0' && tmp[1] == 'x')
		return strtol(tmp, NULL, 16);
	
	return strtol(tmp, NULL, 10);
}

- (void)makeRequestToDevice:(IOUSBDeviceInterface **)dev
       directionHostToDevice:(BOOL)directionHostToDevice
{
    IOUSBDevRequest req;
    UInt count;
    unsigned char tmp[1024];

    if (directionHostToDevice)
    {
        count = [self convertData: tmp maxLength: sizeof(tmp)];
        [self.dataSize setIntValue: count];
    }
    else
    {
        count = [self.dataSize intValue];
        [self.memData setStringValue: @""];
    }

    req.bmRequestType = USBmakebmRequestType(directionHostToDevice ? kUSBOut: kUSBIn,
                        [self.requestType indexOfSelectedItem],
                        [self.requestRecipient indexOfSelectedItem]);

    req.bRequest = [self convertToInt:self.bRequest.stringValue];
    req.wValue = EndianS16_NtoL([self convertToInt:self.wValue.stringValue]);
    req.wIndex = EndianS16_NtoL([self convertToInt:self.wIndex.stringValue]);
    req.wLength = EndianS16_NtoL(count);
    req.pData = tmp;

    HRESULT kernelReturn = (*dev)->DeviceRequest(dev, &req);
    if (kernelReturn)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Request failed";
        alert.informativeText = [NSString stringWithFormat:@"OS reported error code %08x", kernelReturn];
        [alert beginSheetModalForWindow:[NSApp mainWindow] completionHandler:
            ^(NSModalResponse returnCode)
            {

            }];
    }

    if (!directionHostToDevice)
    {
		char tmpstr[(5 * count) + 1];
		char subtmp[6];
		NSInteger i;

		memset(tmpstr, 0, sizeof(tmpstr));
		memset(subtmp, 0, sizeof(subtmp));
		for (i = 0; i < count; i++)
        {
			snprintf(subtmp, 6, "0x%02x ", tmp[i]);
			strncat(tmpstr, subtmp, 6);
		}

		[self.memData setStringValue: [NSString stringWithCString: tmpstr
							    encoding: NSASCIIStringEncoding]];
	}
}

- (void)makeRequestToSelectedDevice:(BOOL)outputDirection
{
    NSInteger selectedRow = [self.deviceTable selectedRow];
    NSDictionary *dict = [self.deviceArray objectAtIndex: selectedRow];
    IOUSBDeviceInterface **dev = [[dict valueForKey: @"dev"] pointerValue];

    [self makeRequestToDevice:dev directionHostToDevice:outputDirection];
}

- (IBAction)getData:(id)sender
{
    [self makeRequestToSelectedDevice:NO];
}

- (IBAction)setData:(id)sender
{
    [self makeRequestToSelectedDevice:YES];
}

- (IBAction)resetDevice:(id)sender
{
    NSInteger selectedRow = [self.deviceTable selectedRow];
    NSDictionary *dict = [self.deviceArray objectAtIndex:selectedRow];
    IOUSBDeviceInterface187 **dev = [[dict valueForKey: @"dev"] pointerValue];

    OSStatus kernelReturn = (*dev)->USBDeviceOpen(dev);
    if (kernelReturn)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Exclusive Device open failed";
        alert.informativeText = [NSString stringWithFormat:@"OS reported error code %08x", kernelReturn];
        [alert beginSheetModalForWindow:[NSApp mainWindow] completionHandler:
            ^(NSModalResponse returnCode)
            {

            }];
        return;
    }

    kernelReturn = (*dev)->ResetDevice(dev);
    if (kernelReturn)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Device reset failed";
        alert.informativeText = [NSString stringWithFormat:@"OS reported error code %08x", kernelReturn];
        [alert beginSheetModalForWindow:[NSApp mainWindow] completionHandler:
            ^(NSModalResponse returnCode)
            {

            }];
    }

    kernelReturn = (*dev)->USBDeviceReEnumerate(dev, 0);
    if (kernelReturn)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"USBDeviceReEnumerate failed";
        alert.informativeText = [NSString stringWithFormat:@"OS reported error code %08x", kernelReturn];
        [alert beginSheetModalForWindow:[NSApp mainWindow] completionHandler:
            ^(NSModalResponse returnCode)
            {

            }];
    }
}

@end
