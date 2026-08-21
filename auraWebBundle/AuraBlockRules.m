#import "AuraBlockRules.h"

#import <os/lock.h>
#import <string.h>

NSString *const AuraBlockRulesFileName = @"rules-v1.json";
NSString *const AuraBlockRulesMessageName = @"aura.rules.fetch";
NSString *const AuraWebRequestStateMessageName = @"aura.webRequest.state";

typedef NS_ENUM(uint8_t, AuraRuleKind) {
    AuraRuleKindBlock = 0,
    AuraRuleKindAllow = 1,
    AuraRuleKindRemoveParam = 2,
    AuraRuleKindRedirect = 3
};

typedef NS_ENUM(uint8_t, AuraRulePartyScope) {
    AuraRulePartyScopeAny = 0,
    AuraRulePartyScopeThirdParty = 1,
    AuraRulePartyScopeFirstParty = 2
};

/// One rule, flattened so matching never touches an Objective-C object.
typedef struct {
    uint32_t types;
    uint32_t index;
    uint8_t kind;
    uint8_t party;
    uint8_t leftAnchor;
    uint8_t rightAnchor;
    uint8_t important;
    uint8_t redirectOnlyWhenBlocked;
    char *host;
    uint32_t hostLength;
    char *pattern;
    uint32_t patternLength;
    char **domains;
    uint32_t domainCount;
    char **excludedDomains;
    uint32_t excludedDomainCount;
} AuraRule;

static bool AuraSameSite(const char *host, size_t hostLength, const char *other, size_t otherLength);
static NSURL *_Nullable AuraStripParameters(NSURL *url, NSArray<NSString *> *parameters);

#pragma mark - Low level matching

static inline bool AuraIsSeparator(char character)
{
    if (character >= 'a' && character <= 'z') { return false; }
    if (character >= 'A' && character <= 'Z') { return false; }
    if (character >= '0' && character <= '9') { return false; }
    return !(character == '_' || character == '-' || character == '.' || character == '%');
}

/// Matches `pattern` starting exactly at `urlIndex`. `*` is any run, `^` is one
/// separator character or the end of the URL, everything else is literal.
static bool AuraMatchAt(
    const char *pattern,
    size_t patternLength,
    size_t patternIndex,
    const char *url,
    size_t urlLength,
    size_t urlIndex,
    bool rightAnchor)
{
    while (patternIndex < patternLength) {
        const char patternCharacter = pattern[patternIndex];
        if (patternCharacter == '*') {
            while (patternIndex < patternLength && pattern[patternIndex] == '*') { patternIndex++; }
            if (patternIndex == patternLength) { return true; }
            for (size_t candidate = urlIndex; candidate <= urlLength; candidate++) {
                if (AuraMatchAt(pattern, patternLength, patternIndex, url, urlLength, candidate, rightAnchor)) {
                    return true;
                }
            }
            return false;
        }
        if (patternCharacter == '^') {
            if (urlIndex == urlLength) { patternIndex++; continue; }
            if (!AuraIsSeparator(url[urlIndex])) { return false; }
            patternIndex++;
            urlIndex++;
            continue;
        }
        if (urlIndex >= urlLength || url[urlIndex] != patternCharacter) { return false; }
        patternIndex++;
        urlIndex++;
    }
    return rightAnchor ? urlIndex == urlLength : true;
}

static bool AuraMatchPattern(
    const char *pattern,
    size_t patternLength,
    const char *url,
    size_t urlLength,
    bool leftAnchor,
    bool rightAnchor,
    size_t minimumPosition)
{
    if (patternLength == 0) { return true; }
    if (leftAnchor) {
        return AuraMatchAt(pattern, patternLength, 0, url, urlLength, minimumPosition, rightAnchor);
    }
    for (size_t start = minimumPosition; start <= urlLength; start++) {
        if (AuraMatchAt(pattern, patternLength, 0, url, urlLength, start, rightAnchor)) { return true; }
    }
    return false;
}

/// Byte ranges of the hostname (port excluded) and of the whole authority
/// (port included) inside an absolute URL string.
static bool AuraFindHost(
    const char *url,
    size_t urlLength,
    size_t *outStart,
    size_t *outEnd,
    size_t *outAuthorityEnd)
{
    const char *schemeEnd = memmem(url, urlLength, "://", 3);
    if (!schemeEnd) { return false; }
    size_t start = (size_t)(schemeEnd - url) + 3;
    size_t cursor = start;
    size_t end = urlLength;
    size_t authorityEnd = urlLength;
    while (cursor < urlLength) {
        const char character = url[cursor];
        if (character == '/' || character == '?' || character == '#') {
            if (end == urlLength) { end = cursor; }
            authorityEnd = cursor;
            break;
        }
        if (character == ':' && end == urlLength) { end = cursor; }
        if (character == '@') {
            start = cursor + 1;
            end = urlLength;
        }
        cursor++;
    }
    if (end < start) { return false; }
    *outStart = start;
    *outEnd = end;
    *outAuthorityEnd = authorityEnd;
    return true;
}

/// `ads.example.com` -> `example.com`. Used as the bucket key on both sides, so
/// a rule host and every request host it can match land in the same bucket.
static void AuraLastTwoLabels(const char *host, size_t length, size_t *outOffset, size_t *outLength)
{
    size_t dots = 0;
    size_t offset = 0;
    for (size_t index = length; index > 0; index--) {
        if (host[index - 1] == '.') {
            dots++;
            if (dots == 2) { offset = index; break; }
        }
    }
    *outOffset = offset;
    *outLength = length - offset;
}

static bool AuraHostMatches(const char *host, size_t hostLength, const char *ruleHost, size_t ruleHostLength)
{
    if (ruleHostLength == 0) { return true; }
    if (hostLength < ruleHostLength) { return false; }
    if (strncasecmp(host + hostLength - ruleHostLength, ruleHost, ruleHostLength) != 0) { return false; }
    return hostLength == ruleHostLength || host[hostLength - ruleHostLength - 1] == '.';
}

static bool AuraDomainListMatches(char *const *list, uint32_t count, const char *host, size_t hostLength)
{
    for (uint32_t index = 0; index < count; index++) {
        const char *entry = list[index];
        if (AuraHostMatches(host, hostLength, entry, strlen(entry))) { return true; }
    }
    return false;
}

#pragma mark - Rule set

/// An immutable snapshot. Readers keep a strong reference for the length of one
/// evaluation, so a reload can swap a new set in without stopping them.
@interface AuraRuleSet: NSObject
@property (nonatomic, assign) AuraRule *rules;
@property (nonatomic, assign) NSUInteger count;
@property (nonatomic, copy) NSDictionary<NSString *, NSData *> *buckets;
@property (nonatomic, copy) NSData *genericIndexes;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *parameterNames;
@property (nonatomic, copy) NSArray<NSString *> *redirectNames;
@property (nonatomic, copy) NSArray<NSString *> *allowlist;
@property (nonatomic, copy) NSString *revision;
@end

@implementation AuraRuleSet

- (void)dealloc
{
    for (NSUInteger index = 0; index < _count; index++) {
        AuraRule *rule = &_rules[index];
        free(rule->host);
        free(rule->pattern);
        for (uint32_t domain = 0; domain < rule->domainCount; domain++) { free(rule->domains[domain]); }
        free(rule->domains);
        for (uint32_t domain = 0; domain < rule->excludedDomainCount; domain++) {
            free(rule->excludedDomains[domain]);
        }
        free(rule->excludedDomains);
    }
    free(_rules);
}

@end

#pragma mark - Redirect resources

/// uBO's neutered stand-ins, inline as data URLs so nothing has to be readable
/// from the WebContent process' sandbox.
///
/// ponytail: data: URLs, which a page's CSP can refuse. Ship the resources as
/// files behind a custom scheme handler if sites start reporting CSP errors.
static NSDictionary<NSString *, NSString *> *AuraRedirectResources(void)
{
    static NSDictionary<NSString *, NSString *> *resources;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *noopJS = @"data:application/javascript,";
        NSString *noopText = @"data:text/plain,";
        NSString *noopHTML = @"data:text/html,%3C!doctype%20html%3E";
        NSString *noopJSON = @"data:application/json,%7B%7D";
        // 43-byte fully transparent GIF.
        NSString *gif = @"data:image/gif;base64,"
            @"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
        // 1x1 transparent PNG.
        NSString *png = @"data:image/png;base64,"
            @"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
        NSString *vast = @"data:text/xml,%3CVAST%20version%3D%222.0%22%3E%3C%2FVAST%3E";
        NSString *vmap = @"data:text/xml,%3Cvmap%3AVMAP%20xmlns%3Avmap%3D%22http%3A%2F%2Fwww.iab.net%2Fvideosuite"
            @"%2Fvmap%22%20version%3D%221.0%22%3E%3C%2Fvmap%3AVMAP%3E";
        resources = @{
            @"noopjs": noopJS,
            @"noop.js": noopJS,
            @"noop.text": noopText,
            @"nooptext": noopText,
            @"noop.txt": noopText,
            @"noopframe": noopHTML,
            @"noop.html": noopHTML,
            @"noopcss": @"data:text/css,",
            @"noop.css": @"data:text/css,",
            @"noopjson": noopJSON,
            @"noop.json": noopJSON,
            @"noopvast-2.0": vast,
            @"noopvast-3.0": vast,
            @"noopvast-4.0": vast,
            @"noopvmap-1.0": vmap,
            @"1x1.gif": gif,
            @"1x1-transparent.gif": gif,
            @"2x2.png": png,
            @"2x2-transparent.png": png,
            @"3x2.png": png,
            @"3x2-transparent.png": png,
            @"32x32.png": png,
            @"32x32-transparent.png": png
        };
    });
    return resources;
}

#pragma mark - AuraBlockRules

@implementation AuraBlockRules {
    os_unfair_lock _lock;
    AuraRuleSet *_ruleSet;
    NSDate *_loadedModificationDate;
    unsigned long long _loadedSize;
}

+ (AuraBlockRules *)sharedRules
{
    static AuraBlockRules *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[AuraBlockRules alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) { _lock = OS_UNFAIR_LOCK_INIT; }
    return self;
}

- (AuraRuleSet *)currentRuleSet
{
    os_unfair_lock_lock(&_lock);
    AuraRuleSet *ruleSet = _ruleSet;
    os_unfair_lock_unlock(&_lock);
    return ruleSet;
}

- (NSUInteger)ruleCount { return [self currentRuleSet].count; }
- (NSUInteger)allowlistedHostCount { return [self currentRuleSet].allowlist.count; }
- (NSString *)revision { return [self currentRuleSet].revision; }

- (void)unload
{
    os_unfair_lock_lock(&_lock);
    _ruleSet = nil;
    _loadedModificationDate = nil;
    _loadedSize = 0;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)reloadIfChangedAtPath:(NSString *)path
{
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    if (!attributes) {
        [self unload];
        return NO;
    }

    NSDate *modified = attributes[NSFileModificationDate];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];

    os_unfair_lock_lock(&_lock);
    const BOOL unchanged = _ruleSet != nil
        && _loadedSize == size
        && modified != nil
        && [modified isEqualToDate:_loadedModificationDate];
    os_unfair_lock_unlock(&_lock);
    if (unchanged) { return NO; }

    if (![self loadFromPath:path]) { return NO; }

    os_unfair_lock_lock(&_lock);
    _loadedModificationDate = modified;
    _loadedSize = size;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (BOOL)loadFromPath:(NSString *)path
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [self loadFromData:data] : NO;
}

- (BOOL)loadFromData:(NSData *)data
{
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) { return NO; }

    NSArray *rawRules = root[@"r"];
    if (![rawRules isKindOfClass:NSArray.class]) { rawRules = @[]; }

    AuraRuleSet *ruleSet = [self buildRuleSetFromRoot:root rawRules:rawRules];

    os_unfair_lock_lock(&_lock);
    _ruleSet = ruleSet;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

// MARK: Building

static char *AuraCopyString(id value)
{
    if (![value isKindOfClass:NSString.class]) { return NULL; }
    const char *utf8 = [(NSString *)value UTF8String];
    if (!utf8 || utf8[0] == '\0') { return NULL; }
    return strdup(utf8);
}

static char **AuraCopyStringList(id value, uint32_t *outCount)
{
    *outCount = 0;
    if (![value isKindOfClass:NSArray.class]) { return NULL; }
    NSArray *array = value;
    if (array.count == 0) { return NULL; }
    char **list = calloc(array.count, sizeof(char *));
    uint32_t count = 0;
    for (id entry in array) {
        char *copy = AuraCopyString([entry isKindOfClass:NSString.class] ? [(NSString *)entry lowercaseString] : nil);
        if (copy) { list[count++] = copy; }
    }
    if (count == 0) {
        free(list);
        return NULL;
    }
    *outCount = count;
    return list;
}

- (AuraRuleSet *)buildRuleSetFromRoot:(NSDictionary *)root rawRules:(NSArray *)rawRules
{
    AuraRuleSet *ruleSet = [[AuraRuleSet alloc] init];
    ruleSet.rules = calloc(MAX(rawRules.count, (NSUInteger)1), sizeof(AuraRule));
    ruleSet.revision = [root[@"rev"] isKindOfClass:NSString.class] ? root[@"rev"] : @"";

    NSMutableArray<NSString *> *allowlist = [NSMutableArray array];
    for (id host in ([root[@"allow"] isKindOfClass:NSArray.class] ? root[@"allow"] : @[])) {
        if ([host isKindOfClass:NSString.class]) { [allowlist addObject:[(NSString *)host lowercaseString]]; }
    }
    ruleSet.allowlist = allowlist;

    NSMutableDictionary<NSString *, NSMutableData *> *buckets = [NSMutableDictionary dictionary];
    NSMutableData *genericIndexes = [NSMutableData data];
    NSMutableArray<NSArray<NSString *> *> *parameterNames = [NSMutableArray array];
    NSMutableArray<NSString *> *redirectNames = [NSMutableArray array];

    NSUInteger count = 0;
    for (id entry in rawRules) {
        if (![entry isKindOfClass:NSDictionary.class]) { continue; }
        NSDictionary *raw = entry;

        AuraRule *rule = &ruleSet.rules[count];
        rule->index = (uint32_t)count;
        rule->kind = (uint8_t)[raw[@"k"] unsignedIntValue];
        rule->types = raw[@"t"] ? [raw[@"t"] unsignedIntValue] : 0;
        rule->party = (uint8_t)[raw[@"tp"] unsignedIntValue];
        rule->leftAnchor = [raw[@"la"] boolValue];
        rule->rightAnchor = [raw[@"ra"] boolValue];
        rule->important = [raw[@"i"] boolValue];
        rule->redirectOnlyWhenBlocked = [raw[@"rr"] boolValue];
        rule->host = AuraCopyString([raw[@"h"] isKindOfClass:NSString.class] ? [raw[@"h"] lowercaseString] : nil);
        rule->hostLength = rule->host ? (uint32_t)strlen(rule->host) : 0;
        rule->pattern = AuraCopyString(raw[@"p"]);
        rule->patternLength = rule->pattern ? (uint32_t)strlen(rule->pattern) : 0;
        rule->domains = AuraCopyStringList(raw[@"d"], &rule->domainCount);
        rule->excludedDomains = AuraCopyStringList(raw[@"x"], &rule->excludedDomainCount);

        NSArray *parameters = [raw[@"pm"] isKindOfClass:NSArray.class] ? raw[@"pm"] : @[];
        [parameterNames addObject:parameters];
        [redirectNames addObject:[raw[@"rd"] isKindOfClass:NSString.class] ? raw[@"rd"] : @""];

        const uint32_t indexValue = (uint32_t)count;
        if (rule->hostLength > 0) {
            size_t keyOffset = 0;
            size_t keyLength = 0;
            AuraLastTwoLabels(rule->host, rule->hostLength, &keyOffset, &keyLength);
            NSString *key = [[NSString alloc] initWithBytes:rule->host + keyOffset
                                                     length:keyLength
                                                   encoding:NSUTF8StringEncoding];
            NSMutableData *bucket = buckets[key];
            if (!bucket) {
                bucket = [NSMutableData data];
                buckets[key] = bucket;
            }
            [bucket appendBytes:&indexValue length:sizeof(uint32_t)];
        } else {
            [genericIndexes appendBytes:&indexValue length:sizeof(uint32_t)];
        }
        count++;
    }

    ruleSet.count = count;
    ruleSet.buckets = buckets;
    ruleSet.genericIndexes = genericIndexes;
    ruleSet.parameterNames = parameterNames;
    ruleSet.redirectNames = redirectNames;
    return ruleSet;
}

// MARK: Evaluation

static bool AuraRuleApplies(
    const AuraRule *rule,
    const char *url,
    size_t urlLength,
    size_t hostStart,
    size_t hostEnd,
    size_t authorityEnd,
    const char *documentHost,
    size_t documentHostLength,
    uint32_t typeMask,
    bool isThirdParty)
{
    if (rule->types != 0 && (rule->types & typeMask) == 0) { return false; }
    if (rule->party == AuraRulePartyScopeThirdParty && !isThirdParty) { return false; }
    if (rule->party == AuraRulePartyScopeFirstParty && isThirdParty) { return false; }

    if (rule->hostLength > 0) {
        if (!AuraHostMatches(url + hostStart, hostEnd - hostStart, rule->host, rule->hostLength)) { return false; }
    }

    if (rule->domainCount > 0) {
        if (documentHostLength == 0) { return false; }
        if (!AuraDomainListMatches(rule->domains, rule->domainCount, documentHost, documentHostLength)) {
            return false;
        }
    }
    if (rule->excludedDomainCount > 0 && documentHostLength > 0) {
        if (AuraDomainListMatches(rule->excludedDomains, rule->excludedDomainCount,
                                  documentHost, documentHostLength)) {
            return false;
        }
    }

    if (rule->patternLength == 0) { return true; }
    if (rule->hostLength == 0) {
        return AuraMatchPattern(rule->pattern, rule->patternLength, url, urlLength,
                                (bool)rule->leftAnchor, (bool)rule->rightAnchor, 0);
    }
    // A `||host` rule anchors its tail right after the hostname. Try again after
    // the port when there is one, so `||host/path` still matches `host:8080/path`.
    if (AuraMatchPattern(rule->pattern, rule->patternLength, url, urlLength,
                         true, (bool)rule->rightAnchor, hostEnd)) {
        return true;
    }
    return authorityEnd != hostEnd
        && AuraMatchPattern(rule->pattern, rule->patternLength, url, urlLength,
                            true, (bool)rule->rightAnchor, authorityEnd);
}

- (BOOL)isAllowlisted:(AuraRuleSet *)ruleSet host:(NSString *)host
{
    if (ruleSet.allowlist.count == 0 || host.length == 0) { return NO; }
    NSString *lowered = host.lowercaseString;
    for (NSString *entry in ruleSet.allowlist) {
        if ([lowered isEqualToString:entry] || [lowered hasSuffix:[@"." stringByAppendingString:entry]]) {
            return YES;
        }
    }
    return NO;
}

- (AuraBlockDecision)decisionForURL:(NSURL *)url
                       documentHost:(NSString *)documentHost
                           typeMask:(uint32_t)typeMask
                        isMainFrame:(BOOL)isMainFrame
                         resultURL:(NSURL *_Nullable *_Nullable)outURL
{
    if (outURL) { *outURL = nil; }

    AuraRuleSet *ruleSet = [self currentRuleSet];
    if (ruleSet.count == 0) { return AuraBlockDecisionAllow; }
    if ([self isAllowlisted:ruleSet host:documentHost]) { return AuraBlockDecisionAllow; }

    NSString *absolute = url.absoluteString;
    const char *urlBytes = absolute.UTF8String;
    if (!urlBytes) { return AuraBlockDecisionAllow; }
    const size_t urlLength = strlen(urlBytes);

    size_t hostStart = 0;
    size_t hostEnd = 0;
    size_t authorityEnd = 0;
    if (!AuraFindHost(urlBytes, urlLength, &hostStart, &hostEnd, &authorityEnd)) {
        return AuraBlockDecisionAllow;
    }
    const size_t hostLength = hostEnd - hostStart;

    const char *documentHostBytes = documentHost.length > 0 ? documentHost.UTF8String : NULL;
    const size_t documentHostLength = documentHostBytes ? strlen(documentHostBytes) : 0;
    const bool isThirdParty = documentHostLength == 0
        ? true
        : !AuraSameSite(urlBytes + hostStart, hostLength, documentHostBytes, documentHostLength);

    size_t keyOffset = 0;
    size_t keyLength = 0;
    AuraLastTwoLabels(urlBytes + hostStart, hostLength, &keyOffset, &keyLength);
    NSString *bucketKey = [[[NSString alloc] initWithBytes:urlBytes + hostStart + keyOffset
                                                   length:keyLength
                                                 encoding:NSUTF8StringEncoding] lowercaseString];

    NSData *hostBucket = bucketKey ? ruleSet.buckets[bucketKey] : nil;
    NSData *buckets[2] = { hostBucket, ruleSet.genericIndexes };

    bool blocked = false;
    bool blockedImportant = false;
    bool excepted = false;
    NSInteger redirectIndex = -1;
    NSInteger redirectOnBlockIndex = -1;
    NSMutableArray<NSString *> *parametersToStrip = nil;

    for (int pass = 0; pass < 2; pass++) {
        NSData *bucket = buckets[pass];
        if (!bucket) { continue; }
        const uint32_t *indexes = bucket.bytes;
        const NSUInteger indexCount = bucket.length / sizeof(uint32_t);
        for (NSUInteger position = 0; position < indexCount; position++) {
            const AuraRule *rule = &ruleSet.rules[indexes[position]];
            if (!AuraRuleApplies(rule, urlBytes, urlLength, hostStart, hostEnd, authorityEnd,
                                 documentHostBytes, documentHostLength, typeMask, isThirdParty)) {
                continue;
            }
            switch (rule->kind) {
            case AuraRuleKindAllow:
                excepted = true;
                break;
            case AuraRuleKindBlock:
                blocked = true;
                if (rule->important) { blockedImportant = true; }
                break;
            case AuraRuleKindRedirect:
                if (rule->redirectOnlyWhenBlocked) {
                    if (redirectOnBlockIndex < 0) { redirectOnBlockIndex = rule->index; }
                } else if (redirectIndex < 0) {
                    redirectIndex = rule->index;
                }
                break;
            case AuraRuleKindRemoveParam:
                if (!parametersToStrip) { parametersToStrip = [NSMutableArray array]; }
                [parametersToStrip addObjectsFromArray:ruleSet.parameterNames[rule->index]];
                break;
            default:
                break;
            }
        }
    }

    if (excepted && !blockedImportant) { return AuraBlockDecisionAllow; }

    // `$removeparam` first, so a rewritten URL survives when nothing else fires.
    NSURL *rewritten = nil;
    if (parametersToStrip.count > 0) {
        rewritten = AuraStripParameters(url, parametersToStrip);
    }

    if (!isMainFrame) {
        if (redirectIndex < 0 && blocked) { redirectIndex = redirectOnBlockIndex; }
        if (redirectIndex >= 0) {
            NSString *resource = AuraRedirectResources()[ruleSet.redirectNames[redirectIndex]];
            NSURL *replacement = resource ? [NSURL URLWithString:resource] : nil;
            if (replacement) {
                if (outURL) { *outURL = replacement; }
                return AuraBlockDecisionRedirect;
            }
            // ponytail: uBO's functional stubs (google-ima.js, gpt.js, …) are not
            // shipped, so those rules fall back to whatever the block rules said.
            // Blocking them outright breaks video players. Ship the stubs to fix.
            if (blocked) { return AuraBlockDecisionBlock; }
        }
        if (blocked) { return AuraBlockDecisionBlock; }
    }

    if (rewritten) {
        if (outURL) { *outURL = rewritten; }
        return AuraBlockDecisionRewrite;
    }
    return AuraBlockDecisionAllow;
}

static bool AuraSameSite(const char *host, size_t hostLength, const char *other, size_t otherLength)
{
    size_t hostOffset = 0;
    size_t hostKeyLength = 0;
    AuraLastTwoLabels(host, hostLength, &hostOffset, &hostKeyLength);
    size_t otherOffset = 0;
    size_t otherKeyLength = 0;
    AuraLastTwoLabels(other, otherLength, &otherOffset, &otherKeyLength);
    if (hostKeyLength != otherKeyLength) { return false; }
    return strncasecmp(host + hostOffset, other + otherOffset, hostKeyLength) == 0;
}

static NSURL *AuraStripParameters(NSURL *url, NSArray<NSString *> *parameters)
{
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSArray<NSURLQueryItem *> *items = components.queryItems;
    if (items.count == 0) { return nil; }

    const BOOL stripEverything = [parameters containsObject:@""];
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray arrayWithCapacity:items.count];
    if (!stripEverything) {
        NSSet<NSString *> *names = [NSSet setWithArray:parameters];
        for (NSURLQueryItem *item in items) {
            if (![names containsObject:item.name]) { [kept addObject:item]; }
        }
    }
    if (kept.count == items.count) { return nil; }

    components.queryItems = kept.count > 0 ? kept : nil;
    if (kept.count == 0) { components.percentEncodedQuery = nil; }
    return components.URL;
}

// MARK: Resource type

+ (uint32_t)typeMaskForURL:(NSURL *)url acceptHeader:(NSString *)acceptHeader isMainFrame:(BOOL)isMainFrame
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

    // Nothing to go on. Match everything so a type-restricted rule still fires.
    return AuraResourceTypeAny;
}

@end
