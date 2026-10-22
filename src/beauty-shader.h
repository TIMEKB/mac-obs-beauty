#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Coordinates use normalized OpenGL texture space: x increases rightwards,
 * y increases upwards. Geometry must come from an actual face detector.
 * An absent/invalid face disables every local effect. */
typedef struct LBFaceGeometry {
    bool valid;
    float center_x, center_y, half_width, half_height;
    float left_eye_x, left_eye_y, right_eye_x, right_eye_y;
    float lip_x, lip_y, lip_half_width, lip_half_height;
} LBFaceGeometry;

#ifdef __cplusplus
extern "C" {
#endif

/* Every engine owns one shader object. All calls require its current OBS
 * OpenGL context. This is our own basic beauty implementation, not a recovered
 * Windows preset. Lipstick/blush use feathered geometry, not complete makeup
 * tracking. Render restores the OpenGL state and source sampling it changes. */
void *lb_beauty_shader_create(void);
bool lb_beauty_shader_render(void *shader, uint32_t srcTex, uint32_t dstTex,
                            int width, int height, double timestamp,
                            const char *settingsJSON,
                            const LBFaceGeometry *face);
const char *lb_beauty_shader_status(void *shader);
void lb_beauty_shader_destroy(void *shader);

#ifdef __cplusplus
}
#endif
