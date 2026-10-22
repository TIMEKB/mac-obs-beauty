#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/utsname.h>

static NSString *const RepositoryURL = @"https://github.com/TIMEKB/obs-live-beauty";
static NSString *const StarMessage = @"如果这个插件对你有帮助，请给我一个星星 ⭐。";
static NSFileManager *FM(void) { return NSFileManager.defaultManager; }
static NSString *Join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static NSString *String(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSArray *Array(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSDictionary *Dictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static NSString *Absolute(NSString *path) {
    NSString *expanded = path.stringByExpandingTildeInPath;
    return (expanded.isAbsolutePath ? expanded : Join(FM().currentDirectoryPath, expanded)).stringByStandardizingPath;
}
static BOOL SafeRelative(NSString *path) {
    if (!path.length || path.isAbsolutePath || [path containsString:@"\\"] || [path containsString:@":"] || [path containsString:[NSString stringWithFormat:@"%C", (unichar)0]]) return NO;
    for (NSString *part in path.pathComponents) if ([part isEqual:@".."] || [part isEqual:@"."]) return NO;
    return YES;
}
static NSDictionary *ReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? Dictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : @{};
}
static BOOL WriteJSON(NSDictionary *object, NSString *path, NSString **error) {
    NSError *e = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&e];
    BOOL ok = data && [data writeToFile:path options:NSDataWritingAtomic error:&e];
    if (!ok && error) *error = e.localizedDescription ?: @"无法写入 JSON";
    return ok;
}
static NSString *Digest(NSString *path, BOOL md5) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX sha; CC_MD5_CTX md;
    if (md5) CC_MD5_Init(&md); else CC_SHA256_Init(&sha);
    uint8_t buffer[65536]; NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        if (md5) CC_MD5_Update(&md, buffer, (CC_LONG)count); else CC_SHA256_Update(&sha, buffer, (CC_LONG)count);
    }
    [stream close];
    if (count < 0) return @"";
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    if (md5) CC_MD5_Final(bytes, &md); else CC_SHA256_Final(bytes, &sha);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < (md5 ? CC_MD5_DIGEST_LENGTH : CC_SHA256_DIGEST_LENGTH); ++i) [result appendFormat:@"%02x", bytes[i]];
    return result;
}
static BOOL RegularFile(NSString *path) {
    NSDictionary *attrs = [FM() attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileType] isEqual:NSFileTypeRegular];
}
static BOOL MatchHash(NSString *path, NSDictionary *entry) {
    NSString *sha = String(entry[@"sha256"]).lowercaseString, *md5 = String(entry[@"md5"]).lowercaseString;
    if (!RegularFile(path) || (!sha.length && !md5.length)) return NO;
    return (!sha.length || [Digest(path, NO) isEqual:sha]) && (!md5.length || [Digest(path, YES) isEqual:md5]);
}
static BOOL Directory(NSString *path, NSString **error) {
    NSError *e = nil;
    BOOL ok = [FM() createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&e];
    if (!ok && error) *error = e.localizedDescription;
    return ok;
}
static BOOL Copy(NSString *source, NSString *destination, NSString **error) {
    if (!Directory(destination.stringByDeletingLastPathComponent, error)) return NO;
    NSError *e = nil;
    BOOL ok = [FM() copyItemAtPath:source toPath:destination error:&e];
    if (!ok && error) *error = e.localizedDescription;
    return ok;
}
static BOOL VerifyTree(NSString *root, NSArray *files) {
    if (!files.count) return NO;
    for (id item in files) {
        NSDictionary *entry = Dictionary(item);
        NSString *path = String(entry[@"path"]);
        if (!SafeRelative(path) || !MatchHash(Join(root, path), entry)) return NO;
    }
    return YES;
}
static BOOL CopyVerifiedTree(NSString *source, NSString *destination, NSArray *files, NSString **error) {
    if (!VerifyTree(source, files)) return NO;
    for (NSDictionary *entry in files) {
        NSString *path = String(entry[@"path"]);
        if (!Copy(Join(source, path), Join(destination, path), error)) return NO;
    }
    return VerifyTree(destination, files);
}

// Validate the central directory before passing an archive to the system extractor.
// No ZIP64, encrypted entries, symlinks, hard links, traversal or unbounded output.
static uint16_t U16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t U32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static BOOL ValidateZIP(NSString *path, NSString **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *b = (const uint8_t *)data.bytes; NSUInteger size = data.length;
    if (size < 22) { if (error) *error = @"ZIP 文件不完整"; return NO; }
    NSUInteger end = NSNotFound, low = size > 65557 ? size - 65557 : 0;
    for (NSUInteger i = size - 22;; --i) {
        if (U32(b + i) == 0x06054b50 && i + 22 + U16(b + i + 20) == size) { end = i; break; }
        if (i == low) break;
    }
    if (end == NSNotFound || U16(b + end + 4) || U16(b + end + 6)) { if (error) *error = @"不支持的 ZIP 结构"; return NO; }
    uint16_t count = U16(b + end + 10); uint32_t offset = U32(b + end + 16), directorySize = U32(b + end + 12);
    if (!count || count == 65535 || count > 20000 || offset == UINT32_MAX || (uint64_t)offset + directorySize > end) { if (error) *error = @"ZIP 文件数量或目录超出限制"; return NO; }
    NSUInteger cursor = offset; uint64_t total = 0;
    for (NSUInteger i = 0; i < count; ++i) {
        if (cursor > size || size - cursor < 46 || U32(b + cursor) != 0x02014b50) { if (error) *error = @"ZIP 目录损坏"; return NO; }
        uint16_t nameLength = U16(b + cursor + 28), extraLength = U16(b + cursor + 30), commentLength = U16(b + cursor + 32);
        uint32_t unpacked = U32(b + cursor + 24), attributes = U32(b + cursor + 38);
        NSUInteger next = cursor + 46 + nameLength + extraLength + commentLength;
        if (next > size || !nameLength || unpacked == UINT32_MAX || U16(b + cursor + 8) & 1) { if (error) *error = @"ZIP 条目不受支持"; return NO; }
        NSData *nameData = [NSData dataWithBytes:b + cursor + 46 length:nameLength];
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithData:nameData encoding:NSISOLatin1StringEncoding];
        mode_t mode = (mode_t)(attributes >> 16);
        if (!SafeRelative(name) || (mode & S_IFMT) == S_IFLNK || ((mode & S_IFMT) && (mode & S_IFMT) != S_IFREG && (mode & S_IFMT) != S_IFDIR)) {
            if (error) *error = @"ZIP 含不安全的路径或链接"; return NO;
        }
        uint32_t localOffset = U32(b + cursor + 42);
        if ((uint64_t)localOffset + 30 > size || U32(b + localOffset) != 0x04034b50 || U16(b + localOffset + 26) != nameLength ||
            (uint64_t)localOffset + 30 + nameLength > size || memcmp(b + localOffset + 30, nameData.bytes, nameLength)) {
            if (error) *error = @"ZIP 本地文件路径与目录不一致"; return NO;
        }
        total += unpacked;
        if (total > 1024ULL * 1024 * 1024) { if (error) *error = @"ZIP 展开体积超过 1 GiB"; return NO; }
        cursor = next;
    }
    return YES;
}
static BOOL Run(NSString *program, NSArray *arguments, NSString **error) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:program]; task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe]; task.standardError = pipe; task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    NSError *e = nil;
    if (![task launchAndReturnError:&e]) { if (error) *error = e.localizedDescription; return NO; }
    NSData *output = [pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    if (task.terminationStatus != 0 && error) *error = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"系统工具执行失败";
    return task.terminationStatus == 0;
}

@interface DownloadDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate>
@end
@implementation DownloadDelegate
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)expected {
    if (totalBytesWritten > 512LL * 1024 * 1024 || expected > 512LL * 1024 * 1024) [task cancel];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSString *oldHost = task.originalRequest.URL.host.lowercaseString ?: @"", *newHost = request.URL.host.lowercaseString ?: @"";
    completionHandler([request.URL.scheme.lowercaseString isEqual:@"https"] && [oldHost isEqual:newHost] ? request : nil);
}
@end
static BOOL Download(NSArray *urls, NSString *destination, NSString **error) {
    for (id raw in urls) {
        NSURL *url = [NSURL URLWithString:String(raw)];
        if (![url.scheme.lowercaseString isEqual:@"https"] || !url.host.length || url.user.length || url.password.length) continue;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil; configuration.URLCredentialStorage = nil;
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 300;
        DownloadDelegate *delegate = [DownloadDelegate new];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
        dispatch_semaphore_t signal = dispatch_semaphore_create(0);
        __block BOOL ok = NO; __block NSString *failure = @"下载失败";
        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *e) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSNumber *bytes = nil; [location getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
            if (!e && status >= 200 && status < 300 && bytes.unsignedLongLongValue <= 512ULL * 1024 * 1024) {
                NSError *copyError = nil; ok = [FM() copyItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:&copyError];
                failure = copyError.localizedDescription ?: failure;
            } else failure = e.localizedDescription ?: [NSString stringWithFormat:@"下载 HTTP %ld 或文件超过 512 MiB", (long)status];
            dispatch_semaphore_signal(signal);
        }];
        [task resume]; dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER); [session finishTasksAndInvalidate];
        if (ok) return YES;
        if (error) *error = failure;
    }
    if (error && !*error) *error = @"没有可用的 HTTPS 下载地址";
    return NO;
}

@interface InstallOptions : NSObject
@property(nonatomic, copy) NSString *app, *pluginDirectory, *resourceDirectory, *importDirectory, *assets;
@property BOOL check, install, json, noninteractive;
@end
@implementation InstallOptions
- (instancetype)init {
    if ((self = [super init])) {
        _app = @"/Applications/Douyin Webcast Mate.app";
        _pluginDirectory = Join(NSHomeDirectory(), @"Library/Application Support/obs-studio/plugins");
        _resourceDirectory = Join(NSHomeDirectory(), @"Library/Application Support/obs-live-beauty/engine-resources");
        _importDirectory = @""; _assets = NSBundle.mainBundle.resourcePath ?: @"";
    } return self;
}
@end

static BOOL OBSRunning(void) {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) if ([app.bundleIdentifier isEqual:@"com.obsproject.obs-studio"]) return YES;
    return NO;
}
typedef void (^Progress)(NSString *, double);

@interface Installer : NSObject
@property(nonatomic, strong) InstallOptions *options;
@property(nonatomic, strong) NSDictionary *spec;
@property(nonatomic, copy) NSString *version, *runtime;
@property(nonatomic, strong) NSMutableArray<NSString *> *errors;
@property(nonatomic) BOOL obsRunning, dependenciesReady;
- (instancetype)initWithOptions:(InstallOptions *)options;
- (NSDictionary *)check;
- (BOOL)installWithProgress:(Progress)progress;
- (NSDictionary *)result:(NSString *)action ok:(BOOL)ok message:(NSString *)message;
@end
@implementation Installer
- (instancetype)initWithOptions:(InstallOptions *)options {
    if ((self = [super init])) { _options = options; _spec = ReadJSON(Join(options.assets, @"install-manifest.json")); _errors = [NSMutableArray array]; }
    return self;
}
- (BOOL)preflight {
    [self.errors removeAllObjects]; self.obsRunning = OBSRunning();
    struct utsname platform; if (uname(&platform) || strcmp(platform.machine, "arm64")) [self.errors addObject:@"此安装包仅支持 Apple Silicon Mac。"];
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 13) [self.errors addObject:@"需要 macOS 13 或更新系统。"];
    if (!self.spec.count) [self.errors addObject:@"安装包缺少 install-manifest.json。"];
    if (![FM() fileExistsAtPath:Join(self.options.assets, @"obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty")]) [self.errors addObject:@"安装包缺少插件二进制。"];
    if (!RegularFile(Join(self.options.assets, @"windows-catalog.json")) || !RegularFile(Join(self.options.assets, @"detector/config.json"))) [self.errors addObject:@"安装包缺少效果目录或检测配置。"];
    NSDictionary *obsInfo = [NSDictionary dictionaryWithContentsOfFile:@"/Applications/OBS.app/Contents/Info.plist"];
    NSString *expectedOBS = String(self.spec[@"obs_version"]); if (!expectedOBS.length) expectedOBS = @"32.2.1";
    if (![String(obsInfo[@"CFBundleShortVersionString"]) isEqual:expectedOBS]) [self.errors addObject:[NSString stringWithFormat:@"需要 /Applications/OBS.app 中的 OBS %@。", expectedOBS]];
    NSArray *obsArchitectures = [NSBundle bundleWithPath:@"/Applications/OBS.app"].executableArchitectures;
    if (![obsArchitectures containsObject:@(0x0100000c)]) [self.errors addObject:@"OBS 必须包含 Apple Silicon arm64 版本。"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:Join(self.options.app, @"Contents/Info.plist")];
    self.version = String(info[@"CFBundleShortVersionString"]);
    NSString *expected = String(self.spec[@"source_app_version"]);
    if (!self.version.length) [self.errors addObject:@"请先安装官方 Mac 直播伴侣，再重试。"];
    else if (expected.length && ![self.version isEqual:expected]) [self.errors addObject:[NSString stringWithFormat:@"当前官方直播伴侣版本为 %@；本安装包已验证版本为 %@。", self.version, expected]];
    NSDictionary *runtime = Dictionary(self.spec[@"runtime"]); NSString *relative = String(runtime[@"relative_path"]);
    self.runtime = SafeRelative(relative) ? Join(self.options.app, relative) : @"";
    if (!self.runtime.length || !MatchHash(self.runtime, runtime)) [self.errors addObject:@"官方运行库缺失或 SHA-256 与已验证版本不符。"];
    if (self.obsRunning) [self.errors addObject:@"OBS 正在运行。请自行退出 OBS 后重试，安装器不会关闭它。"];
    NSString *resource = self.options.resourceDirectory, *pluginDirectory = self.options.pluginDirectory;
    if ([resource isEqual:@"/"] || [resource isEqual:NSHomeDirectory()] || [resource isEqual:pluginDirectory] ||
        [pluginDirectory hasPrefix:[resource stringByAppendingString:@"/"]] || [resource hasPrefix:[self.options.app stringByAppendingString:@"/"]])
        [self.errors addObject:@"资源目录与用户目录、OBS 插件目录或官方应用冲突。"];
    if ([FM() fileExistsAtPath:resource] && !RegularFile(Join(resource, @"manifest.json"))) {
        NSArray *contents = [FM() contentsOfDirectoryAtPath:resource error:nil];
        if (contents.count) [self.errors addObject:@"目标资源目录已有其他文件且不含本插件 manifest.json，请指定独立目录。"];
    }
    NSMutableSet *paths = [NSMutableSet set];
    for (id raw in Array(self.spec[@"downloads"])) {
        NSDictionary *asset = Dictionary(raw); NSString *path = String(asset[@"relative_path"]), *kind = String(asset[@"kind"]);
        if (!SafeRelative(path) || [paths containsObject:path] || (! [kind isEqual:@"zip"] && ![kind isEqual:@"file"]) || (!String(asset[@"sha256"]).length && !String(asset[@"md5"]).length)) [self.errors addObject:@"安装资源清单含无效路径、重复路径或缺少校验值。"];
        [paths addObject:path ?: @""];
    }
    self.dependenciesReady = !self.errors.count;
    return self.dependenciesReady;
}
- (BOOL)resourcesReady {
    NSString *root = self.options.resourceDirectory;
    for (id raw in Array(self.spec[@"downloads"])) {
        NSDictionary *asset = Dictionary(raw); NSString *path = String(asset[@"relative_path"]);
        if (!SafeRelative(path)) return NO;
        if ([String(asset[@"kind"]) isEqual:@"file"]) { if (!MatchHash(Join(root, path), asset)) return NO; }
        else if (!VerifyTree(Join(root, path), Array(asset[@"files"]))) return NO;
    }
    NSDictionary *manifest = ReadJSON(Join(root, @"manifest.json"));
    if (![String(manifest[@"runtime_library"]) isEqual:self.runtime] || ![String(manifest[@"runtime_sha256"]) isEqual:String(Dictionary(self.spec[@"runtime"])[@"sha256"])]) return NO;
    if (![Digest(Join(root, @"windows-catalog.json"), NO) isEqual:Digest(Join(self.options.assets, @"windows-catalog.json"), NO)]) return NO;
    for (NSString *file in [FM() enumeratorAtPath:Join(self.options.assets, @"detector")]) {
        NSString *source = Join(Join(self.options.assets, @"detector"), file);
        if (RegularFile(source) && ![Digest(source, NO) isEqual:Digest(Join(Join(root, @"nodes/native-face-detector"), file), NO)]) return NO;
    }
    return YES;
}
- (BOOL)pluginReady {
    NSString *relative = @"obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty";
    NSString *installed = Join(self.options.pluginDirectory, relative), *payload = Join(self.options.assets, relative);
    return RegularFile(installed) && [Digest(installed, NO) isEqual:Digest(payload, NO)];
}
- (NSDictionary *)check {
    BOOL dependencies = [self preflight]; BOOL resources = dependencies && [self resourcesReady];
    if (dependencies && !resources) [self.errors addObject:@"本地效果资源尚未安装或校验不匹配；执行安装后将导入或下载固定版本资源。"];
    BOOL plugin = dependencies && [self pluginReady];
    if (dependencies && !plugin) [self.errors addObject:@"插件尚未安装或与当前安装包版本不同。"];
    return [self result:@"check" ok:dependencies && resources && plugin message:resources && plugin ? @"依赖、插件和效果资源已就绪。" : @"尚未就绪，请查看 errors。"];
}
- (NSDictionary *)result:(NSString *)action ok:(BOOL)ok message:(NSString *)message {
    return @{@"action":action, @"ok":@(ok), @"ready":@(ok), @"obs_running":@(self.obsRunning), @"source_app":self.options.app,
             @"source_version":self.version ?: @"", @"plugin_dir":self.options.pluginDirectory, @"resource_dir":self.options.resourceDirectory,
             @"dependencies_ready":@(self.dependenciesReady), @"resources_ready":@(self.dependenciesReady && [self resourcesReady]), @"plugin_ready":@(self.dependenciesReady && [self pluginReady]),
             @"message":message ?: @"", @"errors":[self.errors copy], @"repository":RepositoryURL, @"star_message":StarMessage};
}
- (BOOL)prepareAsset:(NSDictionary *)asset stage:(NSString *)stage work:(NSString *)work error:(NSString **)error {
    NSString *relative = String(asset[@"relative_path"]), *destination = Join(stage, relative);
    NSArray *files = Array(asset[@"files"]); BOOL zipped = [String(asset[@"kind"]) isEqual:@"zip"];
    NSArray *sources = self.options.importDirectory.length ? @[self.options.importDirectory, self.options.resourceDirectory] : @[self.options.resourceDirectory];
    for (NSString *sourceRoot in sources) {
        NSString *source = Join(sourceRoot, relative);
        if (zipped && VerifyTree(source, files)) return CopyVerifiedTree(source, destination, files, error);
        if (!zipped && MatchHash(source, asset)) return Copy(source, destination, error) && MatchHash(destination, asset);
    }
    NSString *download = Join(work, [NSUUID UUID].UUIDString);
    if (!Download(Array(asset[@"urls"]), download, error)) return NO;
    if (!MatchHash(download, asset)) { if (error) *error = [@"下载校验失败：" stringByAppendingString:relative]; return NO; }
    if (!zipped) return Copy(download, destination, error) && MatchHash(destination, asset);
    if (!ValidateZIP(download, error)) return NO;
    NSString *unpacked = [download stringByAppendingString:@".unpacked"];
    if (!Directory(unpacked, error) || !Run(@"/usr/bin/ditto", @[@"-x", @"-k", download, unpacked], error)) return NO;
    NSString *content = unpacked;
    if (!RegularFile(Join(content, @"config.json"))) {
        NSArray *children = [FM() contentsOfDirectoryAtPath:unpacked error:nil];
        for (NSString *child in children) if (![child isEqual:@"__MACOSX"] && RegularFile(Join(Join(unpacked, child), @"config.json"))) { content = Join(unpacked, child); break; }
    }
    if (files.count) {
        if (!CopyVerifiedTree(content, destination, files, error)) { if (error && !*error) *error = [@"节点文件校验失败：" stringByAppendingString:relative]; return NO; }
    } else {
        if (!RegularFile(Join(content, @"config.json"))) { if (error) *error = [@"节点缺少 config.json：" stringByAppendingString:relative]; return NO; }
        if (!Copy(content, destination, error)) return NO;
    }
    return YES;
}
- (BOOL)installWithProgress:(Progress)progress {
    if (![self preflight]) return NO;
    NSString *failure = nil, *resourceParent = self.options.resourceDirectory.stringByDeletingLastPathComponent;
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *stage = Join(resourceParent, [@".engine-resources.install-" stringByAppendingString:nonce]);
    NSString *work = Join(NSTemporaryDirectory(), [@"obs-live-beauty-download-" stringByAppendingString:nonce]);
    NSString *pluginName = @"obs-live-beauty.plugin", *plugin = Join(self.options.pluginDirectory, pluginName);
    NSString *pluginStage = Join(self.options.pluginDirectory, [@".obs-live-beauty.install-" stringByAppendingString:nonce]);
    NSString *resourceOld = [self.options.resourceDirectory stringByAppendingFormat:@".previous-%@", nonce];
    NSString *pluginOld = [plugin stringByAppendingFormat:@".previous-%@", nonce];
    __block BOOL ok = Directory(stage, &failure) && Directory(work, &failure) && Directory(self.options.pluginDirectory, &failure);
    NSArray *downloads = Array(self.spec[@"downloads"]); NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 4;
    NSLock *lock = [NSLock new]; __block NSUInteger complete = 0;
    if (ok) for (NSDictionary *asset in downloads) [queue addOperationWithBlock:^{ @autoreleasepool {
        NSString *error = nil; BOOL assetOK = [self prepareAsset:asset stage:stage work:work error:&error];
        [lock lock]; ++complete;
        if (!assetOK) { ok = NO; [self.errors addObject:error ?: [@"资源处理失败：" stringByAppendingString:String(asset[@"relative_path"])]]; }
        double percent = downloads.count ? (double)complete / downloads.count : 1;
        progress([NSString stringWithFormat:@"准备资源 %lu / %lu", (unsigned long)complete, (unsigned long)downloads.count], percent * .85);
        [lock unlock];
    }}];
    [queue waitUntilAllOperationsAreFinished];
    if (ok) {
        progress(@"整理配置与插件…", .90);
        ok = Copy(Join(self.options.assets, @"windows-catalog.json"), Join(stage, @"windows-catalog.json"), &failure) &&
             Copy(Join(self.options.assets, @"detector"), Join(stage, @"nodes/native-face-detector"), &failure);
    }
    if (ok) {
        NSDictionary *manifest = @{@"schema_version":@1, @"source_app_version":self.version ?: @"", @"runtime_library":self.runtime ?: @"", @"runtime_sha256":String(Dictionary(self.spec[@"runtime"])[@"sha256"]), @"models":Array(self.spec[@"models"])};
        ok = WriteJSON(manifest, Join(stage, @"manifest.json"), &failure) && Copy(Join(self.options.assets, pluginName), pluginStage, &failure);
    }
    if (ok && OBSRunning()) { ok = NO; failure = @"OBS 已启动，请退出 OBS 后重试。"; }
    BOOL movedResources = NO, movedPlugin = NO, placedResources = NO, placedPlugin = NO;
    if (ok) {
        NSError *e = nil;
        if ([FM() fileExistsAtPath:self.options.resourceDirectory]) { movedResources = [FM() moveItemAtPath:self.options.resourceDirectory toPath:resourceOld error:&e]; ok = movedResources; }
        if (ok) { placedResources = [FM() moveItemAtPath:stage toPath:self.options.resourceDirectory error:&e]; ok = placedResources; }
        if (ok && [FM() fileExistsAtPath:plugin]) { movedPlugin = [FM() moveItemAtPath:plugin toPath:pluginOld error:&e]; ok = movedPlugin; }
        if (ok) { placedPlugin = [FM() moveItemAtPath:pluginStage toPath:plugin error:&e]; ok = placedPlugin; }
        if (!ok) failure = e.localizedDescription ?: @"替换插件失败";
        if (ok && (![self resourcesReady] || ![self pluginReady])) { ok = NO; failure = @"最终安装内容校验失败。"; }
    }
    if (!ok) {
        NSError *rollback = nil;
        if (placedPlugin && ![FM() removeItemAtPath:plugin error:&rollback]) [self.errors addObject:[NSString stringWithFormat:@"无法移除未完成的插件 %@：%@", plugin, rollback.localizedDescription]];
        rollback = nil;
        if (movedPlugin && ![FM() moveItemAtPath:pluginOld toPath:plugin error:&rollback]) [self.errors addObject:[NSString stringWithFormat:@"恢复旧插件失败；原件保留于 %@：%@", pluginOld, rollback.localizedDescription]];
        rollback = nil;
        if (placedResources && ![FM() removeItemAtPath:self.options.resourceDirectory error:&rollback]) [self.errors addObject:[NSString stringWithFormat:@"无法移除未完成的资源 %@：%@", self.options.resourceDirectory, rollback.localizedDescription]];
        rollback = nil;
        if (movedResources && ![FM() moveItemAtPath:resourceOld toPath:self.options.resourceDirectory error:&rollback]) [self.errors addObject:[NSString stringWithFormat:@"恢复旧资源失败；原件保留于 %@：%@", resourceOld, rollback.localizedDescription]];
        if (failure.length) [self.errors addObject:failure];
    } else { [FM() removeItemAtPath:pluginOld error:nil]; [FM() removeItemAtPath:resourceOld error:nil]; progress(@"安装完成。请打开 OBS → 停靠窗口 → 直播美颜。", 1); }
    [FM() removeItemAtPath:stage error:nil]; [FM() removeItemAtPath:pluginStage error:nil]; [FM() removeItemAtPath:work error:nil];
    return ok;
}
@end

@interface InstallerWindow : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) Installer *installer;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *status, *detail;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSButton *installButton, *starButton;
@end
@implementation InstallerWindow
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,580,330) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"OBS 直播美颜安装器"; [self.window center];
    NSView *content = self.window.contentView;
    NSTextField *title = [NSTextField labelWithString:@"OBS 直播美颜 · Apple Silicon"]; title.font = [NSFont boldSystemFontOfSize:23]; title.frame = NSMakeRect(28,274,530,35); [content addSubview:title];
    self.status = [NSTextField wrappingLabelWithString:@"安装到当前用户，不修改 OBS 场景或原应用。"]; self.status.frame = NSMakeRect(28,222,524,45); [content addSubview:self.status];
    NSString *sourceVersion = String(self.installer.spec[@"source_app_version"]), *obsVersion = String(self.installer.spec[@"obs_version"]);
    self.detail = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"需要已安装官方 Mac 直播伴侣 %@ 和 arm64 OBS %@。\n缺少效果资源时，将从固定的官方 CDN 下载并校验。", sourceVersion.length ? sourceVersion : @"指定版本", obsVersion.length ? obsVersion : @"32.2.1"]]; self.detail.frame = NSMakeRect(28,118,524,100); self.detail.font = [NSFont systemFontOfSize:12]; [content addSubview:self.detail];
    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(28,104,524,14)]; self.progress.indeterminate = NO; self.progress.minValue = 0; self.progress.maxValue = 100; [content addSubview:self.progress];
    self.installButton = [NSButton buttonWithTitle:@"检查并安装" target:self action:@selector(install:)]; self.installButton.bezelStyle = NSBezelStyleRounded; self.installButton.frame = NSMakeRect(412,51,140,34); [content addSubview:self.installButton];
    self.starButton = [NSButton buttonWithTitle:@"给项目一个星星 ⭐" target:self action:@selector(star:)]; self.starButton.bezelStyle = NSBezelStyleRounded; self.starButton.frame = NSMakeRect(28,51,180,34); [content addSubview:self.starButton];
    NSTextField *starText = [NSTextField labelWithString:StarMessage]; starText.font = [NSFont systemFontOfSize:12]; starText.frame = NSMakeRect(28,20,524,20); [content addSubview:starText];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)install:(id)sender {
    self.installButton.enabled = NO; self.status.stringValue = @"检查依赖…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        BOOL ok = [self.installer installWithProgress:^(NSString *message, double percent) { dispatch_async(dispatch_get_main_queue(), ^{ self.status.stringValue = message; self.progress.doubleValue = percent * 100; }); }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.installButton.enabled = YES; self.installButton.title = ok ? @"重新检查并安装" : @"重试安装";
            if (!ok) { self.status.stringValue = @"尚未安装，请处理以下问题后重试。"; self.detail.stringValue = [self.installer.errors componentsJoinedByString:@"\n"]; }
            else self.detail.stringValue = @"安装完成。请启动 OBS，在「停靠窗口」勾选「直播美颜」，再选择视频来源。\n运行库保持在官方应用目录中，请保留官方应用。";
        });
    }});
}
- (void)star:(id)sender { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:RepositoryURL]]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    InstallOptions *options = [InstallOptions new]; NSString *argumentError = nil;
    for (int i = 1; i < argc; ++i) {
        NSString *arg = @(argv[i]);
        if ([arg isEqual:@"--check"]) options.check = YES;
        else if ([arg isEqual:@"--install"]) options.install = YES;
        else if ([arg isEqual:@"--json"]) options.json = YES;
        else if ([arg isEqual:@"--non-interactive"]) options.noninteractive = YES;
        else if ([arg isEqual:@"--app"] || [arg isEqual:@"--plugin-dir"] || [arg isEqual:@"--resource-dir"] || [arg isEqual:@"--resources-from"] || [arg isEqual:@"--assets-dir"]) {
            if (++i >= argc) { argumentError = [@"缺少参数：" stringByAppendingString:arg]; break; }
            NSString *value = Absolute(@(argv[i]));
            if ([arg isEqual:@"--app"]) options.app = value;
            else if ([arg isEqual:@"--plugin-dir"]) options.pluginDirectory = value;
            else if ([arg isEqual:@"--resource-dir"]) options.resourceDirectory = value;
            else if ([arg isEqual:@"--assets-dir"]) options.assets = value;
            else options.importDirectory = value;
        } else if ([arg isEqual:@"--help"]) {
            puts("obs-live-beauty-installer [--check | --install] [--non-interactive] [--json]\n  --app PATH             Official Mac application (default /Applications/Douyin Webcast Mate.app)\n  --resources-from PATH  Import verified existing engine-resources\n  --plugin-dir PATH      Parent OBS plugins directory\n  --resource-dir PATH    External engine-resources destination\n  --assets-dir PATH      Installer payload override (for staging/verification)\nNo arguments: open the installation window. Exit: 0 success, 1 install failure, 2 check not ready, 64 invalid arguments."); return 0;
        } else { argumentError = [@"未知参数：" stringByAppendingString:arg]; break; }
    }
    if (options.check && options.install) argumentError = @"--check 与 --install 不能同时使用。";
    if (!options.check && !options.install && (options.json || options.noninteractive)) argumentError = @"命令行调用需要 --check 或 --install。";
    if (argumentError) { fprintf(stderr, "%s\n", argumentError.UTF8String); return 64; }
    Installer *installer = [[Installer alloc] initWithOptions:options];
    if (!options.check && !options.install) {
        [NSApplication sharedApplication]; InstallerWindow *delegate = [InstallerWindow new]; delegate.installer = installer; NSApp.delegate = delegate; [NSApp run]; return 0;
    }
    @try {
        NSDictionary *result; int code;
        if (options.check) { result = [installer check]; code = [result[@"ok"] boolValue] ? 0 : 2; }
        else {
            BOOL ok = [installer installWithProgress:^(NSString *message, double percent) { if (!options.json) fprintf(stderr, "%3.0f%% %s\n", percent * 100, message.UTF8String); }];
            result = [installer result:@"install" ok:ok message:ok ? @"安装完成。" : @"安装失败。安装器已尝试恢复旧文件；请查看 errors 中的结果和恢复路径。"]; code = ok ? 0 : 1;
        }
        if (options.json) { NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]; fwrite(json.bytes, 1, json.length, stdout); putchar('\n'); }
        else { puts(String(result[@"message"]).UTF8String); for (NSString *error in Array(result[@"errors"])) fprintf(stderr, "%s\n", error.UTF8String); if (code == 0) puts(StarMessage.UTF8String); }
        return code;
    } @catch (NSException *exception) { fprintf(stderr, "安装器错误：%s\n", exception.reason.UTF8String); return 1; }
} }
