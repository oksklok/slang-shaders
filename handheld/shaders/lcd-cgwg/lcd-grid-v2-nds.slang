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
    float MELONDS_RENDERER;
    float NDS_WIDE_LAYOUT;
    float LARGE_SCREEN_POSITION;
    float HYBRID_SMALL_SCREEN_MODE;
    float SECONDARY_SCALE;
    float SCREEN_GAP;
    float DESMUME_HYBRID_GAP;
} params;

#pragma parameter RSUBPIX_R      "Colour of R subpixel: R"       1.0 0.0 1.0 0.01
#pragma parameter RSUBPIX_G      "Colour of R subpixel: G"       0.0 0.0 1.0 0.01
#pragma parameter RSUBPIX_B      "Colour of R subpixel: B"       0.0 0.0 1.0 0.01
#pragma parameter GSUBPIX_R      "Colour of G subpixel: R"       0.0 0.0 1.0 0.01
#pragma parameter GSUBPIX_G      "Colour of G subpixel: G"       1.0 0.0 1.0 0.01
#pragma parameter GSUBPIX_B      "Colour of G subpixel: B"       0.0 0.0 1.0 0.01
#pragma parameter BSUBPIX_R      "Colour of B subpixel: R"       0.0 0.0 1.0 0.01
#pragma parameter BSUBPIX_G      "Colour of B subpixel: G"       0.0 0.0 1.0 0.01
#pragma parameter BSUBPIX_B      "Colour of B subpixel: B"       1.0 0.0 1.0 0.01
#pragma parameter gain           "Gain"                          1.0 0.5 2.0 0.05
#pragma parameter gamma          "LCD Gamma"                     3.0 0.5 5.0 0.1
#pragma parameter blacklevel     "Black level"                    0.05 0.0 0.5 0.01
#pragma parameter ambient        "Ambient"                        0.0 0.0 0.5 0.01
#pragma parameter BGR            "BGR"                            0.0 0.0 1.0 1.0
#pragma parameter MELONDS_RENDERER "melonDS Renderer: 0=Software, 1=OpenGL" 0.0 0.0 1.0 1.0
#pragma parameter NDS_WIDE_LAYOUT "Wide Layout: 0=melonDS, 1=Large, 2=DeSmuME" 0.0 0.0 2.0 1.0
#pragma parameter LARGE_SCREEN_POSITION "Large Screen Position: 0=Left/Top, 1=Right/Bottom" 0.0 0.0 1.0 1.0
#pragma parameter HYBRID_SMALL_SCREEN_MODE "Hybrid Small Screens: 0=Both, 1=Upper, 2=Lower" 0.0 0.0 2.0 1.0
#pragma parameter SECONDARY_SCALE "Vertical Secondary Screen Scale (%)" 100.0 50.0 100.0 5.0
#pragma parameter SCREEN_GAP     "Vertical Screen Gap (core pixels)" 0.0 0.0 126.0 1.0
#pragma parameter DESMUME_HYBRID_GAP "DeSmuME Hybrid Gap (core pixels)" 0.0 0.0 64.0 1.0

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

bool contains_coord(vec2 coord, LatticeRegion region)
{
    return all(greaterThanEqual(coord, region.origin)) &&
           all(lessThan(coord, region.origin + region.extent));
}

bool matches_size(vec2 actual, vec2 expected)
{
    return all(lessThan(abs(actual - expected), vec2(0.25)));
}

bool integer_scale(float scale)
{
    return scale >= 1.0 && abs(scale - floor(scale + 0.5)) < 0.001;
}

LatticeRegion region_from_pixels(vec2 originPx, vec2 extentPx, vec2 sourceSize)
{
    return LatticeRegion(originPx / sourceSize, extentPx / sourceSize, vec2(256.0, 192.0));
}

bool select_pair(vec2 coord, LatticeRegion first, LatticeRegion second, out LatticeRegion region)
{
    if (contains_coord(coord, first)) {
        region = first;
        return true;
    }
    if (contains_coord(coord, second)) {
        region = second;
        return true;
    }
    return false;
}

bool matches_noods_gap(float normalizedGap)
{
    return abs(normalizedGap) < 0.25 ||
           abs(normalizedGap - 36.0) < 0.25 ||
           abs(normalizedGap - 72.0) < 0.25 ||
           abs(normalizedGap - 144.0) < 0.25;
}

bool select_region(vec2 coord, out LatticeRegion region)
{
    const vec2 logicalSize = vec2(256.0, 192.0);
    vec2 sourceSize = global.SourceSize.xy;

    // melonDS DS scaled vertical layouts need explicit scale/gap settings because
    // different combinations can produce the same total framebuffer height.
    float verticalScale = sourceSize.x / logicalSize.x;
    if (integer_scale(verticalScale)) {
        float renderScale = floor(verticalScale + 0.5);
        float secondaryScale = clamp(params.SECONDARY_SCALE, 50.0, 100.0) / 100.0;
        vec2 primaryExtentPx = logicalSize * renderScale;
        vec2 secondaryExtentPx = floor(primaryExtentPx * secondaryScale);
        float secondaryLeftPx = primaryExtentPx.x * (1.0 - secondaryScale) * 0.5;
        float secondaryOriginXPx = floor(secondaryLeftPx);
        // Software truncates a copied rectangle; OpenGL rasterizes the full floating-point span.
        if (params.MELONDS_RENDERER > 0.5) {
            float secondaryRightPx = secondaryLeftPx + primaryExtentPx.x * secondaryScale;
            secondaryExtentPx.x = ceil(secondaryRightPx) - secondaryOriginXPx;
        }
        vec2 secondaryOriginPx = vec2(
            secondaryOriginXPx,
            renderScale * (logicalSize.y + max(params.SCREEN_GAP, 0.0))
        );
        vec2 expectedSize = vec2(primaryExtentPx.x, secondaryOriginPx.y + secondaryExtentPx.y);

        if (matches_size(sourceSize, expectedSize)) {
            return select_pair(
                coord,
                region_from_pixels(vec2(0.0), primaryExtentPx, sourceSize),
                region_from_pixels(secondaryOriginPx, secondaryExtentPx, sourceSize),
                region
            );
        }
    }

    // Single-screen layouts from all audited cores.
    float stockScale = sourceSize.x / logicalSize.x;
    if (integer_scale(stockScale) && matches_size(
        sourceSize,
        logicalSize * floor(stockScale + 0.5)
    )) {
        region = LatticeRegion(vec2(0.0), vec2(1.0), logicalSize);
        return contains_coord(coord, region);
    }

    // Equal-size vertical layouts. The gap is deterministic once the integer
    // per-screen scale has been established.
    float equalVerticalScale = sourceSize.x / logicalSize.x;
    if (integer_scale(equalVerticalScale)) {
        float renderScale = floor(equalVerticalScale + 0.5);
        vec2 screenExtentPx = logicalSize * renderScale;
        float gapPx = sourceSize.y - 2.0 * screenExtentPx.y;
        if (gapPx >= -0.25 && gapPx <= 126.0 * renderScale + 0.25) {
            return select_pair(
                coord,
                region_from_pixels(vec2(0.0), screenExtentPx, sourceSize),
                region_from_pixels(vec2(0.0, screenExtentPx.y + max(gapPx, 0.0)), screenExtentPx, sourceSize),
                region
            );
        }
    }

    // Equal-size horizontal layouts. Screen order changes content, not geometry.
    float equalHorizontalScale = sourceSize.y / logicalSize.y;
    if (integer_scale(equalHorizontalScale)) {
        float renderScale = floor(equalHorizontalScale + 0.5);
        vec2 screenExtentPx = logicalSize * renderScale;
        float gapPx = sourceSize.x - 2.0 * screenExtentPx.x;
        if (gapPx >= -0.25 && gapPx <= 126.0 * renderScale + 0.25) {
            return select_pair(
                coord,
                region_from_pixels(vec2(0.0), screenExtentPx, sourceSize),
                region_from_pixels(vec2(screenExtentPx.x + max(gapPx, 0.0), 0.0), screenExtentPx, sourceSize),
                region
            );
        }
    }

    // NooDS vertical Enlarge Top/Bottom uses a 2x large screen, 1x small
    // screen, and one of four deterministic physical gaps.
    float noodsVerticalScale = sourceSize.x / 512.0;
    if (integer_scale(noodsVerticalScale)) {
        float renderScale = floor(noodsVerticalScale + 0.5);
        float gapPx = sourceSize.y - 576.0 * renderScale;
        if (gapPx >= -0.25 && matches_noods_gap(gapPx / renderScale)) {
            vec2 largeExtentPx = vec2(512.0, 384.0) * renderScale;
            vec2 smallExtentPx = vec2(256.0, 192.0) * renderScale;
            bool largeSecond = params.LARGE_SCREEN_POSITION > 0.5;
            vec2 largeOriginPx = largeSecond ? vec2(0.0, smallExtentPx.y + max(gapPx, 0.0)) : vec2(0.0);
            vec2 smallOriginPx = largeSecond
                ? vec2(128.0 * renderScale, 0.0)
                : vec2(128.0 * renderScale, largeExtentPx.y + max(gapPx, 0.0));
            return select_pair(
                coord,
                region_from_pixels(largeOriginPx, largeExtentPx, sourceSize),
                region_from_pixels(smallOriginPx, smallExtentPx, sourceSize),
                region
            );
        }
    }

    // Wide-layout descriptors. DeSmuME's native Hybrid widths use integer
    // truncation, while legacy melonDS adds a few padding columns.
    bool wideFound = false;
    bool ambiguousWide = false;
    bool legacyMelonDs = false;
    bool desmumeHybrid = false;
    bool forceSingleSmall = false;
    float ratio = 0.0;
    float sideGapPx = 0.0;
    vec2 largeExtentPx = vec2(0.0);
    vec2 smallExtentPx = vec2(0.0);

    float legacyScale2 = sourceSize.y / (logicalSize.y * 2.0);
    float legacyScale3 = sourceSize.y / (logicalSize.y * 3.0);
    if (integer_scale(legacyScale2) && matches_size(
        sourceSize,
        vec2(768.0 * floor(legacyScale2 + 0.5) + 4.0, 384.0 * floor(legacyScale2 + 0.5))
    )) {
        float renderScale = floor(legacyScale2 + 0.5);
        wideFound = true;
        legacyMelonDs = true;
        ratio = 2.0;
        largeExtentPx = vec2(512.0, 384.0) * renderScale;
        smallExtentPx = logicalSize * renderScale;
        sideGapPx = 1.0;
    }
    else if (integer_scale(legacyScale3) && matches_size(
        sourceSize,
        vec2(1024.0 * floor(legacyScale3 + 0.5) + 6.0, 576.0 * floor(legacyScale3 + 0.5))
    )) {
        float renderScale = floor(legacyScale3 + 0.5);
        wideFound = true;
        legacyMelonDs = true;
        ratio = 3.0;
        largeExtentPx = vec2(768.0, 576.0) * renderScale;
        smallExtentPx = logicalSize * renderScale;
        sideGapPx = 2.0;
    }

    if (!wideFound && matches_size(sourceSize, vec2(1023.0, 576.0))) {
        wideFound = true;
        desmumeHybrid = true;
        ratio = 3.0;
        largeExtentPx = vec2(768.0, 576.0);
        smallExtentPx = vec2(255.0, 192.0);
    }

    float desmumeScale = sourceSize.y / logicalSize.y;
    if (!wideFound && integer_scale(desmumeScale)) {
        float renderScale = floor(desmumeScale + 0.5);
        vec2 ratio2Size = vec2(384.0 * renderScale, 192.0 * renderScale);
        vec2 ratio3Size = vec2(
            256.0 * renderScale + floor(256.0 * renderScale / 3.0),
            192.0 * renderScale
        );
        if (matches_size(sourceSize, ratio2Size)) {
            wideFound = true;
            desmumeHybrid = true;
            ratio = 2.0;
            largeExtentPx = logicalSize * renderScale;
            smallExtentPx = floor(logicalSize * renderScale / 2.0);
            ambiguousWide = integer_scale(renderScale / 2.0);
        }
        else if (matches_size(sourceSize, ratio3Size)) {
            wideFound = true;
            desmumeHybrid = true;
            ratio = 3.0;
            largeExtentPx = logicalSize * renderScale;
            smallExtentPx = floor(logicalSize * renderScale / 3.0);
            ambiguousWide = integer_scale(renderScale / 3.0);
        }
    }

    // NooDS horizontal Enlarge Top/Bottom has the same screen scales as a
    // 2:1 Largescreen layout, with an optional scaled gap between them.
    float noodsWideScale = sourceSize.y / 384.0;
    if (!wideFound && integer_scale(noodsWideScale)) {
        float renderScale = floor(noodsWideScale + 0.5);
        float gapPx = sourceSize.x - 768.0 * renderScale;
        if (gapPx > 0.25 && matches_noods_gap(gapPx / renderScale)) {
            wideFound = true;
            forceSingleSmall = true;
            ratio = 2.0;
            sideGapPx = gapPx;
            largeExtentPx = vec2(512.0, 384.0) * renderScale;
            smallExtentPx = logicalSize * renderScale;
        }
    }

    if (!wideFound)
        return false;

    float wideMode = floor(clamp(params.NDS_WIDE_LAYOUT, 0.0, 2.0) + 0.5);
    // Current DeSmuME and DeSmuME 2015 can emit the same 3:1 framebuffer
    // dimensions with different one-pixel placement. Require the current-core
    // mode instead of silently choosing between them.
    if (desmumeHybrid && ratio > 2.5 && !ambiguousWide && wideMode < 1.5)
        return false;
    bool singleSmall = forceSingleSmall || (ambiguousWide && wideMode > 0.5 && wideMode < 1.5);
    bool largeSecond = !legacyMelonDs && params.LARGE_SCREEN_POSITION > 0.5;
    float largeX = largeSecond ? smallExtentPx.x + sideGapPx : 0.0;
    float smallX = largeSecond ? 0.0 : largeExtentPx.x + sideGapPx;
    LatticeRegion large = region_from_pixels(vec2(largeX, 0.0), largeExtentPx, sourceSize);

    if (singleSmall) {
        float smallY = floor((sourceSize.y - smallExtentPx.y) * 0.5);
        LatticeRegion small = region_from_pixels(vec2(smallX, smallY), smallExtentPx, sourceSize);
        return select_pair(coord, large, small, region);
    }

    float hybridGapPx = 0.0;
    bool useDesmumeSpacing = desmumeHybrid && (!ambiguousWide || wideMode > 1.5);
    if (useDesmumeSpacing && ratio > 2.5) {
        float largeScale = largeExtentPx.x / logicalSize.x;
        hybridGapPx = clamp(params.DESMUME_HYBRID_GAP, 0.0, 64.0) * largeScale;
    }
    float smallTopY = useDesmumeSpacing
        ? floor(sourceSize.y * 0.5) - floor(hybridGapPx * 0.5) - smallExtentPx.y
        : 0.0;
    float smallBottomY = useDesmumeSpacing
        ? smallTopY + smallExtentPx.y + hybridGapPx
        : sourceSize.y - smallExtentPx.y;
    LatticeRegion smallTop = region_from_pixels(vec2(smallX, smallTopY), smallExtentPx, sourceSize);
    LatticeRegion smallBottom = region_from_pixels(vec2(smallX, smallBottomY), smallExtentPx, sourceSize);
    float smallMode = floor(clamp(params.HYBRID_SMALL_SCREEN_MODE, 0.0, 2.0) + 0.5);

    if (contains_coord(coord, large)) {
        region = large;
        return true;
    }
    if (smallMode < 1.5 && contains_coord(coord, smallTop)) {
        region = smallTop;
        return true;
    }
    if ((smallMode < 0.5 || smallMode > 1.5) && contains_coord(coord, smallBottom)) {
        region = smallBottom;
        return true;
    }
    return false;
}

vec3 fetch_logical(LatticeRegion region, ivec2 logicalCoord)
{
    ivec2 logicalMax = ivec2(region.logicalSize) - ivec2(1);
    logicalCoord = clamp(logicalCoord, ivec2(0), logicalMax);

    vec2 regionOriginPx = floor(region.origin * global.SourceSize.xy + vec2(0.5));
    vec2 regionExtentPx = floor(region.extent * global.SourceSize.xy + vec2(0.5));
    vec2 sourcePx = regionOriginPx +
        (vec2(logicalCoord) + vec2(0.5)) * regionExtentPx / region.logicalSize;

    ivec2 regionMin = ivec2(regionOriginPx);
    ivec2 regionMax = ivec2(regionOriginPx + regionExtentPx) - ivec2(1);
    ivec2 sourceCoord = clamp(ivec2(floor(sourcePx)), regionMin, regionMax);
    vec3 sourceColor = texelFetch(Source, sourceCoord, 0).rgb;

    return pow(vec3(params.gain) * sourceColor + vec3(params.blacklevel), vec3(params.gamma)) + vec3(params.ambient);
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

    vec3 cred   = pow(vec3(params.RSUBPIX_R, params.RSUBPIX_G, params.RSUBPIX_B), vec3(outgamma));
    vec3 cgreen = pow(vec3(params.GSUBPIX_R, params.GSUBPIX_G, params.GSUBPIX_B), vec3(outgamma));
    vec3 cblue  = pow(vec3(params.BSUBPIX_R, params.BSUBPIX_G, params.BSUBPIX_B), vec3(outgamma));

    ivec2 tli = ivec2(floor(logicalCoord - vec2(0.4999)));

    vec3 lcol, rcol;
    float subpix = (logicalCoord.x - 0.4999 - float(tli.x))*3.0;
    float rsubpix = logicalRange.x * 3.0;

    lcol = vec3(intsmear(subpix+1.0, rsubpix, 1.5, coeffs_x),
                intsmear(subpix    , rsubpix, 1.5, coeffs_x),
                intsmear(subpix-1.0, rsubpix, 1.5, coeffs_x));
    rcol = vec3(intsmear(subpix-2.0, rsubpix, 1.5, coeffs_x),
                intsmear(subpix-3.0, rsubpix, 1.5, coeffs_x),
                intsmear(subpix-4.0, rsubpix, 1.5, coeffs_x));

    if (params.BGR > 0.5) {
        lcol.rgb = lcol.bgr;
        rcol.rgb = rcol.bgr;
    }

    float tcol, bcol;
    subpix = logicalCoord.y - 0.4999 - float(tli.y);
    rsubpix = logicalRange.y;
    tcol = intsmear(subpix    ,rsubpix, 0.63, coeffs_y);
    bcol = intsmear(subpix-1.0,rsubpix, 0.63, coeffs_y);

    vec3 topLeftColor     = fetch_logical(region, tli + ivec2(0,0)) * lcol * vec3(tcol);
    vec3 bottomRightColor = fetch_logical(region, tli + ivec2(1,1)) * rcol * vec3(bcol);
    vec3 bottomLeftColor  = fetch_logical(region, tli + ivec2(0,1)) * lcol * vec3(bcol);
    vec3 topRightColor    = fetch_logical(region, tli + ivec2(1,0)) * rcol * vec3(tcol);

    vec3 averageColor = topLeftColor + bottomRightColor + bottomLeftColor + topRightColor;
    averageColor = mat3(cred, cgreen, cblue) * averageColor;

    FragColor = vec4(pow(averageColor, vec3(1.0/outgamma)),0.0);
}
