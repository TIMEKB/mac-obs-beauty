#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <ImageIO/ImageIO.h>
#include <util/platform.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <string>
#include <cstring>
#include "face-debug.h"
#include "obs-dock-host.h"
#include <obs-frontend-api.h>

namespace {
std::atomic<obs_source_t *> requested{nullptr};
std::mutex frameMutex;
NSDictionary *latest=nil;
uint64_t generation=0;
NSString *text(const char *p){return p?([NSString stringWithUTF8String:p]?:@""):@"";}
NSString *json(id value){NSData *d=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];return d?[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding]:@"{}";}
NSArray *points(const std::vector<LBPoint> &source){
    NSMutableArray *a=[NSMutableArray array];
    for(size_t i=0;i<source.size();i++){
        const auto p=source[i];
        // Keep original index, reject invalid coordinates rather than clamp them
        // onto the face edge and conceal a mapping error.
        if(std::isfinite(p.x)&&std::isfinite(p.y))
            [a addObject:@[@(i),@(p.x),@(p.y)]];
    }
    return a;
}
NSString *thumbnail(LBDebugCapture &c,gs_texture_t *texture){
    if(!texture||!gs_texrender_begin(c.small,c.width,c.height))return nil;
    const bool srgb=gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(false);gs_blend_state_push();gs_blend_function(GS_BLEND_ONE,GS_BLEND_ZERO);
    vec4 clear={};gs_clear(GS_CLEAR_COLOR,&clear,0,0);
    gs_ortho(0,float(c.width),0,float(c.height),-100,100);
    gs_effect_t *effect=obs_get_base_effect(OBS_EFFECT_DEFAULT);
    gs_effect_set_texture(gs_effect_get_param_by_name(effect,"image"),texture);
    while(gs_effect_loop(effect,"Draw"))gs_draw_sprite(texture,0,c.width,c.height);
    gs_blend_state_pop();gs_enable_framebuffer_srgb(srgb);gs_texrender_end(c.small);
    gs_stage_texture(c.stage,gs_texrender_get_texture(c.small));
    uint8_t *pixels=nullptr;uint32_t stride=0;
    if(!gs_stagesurface_map(c.stage,&pixels,&stride))return nil;
    CFDataRef data=CFDataCreate(nullptr,pixels,CFIndex(size_t(stride)*c.height));
    gs_stagesurface_unmap(c.stage);
    CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image=CGImageCreate(c.width,c.height,8,32,stride,color,
        kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast,provider,nullptr,false,kCGRenderingIntentDefault);
    NSMutableData *jpeg=[NSMutableData data];
    CGImageDestinationRef dest=image?CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg,CFSTR("public.jpeg"),1,nullptr):nullptr;
    bool ok=false;
    if(dest){CGImageDestinationAddImage(dest,image,(__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality:@0.87});ok=CGImageDestinationFinalize(dest);CFRelease(dest);}
    if(image)CGImageRelease(image);CGColorSpaceRelease(color);CGDataProviderRelease(provider);CFRelease(data);
    return ok?[@"data:image/jpeg;base64," stringByAppendingString:[jpeg base64EncodedStringWithOptions:0]]:nil;
}
}

void LBDebugCapture::reset(){if(small)gs_texrender_destroy(small);if(stage)gs_stagesurface_destroy(stage);small=nullptr;stage=nullptr;width=height=0;last=0;}
LBDebugCapture::~LBDebugCapture(){reset();}
bool lb_debug_requested(obs_source_t *filter){return filter&&requested.load(std::memory_order_acquire)==filter;}
extern "C" void lb_debug_request(obs_source_t *filter){
    const auto previous=requested.exchange(filter,std::memory_order_acq_rel);
    if(previous!=filter){std::lock_guard<std::mutex> lock(frameMutex);latest=nil;}
}
extern "C" const char *lb_debug_copy_frame_json(){
    thread_local std::string copy;std::lock_guard<std::mutex> lock(frameMutex);
    copy=latest?[json(latest) UTF8String]:"{}";return copy.c_str();
}
void lb_debug_publish(obs_source_t *filter,LBDebugCapture &c,gs_texture_t *input,gs_texture_t *output,const LBDebugGeometry &g,const char *status){
    if(!lb_debug_requested(filter)||!input)return;
    const uint64_t now=os_gettime_ns();if(now-c.last<333333333ULL)return;c.last=now;
    @autoreleasepool {
        const uint32_t iw=gs_texture_get_width(input),ih=gs_texture_get_height(input);
        if(!iw||!ih)return;
        const double scale=std::min({1.,960./iw,720./ih});
        const uint32_t w=std::max(1U,uint32_t(iw*scale)),h=std::max(1U,uint32_t(ih*scale));
        if(c.width!=w||c.height!=h){if(c.stage)gs_stagesurface_destroy(c.stage);c.stage=gs_stagesurface_create(w,h,GS_RGBA);c.width=w;c.height=h;}
        if(!c.small)c.small=gs_texrender_create(GS_RGBA,GS_ZS_NONE);
        if(!c.small||!c.stage)return;
        gs_texrender_reset(c.small);NSString *before=thumbnail(c,input);
        gs_texrender_reset(c.small);NSString *after=output?thumbnail(c,output):before;
        if(!before||!after)return;
        NSMutableArray *faces=[NSMutableArray array];
        for(const auto &f:g.faces)[faces addObject:@{@"id":@(f.id),@"score":@(f.score),@"points":points(f.points),@"head":points(f.head)}];
        std::lock_guard<std::mutex> lock(frameMutex);
        if(!lb_debug_requested(filter))return;
        latest=@{@"type":@"frame",@"sequence":@(++generation),@"width":@(iw),@"height":@(ih),
          @"geometryWidth":@(g.width),@"geometryHeight":@(g.height),@"before":before,@"after":after,
          @"faces":faces,@"status":text(status)};
    }
}

@interface LBFaceDebugController:NSObject<NSWindowDelegate,WKScriptMessageHandler,WKNavigationDelegate>
@property(nonatomic,strong)NSWindow *window;
@property(nonatomic,strong)WKWebView *web;
@property(nonatomic,strong)NSTimer *timer;
@property(nonatomic,assign)obs_source_t *filter;
@property(nonatomic,strong)NSString *engine;
@property(nonatomic,assign)BOOL ready;
@property(nonatomic,assign)BOOL active;
@property(nonatomic,assign)uint64_t sent;
@property(nonatomic,assign)uint64_t lastFrameTime;
- (void)show:(obs_source_t*)filter engine:(NSString*)engine;
- (void)stop;
@end
@interface LBFaceDebugBridge:NSObject<WKScriptMessageHandler>
@property(nonatomic,weak)LBFaceDebugController *owner;
@end
@implementation LBFaceDebugBridge
- (void)userContentController:(WKUserContentController*)c didReceiveScriptMessage:(WKScriptMessage*)m{[self.owner userContentController:c didReceiveScriptMessage:m];}
@end
@implementation LBFaceDebugController
- (instancetype)init{
    if(!(self=[super init]))return nil;
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    LBFaceDebugBridge *bridge=[LBFaceDebugBridge new];bridge.owner=self;
    [config.userContentController addScriptMessageHandler:bridge name:@"faceDebug"];
    self.web=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,1000,740) configuration:config];self.web.navigationDelegate=self;
    self.web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1000,740) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed=NO;self.window.delegate=self;self.window.contentView=self.web;self.window.minSize=NSMakeSize(600,500);
    self.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];[self.window center];
    char *p=obs_module_file("face-debug.html");NSString *path=text(p);bfree(p);
    [self.web loadFileURL:[NSURL fileURLWithPath:path] allowingReadAccessToURL:[NSURL fileURLWithPath:path.stringByDeletingLastPathComponent]];
    return self;
}
- (void)send:(id)value{if(self.ready)[self.web evaluateJavaScript:[NSString stringWithFormat:@"window.FaceDebug.receive(%@)",json(value)] completionHandler:nil];}
- (void)show:(obs_source_t*)filter engine:(NSString*)engine{
    [self stop];self.filter=obs_source_get_ref(filter);self.engine=engine;self.active=YES;self.sent=0;self.lastFrameTime=os_gettime_ns();
    {std::lock_guard<std::mutex> lock(frameMutex);latest=nil;}
    self.window.title=[NSString stringWithFormat:@"识别点诊断 · %@ · %@",engine,text(obs_source_get_name(obs_filter_get_parent(filter)))];
    [self send:@{@"type":@"source",@"engine":engine,@"name":self.window.title}];
    lb_debug_request(self.filter);
    self.timer=[NSTimer scheduledTimerWithTimeInterval:.33 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [self.window makeKeyAndOrderFront:nil];
}
- (void)tick:(NSTimer*)timer{
    if(!self.filter||obs_source_removed(self.filter)){[self stop];[self send:@{@"type":@"idle",@"message":@"来源已移除，请从美颜面板重新打开诊断。"}];return;}
    if(!self.active)return;
    NSDictionary *frame=nil;{std::lock_guard<std::mutex> lock(frameMutex);frame=latest;}
    if(frame&&[frame[@"sequence"] unsignedLongLongValue]!=self.sent){self.sent=[frame[@"sequence"] unsignedLongLongValue];self.lastFrameTime=os_gettime_ns();[self send:frame];}
    else if(os_gettime_ns()-self.lastFrameTime>2000000000ULL)[self send:@{@"type":@"idle",@"message":@"等待新画面：请将此来源显示在当前场景，并启用该美颜实例。画面暂停时不显示旧点。"}];
}
- (void)stop{lb_debug_request(nullptr);[self.timer invalidate];self.timer=nil;if(self.filter)obs_source_release(self.filter);self.filter=nullptr;}
- (BOOL)windowShouldClose:(NSWindow*)window{[self stop];return YES;}
- (void)userContentController:(WKUserContentController*)c didReceiveScriptMessage:(WKScriptMessage*)m{
    if(!m.frameInfo.isMainFrame||!m.frameInfo.request.URL.isFileURL||![m.body isKindOfClass:NSDictionary.class])return;
    if([m.body[@"action"] isEqual:@"ready"]){self.ready=YES;[self send:@{@"type":@"source",@"engine":self.engine?:@"",@"name":self.window.title?:@""}];}
    else if([m.body[@"action"] isEqual:@"active"]){self.active=[m.body[@"value"] boolValue];lb_debug_request(self.active?self.filter:nullptr);self.lastFrameTime=os_gettime_ns();}
}
- (void)webView:(WKWebView*)web decidePolicyForNavigationAction:(WKNavigationAction*)a decisionHandler:(void(^)(WKNavigationActionPolicy))handler{handler(a.request.URL.isFileURL?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);}
@end
static LBFaceDebugController *debugController;
void lb_debug_show(obs_source_t *filter,const char *engine){
    if(!filter||!NSThread.isMainThread||!NSApp)return;
    if(!debugController)debugController=[LBFaceDebugController new];[debugController show:filter engine:text(engine)];
}
namespace {
bool collectDebugSources(void *opaque,obs_source_t *source){
    if(obs_source_get_type(source)==OBS_SOURCE_TYPE_INPUT&&(obs_source_get_output_flags(source)&OBS_SOURCE_VIDEO)){
        [(__bridge NSMutableArray*)opaque addObject:text(obs_source_get_name(source))];
    }
    return true;
}
struct FindDebugFilter {const char *id;obs_source_t *filter=nullptr;};
void findDebugFilter(obs_source_t *,obs_source_t *filter,void *opaque){auto &f=*(FindDebugFilter*)opaque;if(!f.filter&&!strcmp(obs_source_get_id(filter),f.id))f.filter=obs_source_get_ref(filter);}
}
void lb_debug_choose_source(){
    if(!NSThread.isMainThread)return;
    NSMutableArray *names=[NSMutableArray array];obs_enum_sources(collectDebugSources,(__bridge void*)names);[names sortUsingSelector:@selector(localizedStandardCompare:)];
    NSAlert *alert=[NSAlert new];alert.messageText=@"识别点诊断";
    if(!names.count){alert.informativeText=@"先在 OBS 添加一个摄像头、图像或其他视频来源。";[alert addButtonWithTitle:@"关闭"];[alert runModal];return;}
    alert.informativeText=@"选择画面来源与检测引擎。检测标记只显示在诊断窗口，不进入直播或录制。";
    NSView *accessory=[[NSView alloc]initWithFrame:NSMakeRect(0,0,330,76)];
    NSPopUpButton *source=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(0,43,330,28) pullsDown:NO];[source addItemsWithTitles:names];source.accessibilityLabel=@"诊断画面来源";
    NSPopUpButton *engine=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(0,5,330,28) pullsDown:NO];[engine addItemsWithTitles:@[@"直播伴侣 · 106点"]];engine.accessibilityLabel=@"诊断引擎";
    [accessory addSubview:source];[accessory addSubview:engine];alert.accessoryView=accessory;
    [alert addButtonWithTitle:@"打开诊断"];[alert addButtonWithTitle:@"取消"];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    obs_source_t *parent=obs_get_source_by_name(source.titleOfSelectedItem.UTF8String);if(!parent)return;
    const bool wink=engine.indexOfSelectedItem==1;
    FindDebugFilter found{wink?"wink_native_sharpen_filter":"live_beauty_filter"};obs_source_enum_filters(parent,findDebugFilter,&found);
    if(!found.filter){obs_data_t *settings=obs_data_create();obs_data_set_bool(settings,"enabled",false);obs_data_set_string(settings,"node_paths","[]");found.filter=obs_source_create(found.id,wink?"Wink 本地美颜":"直播美颜",settings,nullptr);obs_data_release(settings);if(found.filter)obs_source_filter_add(parent,found.filter);}
    obs_source_release(parent);
    if(found.filter){lb_debug_show(found.filter,wink?"Wink · 原生点位":"直播伴侣 · 106点");obs_source_release(found.filter);}
}
void lb_debug_shutdown(){if(debugController){[debugController stop];[debugController.window orderOut:nil];[debugController.web.configuration.userContentController removeScriptMessageHandlerForName:@"faceDebug"];debugController=nil;}}
