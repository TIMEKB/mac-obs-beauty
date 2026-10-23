#pragma once
#include <cmath>
#include <cstdint>
#include <vector>

// Diagnostic copies only. SDK indices and face identities stay engine-local.
// Canonical display space: normalized coordinates, origin at the input's top left.
struct LBPoint { float x=0, y=0; };
struct LBDebugFace {
    int id=0;
    float score=0;
    std::vector<LBPoint> points, head;
};
struct LBDebugGeometry {
    int width=0, height=0;
    uint64_t frame=0;
    std::vector<LBDebugFace> faces;
};

extern "C" bool lb_engine_copy_debug(void *context,LBDebugGeometry *geometry);
