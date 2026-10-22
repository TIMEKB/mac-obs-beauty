#ifndef MAC_EFFECT_API_H
#define MAC_EFFECT_API_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Recovered from macOS Webcast Mate 10.0.3 arm64 callsites and libeffect
 * EffectSDK-2060. This is a binary-specific ABI, not the public *_ai_* API.
 * No SDK/render call is considered successful until its own return code and
 * output are checked. The library and resources retain their original rights.
 */
typedef uint64_t mac_effect_handle_t;
typedef int32_t mac_effect_result_t;
/* Callback first argument is the effect handle, not application userdata.
 * Callback returns malloc-owned NUL-terminated URI, e.g. file:///absolute/path.
 * The engine owns/free()s the result. Missing resource: strdup("asset://not_found").
 * arg2's exact semantic label is not recovered. arg3 is a resource/model name.
 * Match and log both strings; never assume an unknown name maps to a model.
 */
typedef char *(*mac_effect_resource_finder_t)(void *effect_handle,
                                           const char *arg2,
                                           const char *resource_name);
/* The actual caller passes reserved=0. The current callee consumes only out. */
typedef mac_effect_result_t (*mac_effect_create_handle_fn)(mac_effect_handle_t *out,
                                                          int32_t reserved);
/* destroy has no observed status return: treat as void. */
typedef void (*mac_effect_destroy_fn)(mac_effect_handle_t handle);
typedef mac_effect_result_t (*mac_effect_set_ab_license_fn)(mac_effect_handle_t handle,
                                                           const char *license);
/* Global configuration, no handle. Actual config types from callee loads. */
enum mac_effect_config_type {
    MAC_EFFECT_CONFIG_BOOL = 0, /* uint8_t* */
    MAC_EFFECT_CONFIG_INT = 1,  /* int32_t* */
    MAC_EFFECT_CONFIG_FLOAT = 2,/* float*: plugin numeric branch appears divergent */
    MAC_EFFECT_CONFIG_STRING = 3/* char* directly, not char** */
};
typedef mac_effect_result_t (*mac_effect_config_ab_value_fn)(const char *key,
                                                           const void *value,
                                                           int32_t type);
typedef mac_effect_result_t (*mac_effect_set_render_api_fn)(mac_effect_handle_t handle,
                                                          int32_t render_api);
typedef mac_effect_result_t (*mac_effect_use_pipeline_processor_fn)(mac_effect_handle_t handle,
                                                                  int32_t enable);
typedef mac_effect_result_t (*mac_effect_init_with_resource_finder_v2_fn)(
    mac_effect_handle_t handle, int32_t width, int32_t height,
    mac_effect_resource_finder_t finder, void (*free_resource)(void *),
    const char *device_name);
typedef mac_effect_result_t (*mac_effect_init_fn)(mac_effect_handle_t handle,
    int32_t width, int32_t height, const char *model_directory,
    const char *device_name);
typedef mac_effect_result_t (*mac_effect_set_width_height_fn)(mac_effect_handle_t handle,
                                                            int32_t width, int32_t height);
typedef mac_effect_result_t (*mac_effect_set_orientation_fn)(mac_effect_handle_t handle,
                                                           int32_t orientation);
typedef mac_effect_result_t (*mac_effect_process_texture_fn)(mac_effect_handle_t handle,
    uint32_t input_texture, uint32_t output_texture, double timestamp);
/* Basic algorithm_texture callee forwards handle, texture and d0 timestamp;
 * its third integer register is internally set to force=0. */
typedef mac_effect_result_t (*mac_effect_algorithm_texture_fn)(mac_effect_handle_t handle,
    uint32_t input_texture, double timestamp);
/* Exact macOS wrapper byte layout for its one-texture algorithm call.
 * The wrapper zeros the opaque bytes. Do not infer fields beyond those written.
 * Params flag_8 and flag_9 receive the same state byte: 1 after texture/context
 * setup or state change, then 0 after a completed frame; names remain unknown.
 */
typedef struct __attribute__((aligned(8))) mac_effect_texture_info {
    uint32_t texture;             /* +0 */
    int32_t width;                /* +4 */
    int32_t height;               /* +8 */
    uint8_t opaque_zero[68];      /* +12..79 */
} mac_effect_texture_info;
typedef struct mac_effect_algorithm_params {
    double timestamp;            /* +0 */
    uint8_t flag_8;               /* +8: same original state byte */
    uint8_t flag_9;               /* +9: same original state byte */
    uint8_t opaque_zero[46];      /* +10..55 */
} mac_effect_algorithm_params;
typedef mac_effect_result_t (*mac_effect_algorithm_multi_texture_with_params_fn)(
    mac_effect_handle_t handle, const mac_effect_texture_info *textures,
    int32_t texture_count, const mac_effect_algorithm_params *params);
#ifdef __cplusplus
static_assert(sizeof(mac_effect_texture_info) == 80, "SDK texture record stride");
static_assert(sizeof(mac_effect_algorithm_params) == 56, "SDK parameter copy size");
static_assert(offsetof(mac_effect_algorithm_params, flag_8) == 8, "SDK flag offset");
#else
_Static_assert(sizeof(mac_effect_texture_info) == 80, "SDK texture record stride");
_Static_assert(sizeof(mac_effect_algorithm_params) == 56, "SDK parameter copy size");
_Static_assert(offsetof(mac_effect_algorithm_params, flag_8) == 8, "SDK flag offset");
#endif
/* Required after init_v2 in the original Mac wrapper: (handle, 1, 0). */
typedef mac_effect_result_t (*mac_effect_composer_set_mode_fn)(mac_effect_handle_t handle,
    int32_t mode, int32_t order_type);
typedef mac_effect_result_t (*mac_effect_composer_set_nodes_fn)(mac_effect_handle_t handle,
    const char **absolute_node_paths, int32_t node_count);
typedef mac_effect_result_t (*mac_effect_composer_update_node_fn)(mac_effect_handle_t handle,
    const char *absolute_node_path, const char *node_key, float intensity);
/* The Mac wrapper sets render_api=1 while its CGL context is current, then
 * pipeline_processor=0, then init_v2(handle,w,h,finder,free,"pc_mac").
 * Config flags use uint8_t false, type=MAC_EFFECT_CONFIG_BOOL. */
#ifdef __cplusplus
}
#endif
#endif
