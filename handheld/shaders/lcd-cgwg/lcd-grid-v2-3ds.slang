#version 450

layout(push_constant) uniform Push
{
    float RSUBPIX_R;
    float RSUBPIX_G;
    float RSUBPIX_B;
    float GSUBPIX_R;
    float GSUBPIX_G;
    float GSUBPIX_B;
    float BSUBPIX_R;
    float BSUBPIX_G;
    float BSUBPIX_B;
    float gain;
    float gamma;
    float blacklevel;
    float ambient;
    float BGR;
    float AZAHAR_SWAP;
    float AZAHAR_LARGE_PROPORTION;
    float AZAHAR_SOURCE_FLIP;
} params;

#pragma parameter RSUBPIX_R  "Colour of R subpixel: R" 1.0 0.0 1.0 0.01
#pragma parameter RSUBPIX_G  "Colour of R subpixel: G" 0.0 0.0 1.0 0.01
#pragma parameter RSUBPIX_B  "Colour of R subpixel: B" 0.0 0.0 1.0 0.01
#pragma parameter GSUBPIX_R  "Colour of G subpixel: R" 0.0 0.0 1.0 0.01
#pragma parameter GSUBPIX_G  "Colour of G subpixel: G" 1.0 0.0 1.0 0.01
#pragma parameter GSUBPIX_B  "Colour of G subpixel: B" 0.0 0.0 1.0 0.01
#pragma parameter BSUBPIX_R  "Colour of B subpixel: R" 0.0 0.0 1.0 0.01
#pragma parameter BSUBPIX_G  "Colour of B subpixel: G" 0.0 0.0 1.0 0.01
#pragma parameter BSUBPIX_B  "Colour of B subpixel: B" 1.0 0.0 1.0 0.01
#pragma parameter gain       "Gain"                    1.0 0.5 2.0 0.05
#pragma parameter gamma      "LCD Gamma"               3.0 0.5 5.0 0.1
#pragma parameter blacklevel "Black level"            0.05 0.0 0.5 0.01
#pragma parameter ambient    "Ambient"                 0.0 0.0 0.5 0.01
#pragma parameter BGR        "BGR"                     0 0 1 1

#pragma parameter AZAHAR_SWAP "Azahar Swap Screens (stacked / side by side)" 0.0 0.0 1.0 1.0
#pragma parameter AZAHAR_LARGE_PROPORTION "Azahar Large Screen Proportion (match core)" 4.0 1.0 6.0 0.25
#pragma parameter AZAHAR_SOURCE_FLIP "Azahar Source: 0=Vulkan/Software, 1=OpenGL" 1.0 0.0 1.0 1.0

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    vec4 OutputSize;
    vec4 OriginalSize;
    vec4 SourceSize;
} global;

#define outgamma 2.2

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

struct LatticeRegion
{
    vec2 origin;
    vec2 extent;
    vec2 logicalSize;
};

// Layout adaptation: Copyright 2016-2026 Citra Emulator Project /
// Azahar Emulator Project, GPLv2 or later.
// Geometry follows azahar-emu/azahar 164fd78ca55285d5e6cdcb954de725ecebe60a6e:
// src/citra_libretro/emu_window/libretro_window.cpp (ComputeLayoutGeometry),
// src/core/frontend/framebuffer_layout.cpp (LargeFrameLayout), and
// src/common/settings.h (BottomRight, zero gap, no integer scaling).
// Assumes the libretro core's 2D output, without cropping, rotation or borders.
// OriginalSize identifies the core framebuffer even after a scaling pass.
// Stacked / side-by-side swap state and Large Screen Proportion cannot be
// inferred from framebuffer size: match those two parameters to the core.
// citra_libretro.cpp sets bottom_left_origin for OpenGL; its source texture
// is vertically reversed relative to layout coordinates. Slang does not expose
// this core flag, so match Source to the core renderer as well.
// Large Screen's buffer uses a fixed 4:1 proportion and max(resolution, 4),
// even when its actual rectangles use a different proportion (1.00 .. 6.00).

bool matches_frame(vec2 size, vec2 base, float minimumScale)
{
    float scale = floor(size.y / base.y + 0.5);
    return scale >= minimumScale && scale <= 18.0 &&
           all(lessThan(abs(size - base * scale), vec2(0.5)));
}

bool contains_coord(vec2 coord, LatticeRegion region)
{
    return all(greaterThanEqual(coord, region.origin)) &&
           all(lessThan(coord, region.origin + region.extent));
}

LatticeRegion pixel_region(vec2 origin, vec2 extent, vec2 logical, vec2 frame)
{
    if (params.AZAHAR_SOURCE_FLIP > 0.5)
        origin.y = frame.y - origin.y - extent.y;
    return LatticeRegion(origin / frame, extent / frame, logical);
}

float layout_divide(float numerator, float denominator)
{
    // GPU division may use an approximate reciprocal. Correct its residual
    // before the core's integer truncation (e.g. 1173 / 240 * 400 at 5x,
    // proportion 3.50). This avoids a one-pixel difference without float64.
    precise float quotient = numerator / denominator;
    precise float residual = fma(-quotient, denominator, numerator);
    precise float corrected = quotient + residual / denominator;
    return corrected;
}

bool select_region(vec2 coord, out LatticeRegion region)
{
    vec2 frame = global.OriginalSize.xy;
    bool swapped = params.AZAHAR_SWAP > 0.5;
    vec2 top = vec2(400.0, 240.0);
    vec2 bottom = vec2(320.0, 240.0);

    // Single-screen dimensions identify the physical screen without a setting.
    if (matches_frame(frame, top, 1.0)) {
        region = pixel_region(vec2(0.0), frame, top, frame);
        return contains_coord(coord, region);
    }
    if (matches_frame(frame, bottom, 1.0)) {
        region = pixel_region(vec2(0.0), frame, bottom, frame);
        return contains_coord(coord, region);
    }

    bool stacked = matches_frame(frame, vec2(400.0, 480.0), 1.0);
    bool sideBySide = matches_frame(frame, vec2(720.0, 240.0), 1.0);
    bool largeTop = matches_frame(frame, vec2(480.0, 240.0), 4.0);
    bool largeBottom = matches_frame(frame, vec2(420.0, 240.0), 4.0);
    if (!(stacked || sideBySide || largeTop || largeBottom))
        return false;

    // Large Screen's dimensions identify which screen is prominent.
    bool largeLayout = largeTop || largeBottom;
    if (largeLayout)
        swapped = largeBottom;
    vec2 mainLogical = swapped ? bottom : top;
    vec2 smallLogical = swapped ? top : bottom;
    float proportion = largeLayout
        ? floor(clamp(params.AZAHAR_LARGE_PROPORTION, 1.0, 6.0) * 4.0 + 0.5) / 4.0
        : 1.0;

    // Match the core's integer truncation BEFORE fitting the combined box.
    vec2 mainNative = mainLogical;
    vec2 smallNative = floor(smallLogical / proportion);
    vec2 box = stacked
        ? vec2(max(mainNative.x, smallNative.x), mainNative.y + smallNative.y)
        : vec2(mainNative.x + smallNative.x, max(mainNative.y, smallNative.y));
    precise float fit = min(layout_divide(frame.x, box.x), layout_divide(frame.y, box.y));
    precise vec2 fitted = floor(box * fit);
    vec2 boxOrigin = floor((frame - fitted) * 0.5);
    precise float scale = layout_divide(fitted.y, box.y);
    // The core truncates the absolute right/bottom coordinates, not just sizes.
    precise vec2 mainEnd = mainNative * scale + boxOrigin;
    precise vec2 smallEnd = smallNative * scale + boxOrigin;
    vec2 mainExtent = floor(mainEnd) - boxOrigin;
    vec2 smallExtent = floor(smallEnd) - boxOrigin;
    vec2 mainOrigin = boxOrigin;
    vec2 smallOrigin = boxOrigin;

    if (stacked) {
        mainOrigin.x += floor((fitted.x - mainExtent.x) * 0.5);
        smallOrigin += vec2(mainOrigin.x - boxOrigin.x +
                            floor(mainExtent.x * 0.5) - floor(smallExtent.x * 0.5),
                            mainExtent.y);
    } else {
        smallOrigin.x += mainExtent.x;
        smallOrigin.y += largeLayout ? mainExtent.y - smallExtent.y
                                     : floor((mainExtent.y - smallExtent.y) * 0.5);
    }

    LatticeRegion mainRegion = pixel_region(mainOrigin, mainExtent, mainLogical, frame);
    LatticeRegion smallRegion = pixel_region(smallOrigin, smallExtent, smallLogical, frame);
    if (contains_coord(coord, mainRegion)) {
        region = mainRegion;
        return true;
    }
    if (contains_coord(coord, smallRegion)) {
        region = smallRegion;
        return true;
    }
    return false;
}

// On an unresolved screen, integrate the source footprint of each native LCD
// cell instead of selecting one texel from the core's fractionally scaled image.
// Retain the established sampling on resolved screens; smoothly transition so
// filtering the small screen does not cost a full-screen supersampling pass.
// Edge taps never leave this screen. Native nearest replication stays sharp.
vec3 fetch_logical(LatticeRegion region, ivec2 logicalCoord)
{
    logicalCoord = clamp(logicalCoord, ivec2(0), ivec2(region.logicalSize) - ivec2(1));
    vec2 origin = region.origin * global.SourceSize.xy;
    vec2 extent = region.extent * global.SourceSize.xy;
    vec2 cell = extent / region.logicalSize;
    vec2 lo = origin + vec2(logicalCoord) * cell;
    vec2 hi = origin + vec2(logicalCoord + ivec2(1)) * cell;
    ivec2 regionMin = ivec2(ceil(origin - vec2(0.5)));
    ivec2 regionMax = ivec2(ceil(origin + extent - vec2(0.5))) - ivec2(1);
    regionMin = clamp(regionMin, ivec2(0), ivec2(global.SourceSize.xy) - ivec2(1));
    regionMax = clamp(regionMax, regionMin, ivec2(global.SourceSize.xy) - ivec2(1));
    vec3 centre = texelFetch(Source, clamp(ivec2(floor((lo + hi) * 0.5)), regionMin, regionMax), 0).rgb;
    centre = pow(vec3(params.gain) * centre + vec3(params.blacklevel), vec3(params.gamma)) + vec3(params.ambient);
    vec2 outputScale = region.extent * global.OutputSize.xy / region.logicalSize;
    float filtering = 1.0 - smoothstep(2.0, 2.5, min(outputScale.x, outputScale.y));
    if (filtering <= 0.0) return centre;
    vec3 sum = vec3(0.0);
    for (int y = int(floor(lo.y)); y < int(ceil(hi.y)); ++y) {
        float wy = max(0.0, min(hi.y, float(y + 1)) - max(lo.y, float(y)));
        for (int x = int(floor(lo.x)); x < int(ceil(hi.x)); ++x) {
            float wx = max(0.0, min(hi.x, float(x + 1)) - max(lo.x, float(x)));
            vec3 c = texelFetch(Source, clamp(ivec2(x, y), regionMin, regionMax), 0).rgb;
            sum += wx * wy * (pow(vec3(params.gain) * c + vec3(params.blacklevel),
                                  vec3(params.gamma)) + vec3(params.ambient));
        }
    }
    return mix(centre, sum / (cell.x * cell.y), filtering);
}

// integral of (1 - x^2 - x^4 + x^6)^2
float coeffs_x[7] = float[](1.0, -2.0/3.0, -1.0/5.0, 4.0/7.0, -1.0/9.0, -2.0/11.0, 1.0/13.0);
// integral of (1 - 2x^4 + x^6)^2
float coeffs_y[7] = float[](1.0,      0.0, -4.0/5.0, 2.0/7.0,  4.0/9.0, -4.0/11.0, 1.0/13.0);

float intsmear_func(float z, float coeffs[7])
{
    float z2 = z*z;
    float zn = z;
    float ret = 0.0;
    for (int i = 0; i < 7; i++) {
        ret += zn*coeffs[i];
        zn *= z2;
    }
    return ret;
}

float intsmear(float x, float dx, float d, float coeffs[7])
{
    float zl = clamp((x-dx*0.5)/d,-1.0,1.0);
    float zh = clamp((x+dx*0.5)/d,-1.0,1.0);
    return d * ( intsmear_func(zh,coeffs) - intsmear_func(zl,coeffs) )/dx;
}

void main()
{
    LatticeRegion region;
    if (!select_region(vTexCoord, region)) {
        FragColor = texture(Source, vTexCoord);
        return;
    }
    vec2 logicalTexelSize = region.extent / region.logicalSize;
    vec2 logicalCoord = (vTexCoord - region.origin) / logicalTexelSize;
    vec2 logicalRange = global.OutputSize.zw / logicalTexelSize;

    vec3 cred = pow(vec3(params.RSUBPIX_R, params.RSUBPIX_G, params.RSUBPIX_B), vec3(outgamma));
    vec3 cgreen = pow(vec3(params.GSUBPIX_R, params.GSUBPIX_G, params.GSUBPIX_B), vec3(outgamma));
    vec3 cblue = pow(vec3(params.BSUBPIX_R, params.BSUBPIX_G, params.BSUBPIX_B), vec3(outgamma));

    // At low output scale the RGB aperture is not resolvable. Blend towards
    // area-filtered cell colours, per screen, not a blur of the composite.
    // Both kernels have the same integrated light output, avoiding a gain or
    // white-point change as the grid fades. At >=4 pixels/cell it is unchanged.
    float visibility = smoothstep(2.5, 4.0, min(1.0 / logicalRange.x, 1.0 / logicalRange.y));
    float meanX = intsmear_func(1.0, coeffs_x); // full aperture / RGB period
    float meanY = 1.26 * intsmear_func(1.0, coeffs_y);
    vec2 lo = logicalCoord - logicalRange * 0.5;
    vec2 hi = logicalCoord + logicalRange * 0.5;
    // Include the entire aperture plus the output-pixel footprint. The old
    // fixed 2x2 neighbourhood misses edge lobes at low output scales.
    vec2 support = visibility > 0.0 ? vec2(1.0 / 3.0, 0.13) : vec2(0.0);
    ivec2 first = ivec2(floor(lo - support));
    ivec2 last = ivec2(floor(hi + support));
    vec3 averageColor = vec3(0.0);
    for (int y = first.y; y <= last.y; ++y) {
        float plainY = max(0.0, min(hi.y, float(y + 1)) - max(lo.y, float(y))) / logicalRange.y;
        float gridY = intsmear(logicalCoord.y - float(y) - 0.5, logicalRange.y, 0.63, coeffs_y);
        float wy = mix(plainY * meanY, gridY, visibility);
        if (wy <= 0.0) continue;
        for (int x = first.x; x <= last.x; ++x) {
            float plainX = max(0.0, min(hi.x, float(x + 1)) - max(lo.x, float(x))) / logicalRange.x;
            float phase = (logicalCoord.x - float(x) - 0.5) * 3.0;
            vec3 gridX = vec3(intsmear(phase + 1.0, logicalRange.x * 3.0, 1.5, coeffs_x),
                              intsmear(phase, logicalRange.x * 3.0, 1.5, coeffs_x),
                              intsmear(phase - 1.0, logicalRange.x * 3.0, 1.5, coeffs_x));
            if (params.BGR > 0.5) gridX = gridX.bgr;
            vec3 wx = mix(vec3(plainX * meanX), gridX, visibility);
            if (max(max(wx.r, wx.g), wx.b) <= 0.0) continue;
            averageColor += fetch_logical(region, ivec2(x, y)) * wx * wy;
        }
    }
    averageColor = mat3(cred, cgreen, cblue) * averageColor;
    FragColor = vec4(pow(averageColor, vec3(1.0 / outgamma)), 0.0);
}
