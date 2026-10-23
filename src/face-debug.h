#pragma once
#include <obs-module.h>
#include "face-debug-data.h"

// All GPU methods are render-thread only. UI methods are main-thread only.
struct LBDebugCapture {
    gs_texrender_t *small=nullptr;
    gs_stagesurf_t *stage=nullptr;
    uint32_t width=0, height=0;
    uint64_t last=0;
    void reset();
    ~LBDebugCapture(); // destroy with OBS graphics current
};
bool lb_debug_requested(obs_source_t *filter);
// Synchronous observer API also usable by standalone libobs diagnostic hosts.
// The caller holds a reference to filter until deselecting it.
extern "C" void lb_debug_request(obs_source_t *filter);
extern "C" const char *lb_debug_copy_frame_json(void);
void lb_debug_publish(obs_source_t *filter,LBDebugCapture &capture,
                      gs_texture_t *input,gs_texture_t *output,
                      const LBDebugGeometry &geometry,const char *status);
void lb_debug_show(obs_source_t *filter,const char *engine);
void lb_debug_choose_source(void);
void lb_debug_shutdown(void);
