#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Called with the OBS OpenGL graphics context current. Each filter owns one
 * engine. Texture IDs refer to 2D RGBA textures in that context. The driver must
 * restore any OpenGL state it changes before returning. A false result means
 * the host preserves the unfiltered source. No output may be assumed valid. */
void *lb_engine_create(const char *resourceRoot);
bool lb_engine_render(void *engine, uint32_t srcTex, uint32_t dstTex, int width,
                      int height, double timestamp, const char *settingsJSON);
/* A READY prefix is reserved for an engine whose selected nodes are usable.
 * The host copies the returned text while on the render thread. */
const char *lb_engine_status(void *engine);
/* True only when the last render deliberately selected the original frame. */
bool lb_engine_is_passthrough(void *engine);
void lb_engine_destroy(void *engine);

#ifdef __cplusplus
}
#endif
