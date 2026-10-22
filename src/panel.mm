#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include "panel.h"
#include "obs-dock-host.h"
#include "resource-path.h"

static NSString *LBString(const char *value)
{
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

static id LBDecode(NSString *text)
{
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    return bytes.length ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nullptr] : nil;
}

static NSString *LBJSON(id object)
{
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:nullptr];
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : @"null";
}

static NSString *LBDefaultRoot(void)
{
    return LBResourceRoot();
}

@interface LBPanelController : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, assign) void *dock;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray<NSString *> *sourceNames;
@property(nonatomic, strong) NSString *selectedSource;
@property(nonatomic, strong) NSString *resourceRoot;
@property(nonatomic, strong) NSString *htmlPath;
@property(nonatomic, strong) NSDictionary *catalog;
@property(nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *itemIndex;
@property(nonatomic, strong) NSDictionary *selection;
@property(nonatomic, strong) NSDictionary *presets;
@property(nonatomic, assign) obs_source_t *currentFilter;
@property(nonatomic, assign) BOOL pageReady;
@property(nonatomic, assign) obs_source_t *comparisonFilter;
@property(nonatomic, assign) BOOL comparisonWasEnabled;
- (void)showPanel;
- (void)dockVisibilityChanged:(BOOL)visible;
- (void)endComparison;
- (void)shutdown;
@end

@interface LBPanelBridge : NSObject <WKScriptMessageHandler, WKURLSchemeHandler>
@property(nonatomic, weak) LBPanelController *owner;
@end

@implementation LBPanelBridge
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.owner userContentController:controller didReceiveScriptMessage:message];
}
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    [self.owner webView:webView startURLSchemeTask:task];
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    [self.owner webView:webView stopURLSchemeTask:task];
}
@end

static bool LBCollectSource(void *data, obs_source_t *source)
{
    if (obs_source_get_type(source) == OBS_SOURCE_TYPE_INPUT && (obs_source_get_output_flags(source) & OBS_SOURCE_VIDEO)) {
        NSString *name = LBString(obs_source_get_name(source));
        if (name.length) {
            LBPanelController *controller = (__bridge LBPanelController *)data;
            [controller.sourceNames addObject:name];
        }
    }
    return true;
}

static void LBFindFilter(obs_source_t *, obs_source_t *filter, void *data)
{
    auto **result = static_cast<obs_source_t **>(data);
    if (!*result && strcmp(obs_source_get_id(filter), lb_filter_id()) == 0)
        *result = obs_source_get_ref(filter);
}

struct LBSceneChoice {
    NSSet<NSString *> *names;
    NSString *selected = nil;
    NSString *filtered = nil;
};

static bool LBChooseSceneSource(obs_scene_t *, obs_sceneitem_t *item, void *data)
{
    auto *choice = static_cast<LBSceneChoice *>(data);
    if (obs_sceneitem_is_group(item))
        obs_scene_enum_items(obs_sceneitem_group_get_scene(item), LBChooseSceneSource, data);
    obs_source_t *source = obs_sceneitem_get_source(item);
    if (!source || obs_source_get_type(source) != OBS_SOURCE_TYPE_INPUT ||
        !(obs_source_get_output_flags(source) & OBS_SOURCE_VIDEO))
        return true;
    NSString *name = LBString(obs_source_get_name(source));
    if (![choice->names containsObject:name])
        return true;
    if (!choice->selected && obs_sceneitem_selected(item))
        choice->selected = name;
    if (!choice->filtered) {
        obs_source_t *filter = nullptr;
        obs_source_enum_filters(source, LBFindFilter, &filter);
        if (filter) {
            choice->filtered = name;
            obs_source_release(filter);
        }
    }
    return true;
}

@implementation LBPanelController

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;
    _sourceNames = [NSMutableArray array];
    _selectedSource = @"";
    _resourceRoot = LBDefaultRoot();
    _selection = @{@"version": @1, @"items": @[]};
    _presets = @{};
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    LBPanelBridge *bridge = [[LBPanelBridge alloc] init];
    bridge.owner = self;
    [configuration.userContentController addScriptMessageHandler:bridge name:@"liveBeauty"];
    [configuration setURLSchemeHandler:bridge forURLScheme:@"lbasset"];
    _webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 420, 720) configuration:configuration];
    _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _webView.navigationDelegate = self;
    _webView.underPageBackgroundColor = [NSColor colorWithSRGBRed:.09 green:.09 blue:.11 alpha:1];
    _webView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    __weak LBPanelController *weakSelf = self;
    _dock = lb_dock_create("live-beauty-dock", "直播美颜", _webView,
        ^(bool visible) { [weakSelf dockVisibilityChanged:visible]; },
        ^{ [weakSelf endComparison]; });
    if (!_dock)
        return nil;
    char *html = obs_module_file("panel.html");
    _htmlPath = LBString(html);
    bfree(html);
    [self loadCatalog];
    if (_htmlPath.length)
        [_webView loadFileURL:[NSURL fileURLWithPath:_htmlPath] allowingReadAccessToURL:[NSURL fileURLWithPath:_htmlPath.stringByDeletingLastPathComponent isDirectory:YES]];
    return self;
}

- (void)send:(NSDictionary *)message
{
    if (!self.pageReady)
        return;
    NSString *script = [NSString stringWithFormat:@"window.LiveBeauty && window.LiveBeauty.receive(%@)", LBJSON(message)];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)releaseFilter
{
    if (self.currentFilter) {
        obs_source_release(self.currentFilter);
        self.currentFilter = nullptr;
    }
}

- (void)loadCatalog
{
    NSData *bytes = [NSData dataWithContentsOfFile:[self.resourceRoot stringByAppendingPathComponent:@"windows-catalog.json"]];
    id decoded = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nullptr] : nil;
    NSDictionary *catalog = [decoded isKindOfClass:NSDictionary.class] ? decoded : @{};
    NSMutableArray *items = [NSMutableArray array];
    NSMutableDictionary *index = [NSMutableDictionary dictionary];
    for (id value in catalog[@"items"]) {
        if (![value isKindOfClass:NSDictionary.class] || ![value[@"id"] isKindOfClass:NSString.class])
            continue;
        NSMutableDictionary *item = [value mutableCopy];
        NSString *icon = [item[@"icon_path"] isKindOfClass:NSString.class] ? item[@"icon_path"] : @"";
        if (icon.length && !icon.isAbsolutePath && [self safeAssetPath:icon]) {
            NSString *encoded = [icon stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
            item[@"icon_url"] = [@"lbasset://catalog/" stringByAppendingString:encoded];
        }
        [items addObject:item];
        index[item[@"id"]] = item;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *value in catalog[@"ui_rows"]) {
        NSMutableDictionary *row = [value mutableCopy];
        NSString *icon = row[@"icon_path"];
        if ([icon isKindOfClass:NSString.class] && [self safeAssetPath:icon]) {
            NSString *encoded = [icon stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
            row[@"icon_url"] = [@"lbasset://catalog/" stringByAppendingString:encoded];
        }
        [rows addObject:row];
    }
    self.catalog = @{@"groups": [catalog[@"groups"] isKindOfClass:NSArray.class] ? catalog[@"groups"] : @[], @"items": items, @"ui_rows":rows};
    self.itemIndex = index;
}

- (NSString *)safeAssetPath:(NSString *)relative
{
    if (!relative.length || relative.isAbsolutePath)
        return nil;
    NSString *root = self.resourceRoot.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *path = [[root stringByAppendingPathComponent:relative] stringByStandardizingPath].stringByResolvingSymlinksInPath;
    return [path hasPrefix:[root stringByAppendingString:@"/"]] ? path : nil;
}

- (void)refreshSources
{
    [self endComparison];
    [self.sourceNames removeAllObjects];
    obs_enum_sources(LBCollectSource, (__bridge void *)self);
    [self.sourceNames sortUsingSelector:@selector(localizedStandardCompare:)];
    if (![self.sourceNames containsObject:self.selectedSource]) {
        LBSceneChoice choice{[NSSet setWithArray:self.sourceNames]};
        obs_source_t *sceneSource = obs_frontend_get_current_scene();
        obs_scene_t *scene = sceneSource ? obs_scene_from_source(sceneSource) : nullptr;
        if (scene)
            obs_scene_enum_items(scene, LBChooseSceneSource, &choice);
        if (sceneSource)
            obs_source_release(sceneSource);
        self.selectedSource = choice.selected ?: choice.filtered ?: self.sourceNames.firstObject ?: @"";
    }
    [self loadSelectedFilter];
}

- (void)loadSelectedFilter
{
    [self endComparison];
    [self releaseFilter];
    obs_source_t *source = self.selectedSource.length ? obs_get_source_by_name(self.selectedSource.UTF8String) : nullptr;
    if (source) {
        obs_source_enum_filters(source, LBFindFilter, &_currentFilter);
        obs_source_release(source);
    }
    obs_data_t *settings = self.currentFilter ? obs_source_get_settings(self.currentFilter) : nullptr;
    NSString *root = LBResolveResourceRoot(settings ? LBString(obs_data_get_string(settings, "resource_root")) : LBDefaultRoot());
    if (![root isEqual:self.resourceRoot] || !self.itemIndex.count) {
        self.resourceRoot = root;
        [self loadCatalog];
    }
    id selection = settings ? LBDecode(LBString(obs_data_get_string(settings, "native_selection"))) : nil;
    BOOL wellFormed = [selection isKindOfClass:NSDictionary.class] && [selection[@"items"] isKindOfClass:NSArray.class];
    if (wellFormed && selection[@"disabled_panels"] && ![selection[@"disabled_panels"] isKindOfClass:NSArray.class])
        wellFormed = NO;
    if (wellFormed)
        for (id entry in selection[@"items"])
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"id"] isKindOfClass:NSString.class] || ![entry[@"values"] isKindOfClass:NSDictionary.class]) {
                wellFormed = NO;
                break;
            }
    // Preserve valid legacy selections byte-for-byte; repair malformed UI data
    // in memory only, without changing the saved source or running engine.
    NSSet *allowedPanels = [NSSet setWithArray:@[@"effect",@"slim",@"makeupstyle",@"makeupsingle",@"composerfilter"]];
    self.selection = wellFormed ? selection : [self normalizedSelection:selection panels:allowedPanels];
    id presets = settings ? LBDecode(LBString(obs_data_get_string(settings, "native_presets"))) : nil;
    self.presets = [self normalizedPresets:presets currentSelection:self.selection];
    if (settings)
        obs_data_release(settings);
    [self sendState];
}

- (void)sendState
{
    obs_data_t *settings = self.currentFilter ? obs_source_get_settings(self.currentFilter) : nullptr;
    BOOL enabled = settings && obs_data_get_bool(settings, "enabled");
    if (settings)
        obs_data_release(settings);
    [self send:@{@"type":@"state", @"sources":self.sourceNames, @"selectedSource":self.selectedSource,
                 @"hasFilter":@(self.currentFilter != nullptr), @"enabled":@(enabled),
                 @"resourceRoot":self.resourceRoot, @"catalog":self.catalog, @"selection":self.selection, @"presets":self.presets}];
    [self refreshStatus:nil];
}

- (void)refreshStatus:(NSTimer *)timer
{
    if (self.currentFilter && obs_source_removed(self.currentFilter)) {
        [self refreshSources];
        return;
    }
    char text[4096] = {};
    lb_filter_copy_status(self.currentFilter, text, sizeof(text));
    NSString *status = LBString(text);
    BOOL ready = [status hasPrefix:@"READY"];
    if ([status hasPrefix:@"READY: "])
        status = [status substringFromIndex:7];
    [self send:@{@"type":@"status", @"ready":@(ready), @"status":status}];
}

- (void)beginComparison
{
    if (self.comparisonFilter || !self.currentFilter)
        return;
    obs_data_t *settings = obs_source_get_settings(self.currentFilter);
    BOOL enabled = obs_data_get_bool(settings, "enabled");
    if (enabled) {
        self.comparisonFilter = obs_source_get_ref(self.currentFilter);
        self.comparisonWasEnabled = YES;
        obs_data_set_bool(settings, "enabled", false);
        obs_source_update(self.currentFilter, settings);
        [self send:@{@"type":@"comparison", @"active":@YES}];
    }
    obs_data_release(settings);
}

- (void)endComparison
{
    if (!self.comparisonFilter)
        return;
    if (!obs_source_removed(self.comparisonFilter)) {
        obs_data_t *settings = obs_source_get_settings(self.comparisonFilter);
        obs_data_set_bool(settings, "enabled", self.comparisonWasEnabled);
        obs_source_update(self.comparisonFilter, settings);
        obs_data_release(settings);
    }
    obs_source_release(self.comparisonFilter);
    self.comparisonFilter = nullptr;
    [self send:@{@"type":@"comparison", @"active":@NO}];
}

- (NSString *)exclusionGroup:(NSDictionary *)item
{
    for (NSDictionary *row in self.catalog[@"ui_rows"]) {
        NSUInteger groupIndex = 0;
        for (NSDictionary *composition in row[@"groups"]) {
            NSArray *members = composition[@"members"];
            if ([members containsObject:item[@"id"]])
                return members.count > 1 ? [NSString stringWithFormat:@"composition:%@:%lu", row[@"id"], (unsigned long)groupIndex] : @"";
            ++groupIndex;
        }
    }
    NSString *panel = item[@"panel"] ?: @"";
    NSString *group = item[@"group_id"] ?: @"";
    NSString *parent = item[@"parent_name"] ?: @"";
    if (([group isEqual:@"beauty"] || [group isEqual:@"shape"]) && parent.length)
        return [NSString stringWithFormat:@"%@:%@", group, parent];
    if ([panel isEqual:@"composerfilter"] || [panel isEqual:@"picofilter"])
        return @"filter";
    if ([panel isEqual:@"makeupstyle"] || [panel isEqual:@"picomakeupstyle"])
        return @"makeupstyle";
    if ([panel isEqual:@"makeupsingle"] || [panel isEqual:@"picomakeupsingle"]) {
        NSString *category = [item[@"parent_name"] length] ? item[@"parent_name"] : (item[@"category_id"] ?: @"");
        return [@"makeupsingle:" stringByAppendingString:category];
    }
    return @"";
}

- (BOOL)item:(NSDictionary *)item conflictsWith:(NSDictionary *)other
{
    NSString *panel = item[@"panel"] ?: @"";
    NSString *otherPanel = other[@"panel"] ?: @"";
    BOOL style = [panel isEqual:@"makeupstyle"] || [panel isEqual:@"picomakeupstyle"];
    BOOL single = [panel isEqual:@"makeupsingle"] || [panel isEqual:@"picomakeupsingle"];
    BOOL otherStyle = [otherPanel isEqual:@"makeupstyle"] || [otherPanel isEqual:@"picomakeupstyle"];
    BOOL otherSingle = [otherPanel isEqual:@"makeupsingle"] || [otherPanel isEqual:@"picomakeupsingle"];
    if ((style && otherSingle) || (single && otherStyle))
        return YES;
    NSString *group = [self exclusionGroup:item];
    return group.length && [group isEqual:[self exclusionGroup:other]];
}

- (NSDictionary *)normalizedSelection:(id)request panels:(NSSet<NSString *> *)allowedPanels
{
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"items"] isKindOfClass:NSArray.class])
        return @{@"version":@1, @"items":@[], @"disabled_panels":@[]};
    NSMutableArray<NSDictionary *> *selected = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *disabledPanels = [NSMutableOrderedSet orderedSet];
    if ([request[@"disabled_panels"] isKindOfClass:NSArray.class])
        for (id panel in request[@"disabled_panels"])
            if ([allowedPanels containsObject:panel])
                [disabledPanels addObject:panel];
    for (id entry in request[@"items"]) {
        if (![entry isKindOfClass:NSDictionary.class])
            continue;
        if (![entry[@"id"] isKindOfClass:NSString.class])
            continue;
        NSDictionary *item = self.itemIndex[entry[@"id"]];
        NSString *node = item[@"node_path"];
        if (!item || ![allowedPanels containsObject:item[@"panel"]] || ![node isKindOfClass:NSString.class] || ![self safeAssetPath:node])
            continue;
        NSIndexSet *old = [selected indexesOfObjectsPassingTest:^BOOL(NSDictionary *previous, NSUInteger idx, BOOL *stop) {
            return [previous[@"id"] isEqual:entry[@"id"]] || [self item:item conflictsWith:self.itemIndex[previous[@"id"]]];
        }];
        [selected removeObjectsAtIndexes:old];
        NSDictionary *requested = [entry[@"values"] isKindOfClass:NSDictionary.class] ? entry[@"values"] : @{};
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSDictionary *control in item[@"controls"]) {
            NSString *tag = control[@"tag"];
            if (![tag isKindOfClass:NSString.class] || !tag.length)
                continue;
            double low = [control[@"min"] doubleValue];
            double high = control[@"max"] ? [control[@"max"] doubleValue] : 100;
            if (high < low)
                std::swap(low, high);
            id value = requested[tag] ?: control[@"value"] ?: @0;
            double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
            if (!std::isfinite(number))
                number = 0;
            values[tag] = @(std::clamp(number, low, high));
        }
        [selected addObject:@{@"id":item[@"id"], @"values":values}];
    }
    return @{@"version":@1, @"items":selected, @"disabled_panels":disabledPanels.array};
}

- (NSDictionary *)normalizedPresets:(id)request currentSelection:(NSDictionary *)current
{
    NSDictionary *requestedScopes = [request isKindOfClass:NSDictionary.class] && [request[@"scopes"] isKindOfClass:NSDictionary.class] ? request[@"scopes"] : @{};
    NSDictionary *scopePanels = @{@"effectall":@[@"effect",@"slim"], @"makeup":@[@"makeupstyle",@"makeupsingle"]};
    NSMutableDictionary *scopes = [NSMutableDictionary dictionary];
    for (NSString *scope in @[@"effectall",@"makeup"]) {
        NSSet *panels = [NSSet setWithArray:scopePanels[scope]];
        NSDictionary *value = [requestedScopes[scope] isKindOfClass:NSDictionary.class] ? requestedScopes[scope] : @{};
        NSArray *entries = [value[@"entries"] isKindOfClass:NSArray.class] ? value[@"entries"] : @[];
        NSMutableArray *normalized = [NSMutableArray array];
        NSMutableSet *ids = [NSMutableSet set];
        for (id entry in entries) {
            if (normalized.count >= 15)
                break;
            if (![entry isKindOfClass:NSDictionary.class])
                continue;
            NSString *identifier = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : @"";
            if (!identifier.length || identifier.length > 128 || [ids containsObject:identifier])
                continue;
            NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : @"";
            name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            __block NSMutableString *shortName = [NSMutableString string];
            __block NSUInteger characters = 0;
            [name enumerateSubstringsInRange:NSMakeRange(0,name.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) {
                [shortName appendString:part];
                if (++characters == 5)
                    *stop = YES;
            }];
            if (!shortName.length)
                [shortName appendFormat:@"预设%lu",(unsigned long)normalized.count + 1];
            [normalized addObject:@{@"id":identifier, @"name":shortName, @"selection":[self normalizedSelection:entry[@"selection"] panels:panels]}];
            [ids addObject:identifier];
        }
        if (!normalized.count) {
            NSString *identifier = [scope stringByAppendingString:@"-preset-1"];
            [normalized addObject:@{@"id":identifier, @"name":@"预设1", @"selection":[self normalizedSelection:current panels:panels]}];
            [ids addObject:identifier];
        }
        NSString *active = [value[@"active_id"] isKindOfClass:NSString.class] ? value[@"active_id"] : @"";
        if (![ids containsObject:active])
            active = normalized.firstObject[@"id"];
        scopes[scope] = @{@"active_id":active, @"entries":normalized};
    }
    return @{@"version":@1, @"scopes":scopes};
}

- (void)applySelection:(id)request revision:(NSInteger)revision presets:(id)presets
{
    if (!self.currentFilter || ![request isKindOfClass:NSDictionary.class] || ![request[@"items"] isKindOfClass:NSArray.class])
        return;
    NSSet *allowedPanels = [NSSet setWithArray:@[@"effect",@"slim",@"makeupstyle",@"makeupsingle",@"composerfilter"]];
    NSDictionary *normalized = [self normalizedSelection:request panels:allowedPanels];
    NSArray *selected = normalized[@"items"];
    NSArray *disabledPanels = normalized[@"disabled_panels"];
    NSMutableArray<NSDictionary *> *active = [NSMutableArray array];
    for (NSDictionary *entry in selected) {
        NSDictionary *item = self.itemIndex[entry[@"id"]];
        if (![disabledPanels containsObject:item[@"panel"]] && [item[@"installed"] boolValue] && !([item[@"supported"] isKindOfClass:NSNumber.class] && ![item[@"supported"] boolValue]) && ![item[@"missing_models"] count])
            [active addObject:entry];
    }
    NSMutableOrderedSet<NSString *> *nodes = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSNumber *> *nodeRanks = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSNumber *> *groupRanks = @{@"beauty":@0, @"shape":@1, @"body":@2,
        @"makeupstyle":@3, @"makeupsingle":@4, @"composerfilter":@5};
    NSMutableDictionary<NSString *, NSDictionary *> *updatesByKey = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *updateOrder = [NSMutableArray array];
    for (NSDictionary *entry in active) {
        NSDictionary *item = self.itemIndex[entry[@"id"]];
        NSString *node = item[@"node_path"];
        [nodes addObject:node];
        NSNumber *rank = groupRanks[item[@"group_id"] ?: @""] ?: @6;
        if (!nodeRanks[node] || rank.integerValue < nodeRanks[node].integerValue)
            nodeRanks[node] = rank;
    }
    NSArray<NSString *> *orderedNodes = [nodes.array sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger rankA = nodeRanks[a].integerValue;
        NSInteger rankB = nodeRanks[b].integerValue;
        return rankA == rankB ? [a compare:b] : rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
    }];
    /* Several original presets share a node. Clear every known parameter on
     * active nodes before overlaying selected values, so a preset switch does
     * not leave the previous preset's tag active in the native SDK. */
    for (NSDictionary *item in self.catalog[@"items"]) {
        NSString *node = item[@"node_path"];
        if (![nodes containsObject:node])
            continue;
        for (NSDictionary *control in item[@"controls"]) {
            NSString *tag = control[@"tag"];
            if (![tag isKindOfClass:NSString.class] || !tag.length)
                continue;
            NSString *key = [NSString stringWithFormat:@"%@\n%@", node, tag];
            if (!updatesByKey[key])
                [updateOrder addObject:key];
            updatesByKey[key] = @{@"node":node, @"tag":tag, @"value":@0};
        }
    }
    for (NSDictionary *entry in active) {
        NSDictionary *item = self.itemIndex[entry[@"id"]];
        NSString *node = item[@"node_path"];
        for (NSDictionary *control in item[@"controls"]) {
            NSString *tag = control[@"tag"];
            NSNumber *value = entry[@"values"][tag];
            if (!tag.length || !value)
                continue;
            NSString *key = [NSString stringWithFormat:@"%@\n%@", node, tag];
            if (!updatesByKey[key])
                [updateOrder addObject:key];
            updatesByKey[key] = @{@"node":node, @"tag":tag, @"value":@(value.doubleValue / 100.0)};
        }
    }
    NSMutableArray *updates = [NSMutableArray array];
    for (NSString *key in updateOrder)
        if ([updatesByKey[key][@"value"] doubleValue] == 0.0)
            [updates addObject:updatesByKey[key]];
    for (NSString *key in updateOrder)
        if ([updatesByKey[key][@"value"] doubleValue] != 0.0)
            [updates addObject:updatesByKey[key]];
    self.selection = normalized;
    self.presets = [self normalizedPresets:[presets isKindOfClass:NSDictionary.class] ? presets : self.presets currentSelection:self.selection];
    obs_data_t *settings = obs_source_get_settings(self.currentFilter);
    obs_data_set_bool(settings, "native_mode", true);
    obs_data_set_string(settings, "native_selection", LBJSON(self.selection).UTF8String);
    obs_data_set_string(settings, "native_presets", LBJSON(self.presets).UTF8String);
    obs_data_set_string(settings, "native_updates", LBJSON(updates).UTF8String);
    obs_data_set_string(settings, "node_paths", LBJSON(orderedNodes).UTF8String);
    obs_source_update(self.currentFilter, settings);
    obs_data_release(settings);
    [self send:@{@"type":@"applied", @"selection":self.selection, @"presets":self.presets, @"revision":@(revision), @"sourceName":self.selectedSource}];
    [self refreshStatus:nil];
}

- (void)addFilter
{
    if (self.currentFilter || !self.selectedSource.length)
        return;
    obs_source_t *source = obs_get_source_by_name(self.selectedSource.UTF8String);
    if (!source)
        return;
    // A source may have gained the engine while this dock was hidden.
    obs_source_t *existing = nullptr;
    obs_source_enum_filters(source, LBFindFilter, &existing);
    if (existing) {
        obs_source_release(existing);
        obs_source_release(source);
        [self loadSelectedFilter];
        return;
    }
    obs_data_t *settings = obs_data_create();
    obs_data_set_bool(settings, "enabled", true);
    obs_data_set_bool(settings, "native_mode", true);
    obs_data_set_string(settings, "native_selection", "{\"version\":1,\"items\":[]}");
    obs_data_set_string(settings, "native_updates", "[]");
    obs_data_set_string(settings, "node_paths", "[]");
    obs_source_t *filter = obs_source_create(lb_filter_id(), "直播美颜", settings, nullptr);
    obs_data_release(settings);
    if (filter) {
        obs_source_filter_add(source, filter);
        obs_source_release(filter);
    }
    obs_source_release(source);
    [self loadSelectedFilter];
}

- (void)chooseResourceRoot
{
    if (!self.currentFilter)
        return;
    NSOpenPanel *dialog = [NSOpenPanel openPanel];
    dialog.title = @"选择美颜资源目录";
    dialog.prompt = @"使用此目录";
    dialog.canChooseDirectories = YES;
    dialog.canChooseFiles = NO;
    dialog.allowsMultipleSelection = NO;
    [dialog beginSheetModalForWindow:self.webView.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !self.currentFilter)
            return;
        obs_data_t *settings = obs_source_get_settings(self.currentFilter);
        obs_data_set_string(settings, "resource_root", dialog.URL.path.UTF8String);
        obs_source_update(self.currentFilter, settings);
        obs_data_release(settings);
        [self loadSelectedFilter];
    }];
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (!message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSDictionary.class])
        return;
    NSURL *url = message.frameInfo.request.URL;
    if (![url.scheme isEqual:@"file"] || ![url.path.stringByStandardizingPath isEqual:self.htmlPath.stringByStandardizingPath])
        return;
    NSDictionary *body = message.body;
    NSString *action = body[@"action"];
    if ([action isEqual:@"ready"]) {
        self.pageReady = YES;
        [self refreshSources];
    } else if ([action isEqual:@"refreshSources"]) {
        [self refreshSources];
    } else if ([action isEqual:@"selectSource"]) {
        if ([self.sourceNames containsObject:body[@"name"]]) {
            self.selectedSource = body[@"name"];
            [self loadSelectedFilter];
        }
    } else if ([action isEqual:@"addFilter"]) {
        [self addFilter];
    } else if ([action isEqual:@"setEnabled"] && self.currentFilter) {
        [self endComparison];
        obs_data_t *settings = obs_source_get_settings(self.currentFilter);
        obs_data_set_bool(settings, "enabled", [body[@"enabled"] boolValue]);
        obs_source_update(self.currentFilter, settings);
        obs_data_release(settings);
        [self refreshStatus:nil];
    } else if ([action isEqual:@"applySelection"]) {
        if ([body[@"sourceName"] isEqual:self.selectedSource])
            [self applySelection:body[@"selection"] revision:[body[@"revision"] integerValue] presets:body[@"presets"]];
    } else if ([action isEqual:@"beginComparison"]) {
        if ([body[@"sourceName"] isEqual:self.selectedSource])
            [self beginComparison];
    } else if ([action isEqual:@"endComparison"]) {
        [self endComparison];
    } else if ([action isEqual:@"reset"]) {
        [self applySelection:@{@"items":@[]} revision:[body[@"revision"] integerValue] presets:nil];
        [self sendState];
    } else if ([action isEqual:@"chooseResourceRoot"]) {
        [self chooseResourceRoot];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = action.request.URL;
    BOOL local = [url.scheme isEqual:@"file"] && [url.path.stringByStandardizingPath isEqual:self.htmlPath.stringByStandardizingPath];
    decisionHandler(local ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSString *relative = [task.request.URL.path stringByRemovingPercentEncoding];
    if ([relative hasPrefix:@"/"])
        relative = [relative substringFromIndex:1];
    NSString *path = [self safeAssetPath:relative];
    NSData *bytes = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nullptr] : nil;
    if (!bytes.length) {
        [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
        return;
    }
    NSString *extension = path.pathExtension.lowercaseString;
    NSString *mime = [extension isEqual:@"jpg"] || [extension isEqual:@"jpeg"] ? @"image/jpeg" : [extension isEqual:@"webp"] ? @"image/webp" : [extension isEqual:@"gif"] ? @"image/gif" : @"image/png";
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:task.request.URL MIMEType:mime expectedContentLength:bytes.length textEncodingName:nil];
    [task didReceiveResponse:response];
    [task didReceiveData:bytes];
    [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {}

- (void)showPanel
{
    lb_dock_show(self.dock);
    [self dockVisibilityChanged:YES];
}

- (void)dockVisibilityChanged:(BOOL)visible
{
    [self endComparison];
    if (visible) {
        [self refreshSources];
        if (!self.timer)
            self.timer = [NSTimer scheduledTimerWithTimeInterval:.75 target:self selector:@selector(refreshStatus:) userInfo:nil repeats:YES];
    } else {
        [self.timer invalidate];
        self.timer = nil;
        [self releaseFilter];
    }
}

- (void)shutdown
{
    [self endComparison];
    [self.timer invalidate];
    self.timer = nil;
    [self releaseFilter];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"liveBeauty"];
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    lb_dock_destroy(self.dock);
    self.dock = nullptr;
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    [self endComparison];
    self.pageReady = NO;
}
@end

static LBPanelController *gPanel;

void lb_panel_register_dock(void)
{
    if (!NSThread.isMainThread || !lb_dock_frontend_available())
        return;
    if (!gPanel)
        gPanel = [[LBPanelController alloc] init];
}

void lb_panel_refresh_sources(void)
{
    void (^refresh)(void) = ^{
        if (gPanel && lb_dock_is_visible(gPanel.dock))
            [gPanel refreshSources];
    };
    if (NSThread.isMainThread) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

void lb_panel_show(void)
{
    void (^show)(void) = ^{
        lb_panel_register_dock();
        [gPanel showPanel];
    };
    if (NSThread.isMainThread)
        show();
    else
        dispatch_async(dispatch_get_main_queue(), show);
}

void lb_panel_shutdown(void)
{
    void (^shutdown)(void) = ^{
        [gPanel shutdown];
        gPanel = nil;
    };
    if (NSThread.isMainThread)
        shutdown();
    else
        dispatch_sync(dispatch_get_main_queue(), shutdown);
}
