#ifndef MAC_FACE_RESULT_API_H
#define MAC_FACE_RESULT_API_H
#include <stddef.h>
#include <stdint.h>
#include "mac_effect_api.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Webcast Mate 10.0.3 arm64 binary-specific output ABI.
 * Plugin GetFacePoint 0x9b50 reads count at +0x8750, steps faces by 0x528,
 * and copies 106 {float,float} pairs at face+0x14..face+0x363.
 * GetROI 0xa074 copies first 16 bytes as four int32 coordinates.
 * Do not substitute an older public SDK face_info: extra_infos changed size.
 */
typedef struct mac_face_point { float x,y; } mac_face_point;
typedef struct mac_face_106 {
    int32_t rect[4];                  /* +0: original four int32 coordinates */
    float score;                     /* +16: confidence, cross-checked public header */
    mac_face_point points[106];       /* +20, 848 bytes */
    uint8_t trailing_opaque[452];      /* includes deprecated visibility and metadata */
} mac_face_106;
enum { MAC_FACE_MAX_COUNT=10, MAC_FACE_RESULT_BYTES=0x8754,
       MAC_FACE_RESULT_COUNT_OFFSET=0x8750 };
typedef struct mac_face_result {
    mac_face_106 faces[MAC_FACE_MAX_COUNT];
    uint8_t extra_opaque[0x8750 - 10*0x528];
    int32_t face_count;
} mac_face_result;
typedef mac_effect_result_t (*mac_effect_get_face_detect_result_fn)(
    mac_effect_handle_t handle, mac_face_result *result);
#ifdef __cplusplus
}
static_assert(sizeof(mac_face_point)==8,"point stride");
static_assert(sizeof(mac_face_106)==0x528,"face stride");
static_assert(offsetof(mac_face_106,points)==0x14,"point offset");
static_assert(offsetof(mac_face_result,face_count)==0x8750,"face count offset");
static_assert(sizeof(mac_face_result)==0x8754,"face result capacity");
#else
_Static_assert(sizeof(mac_face_point)==8,"point stride");
_Static_assert(sizeof(mac_face_106)==0x528,"face stride");
_Static_assert(offsetof(mac_face_106,points)==0x14,"point offset");
_Static_assert(offsetof(mac_face_result,face_count)==0x8750,"face count offset");
_Static_assert(sizeof(mac_face_result)==0x8754,"face result capacity");
#endif
#endif
