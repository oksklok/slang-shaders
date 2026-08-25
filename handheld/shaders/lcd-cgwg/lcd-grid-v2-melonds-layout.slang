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
    float MELONDS_LAYOUT;
    float MELONDS_RENDERER;
    float HYBRID_RATIO;
    float HYBRID_FLIPPED;
    float SECONDARY_SCALE;
    float SCREEN_GAP;
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
#pragma parameter MELONDS_LAYOUT "melonDS Layout: 0=Hybrid, 1=Vertical" 0.0 0.0 1.0 1.0
#pragma parameter MELONDS_RENDERER "melonDS Renderer: 0=Software, 1=OpenGL" 0.0 0.0 1.0 1.0
#pragma parameter HYBRID_RATIO   "melonDS Hybrid Ratio: 2:1 / 3:1"     2.0 2.0 3.0 1.0
#pragma parameter HYBRID_FLIPPED "Hybrid Large Screen Side: 0=Left, 1=Right" 0.0 0.0 1.0 1.0
#pragma parameter SECONDARY_SCALE "Vertical Secondary Screen Scale (%)" 100.0 50.0 100.0 5.0
#pragma parameter SCREEN_GAP     "Vertical Screen Gap (core pixels)" 0.0 0.0 126.0 1.0

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

bool select_region(vec2 coord, out LatticeRegion region)
{
    const vec2 logicalSize = vec2(256.0, 192.0);
    float ratio = floor(params.HYBRID_RATIO + 0.5);

    // Test-only stock-equivalence control. The user-facing range is 2:1 / 3:1.
    if (ratio < 1.5) {
        region = LatticeRegion(vec2(0.0), vec2(1.0), logicalSize);
        return contains_coord(coord, region);
    }

    if (params.MELONDS_LAYOUT > 0.5) {
        float renderScale = global.SourceSize.x / logicalSize.x;
        float secondaryScale = clamp(params.SECONDARY_SCALE, 50.0, 100.0) / 100.0;
        vec2 sourceSize = global.SourceSize.xy;
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

        LatticeRegion primary = LatticeRegion(
            vec2(0.0),
            primaryExtentPx / sourceSize,
            logicalSize
        );
        LatticeRegion secondary = LatticeRegion(
            secondaryOriginPx / sourceSize,
            secondaryExtentPx / sourceSize,
            logicalSize
        );

        if (contains_coord(coord, primary)) {
            region = primary;
            return true;
        }
        if (contains_coord(coord, secondary)) {
            region = secondary;
            return true;
        }
        return false;
    }

    float columnWidth = 1.0 / (ratio + 1.0);
    float rowHeight = 1.0 / ratio;
    bool flipped = params.HYBRID_FLIPPED > 0.5;
    float sideX = flipped ? 0.0 : ratio * columnWidth;

    LatticeRegion large = LatticeRegion(
        vec2(flipped ? columnWidth : 0.0, 0.0),
        vec2(ratio * columnWidth, 1.0),
        logicalSize
    );
    LatticeRegion smallTop = LatticeRegion(
        vec2(sideX, 0.0),
        vec2(columnWidth, rowHeight),
        logicalSize
    );
    LatticeRegion smallBottom = LatticeRegion(
        vec2(sideX, (ratio - 1.0) * rowHeight),
        vec2(columnWidth, rowHeight),
        logicalSize
    );

    if (contains_coord(coord, large)) {
        region = large;
        return true;
    }
    if (contains_coord(coord, smallTop)) {
        region = smallTop;
        return true;
    }
    if (contains_coord(coord, smallBottom)) {
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
