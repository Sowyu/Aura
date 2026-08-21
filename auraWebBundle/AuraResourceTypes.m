#import "AuraResourceTypes.h"

NSString *const AuraWebRequestStateMessageName = @"aura.webRequest.state";

uint32_t AuraResourceTypeMaskForURL(NSURL *url, NSString *acceptHeader, BOOL isMainFrame)
{
    NSString *accept = acceptHeader.lowercaseString;
    if (accept.length > 0) {
        if ([accept containsString:@"text/css"]) { return AuraResourceTypeStylesheet; }
        if ([accept hasPrefix:@"image/"] || [accept containsString:@"image/avif"]
            || [accept containsString:@"image/webp"]) {
            return AuraResourceTypeImage;
        }
        if ([accept hasPrefix:@"font/"] || [accept containsString:@"application/font"]) {
            return AuraResourceTypeFont;
        }
        if ([accept hasPrefix:@"video/"] || [accept hasPrefix:@"audio/"]) { return AuraResourceTypeMedia; }
        if ([accept containsString:@"text/html"]) {
            return isMainFrame ? AuraResourceTypeDocument : AuraResourceTypeSubdocument;
        }
    }

    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"]) { return AuraResourceTypeWebSocket; }

    NSString *extension = url.pathExtension.lowercaseString;
    if (extension.length > 0) {
        static NSDictionary<NSString *, NSNumber *> *byExtension;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            byExtension = @{
                @"js": @(AuraResourceTypeScript), @"mjs": @(AuraResourceTypeScript),
                @"css": @(AuraResourceTypeStylesheet),
                @"png": @(AuraResourceTypeImage), @"jpg": @(AuraResourceTypeImage),
                @"jpeg": @(AuraResourceTypeImage), @"gif": @(AuraResourceTypeImage),
                @"webp": @(AuraResourceTypeImage), @"avif": @(AuraResourceTypeImage),
                @"svg": @(AuraResourceTypeImage), @"ico": @(AuraResourceTypeImage),
                @"bmp": @(AuraResourceTypeImage),
                @"woff": @(AuraResourceTypeFont), @"woff2": @(AuraResourceTypeFont),
                @"ttf": @(AuraResourceTypeFont), @"otf": @(AuraResourceTypeFont),
                @"eot": @(AuraResourceTypeFont),
                @"mp4": @(AuraResourceTypeMedia), @"webm": @(AuraResourceTypeMedia),
                @"mp3": @(AuraResourceTypeMedia), @"ogg": @(AuraResourceTypeMedia),
                @"m4a": @(AuraResourceTypeMedia), @"mov": @(AuraResourceTypeMedia),
                @"m3u8": @(AuraResourceTypeMedia),
                @"json": @(AuraResourceTypeXHR),
                @"html": @(AuraResourceTypeSubdocument), @"htm": @(AuraResourceTypeSubdocument)
            };
        });
        NSNumber *mapped = byExtension[extension];
        if (mapped) { return mapped.unsignedIntValue; }
    }

    // Nothing to go on.
    return AuraResourceTypeAny;
}
