#import "MirrorPhoneUSB.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

static const uint16_t MMGoogleVendorID = 0x18D1;
static const uint16_t MMAccessoryProductID = 0x2D00;
static const uint16_t MMAccessoryADBProductID = 0x2D01;
static const NSUInteger MMReadBufferSize = 256 * 1024;

@interface MMAndroidAccessoryHost : NSObject
@property(nonatomic) void *callbackContext;
@property(nonatomic) MMAndroidAccessoryDataCallback dataCallback;
@property(nonatomic) MMAndroidAccessoryStatusCallback statusCallback;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) IOUSBHostDevice *device;
@property(nonatomic) IOUSBHostInterface *interface;
@property(nonatomic) IOUSBHostPipe *inputPipe;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL reading;
@property(nonatomic) uint64_t lastAttemptRegistryID;
@property(nonatomic) CFAbsoluteTime lastAttemptTime;
@end

@implementation MMAndroidAccessoryHost

- (instancetype)initWithContext:(void *)context
                    dataCallback:(MMAndroidAccessoryDataCallback)dataCallback
                  statusCallback:(MMAndroidAccessoryStatusCallback)statusCallback {
  self = [super init];
  if (self) {
    _callbackContext = context;
    _dataCallback = dataCallback;
    _statusCallback = statusCallback;
    _queue = dispatch_queue_create("com.rockyshi.mirrorphone.android-accessory", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)start {
  dispatch_async(self.queue, ^{
    if (self.started) return;
    self.started = YES;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        NSEC_PER_SEC,
        100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
      [self poll];
    });
    self.timer = timer;
    dispatch_resume(timer);
  });
}

- (void)stop {
  dispatch_sync(self.queue, ^{
    if (!self.started) return;
    self.started = NO;
    if (self.timer) {
      dispatch_source_cancel(self.timer);
      self.timer = nil;
    }
    [self closeAccessoryReporting:NO];
  });
}

- (void)poll {
  if (!self.started || self.reading) return;
  if (self.device) {
    [self openAccessoryInterface];
    return;
  }

  io_iterator_t iterator = IO_OBJECT_NULL;
  kern_return_t result = IOServiceGetMatchingServices(
      kIOMainPortDefault,
      IOServiceMatching("IOUSBHostDevice"),
      &iterator);
  if (result != KERN_SUCCESS) return;

  io_service_t rawCandidate = IO_OBJECT_NULL;
  io_service_t service;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    uint16_t vendorID = [self numberProperty:@"idVendor" service:service].unsignedShortValue;
    uint16_t productID = [self numberProperty:@"idProduct" service:service].unsignedShortValue;
    if (vendorID == MMGoogleVendorID &&
        (productID == MMAccessoryProductID || productID == MMAccessoryADBProductID)) {
      [self claimAccessoryDevice:service];
      IOObjectRelease(service);
      if (rawCandidate) IOObjectRelease(rawCandidate);
      rawCandidate = IO_OBJECT_NULL;
      break;
    }
    if (!rawCandidate &&
        [self isKnownAndroidVendor:vendorID] &&
        [self hasAndroidDataInterface:service]) {
      rawCandidate = service;
      continue;
    }
    IOObjectRelease(service);
  }
  IOObjectRelease(iterator);

  if (!self.device && rawCandidate) {
    [self requestAccessoryMode:rawCandidate];
    IOObjectRelease(rawCandidate);
  }
}

- (BOOL)hasAndroidDataInterface:(io_service_t)deviceService {
  // A vendor ID alone is not enough: manufacturers such as Xiaomi and Sony
  // reuse their IDs for speakers, cameras, and other peripherals. Only probe
  // devices that already expose an Android data function. MTP uses the USB
  // still-image class; ADB uses the vendor-specific 0xff/0x42/0x01 tuple.
  io_iterator_t iterator = IO_OBJECT_NULL;
  kern_return_t result = IORegistryEntryCreateIterator(
      deviceService,
      kIOServicePlane,
      kIORegistryIterateRecursively,
      &iterator);
  if (result != KERN_SUCCESS) return NO;

  BOOL found = NO;
  io_service_t child;
  while ((child = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
      uint8_t interfaceClass =
          [self numberProperty:@"bInterfaceClass" service:child].unsignedCharValue;
      uint8_t interfaceSubclass =
          [self numberProperty:@"bInterfaceSubClass" service:child].unsignedCharValue;
      uint8_t interfaceProtocol =
          [self numberProperty:@"bInterfaceProtocol" service:child].unsignedCharValue;
      BOOL isMTP = interfaceClass == 0x06;
      BOOL isADB = interfaceClass == 0xFF &&
                   interfaceSubclass == 0x42 &&
                   interfaceProtocol == 0x01;
      if (isMTP || isADB) found = YES;
    }
    IOObjectRelease(child);
    if (found) break;
  }
  IOObjectRelease(iterator);
  return found;
}

- (BOOL)isKnownAndroidVendor:(uint16_t)vendorID {
  // USB vendor IDs used by common Android manufacturers. This filter prevents
  // MirrorPhone from claiming unrelated USB peripherals before probing AOA.
  switch (vendorID) {
    case 0x0409: // NEC / some Android reference devices
    case 0x0451: // Texas Instruments
    case 0x0471: // Philips
    case 0x0489: // Foxconn
    case 0x04DD: // Sharp
    case 0x04E8: // Samsung
    case 0x0502: // Acer
    case 0x054C: // Sony
    case 0x05C6: // Qualcomm
    case 0x0B05: // ASUS
    case 0x0BB4: // HTC
    case 0x0E8D: // MediaTek
    case 0x0FCE: // Sony Ericsson
    case 0x1004: // LG
    case 0x109B: // Hisense
    case 0x12D1: // Huawei
    case 0x17EF: // Lenovo
    case 0x18D1: // Google
    case 0x19D2: // ZTE
    case 0x1BBB: // Alcatel
    case 0x22B8: // Motorola
    case 0x22D9: // OPPO
    case 0x2717: // Xiaomi
    case 0x2A70: // OnePlus
    case 0x2D95: // vivo
    case 0x2E17: // Essential
      return YES;
    default:
      return NO;
  }
}

- (void)requestAccessoryMode:(io_service_t)service {
  uint64_t registryID = 0;
  IORegistryEntryGetRegistryEntryID(service, &registryID);
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (registryID == self.lastAttemptRegistryID && now - self.lastAttemptTime < 3) return;
  self.lastAttemptRegistryID = registryID;
  self.lastAttemptTime = now;

  NSError *error = nil;
  IOUSBHostDevice *device = [[IOUSBHostDevice alloc]
      initWithIOService:service
                 options:IOUSBHostObjectInitOptionsNone
                   queue:self.queue
                   error:&error
         interestHandler:nil];
  if (!device) {
    error = nil;
    device = [[IOUSBHostDevice alloc]
        initWithIOService:service
                   options:IOUSBHostObjectInitOptionsDeviceSeize
                     queue:self.queue
                     error:&error
           interestHandler:nil];
  }
  if (!device) return;

  NSMutableData *protocolData = [NSMutableData dataWithLength:2];
  IOUSBDeviceRequest protocolRequest = {
      .bmRequestType = IOUSBHostDeviceRequestType(
          kIOUSBDeviceRequestDirectionValueIn,
          kIOUSBDeviceRequestTypeValueVendor,
          kIOUSBDeviceRequestRecipientValueDevice),
      .bRequest = 51,
      .wValue = 0,
      .wIndex = 0,
      .wLength = 2,
  };
  NSUInteger transferred = 0;
  BOOL supported = [device sendDeviceRequest:protocolRequest
                                        data:protocolData
                            bytesTransferred:&transferred
                           completionTimeout:1
                                       error:&error];
  if (!supported || transferred != 2) {
    [device destroy];
    return;
  }
  const uint8_t *versionBytes = protocolData.bytes;
  uint16_t protocolVersion = versionBytes[0] | ((uint16_t)versionBytes[1] << 8);
  if (protocolVersion == 0) {
    [device destroy];
    return;
  }

  NSArray<NSString *> *identification = @[
    @"Shibang",
    @"MirrorPhone",
    @"MirrorPhone Android cable transport",
    @"1.0",
    @"https://mirrorphone.local",
    @"MirrorPhone",
  ];
  for (NSUInteger index = 0; index < identification.count; index++) {
    NSMutableData *data = [[identification[index] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    uint8_t terminator = 0;
    [data appendBytes:&terminator length:1];
    IOUSBDeviceRequest stringRequest = {
        .bmRequestType = IOUSBHostDeviceRequestType(
            kIOUSBDeviceRequestDirectionValueOut,
            kIOUSBDeviceRequestTypeValueVendor,
            kIOUSBDeviceRequestRecipientValueDevice),
        .bRequest = 52,
        .wValue = 0,
        .wIndex = (uint16_t)index,
        .wLength = (uint16_t)data.length,
    };
    if (![device sendDeviceRequest:stringRequest
                              data:data
                  bytesTransferred:&transferred
                 completionTimeout:1
                             error:&error]) {
      [device destroy];
      return;
    }
  }

  IOUSBDeviceRequest startRequest = {
      .bmRequestType = IOUSBHostDeviceRequestType(
          kIOUSBDeviceRequestDirectionValueOut,
          kIOUSBDeviceRequestTypeValueVendor,
          kIOUSBDeviceRequestRecipientValueDevice),
      .bRequest = 53,
      .wValue = 0,
      .wIndex = 0,
      .wLength = 0,
  };
  [device sendDeviceRequest:startRequest
                       data:nil
           bytesTransferred:&transferred
          completionTimeout:1
                      error:&error];
  [device destroy];
  [self reportStatus:"Android cable detected · opening MirrorPhone" connected:NO];
}

- (void)claimAccessoryDevice:(io_service_t)service {
  if (self.device) return;
  NSError *error = nil;
  IOUSBHostDevice *device = [[IOUSBHostDevice alloc]
      initWithIOService:service
                 options:IOUSBHostObjectInitOptionsNone
                   queue:self.queue
                   error:&error
         interestHandler:^(IOUSBHostObject *object, uint32_t messageType, void *argument) {
           if (messageType == kIOMessageServiceIsTerminated) {
             dispatch_async(self.queue, ^{
               [self closeAccessoryReporting:YES];
             });
           }
         }];
  if (!device) return;
  self.device = device;
  NSNumber *configuration = [self numberProperty:@"kUSBCurrentConfiguration" service:service];
  if (configuration.unsignedIntegerValue != 1) {
    if (![device configureWithValue:1 matchInterfaces:YES error:&error]) {
      [self closeAccessoryReporting:NO];
      return;
    }
  }
  [self openAccessoryInterface];
}

- (void)openAccessoryInterface {
  if (!self.device || self.interface || !self.started) return;
  io_iterator_t iterator = IO_OBJECT_NULL;
  if (IORegistryEntryGetChildIterator(
          self.device.ioService, kIOServicePlane, &iterator) != KERN_SUCCESS) return;
  io_service_t service;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    if (!IOObjectConformsTo(service, "IOUSBHostInterface")) {
      IOObjectRelease(service);
      continue;
    }
    NSError *error = nil;
    IOUSBHostInterface *interface = [[IOUSBHostInterface alloc]
        initWithIOService:service
                   options:IOUSBHostObjectInitOptionsNone
                     queue:self.queue
                     error:&error
           interestHandler:^(IOUSBHostObject *object, uint32_t messageType, void *argument) {
             if (messageType == kIOMessageServiceIsTerminated) {
               dispatch_async(self.queue, ^{
                 [self closeAccessoryReporting:YES];
               });
             }
           }];
    IOObjectRelease(service);
    if (!interface) continue;

    const IOUSBConfigurationDescriptor *configuration = interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *interfaceDescriptor = interface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *endpoint = NULL;
    while ((endpoint = IOUSBGetNextEndpointDescriptor(
                configuration,
                interfaceDescriptor,
                (const IOUSBDescriptorHeader *)endpoint))) {
      if (IOUSBGetEndpointType(endpoint) == kIOUSBEndpointTypeBulk &&
          IOUSBGetEndpointDirection(endpoint) == kIOUSBEndpointDirectionIn) {
        IOUSBHostPipe *pipe = [interface copyPipeWithAddress:IOUSBGetEndpointAddress(endpoint)
                                                      error:&error];
        if (pipe) {
          self.interface = interface;
          self.inputPipe = pipe;
          self.reading = YES;
          [self reportStatus:"Android connected by cable · waiting for video" connected:YES];
          [self enqueueRead];
          IOObjectRelease(iterator);
          return;
        }
      }
    }
    [interface destroy];
  }
  IOObjectRelease(iterator);
}

- (void)enqueueRead {
  if (!self.started || !self.reading || !self.inputPipe) return;
  NSError *error = nil;
  NSMutableData *buffer = [NSMutableData dataWithLength:MMReadBufferSize];
  BOOL queued = [self.inputPipe enqueueIORequestWithData:buffer
                                      completionTimeout:0
                                                  error:&error
                                      completionHandler:^(IOReturn status, NSUInteger bytesTransferred) {
    if (!self.started || !self.reading) return;
    if (status != kIOReturnSuccess) {
      [self closeAccessoryReporting:YES];
      return;
    }
    if (bytesTransferred > 0 && self.dataCallback) {
      self.dataCallback(self.callbackContext, buffer.bytes, bytesTransferred);
    }
    [self enqueueRead];
  }];
  if (!queued) [self closeAccessoryReporting:YES];
}

- (void)closeAccessoryReporting:(BOOL)report {
  BOOL wasConnected = self.reading;
  self.reading = NO;
  if (self.inputPipe) {
    [self.inputPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    self.inputPipe = nil;
  }
  if (self.interface) {
    [self.interface destroy];
    self.interface = nil;
  }
  if (self.device) {
    [self.device destroy];
    self.device = nil;
  }
  if (report && wasConnected) {
    [self reportStatus:"Android cable disconnected · waiting to reconnect" connected:NO];
  }
}

- (NSNumber *)numberProperty:(NSString *)key service:(io_service_t)service {
  CFTypeRef value = IORegistryEntryCreateCFProperty(
      service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
  return CFBridgingRelease(value);
}

- (void)reportStatus:(const char *)status connected:(BOOL)connected {
  if (self.statusCallback) {
    self.statusCallback(self.callbackContext, status, connected);
  }
}

@end

MMAndroidAccessoryHostRef mm_android_accessory_host_create(
    void *context,
    MMAndroidAccessoryDataCallback data_callback,
    MMAndroidAccessoryStatusCallback status_callback) {
  MMAndroidAccessoryHost *host = [[MMAndroidAccessoryHost alloc]
      initWithContext:context
         dataCallback:data_callback
       statusCallback:status_callback];
  return (__bridge_retained void *)host;
}

void mm_android_accessory_host_start(MMAndroidAccessoryHostRef host) {
  [(__bridge MMAndroidAccessoryHost *)host start];
}

void mm_android_accessory_host_stop(MMAndroidAccessoryHostRef host) {
  [(__bridge MMAndroidAccessoryHost *)host stop];
}

void mm_android_accessory_host_destroy(MMAndroidAccessoryHostRef host) {
  if (!host) return;
  MMAndroidAccessoryHost *object = CFBridgingRelease(host);
  [object stop];
}
