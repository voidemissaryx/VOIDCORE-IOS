//
//  Runner-Bridging-Header.h
//  VOIDCORE VPN (Runner)
//
//  Exposes the C entry points used by Swift code (CommonCrypto for SHA-256,
//  and the Xray framework module map when the XCFramework is linked).
//

#ifndef Runner_Bridging_Header_h
#define Runner_Bridging_Header_h

#import <CommonCrypto/CommonCrypto.h>
#import "GeneratedPluginRegistrant.h"

// When the Xray.xcframework is linked, its module map is auto-imported by
// the Swift compiler through the framework search path; no manual import is
// needed here. This header is reserved for plain-C declarations only.

#endif /* Runner_Bridging_Header_h */
