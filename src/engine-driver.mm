#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <OpenGL/gl3.h>
#include <OpenGL/OpenGL.h>
#include <dlfcn.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "engine.h"
#include "mac_effect_api.h"
#include "mac_face_result_api.h"
#include "beauty-shader.h"

namespace {
struct Engine;
std::mutex finderMutex;
std::map<mac_effect_handle_t,Engine*> finderEngines;
std::string str(NSString *s) { return s ? std::string(s.UTF8String) : std::string(); }
NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }
NSDictionary *readJSON(const std::string &path) {
    NSData *data = [NSData dataWithContentsOfFile:ns(path)];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

// Recheck before loading: the official application can update after installation.
NSString *librarySHA256(NSString *path) {
    NSInputStream *stream=[NSInputStream inputStreamWithFileAtPath:path];
    if(!stream)return @"";
    [stream open];
    CC_SHA256_CTX context;CC_SHA256_Init(&context);
    uint8_t buffer[65536];NSInteger count;
    while((count=[stream read:buffer maxLength:sizeof(buffer)])>0)
        CC_SHA256_Update(&context,buffer,(CC_LONG)count);
    [stream close];
    if(count<0)return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);
    NSMutableString *result=[NSMutableString string];
    for(unsigned char value:digest)[result appendFormat:@"%02x",value];
    return result;
}

// libobs and EffectSDK both cache GL state. A shared context isolates those
// caches while keeping the source/output textures on the GPU. Fences make
// texture writes visible before either context consumes the other one's work.
struct EffectContextScope {
    CGLContextObj previous=nullptr, effect=nullptr;
    bool active=false, shared=false;
    explicit EffectContextScope(CGLContextObj destination) : effect(destination) {
        previous=CGLGetCurrentContext();
        if(!effect)return;
        shared=previous && CGLGetShareGroup(previous)==CGLGetShareGroup(effect);
        GLsync ready=shared?glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0):nullptr;
        if(previous){if(shared)glFlush();else glFinish();}
        if(CGLSetCurrentContext(effect)!=kCGLNoError){if(ready)glDeleteSync(ready);return;}
        if(ready){glWaitSync(ready,0,GL_TIMEOUT_IGNORED);glDeleteSync(ready);}
        active=true;
    }
    ~EffectContextScope(){
        if(!active)return;
        GLsync ready=shared?glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0):nullptr;
        if(shared)glFlush();else glFinish();
        if(CGLSetCurrentContext(previous)==kCGLNoError && ready){
            glWaitSync(ready,0,GL_TIMEOUT_IGNORED);glDeleteSync(ready);
        }
    }
};

struct Engine {
    std::string root, status="等待引擎初始化", configIdentity;
    void *library=nullptr;
    CGLContextObj effectContext=nullptr;
    mac_effect_handle_t handle=0;
    int width=0,height=0;
    bool attempted=false;
    bool passthrough=false;
    int parameterReplayFrames=0;
    double timeOrigin=-1.0,lastEffectTime=0.0;
    std::map<std::string,std::string> models;
    std::vector<std::string> nodes;
    mac_face_result faces={};
    int faceResultCode=-11;
    bool detectionActivated=false;
    void *beautyShader=nullptr;
    mac_effect_get_face_detect_result_fn getFaces=nullptr;
    mac_effect_create_handle_fn create=nullptr;
    mac_effect_destroy_fn destroy=nullptr;
    mac_effect_set_ab_license_fn license=nullptr;
    mac_effect_config_ab_value_fn config=nullptr;
    mac_effect_set_render_api_fn renderAPI=nullptr;
    mac_effect_use_pipeline_processor_fn pipeline=nullptr;
    mac_effect_init_with_resource_finder_v2_fn init=nullptr;
    mac_effect_set_width_height_fn size=nullptr;
    mac_effect_algorithm_texture_fn algorithm=nullptr;
    mac_effect_process_texture_fn process=nullptr;
    mac_effect_composer_set_nodes_fn setNodes=nullptr;
    mac_effect_composer_set_mode_fn setMode=nullptr;
    mac_effect_composer_update_node_fn updateNode=nullptr;

    template<class T> bool symbol(T &fn,const char *name){
        fn=reinterpret_cast<T>(dlsym(library,name));
        if(!fn){status=std::string("缺少引擎接口：")+name;return false;}return true;
    }
    bool load(){
        if(library)return true;
        NSDictionary *manifest=readJSON(root+"/manifest.json");
        NSString *installedLibrary=manifest[@"runtime_library"];
        NSString *expected=manifest[@"runtime_sha256"];
        if(![installedLibrary isKindOfClass:NSString.class] || !installedLibrary.isAbsolutePath ||
           ![expected isKindOfClass:NSString.class] || expected.length!=64){
            status="尚未配置官方运行库，请运行安装器；当前保留原画";return false;
        }
        if(![librarySHA256(installedLibrary) isEqual:expected.lowercaseString]){
            status="官方运行库已改变，请重新核对版本并运行安装器；当前保留原画";return false;
        }
        const std::string libraryPath=str(installedLibrary);
        library=dlopen(libraryPath.c_str(),RTLD_NOW|RTLD_LOCAL);
        if(!library){const char*e=dlerror();status=std::string("引擎加载失败：")+(e?e:"");return false;}
        return symbol(create,"bef_effect_create_handle") && symbol(destroy,"bef_effect_destroy") &&
          symbol(license,"bef_effect_set_ab_license") && symbol(config,"bef_effect_config_ab_value") &&
          symbol(renderAPI,"bef_effect_set_render_api") && symbol(pipeline,"bef_effect_use_pipeline_processor") &&
          symbol(init,"bef_effect_init_with_resource_finder_v2") && symbol(size,"bef_effect_set_width_height") &&
          symbol(algorithm,"bef_effect_algorithm_texture") && symbol(process,"bef_effect_process_texture") &&
          symbol(setNodes,"bef_effect_composer_set_nodes") && symbol(setMode,"bef_effect_composer_set_mode") &&
          symbol(getFaces,"bef_effect_get_face_detect_result") && symbol(updateNode,"bef_effect_composer_update_node");
    }
    bool check(int code,const char *stage){
        if(code==0)return true;
        status=std::string("引擎返回错误：")+stage+" = "+std::to_string(code)+"；当前保留原画";
        return false;
    }
    static char *finder(void *effectHandle,const char *type,const char *name){
        std::string wanted=name?name:"";
        size_t slash=wanted.find_last_of('/');if(slash!=std::string::npos)wanted=wanted.substr(slash+1);
        std::string found,best;
        {
            std::lock_guard<std::mutex> lock(finderMutex);
            auto entry=finderEngines.find(reinterpret_cast<uintptr_t>(effectHandle));
            if(entry==finderEngines.end())return strdup("asset://not_found");
            Engine *e=entry->second;
            // Complete logical names before an optional version, longest first.
            for(const auto &m:e->models){
                if(wanted==m.first || wanted.rfind(m.first+"_v",0)==0 || wanted.rfind(m.first+".model",0)==0)
                    if(m.first.size()>best.size()){best=m.first;found=m.second;}
            }
        }
        if(found.empty() && name && name[0]=='/' && [[NSFileManager defaultManager] fileExistsAtPath:@(name)])found=name;
        std::string uri=found.empty()?"asset://not_found":"file://"+found;
        fprintf(stderr,"[live-beauty] resource %s / %s -> %s\n",type?type:"",name?name:"",found.empty()?"not found":best.c_str());
        return strdup(uri.c_str());
    }
    bool initialize(int w,int h){
        attempted=true;
        if(!load())return false;
        NSDictionary *manifest=readJSON(root+"/manifest.json");
        for(NSDictionary *m in manifest[@"models"]){
            if([m isKindOfClass:NSDictionary.class]){
                const std::string path=root+"/"+str(m[@"relative_path"]);
                models[str(m[@"logical_name"])]=path;
                if([m[@"encoded_name"] isKindOfClass:NSString.class])models[str(m[@"encoded_name"])]=path;
                if([m[@"encoded_basename"] isKindOfClass:NSString.class])models[str(m[@"encoded_basename"])]=path;
            }
        }
        if(!check(create(&handle,0),"create_handle") || !handle)return false;
        {std::lock_guard<std::mutex> lock(finderMutex);finderEngines[handle]=this;}
        if(!check(license(handle,"mediasdk"),"set_ab_license"))return false;
        uint8_t off=0;
        const char *flags[]={"effect_config_mediasdk_enable_multi_render_device_effect_node","effect_config_mediasdk_enable_cross_shader_online","effect_config_mediasdk_enable_cache_cross_shader","effect_config_mediasdk_enable_renderer_type_shader_finder","effect_config_mediasdk_enable_unified_renderer_type","effect_config_mediasdk_use_pixel_read"};
        for(const char *f:flags)if(!check(config(f,&off,MAC_EFFECT_CONFIG_BOOL),"config_ab_value"))return false;
        if(!check(renderAPI(handle,1),"set_render_api") || !check(pipeline(handle,0),"use_pipeline_processor"))return false;
        if(!check(init(handle,w,h,finder,::free,"pc_mac"),"init_with_resource_finder_v2"))return false;
        if(!check(setMode(handle,1,0),"composer_set_mode"))return false;
        width=w;height=h;status="引擎初始化成功；等待效果节点";return true;
    }
    bool prepareContext(){
        CGLContextObj host=CGLGetCurrentContext();
        if(!host){status="无法取得 OBS 图形上下文；当前保留原画";return false;}
        if(effectContext){
            if(CGLGetShareGroup(host)!=CGLGetShareGroup(effectContext)){
                status="OBS 图形设备已改变，请重新添加美颜滤镜；当前保留原画";return false;
            }
            return true;
        }
        CGLError error=CGLCreateContext(CGLGetPixelFormat(host),host,&effectContext);
        if(error!=kCGLNoError || !effectContext){
            status=std::string("无法建立美颜图形上下文：")+CGLErrorString(error);return false;
        }
        return true;
    }
    ~Engine(){
        if(effectContext){
            {
                EffectContextScope scope(effectContext);
                if(scope.active){
                    if(beautyShader)lb_beauty_shader_destroy(beautyShader);
                    if(handle&&destroy)destroy(handle);
                    glFinish();
                }
            }
            CGLDestroyContext(effectContext);
        }
        {std::lock_guard<std::mutex> lock(finderMutex);finderEngines.erase(handle);}
        /* Keep vendor code resident until OBS exits: SDK owns shared worker pools. */
    }

};
}

extern "C" void *lb_engine_create(const char *resourceRoot){
    Engine *e=new Engine();
    char *canonical=resourceRoot?realpath(resourceRoot,nullptr):nullptr;
    e->root=canonical?canonical:(resourceRoot?resourceRoot:"");free(canonical);return e;
}
extern "C" const char *lb_engine_status(void *context){return context?static_cast<Engine*>(context)->status.c_str():"引擎尚未创建";}
extern "C" bool lb_engine_is_passthrough(void *context){return context&&static_cast<Engine*>(context)->passthrough;}
extern "C" int lb_engine_copy_face_debug(void *context,float *points,int capacity,int *rect){
    Engine *e=static_cast<Engine*>(context);if(!e)return 0;
    int count=e->faces.face_count;if(count<1||count>MAC_FACE_MAX_COUNT)return 0;
    if(points&&capacity>=212)memcpy(points,e->faces.faces[0].points,sizeof(mac_face_point)*106);
    if(rect)memcpy(rect,e->faces.faces[0].rect,sizeof(int32_t)*4);
    return count;
}
extern "C" int lb_engine_face_result_code(void *context){return context?static_cast<Engine*>(context)->faceResultCode:-1;}
extern "C" void lb_engine_destroy(void *context){if(!context)return;delete static_cast<Engine*>(context);}
extern "C" bool lb_engine_render(void *context,uint32_t source,uint32_t target,int w,int h,double timestamp,const char *settingsJSON){
    @autoreleasepool {
        if(!context)return false;
        Engine *e=static_cast<Engine*>(context);
        e->passthrough=false;
        if(w<=0||h<=0||!source||!target||source==target)return false;
        NSData *data=settingsJSON?[@(settingsJSON) dataUsingEncoding:NSUTF8StringEncoding]:nil;
        id obj=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        NSDictionary *settings=[obj isKindOfClass:NSDictionary.class]?obj:@{};
        if(settings[@"enabled"] && ![settings[@"enabled"] boolValue]){e->status="已关闭";return false;}
        if(!e->prepareContext())return false;
        EffectContextScope effectScope(e->effectContext);
        if(!effectScope.active){e->status="无法切换美颜图形上下文；当前保留原画";return false;}
        if(!e->attempted){if(!e->initialize(w,h))return false;}
        if(!e->handle || !e->width)return false;
        if((w!=e->width||h!=e->height) && !e->check(e->size(e->handle,w,h),"set_width_height"))return false;
        e->width=w;e->height=h;
        const bool nativeMode=[settings[@"native_mode"] boolValue];
        NSArray *list=[settings[@"node_paths"] isKindOfClass:NSArray.class]?settings[@"node_paths"]:@[];
        std::vector<std::string> nodes;
        for(id p in list)if([p isKindOfClass:NSString.class]){
            std::string node=str(p);if(!node.empty() && node.front()!='/')node=e->root+"/"+node;
            if([[NSFileManager defaultManager] fileExistsAtPath:ns(node)])nodes.push_back(node);
        }
        // This original deformation scene switches its detection features off
        // while unused controls are neutralized. Keep the plain detection graph
        // active independently so both landmark-based feature groups still run.
        const std::string shapeNode=e->root+"/nodes/windows/03ec5a22e8e96469706ef0136a41c16d";
        if(nativeMode && std::find(nodes.begin(),nodes.end(),shapeNode)!=nodes.end()){
            const std::string detector=e->root+"/nodes/native-face-detector";
            if(![[NSFileManager defaultManager] fileExistsAtPath:ns(detector)]){
                e->status="缺少美型检测节点；当前保留原画";
                return false;
            }
            if(std::find(nodes.begin(),nodes.end(),detector)==nodes.end())nodes.insert(nodes.begin(),detector);
        }
        if(nodes.empty()){e->status="引擎已初始化；未选择可用美颜素材，当前保留原画";return false;}
        if(nodes!=e->nodes){
            std::vector<const char*> paths;for(const auto&n:nodes)paths.push_back(n.c_str());
            if(!e->check(e->setNodes(e->handle,paths.data(),(int)paths.size()),"composer_set_nodes"))return false;
            e->nodes=nodes;
        }
        const bool changed=e->configIdentity!=(settingsJSON?settingsJSON:"");
        if(nativeMode && changed)e->parameterReplayFrames=120;
        // Composer loads scene nodes asynchronously. A successful early update
        // does not mean its Lua/JS parameter receiver exists yet. Replay the
        // current selection briefly after a change so late-created receivers
        // receive their intended values as well.
        if(nativeMode && e->parameterReplayFrames>0){
            --e->parameterReplayFrames;
            NSArray *updates=[settings[@"native_updates"] isKindOfClass:NSArray.class]?settings[@"native_updates"]:@[];
            for(id candidate in updates){
                if(![candidate isKindOfClass:NSDictionary.class])continue;
                NSDictionary *u=candidate;
                if(![u[@"node"] isKindOfClass:NSString.class] || ![u[@"tag"] isKindOfClass:NSString.class] ||
                   ![u[@"value"] isKindOfClass:NSNumber.class])continue;
                std::string path=str(u[@"node"]);if(!path.empty()&&path.front()!='/')path=e->root+"/"+path;
                if(std::find(e->nodes.begin(),e->nodes.end(),path)==e->nodes.end())continue;
                float value=[u[@"value"] floatValue];
                if(!std::isfinite(value)||fabsf(value)>10000.0f || ![u[@"tag"] length])continue;
                if(!e->check(e->updateNode(e->handle,path.c_str(),[u[@"tag"] UTF8String],value),"composer_update_node"))return false;
            }
        }
        NSDictionary *bindings=nativeMode?@{}:readJSON(e->root+"/controls.json");
        for(NSDictionary *b in changed?bindings[@"bindings"]:@[]){
            NSString *key=b[@"control"],*tag=b[@"tag"],*node=b[@"node"];
            if(!key||!tag||!node||!settings[key])continue;
            std::string path=str(node);if(!path.empty()&&path.front()!='/')path=e->root+"/"+path;
            if(std::find(e->nodes.begin(),e->nodes.end(),path)==e->nodes.end())continue;
            float value=std::clamp([settings[key] floatValue],0.0f,1.0f);
            if(!e->check(e->updateNode(e->handle,path.c_str(),tag.UTF8String,value),"composer_update_node"))return false;
        }
        e->configIdentity=settingsJSON?settingsJSON:"";
        // The host clock can be an uptime-sized value, or unchanged during
        // manual/offscreen draws. Feed EffectSDK a small monotonic local clock.
        if(e->timeOrigin<0 && std::isfinite(timestamp))e->timeOrigin=timestamp;
        double effectTime=std::isfinite(timestamp)?1.0+std::max(0.0,timestamp-e->timeOrigin):e->lastEffectTime+1.0/60.0;
        if(effectTime<=e->lastEffectTime)effectTime=e->lastEffectTime+1.0/60.0;
        e->lastEffectTime=effectTime;
        int algorithmResult=e->algorithm(e->handle,source,effectTime);
        // -11 means no detection result yet. The first render activates pending
        // Composer nodes; it must run before a later frame can detect a face.
        // Never treat that warm-up frame as successful beauty output.
        if(algorithmResult!=0 && algorithmResult!=-11 && !e->check(algorithmResult,"algorithm_texture"))return false;
        if(!e->check(e->process(e->handle,source,target,effectTime),"process_texture"))return false;
        memset(&e->faces,0,sizeof(e->faces));
        e->faceResultCode=e->getFaces(e->handle,&e->faces);
        if(e->faceResultCode!=0 || e->faces.face_count<0 || e->faces.face_count>MAC_FACE_MAX_COUNT)e->faces.face_count=0;
        if(algorithmResult==0 && e->faceResultCode==0)e->detectionActivated=true;
        if(nativeMode){
            // Keep the engine/detectors warm and deliver the zero updates above,
            // but use OBS's original frame when every explicit intensity is zero.
            // Some vendor makeup nodes otherwise alter a few pixels at zero.
            NSArray *updates=[settings[@"native_updates"] isKindOfClass:NSArray.class]?settings[@"native_updates"]:@[];
            bool allZero=updates.count>0;
            for(id value in updates){
                if(![value isKindOfClass:NSDictionary.class] || ![value[@"value"] isKindOfClass:NSNumber.class] ||
                   !std::isfinite([value[@"value"] doubleValue]) || [value[@"value"] doubleValue]!=0.0){
                    allZero=false;break;
                }
            }
            if(allZero){e->passthrough=true;e->status="READY: 原版效果已连接，所有强度归零，当前保留原画";return false;}
            e->status=e->faces.face_count>0?"READY: 原版效果已连接，已识别人脸":"READY: 原版效果已连接";
            return true;
        }
        LBFaceGeometry face={};
        if(e->faces.face_count>0){
            const mac_face_106 &f=e->faces.faces[0];
            const float fw=float(f.rect[2]-f.rect[0]),fh=float(f.rect[3]-f.rect[1]);
            if(fw>10&&fh>10&&fw<w*1.1f&&fh<h*1.1f){
                face.valid=true;
                face.center_x=(f.rect[0]+f.rect[2])*0.5f/w;
                face.center_y=((f.rect[1]+f.rect[3])*0.5f-fh*0.10f)/h;
                face.half_width=fw*0.56f/w;face.half_height=fh*0.70f/h;
                for(int i=52;i<58;i++){face.left_eye_x+=f.points[i].x/(6.0f*w);face.left_eye_y+=f.points[i].y/(6.0f*h);}
                for(int i=58;i<64;i++){face.right_eye_x+=f.points[i].x/(6.0f*w);face.right_eye_y+=f.points[i].y/(6.0f*h);}
                float minX=float(w),minY=float(h),maxX=0,maxY=0;
                for(int i=84;i<96;i++){minX=std::min(minX,f.points[i].x);maxX=std::max(maxX,f.points[i].x);minY=std::min(minY,f.points[i].y);maxY=std::max(maxY,f.points[i].y);}
                face.lip_x=(minX+maxX)*0.5f/w;face.lip_y=(minY+maxY)*0.5f/h;
                face.lip_half_width=(maxX-minX)*0.52f/w;face.lip_half_height=(maxY-minY)*0.57f/h;
                if(!std::isfinite(face.center_x)||!std::isfinite(face.center_y))face.valid=false;
            }
        }
        if(!e->detectionActivated){e->status="等待人脸检测节点初始化；当前保留原画";return false;}
        if(!e->beautyShader)e->beautyShader=lb_beauty_shader_create();
        if(!lb_beauty_shader_render(e->beautyShader,source,target,w,h,timestamp,settingsJSON,&face)){
            e->status=lb_beauty_shader_status(e->beautyShader);return false;
        }
        e->status=face.valid?"READY: 已识别人脸，基础美颜已连接":"READY: 等待人脸进入画面";
        return true;
    }
}
