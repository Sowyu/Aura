#import "AuraResourceTypes.h"

NSString *const AuraWebRequestStateMessageName = @"aura.webRequest.state";

/// Types inferred from the `Accept` header, or 0 when it says nothing useful.
/// Scripts and fetches both arrive as `*/*`, so that value deliberately falls
/// through to the extension table rather than claiming one of them.
static uint32_t AuraResourceTypeFromAccept(NSString *acceptHeader, BOOL isMainFrame)
{
    NSString *accept = acceptHeader.lowercaseString;
    if (accept.length == 0) { return 0; }
    if ([accept containsString:@"text/css"]) { return AuraResourceTypeStylesheet; }
    if ([accept hasPrefix:@"image/"] || [accept containsString:@"image/webp"]
        || [accept containsString:@"image/avif"]) {
        return AuraResourceTypeImage;
    }
    if ([accept hasPrefix:@"font/"] || [accept containsString:@"application/font"]) {
        return AuraResourceTypeFont;
    }
    if ([accept hasPrefix:@"video/"] || [accept hasPrefix:@"audio/"]) { return AuraResourceTypeMedia; }
    if ([accept containsString:@"text/html"] || [accept containsString:@"application/xhtml"]) {
        return isMainFrame ? AuraResourceTypeDocument : AuraResourceTypeSubdocument;
    }
    return 0;
}

uint32_t AuraResourceTypeForFetchDestination(NSString *destination)
{
    if (destination.length == 0) { return 0; }
    static NSDictionary<NSString *, NSNumber *> *byDestination;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        byDestination = @{
            @"document": @(AuraResourceTypeDocument),
            @"iframe": @(AuraResourceTypeSubdocument), @"frame": @(AuraResourceTypeSubdocument),
            @"embed": @(AuraResourceTypeOther), @"object": @(AuraResourceTypeOther),
            @"script": @(AuraResourceTypeScript),
            @"worker": @(AuraResourceTypeScript), @"sharedworker": @(AuraResourceTypeScript),
            @"serviceworker": @(AuraResourceTypeScript),
            @"style": @(AuraResourceTypeStylesheet),
            @"image": @(AuraResourceTypeImage),
            @"font": @(AuraResourceTypeFont),
            @"audio": @(AuraResourceTypeMedia), @"video": @(AuraResourceTypeMedia),
            @"track": @(AuraResourceTypeMedia),
            @"websocket": @(AuraResourceTypeWebSocket),
            // `empty` is what fetch() and XMLHttpRequest send.
            @"empty": @(AuraResourceTypeXHR),
            @"report": @(AuraResourceTypePing), @"manifest": @(AuraResourceTypeOther)
        };
    });
    NSNumber *mapped = byDestination[destination.lowercaseString];
    return mapped ? mapped.unsignedIntValue : 0;
}

uint32_t AuraResourceTypeMaskForURL(NSURL *url, NSString *acceptHeader, BOOL isMainFrame)
{
    const uint32_t fromAccept = AuraResourceTypeFromAccept(acceptHeader, isMainFrame);
    if (fromAccept != 0) { return fromAccept; }

    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"]) { return AuraResourceTypeWebSocket; }

    NSString *extension = url.pathExtension.lowercaseString;
    if (extension.length > 0) {
        static NSDictionary<NSString *, NSNumber *> *byExtension;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // No html/htm entry. A document load always carries an `Accept` of
            // its own, so anything left here ending in .html is a fetch, and
            // calling that a sub_frame is how a page's own JSON API ended up
            // judged by an extension's $subdocument filters.
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
                @"json": @(AuraResourceTypeXHR)
            };
        });
        NSNumber *mapped = byExtension[extension];
        if (mapped) { return mapped.unsignedIntValue; }
    }

    // Nothing to go on.
    return AuraResourceTypeAny;
}

NSString *AuraWebRequestTypeName(uint32_t typeMask, BOOL isMainDocument, BOOL isSubframe)
{
    if (isMainDocument) { return @"main_frame"; }
    // Nothing was inferred. Every bit is set in that case, so walking the bits
    // would answer with whichever one is tested first, and an extensionless
    // fetch would come back as a sub_frame.
    if (typeMask == AuraResourceTypeAny) { return @"other"; }
    if (typeMask & AuraResourceTypeSubdocument) { return @"sub_frame"; }
    if (typeMask & AuraResourceTypeScript) { return @"script"; }
    if (typeMask & AuraResourceTypeImage) { return @"image"; }
    if (typeMask & AuraResourceTypeStylesheet) { return @"stylesheet"; }
    if (typeMask & AuraResourceTypeFont) { return @"font"; }
    if (typeMask & AuraResourceTypeMedia) { return @"media"; }
    if (typeMask & AuraResourceTypeXHR) { return @"xmlhttprequest"; }
    if (typeMask & AuraResourceTypeWebSocket) { return @"websocket"; }
    if (typeMask & AuraResourceTypePing) { return @"ping"; }
    if (typeMask & AuraResourceTypeDocument) { return isSubframe ? @"sub_frame" : @"main_frame"; }
    return @"other";
}
