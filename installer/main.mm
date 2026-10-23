#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/utsname.h>

static NSString *const RepositoryURL = @"https://github.com/TIMEKB/mac-obs-beauty";
static NSString *const OBSDownloadURL = @"https://github.com/obsproject/obs-studio/releases/download/32.2.1/OBS-Studio-32.2.1-macOS-Apple.dmg";
static NSString *const CompanionDownloadURL = @"https://lf3-cdn-tos.bytegoofy.com/obj/tron-demo/7637411201357453594/429701125/10.0.0/darwin-universal/douyin-webcast-mate-v10.0.0-master-d169fb19-darwin-universal.dmg";
static NSString *const CompanionWebsiteURL = @"https://streamingtool.douyin.com/";
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
@property(nonatomic, copy) NSString *app, *obsApp, *pluginDirectory, *resourceDirectory, *importDirectory, *assets;
@property BOOL check, install, json, noninteractive, explicitApp, explicitOBS, pluginOnly;
@end
@implementation InstallOptions
- (instancetype)init {
    if ((self = [super init])) {
        _app = @"/Applications/Douyin Webcast Mate.app"; _obsApp = @"/Applications/OBS.app";
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
static NSString *DiscoverApp(NSString *name) {
    NSString *system = Join(@"/Applications", name), *user = Join(Join(NSHomeDirectory(), @"Applications"), name);
    return [FM() fileExistsAtPath:system] ? system : ([FM() fileExistsAtPath:user] ? user : system);
}
typedef void (^Progress)(NSString *, double);

@interface Installer : NSObject
@property(nonatomic, strong) InstallOptions *options;
@property(nonatomic, strong) NSDictionary *spec, *selectedRuntime;
@property(nonatomic, strong) NSArray *dependencies;
@property(nonatomic, copy) NSString *version, *runtime;
@property(nonatomic, strong) NSMutableArray<NSString *> *errors;
@property(nonatomic) BOOL obsRunning, dependenciesReady;
- (instancetype)initWithOptions:(InstallOptions *)options;
- (NSDictionary *)check;
- (BOOL)preflight;
- (BOOL)installWithProgress:(Progress)progress;
- (BOOL)installPluginOnly;
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
    if (self.options.pluginOnly) {
        self.version = @""; self.runtime = @""; self.selectedRuntime = @{}; self.dependencies = @[];
        if (self.obsRunning) [self.errors addObject:@"OBS 正在运行。请结束直播/录制并退出 OBS 后安装。"];
        self.dependenciesReady = !self.errors.count; return self.dependenciesReady;
    }
    if (!self.options.explicitOBS) self.options.obsApp = DiscoverApp(@"OBS.app");
    if (!self.options.explicitApp) self.options.app = DiscoverApp(@"Douyin Webcast Mate.app");
    NSDictionary *obsInfo = [NSDictionary dictionaryWithContentsOfFile:Join(self.options.obsApp, @"Contents/Info.plist")];
    NSString *expectedOBS = String(self.spec[@"obs_version"]); if (!expectedOBS.length) expectedOBS = @"32.2.1";
    NSString *obsVersion = String(obsInfo[@"CFBundleShortVersionString"]);
    NSString *obsCode = @"ready", *obsMessage = [NSString stringWithFormat:@"已找到 OBS %@（Apple Silicon）。", obsVersion];
    if (!obsVersion.length) { obsCode = @"missing"; obsMessage = @"未安装 OBS。点击「下载兼容 OBS」，打开下载的 DMG，将 OBS 拖入 Applications。"; }
    else if (![String(obsInfo[@"CFBundleIdentifier"]) isEqual:@"com.obsproject.obs-studio"]) { obsCode = @"invalid_app"; obsMessage = @"所选应用不是 OBS Studio，请重新选择。"; }
    else if (![obsVersion isEqual:expectedOBS]) { obsCode = @"unsupported_version"; obsMessage = [NSString stringWithFormat:@"当前 OBS %@；需要已验证的 %@。下载前先退出 OBS，并保留你的场景设置。", obsVersion, expectedOBS]; }
    else if (![[NSBundle bundleWithPath:self.options.obsApp].executableArchitectures containsObject:@(0x0100000c)]) { obsCode = @"unsupported_architecture"; obsMessage = @"OBS 需要 Apple Silicon arm64 版本，请下载兼容 OBS。"; }
    if (![obsCode isEqual:@"ready"]) [self.errors addObject:obsMessage];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:Join(self.options.app, @"Contents/Info.plist")];
    self.version = String(info[@"CFBundleShortVersionString"]);
    NSMutableArray *supported = [NSMutableArray array]; self.selectedRuntime = @{};
    NSArray *runtimes = Array(self.spec[@"supported_runtimes"]);
    if (!runtimes.count) runtimes = @[@{@"version":String(self.spec[@"source_app_version"]), @"runtime":Dictionary(self.spec[@"runtime"])}];
    for (NSDictionary *entry in runtimes) {
        [supported addObject:String(entry[@"version"])];
        if ([self.version isEqual:String(entry[@"version"])]) self.selectedRuntime = Dictionary(entry[@"runtime"]);
    }
    NSString *relative = String(self.selectedRuntime[@"relative_path"]);
    self.runtime = SafeRelative(relative) ? Join(self.options.app, relative) : @"";
    NSString *sourceCode = @"ready", *sourceMessage = [NSString stringWithFormat:@"已找到 Mac 直播伴侣 %@，运行库校验通过。", self.version];
    if (!self.version.length) { sourceCode = @"missing"; sourceMessage = @"未安装 Mac 直播伴侣。点击下载，打开 DMG，将应用拖入 Applications，然后返回此窗口。"; }
    else if (![String(info[@"CFBundleIdentifier"]) isEqual:@"com.bytedance.webcastmate.mac"]) { sourceCode = @"invalid_app"; sourceMessage = @"所选应用不是官方 Mac 直播伴侣，请重新选择。"; }
    else if (!self.selectedRuntime.count) { sourceCode = @"unsupported_version"; sourceMessage = [NSString stringWithFormat:@"当前直播伴侣 %@；已验证版本：%@。请使用下方兼容版本下载或选择已有应用。", self.version, [supported componentsJoinedByString:@" / "]]; }
    else if (!self.runtime.length || !MatchHash(self.runtime, self.selectedRuntime)) { sourceCode = @"runtime_mismatch"; sourceMessage = @"官方运行库缺失或校验不符，请重新下载安装兼容版本；不要手动修改哈希。"; }
    if (![sourceCode isEqual:@"ready"]) [self.errors addObject:sourceMessage];
    self.dependencies = @[
        @{@"id":@"obs", @"status":obsCode, @"ready":@([obsCode isEqual:@"ready"]), @"path":self.options.obsApp, @"version":obsVersion, @"supported_versions":@[expectedOBS], @"download_url":OBSDownloadURL, @"official_url":@"https://obsproject.com/", @"instructions":obsMessage},
        @{@"id":@"companion", @"status":sourceCode, @"ready":@([sourceCode isEqual:@"ready"]), @"path":self.options.app, @"version":self.version, @"supported_versions":supported, @"download_url":CompanionDownloadURL, @"official_url":CompanionWebsiteURL, @"instructions":sourceMessage}
    ];
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
    if (![String(manifest[@"runtime_library"]) isEqual:self.runtime] || ![String(manifest[@"runtime_sha256"]) isEqual:String(self.selectedRuntime[@"sha256"])]) return NO;
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
    BOOL dependencies = [self preflight]; BOOL resources = !self.options.pluginOnly && dependencies && [self resourcesReady];
    if (!self.options.pluginOnly && dependencies && !resources) [self.errors addObject:@"本地效果资源尚未安装或校验不匹配；执行安装后将导入或下载固定版本资源。"];
    BOOL plugin = dependencies && [self pluginReady];
    if (dependencies && !plugin) [self.errors addObject:@"插件尚未安装或与当前安装包版本不同。"];
    return [self result:@"check" ok:dependencies && (resources || self.options.pluginOnly) && plugin message:(resources || self.options.pluginOnly) && plugin ? (self.options.pluginOnly ? @"标准 OBS 插件已安装。" : @"依赖、插件和效果资源已就绪。") : @"尚未就绪，请查看 errors。"];
}
- (NSDictionary *)result:(NSString *)action ok:(BOOL)ok message:(NSString *)message {
    return @{@"action":action, @"ok":@(ok), @"ready":@(ok), @"obs_running":@(self.obsRunning), @"source_app":self.options.app,
             @"source_version":self.version ?: @"", @"obs_app":self.options.obsApp, @"dependencies":self.dependencies ?: @[], @"plugin_dir":self.options.pluginDirectory, @"resource_dir":self.options.resourceDirectory,
             @"scope":self.options.pluginOnly ? @"plugin" : @"complete", @"dependencies_ready":@(self.dependenciesReady), @"resources_ready":@(!self.options.pluginOnly && self.dependenciesReady && [self resourcesReady]), @"plugin_ready":@(self.dependenciesReady && [self pluginReady]),
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
- (BOOL)installPluginOnly {
    NSString *error = nil, *name = @"obs-live-beauty.plugin";
    NSString *destination = Join(self.options.pluginDirectory, name);
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *stage = Join(self.options.pluginDirectory, [@".plugin-install-" stringByAppendingString:nonce]);
    NSString *previous = [destination stringByAppendingFormat:@".previous-%@", nonce];
    if (!Directory(self.options.pluginDirectory, &error) || !Copy(Join(self.options.assets, name), stage, &error)) {
        [self.errors addObject:error ?: @"无法准备插件文件。"];
        [FM() removeItemAtPath:stage error:nil]; return NO;
    }
    NSError *fileError = nil; BOOL moved = NO, placed = NO, ok = YES;
    if (OBSRunning()) { ok = NO; error = @"OBS 已启动，请退出后重新安装。"; }
    if (ok && [FM() fileExistsAtPath:destination]) { moved = [FM() moveItemAtPath:destination toPath:previous error:&fileError]; ok = moved; }
    if (ok) { placed = [FM() moveItemAtPath:stage toPath:destination error:&fileError]; ok = placed && [self pluginReady]; }
    if (!ok) {
        [self.errors addObject:error ?: fileError.localizedDescription ?: @"插件安装校验失败。"];
        if (placed) [FM() removeItemAtPath:destination error:nil];
        if (moved && ![FM() moveItemAtPath:previous toPath:destination error:&fileError]) [self.errors addObject:[@"恢复旧插件失败，原件保留于：" stringByAppendingString:previous]];
    } else if (moved) [FM() removeItemAtPath:previous error:nil];
    [FM() removeItemAtPath:stage error:nil]; return ok;
}
- (BOOL)installWithProgress:(Progress)progress {
    if (![self preflight]) return NO;
    if (self.options.pluginOnly) return [self installPluginOnly];
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
        NSDictionary *manifest = @{@"schema_version":@1, @"source_app_version":self.version ?: @"", @"runtime_library":self.runtime ?: @"", @"runtime_sha256":String(self.selectedRuntime[@"sha256"]), @"models":Array(self.spec[@"models"])};
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
@property(nonatomic, strong) NSTextField *status, *detail, *obsStatus, *companionStatus;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSButton *installButton;
@property(nonatomic, strong) NSMutableArray<NSButton *> *controls;
@property BOOL busy, completed;
@end
@implementation InstallerWindow
- (NSTextField *)label:(NSString *)text x:(double)x y:(double)y width:(double)width height:(double)height size:(double)size {
    NSTextField *label = [NSTextField wrappingLabelWithString:text]; label.font = [NSFont systemFontOfSize:size]; label.frame = NSMakeRect(x,y,width,height); [self.window.contentView addSubview:label]; return label;
}
- (NSButton *)button:(NSString *)title x:(double)x y:(double)y width:(double)width action:(SEL)action tag:(NSInteger)tag {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action]; button.bezelStyle = NSBezelStyleRounded; button.frame = NSMakeRect(x,y,width,32); button.tag = tag; [self.window.contentView addSubview:button]; [self.controls addObject:button]; return button;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; self.controls = [NSMutableArray array];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,680,560) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Mac OBS 美颜 · 安装与依赖检查"; [self.window center];
    NSTextField *title = [self label:@"Mac OBS Beauty · Mac OBS 美颜" x:28 y:504 width:625 height:35 size:24]; title.font = [NSFont boldSystemFontOfSize:24];
    self.status = [self label:@"正在自动检查…" x:28 y:464 width:625 height:34 size:14];
    [self label:@"1 · OBS Studio（Apple Silicon）" x:28 y:431 width:625 height:25 size:15];
    self.obsStatus = [self label:@"检查中…" x:28 y:377 width:625 height:52 size:13];
    [self button:@"下载兼容 OBS" x:28 y:340 width:150 action:@selector(download:) tag:0];
    [self button:@"选择已有 OBS…" x:190 y:340 width:170 action:@selector(choose:) tag:0];
    [self label:@"2 · 官方 Mac 直播伴侣（保留应用以提供美颜运行库）" x:28 y:302 width:625 height:25 size:15];
    self.companionStatus = [self label:@"检查中…" x:28 y:247 width:625 height:52 size:13];
    [self button:@"下载 Mac 直播伴侣" x:28 y:210 width:170 action:@selector(download:) tag:1];
    [self button:@"选择已有直播伴侣…" x:210 y:210 width:180 action:@selector(choose:) tag:1];
    [self button:@"官方网站" x:402 y:210 width:115 action:@selector(website:) tag:1];
    self.detail = [self label:@"下载后打开 DMG，将依赖应用拖入 Applications。返回这里会自动重新检查。首次资源准备需要联网，无需 Xcode、Python 或 Homebrew。" x:28 y:133 width:625 height:69 size:12];
    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(28,114,624,12)]; self.progress.indeterminate = NO; self.progress.minValue = 0; self.progress.maxValue = 100; [self.window.contentView addSubview:self.progress];
    [self button:@"重新检查" x:28 y:66 width:115 action:@selector(refresh:) tag:0];
    [self button:@"给项目一个星星 ⭐" x:156 y:66 width:180 action:@selector(star:) tag:0];
    self.installButton = [self button:@"安装美颜插件" x:492 y:66 width:160 action:@selector(install:) tag:0]; self.installButton.enabled = NO;
    [self label:StarMessage x:28 y:25 width:625 height:24 size:12];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [self refresh:nil];
}
- (void)setWorking:(BOOL)working {
    self.busy = working; for (NSButton *button in self.controls) button.enabled = !working;
    self.installButton.enabled = !working && self.installer.dependenciesReady;
}
- (void)refresh:(id)sender {
    if (self.busy) return; [self setWorking:YES]; self.status.stringValue = @"检查版本和运行库，请稍候…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        BOOL ready = [self.installer preflight]; NSArray *deps = self.installer.dependencies; NSArray *errors = [self.installer.errors copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (deps.count == 2) { self.obsStatus.stringValue = String(deps[0][@"instructions"]); self.companionStatus.stringValue = String(deps[1][@"instructions"]); }
            self.status.stringValue = ready ? (self.completed ? @"安装完成。可以打开 OBS 使用直播美颜。" : @"依赖已就绪。点击「安装美颜插件」完成安装。") : @"请按下面提示补齐依赖，然后返回此窗口。";
            if (!ready) self.detail.stringValue = [errors componentsJoinedByString:@"\n"];
            else self.detail.stringValue = self.completed ? @"打开 OBS → 停靠窗口 / 工具 → 直播美颜，选择视频来源并点击「添加到来源」。请保留官方直播伴侣应用。" : @"安装到当前用户。首次准备效果资源需要联网；下载失败时会显示具体原因，之后可重试。无需编译或开发工具。";
            [self setWorking:NO];
        });
    }});
}
- (void)applicationDidBecomeActive:(NSNotification *)notification { if (self.window && !self.busy) [self refresh:nil]; }
- (void)download:(NSButton *)sender {
    NSString *link = sender.tag ? CompanionDownloadURL : OBSDownloadURL;
    if (![NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:link]]) self.detail.stringValue = @"无法打开浏览器，请使用官方网站下载，或检查默认浏览器设置。";
    else self.detail.stringValue = @"浏览器会下载官方兼容版本。下载完成后打开 DMG，将应用拖入 Applications；安装后返回这里自动检查。若下载失败，可点击官方网站，或稍后重试。";
}
- (void)website:(NSButton *)sender { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:CompanionWebsiteURL]]; }
- (void)choose:(NSButton *)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel]; panel.title = sender.tag ? @"选择已安装的官方 Mac 直播伴侣" : @"选择已安装的 OBS.app"; panel.canChooseDirectories = NO; panel.canChooseFiles = YES; panel.allowsMultipleSelection = NO; panel.allowedFileTypes = @[@"app"];
    if ([panel runModal] == NSModalResponseOK) {
        NSString *path = panel.URL.path;
        if ([path hasPrefix:@"/Volumes/"]) { self.detail.stringValue = @"请先将应用从 DMG 拖入 Applications，再选择已安装的应用，避免弹出磁盘后无法使用。"; return; }
        if (sender.tag) { self.installer.options.app = path; self.installer.options.explicitApp = YES; }
        else { self.installer.options.obsApp = path; self.installer.options.explicitOBS = YES; }
        [self refresh:nil];
    }
}
- (void)install:(id)sender {
    if (self.busy) return; [self setWorking:YES]; self.status.stringValue = @"检查依赖…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        BOOL ok = [self.installer installWithProgress:^(NSString *message, double percent) { dispatch_async(dispatch_get_main_queue(), ^{ self.status.stringValue = message; self.progress.doubleValue = percent * 100; }); }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.completed = ok; [self setWorking:NO];
            self.installButton.title = ok ? @"重新安装 / 修复" : @"重试安装";
            if (!ok) { self.status.stringValue = @"尚未安装，请处理以下问题后重试。"; self.detail.stringValue = [self.installer.errors componentsJoinedByString:@"\n"]; }
            else { self.status.stringValue = @"安装完成。打开 OBS 即可使用。"; self.detail.stringValue = @"OBS → 停靠窗口 / 工具 → 直播美颜，选择视频来源并点击「添加到来源」。请保留官方直播伴侣应用。"; }
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
        else if ([arg isEqual:@"--plugin-only"]) options.pluginOnly = YES;
        else if ([arg isEqual:@"--app"] || [arg isEqual:@"--obs-app"] || [arg isEqual:@"--plugin-dir"] || [arg isEqual:@"--resource-dir"] || [arg isEqual:@"--resources-from"] || [arg isEqual:@"--assets-dir"]) {
            if (++i >= argc) { argumentError = [@"缺少参数：" stringByAppendingString:arg]; break; }
            NSString *value = Absolute(@(argv[i]));
            if ([arg isEqual:@"--app"]) { options.app = value; options.explicitApp = YES; }
            else if ([arg isEqual:@"--obs-app"]) { options.obsApp = value; options.explicitOBS = YES; }
            else if ([arg isEqual:@"--plugin-dir"]) options.pluginDirectory = value;
            else if ([arg isEqual:@"--resource-dir"]) options.resourceDirectory = value;
            else if ([arg isEqual:@"--assets-dir"]) options.assets = value;
            else options.importDirectory = value;
        } else if ([arg isEqual:@"--help"]) {
            puts("obs-live-beauty-installer [--check | --install] [--non-interactive] [--json]\n  --plugin-only          Install/check the standard plugin without checking or downloading runtime dependencies\n  --obs-app PATH         Installed OBS application\n  --app PATH             Installed official Mac companion application\n  --resources-from PATH  Import verified existing engine-resources\n  --plugin-dir PATH      Parent OBS plugins directory\n  --resource-dir PATH    External engine-resources destination\n  --assets-dir PATH      Installer payload override (for staging/verification)\nNo arguments: open the installation window. Exit: 0 success, 1 install failure, 2 check not ready, 64 invalid arguments."); return 0;
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
