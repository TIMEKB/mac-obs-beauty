#import <Foundation/Foundation.h>

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/platform.h>

#include <algorithm>
#include <cstdio>
#include <mutex>
#include <string>
#include <unordered_map>

#include "engine.h"
#include "panel.h"
#include "obs-dock-host.h"
#include "resource-path.h"
#include "face-debug.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-live-beauty", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
    return "Apple Silicon live beauty engines with OBS dock controls";
}

namespace {
constexpr const char *kFilterID = "live_beauty_filter";
constexpr const char *kParameters[] = {
    "smooth", "whiten", "sharpen", "face_slim", "eye_enlarge",
    "lipstick", "blush", "filter_intensity",
};

struct Filter {
    obs_source_t *source = nullptr;
    std::mutex mutex;
    bool enabled = true;
    bool hasNodes = false;
    uint64_t settingsRevision = 0;
    uint64_t lastCreateAttemptRevision = UINT64_MAX;
    std::string resourceRoot;
    std::string settingsJSON;
    std::string status = "未就绪：未选择美颜节点，当前保留原画。";
    void *engine = nullptr;
    std::string engineRoot;
    gs_texrender_t *capture = nullptr;
    gs_texture_t *engineInput = nullptr;
    gs_texture_t *output = nullptr;
    uint32_t outputWidth = 0;
    uint32_t outputHeight = 0;
    LBDebugCapture debug;
};

std::mutex gFiltersMutex;
std::unordered_map<obs_source_t *, Filter *> gFilters;

NSString *string(const char *value)
{
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

void setStatus(Filter *filter, const std::string &status)
{
    std::lock_guard<std::mutex> lock(filter->mutex);
    filter->status = status;
}

void updateFilter(void *data, obs_data_t *settings)
{
    auto *filter = static_cast<Filter *>(data);
    @autoreleasepool {
        NSString *nodeText = string(obs_data_get_string(settings, "node_paths"));
        NSData *nodeData = [nodeText dataUsingEncoding:NSUTF8StringEncoding];
        id decoded = nodeData.length ? [NSJSONSerialization JSONObjectWithData:nodeData options:0 error:nullptr] : nil;
        NSMutableArray<NSString *> *nodes = [NSMutableArray array];
        if ([decoded isKindOfClass:[NSArray class]]) {
            for (id node in decoded) {
                if ([node isKindOfClass:[NSString class]] && [node length] > 0)
                    [nodes addObject:node];
            }
        }
        NSString *root = LBResolveResourceRoot(string(obs_data_get_string(settings, "resource_root")));
        BOOL enabled = obs_data_get_bool(settings, "enabled");
        NSMutableDictionary *json = [@{
            @"enabled": @(enabled),
            @"resource_root": root,
            @"node_paths": nodes,
            @"native_mode": @(obs_data_get_bool(settings,"native_mode")),
        } mutableCopy];
        NSString *updateText=string(obs_data_get_string(settings,"native_updates"));
        NSData *updateData=[updateText dataUsingEncoding:NSUTF8StringEncoding];
        id updates=updateData.length?[NSJSONSerialization JSONObjectWithData:updateData options:0 error:nullptr]:nil;
        json[@"native_updates"]=[updates isKindOfClass:NSArray.class]?updates:@[];
        for (const char *key : kParameters)
            json[string(key)] = @(std::clamp(obs_data_get_double(settings, key), 0.0, 1.0));
        NSData *serialized = [NSJSONSerialization dataWithJSONObject:json options:0 error:nullptr];
        std::string engineJSON;
        if (serialized)
            engineJSON.assign(static_cast<const char *>(serialized.bytes), serialized.length);
        std::lock_guard<std::mutex> lock(filter->mutex);
        filter->enabled = enabled;
        filter->hasNodes = nodes.count > 0;
        filter->resourceRoot = root.UTF8String ?: "";
        filter->settingsJSON = std::move(engineJSON);
        ++filter->settingsRevision;
        if (!enabled)
            filter->status = "已关闭，当前保留原画。";
        else if (nodes.count == 0)
            filter->status = "未就绪：未选择美颜节点，当前保留原画。";
        else
            filter->status = "等待渲染与节点检查，当前保留原画。";
    }
}

void defaults(obs_data_t *settings)
{
    obs_data_set_default_bool(settings, "enabled", true);
    obs_data_set_default_bool(settings, "native_mode", true);
    obs_data_set_default_string(settings, "native_updates", "[]");
    obs_data_set_default_string(settings, "native_selection", "{\"version\":1,\"items\":[]}");
    obs_data_set_default_string(settings, "native_presets", "{}");
    obs_data_set_default_string(settings, "node_paths", "[\"nodes/native-face-detector\"]");
    obs_data_set_default_string(settings, "resource_root", LBResourceRoot().UTF8String);
    for (const char *key : kParameters)
        obs_data_set_default_double(settings, key, 0.0);
    obs_data_set_default_double(settings, "smooth", 0.40);
    obs_data_set_default_double(settings, "whiten", 0.15);
    obs_data_set_default_double(settings, "sharpen", 0.10);
}

const char *filterName(void *) { return obs_module_text("LiveBeauty"); }

void *createFilter(obs_data_t *settings, obs_source_t *source)
{
    auto *filter = new Filter;
    filter->source = source;
    updateFilter(filter, settings);
    {
        std::lock_guard<std::mutex> lock(gFiltersMutex);
        gFilters.emplace(source, filter);
    }
    return filter;
}

void destroyFilter(void *data)
{
    auto *filter = static_cast<Filter *>(data);
    {
        std::lock_guard<std::mutex> lock(gFiltersMutex);
        gFilters.erase(filter->source);
    }
    obs_enter_graphics();
    if (filter->engine)
        lb_engine_destroy(filter->engine);
    if (filter->capture)
        gs_texrender_destroy(filter->capture);
    if (filter->engineInput)
        gs_texture_destroy(filter->engineInput);
    if (filter->output)
        gs_texture_destroy(filter->output);
    // LBDebugCapture owns GPU resources; its destructor must run in graphics.
    filter->debug.reset();
    obs_leave_graphics();
    delete filter;
}

bool openPanel(obs_properties_t *, obs_property_t *, void *)
{
    lb_panel_show();
    return false;
}

bool openDebug(obs_properties_t *,obs_property_t *,void *data){
    auto *f=static_cast<Filter*>(data);if(f)lb_debug_show(f->source,"直播伴侣 · 106点");return false;
}
obs_properties_t *properties(void *data)
{
    obs_properties_t *props = obs_properties_create();
    obs_properties_add_bool(props, "enabled", obs_module_text("Enable"));
    obs_properties_add_button2(props,"face_debug","识别点诊断（仅诊断窗口）",openDebug,data);
    obs_properties_add_text(props, "panel_hint", obs_module_text("PanelHint"), OBS_TEXT_INFO);
    obs_properties_add_button2(props, "open_panel", obs_module_text("OpenPanel"), openPanel, nullptr);
    return props;
}

bool ensureCapture(Filter *filter, uint32_t width, uint32_t height)
{
    if (!filter->capture)
        /* Sources such as Image Source draw linear RGB with framebuffer sRGB
         * enabled. Capture into sRGB storage so their encoded bytes survive. */
        filter->capture = gs_texrender_create(GS_RGBA, GS_ZS_NONE);
    if (!filter->capture)
        return false;
    if (filter->outputWidth != width || filter->outputHeight != height) {
        gs_texture_destroy(filter->output);
        filter->output = nullptr;
        gs_texture_destroy(filter->engineInput);
        filter->engineInput = nullptr;
        filter->outputWidth = width;
        filter->outputHeight = height;
    }
    /* Raw SDK/shader sampling must not apply the sRGB decode. A GPU copy
     * changes only the texture interpretation, preserving encoded bytes. */
    if (!filter->engineInput)
        filter->engineInput = gs_texture_create(width, height, GS_RGBA_UNORM, 1, nullptr, GS_RENDER_TARGET);
    if (!filter->output)
        filter->output = gs_texture_create(width, height, GS_RGBA, 1, nullptr, GS_RENDER_TARGET);
    return filter->engineInput && filter->output;
}

void renderFilter(void *data, gs_effect_t *)
{
    auto *filter = static_cast<Filter *>(data);
    bool enabled, hasNodes;
    uint64_t revision;
    std::string root, json;
    {
        std::lock_guard<std::mutex> lock(filter->mutex);
        enabled = filter->enabled;
        hasNodes = filter->hasNodes;
        revision = filter->settingsRevision;
        root = filter->resourceRoot;
        json = filter->settingsJSON;
    }
    const bool debug=lb_debug_requested(filter->source);
    if(debug&&(!enabled||!hasNodes)&&os_gettime_ns()-filter->debug.last<333333333ULL){obs_source_skip_video_filter(filter->source);return;}
    if ((!enabled || !hasNodes) && !debug) {
        obs_source_skip_video_filter(filter->source);
        return;
    }
    if (gs_get_device_type() != GS_DEVICE_OPENGL) {
        setStatus(filter, "未就绪：当前渲染后端不是 OpenGL，当前保留原画。");
        obs_source_skip_video_filter(filter->source);
        return;
    }
    if (root.empty()) {
        setStatus(filter, "未就绪：未选择资源目录，当前保留原画。");
        obs_source_skip_video_filter(filter->source);
        return;
    }
    if (filter->engine && filter->engineRoot != root) {
        lb_engine_destroy(filter->engine);
        filter->engine = nullptr;
    }
    if (!filter->engine) {
        if (filter->lastCreateAttemptRevision == revision) {
            obs_source_skip_video_filter(filter->source);
            return;
        }
        filter->lastCreateAttemptRevision = revision;
        filter->engine = lb_engine_create(root.c_str());
        filter->engineRoot = root;
        if (!filter->engine) {
            setStatus(filter, "未就绪：引擎创建失败，当前保留原画。");
            obs_source_skip_video_filter(filter->source);
            return;
        }
    }

    obs_source_t *target = obs_filter_get_target(filter->source);
    const uint32_t width = target ? obs_source_get_base_width(target) : 0;
    const uint32_t height = target ? obs_source_get_base_height(target) : 0;
    if (!width || !height || !ensureCapture(filter, width, height)) {
        setStatus(filter, "未就绪：来源尺寸或纹理不可用，当前保留原画。");
        obs_source_skip_video_filter(filter->source);
        return;
    }
    const gs_color_space requestedSpace = GS_CS_SRGB;
    if (obs_source_get_color_space(target, 1, &requestedSpace) != GS_CS_SRGB) {
        setStatus(filter, "未就绪：当前来源不是 SDR sRGB，当前保留原画。");
        obs_source_skip_video_filter(filter->source);
        return;
    }
    gs_texrender_reset(filter->capture);
    if (!gs_texrender_begin(filter->capture, width, height)) {
        setStatus(filter, "未就绪：无法捕获来源纹理，当前保留原画。");
        obs_source_skip_video_filter(filter->source);
        return;
    }
    vec4 clear = {};
    gs_blend_state_push();
    gs_blend_function_separate(GS_BLEND_SRCALPHA, GS_BLEND_INVSRCALPHA,
                              GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);
    gs_clear(GS_CLEAR_COLOR, &clear, 0.0f, 0);
    gs_ortho(0.0f, float(width), 0.0f, float(height), -100.0f, 100.0f);
    /* OBS routes parent/async/custom-draw sources correctly and avoids
     * recursively invoking this filter when target is the parent input. */
    const bool captureFramebufferSRGB = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(false);
    obs_source_skip_video_filter(filter->source);
    gs_enable_framebuffer_srgb(captureFramebufferSRGB);
    gs_blend_state_pop();
    gs_texrender_end(filter->capture);
    gs_texture_t *input = gs_texrender_get_texture(filter->capture);
    const bool copyFramebufferSRGB = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(false);
    gs_copy_texture(filter->engineInput, input);
    gs_enable_framebuffer_srgb(copyFramebufferSRGB);
    auto *inputObject = static_cast<uint32_t *>(gs_texture_get_obj(filter->engineInput));
    auto *outputObject = static_cast<uint32_t *>(gs_texture_get_obj(filter->output));
    const double timestamp = double(obs_get_video_frame_time()) / 1.0e9;
    bool processed = false;
    if(debug){
        @autoreleasepool {
            NSData *bytes=[@(json.c_str()) dataUsingEncoding:NSUTF8StringEncoding];
            id decoded=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingMutableContainers error:nil]:nil;
            NSMutableDictionary *temporary=[decoded isKindOfClass:NSMutableDictionary.class]?decoded:[NSMutableDictionary dictionary];
            temporary[@"debug_points"]=@YES;temporary[@"enabled"]=@YES;
            if(!enabled||!hasNodes){temporary[@"node_paths"]=@[];temporary[@"native_updates"]=@[];temporary[@"native_mode"]=@YES;}
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:temporary options:0 error:nil];
            if(encoded)json.assign((const char*)encoded.bytes,encoded.length);
        }
    }
    if (inputObject && outputObject) {
        processed = lb_engine_render(filter->engine, *inputObject, *outputObject,
                                     int(width), int(height), timestamp, json.c_str());
    }
    const char *engineStatus = lb_engine_status(filter->engine);
    std::string status = engineStatus && *engineStatus ? engineStatus :
        (processed ? "READY: 当前使用引擎输出。" : "未就绪：纹理处理失败，当前保留原画。");
    const bool passthrough = inputObject && outputObject && lb_engine_is_passthrough(filter->engine);
    if (!processed && !passthrough && status.rfind("READY", 0) == 0)
        status = "未就绪：本帧处理失败，当前保留原画。";
    setStatus(filter, status);
    if(debug){LBDebugGeometry geometry;lb_engine_copy_debug(filter->engine,&geometry);
        lb_debug_publish(filter->source,filter->debug,filter->engineInput,processed&&enabled&&hasNodes?filter->output:nullptr,geometry,status.c_str());}
    if (!processed || !enabled || !hasNodes) {
        obs_source_skip_video_filter(filter->source);
        return;
    }

    gs_effect_t *effect = obs_get_base_effect(OBS_EFFECT_DEFAULT);
    const bool linearSRGB = gs_get_linear_srgb();
    const bool outputFramebufferSRGB = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(linearSRGB);
    gs_eparam_t *image = gs_effect_get_param_by_name(effect, "image");
    if (linearSRGB)
        gs_effect_set_texture_srgb(image, filter->output);
    else
        gs_effect_set_texture(image, filter->output);
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);
    while (gs_effect_loop(effect, "Draw"))
        gs_draw_sprite(filter->output, 0, width, height);
    gs_blend_state_pop();
    gs_enable_framebuffer_srgb(outputFramebufferSRGB);
}

void menuCallback(void *) { lb_panel_show(); }
void dockGroupCallback(void *) { lb_dock_group_in_main_window(); }
void resourceMenuCallback(void *) { lb_panel_prepare_resources(); }
void debugMenuCallback(void *) { lb_debug_choose_source(); }

void frontendEvent(enum obs_frontend_event event, void *)
{
    if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING ||
        event == OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED ||
        event == OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED) {
        lb_panel_refresh_sources();
    }
    if (event == OBS_FRONTEND_EVENT_EXIT) {
        lb_panel_shutdown();
    }
}
} // namespace

const char *lb_filter_id(void) { return kFilterID; }

void lb_filter_copy_status(obs_source_t *source, char *buffer, size_t capacity)
{
    if (!buffer || capacity == 0)
        return;
    std::lock_guard<std::mutex> filtersLock(gFiltersMutex);
    const auto it = gFilters.find(source);
    if (it == gFilters.end()) {
        snprintf(buffer, capacity, "%s", "尚未添加直播美颜滤镜。");
        return;
    }
    std::lock_guard<std::mutex> lock(it->second->mutex);
    snprintf(buffer, capacity, "%s", it->second->status.c_str());
}

bool obs_module_load(void)
{
    struct obs_source_info info = {};
    info.id = kFilterID;
    info.type = OBS_SOURCE_TYPE_FILTER;
    info.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB;
    info.get_name = filterName;
    info.create = createFilter;
    info.destroy = destroyFilter;
    info.update = updateFilter;
    info.get_defaults = defaults;
    info.get_properties = properties;
    info.video_render = renderFilter;
    obs_register_source(&info);
    obs_frontend_add_tools_menu_item(obs_module_text("LiveBeauty"), menuCallback, nullptr);
    obs_frontend_add_tools_menu_item("将美颜面板停靠到主窗口", dockGroupCallback, nullptr);
    obs_frontend_add_tools_menu_item("识别点诊断…", debugMenuCallback, nullptr);
    obs_frontend_add_tools_menu_item("美颜运行资源…", resourceMenuCallback, nullptr);
    obs_frontend_add_event_callback(frontendEvent, nullptr);
    blog(LOG_INFO, "[obs-live-beauty] arm64 host loaded; dock controls register after frontend load");
    return true;
}

void obs_module_post_load(void)
{
    lb_panel_register_dock();
}

void obs_module_unload(void)
{
    lb_debug_shutdown();
    obs_frontend_remove_event_callback(frontendEvent, nullptr);
    lb_panel_shutdown();
}

#if LB_BUILD_STUB
/* Build-only fallback. This engine never claims to beautify or yields output. */
void *lb_engine_create(const char *) { return new int(0); }
bool lb_engine_render(void *, uint32_t, uint32_t, int, int, double, const char *) { return false; }
bool lb_engine_copy_debug(void *,LBDebugGeometry *g){if(g)*g={};return false;}
bool lb_engine_is_passthrough(void *) { return false; }
const char *lb_engine_status(void *) { return "未就绪：当前为编译检查占位引擎，当前保留原画。"; }
void lb_engine_destroy(void *engine) { delete static_cast<int *>(engine); }
#endif
