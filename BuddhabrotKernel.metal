#include <metal_stdlib>
using namespace metal;

kernel void buddhabrotKernel(device atomic_uint *image            [[ buffer(0) ]],
                              constant int      &width              [[ buffer(1) ]],
                              constant int      &height             [[ buffer(2) ]],
                              constant float    &worldMinX          [[ buffer(3) ]],
                              constant float    &worldMinY          [[ buffer(4) ]],
                              constant float    &worldMaxX          [[ buffer(5) ]],
                              constant float    &worldMaxY          [[ buffer(6) ]],
                              constant int      &maxDepth           [[ buffer(7) ]],
                              constant int      &nCol               [[ buffer(8) ]],
                              constant int      &nRow               [[ buffer(9) ]],
                              constant float    &dx                 [[ buffer(10) ]],
                              constant float    &dy                 [[ buffer(11) ]],
                              constant float    &nWorld2ImageX      [[ buffer(12) ]],
                              constant float    &nWorld2ImageY      [[ buffer(13) ]],
                              constant ulong    &baseIndex          [[ buffer(14) ]],
                              uint tid                                [[ thread_position_in_grid ]])
{
    ulong globalIndex = baseIndex + tid;
    ulong totalSamples = ((ulong)nCol) * ((ulong)nRow);
    if (globalIndex >= totalSamples)
        return;
    
    int iCol = (int)(globalIndex / ((ulong)nRow));
    int iRow = (int)(globalIndex % ((ulong)nRow));
    
    float x = worldMinX + iCol * dx;
    float y = worldMinY + iRow * dy;
    
    float r = 0.0f, im = 0.0f, s, j;
    bool escaped = false;
    int escapeIndex = 0;
    for (int depth = 0; depth < maxDepth; depth++) {
        s = (r * r - im * im) + x;
        j = (2.0f * r * im) + y;
        r = s;
        im = j;
        if ((r * r + im * im) > 4.0f) {
            escaped = true;
            escapeIndex = depth;
            break;
        }
    }
    if (escaped) {
        r = 0.0f;
        im = 0.0f;
        for (int depth = 0; depth < escapeIndex; depth++) {
            s = (r * r - im * im) + x;
            j = (2.0f * r * im) + y;
            r = s;
            im = j;
            int u = (int)((r - worldMinX) * nWorld2ImageX);
            int v = (int)((im - worldMinY) * nWorld2ImageY);
            if (u >= 0 && u < width && v >= 0 && v < height) {
                atomic_fetch_add_explicit(&image[v * width + u], 1, memory_order_relaxed);
            }
        }
    }
}
