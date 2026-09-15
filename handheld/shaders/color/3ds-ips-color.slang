#version 450

/*
 * Representative face-on Nintendo New 3DS XL IPS color response, sRGB output.
 * One measured New 3DS XL top IPS panel is used for both physical screens;
 * this is not an average of New 3DS XL or 3DS-family panels.
 *
 * Data: pica200, 2024-12-21, Calibrite Display Plus HL / HCFR,
 * warmed display, no ambient lighting, white set to approximately 80 cd/m2.
 * Measurement report and Brankale's derived gamma/primary data:
 * https://github.com/Brankale/Handheld-Color-Space-Project/tree/ae3e37036965b11028e2bfc96450adf2aca34d29/handhelds/Nintendo%20New%203DS%20XL/%5B2024-12-21%5D%5BTop%20IPS%5D%5Bpica200%5D
 *
 * Matrix = XYZ-to-linear-sRGB * measured RGB-to-XYZ, without chromatic
 * adaptation. Constants are rounded computational results, not claims of
 * measurement precision. Retain the panel's cool white; normalize its largest
 * white RGB component to 1. Absolute brightness and black leakage are omitted.
 * Colors outside sRGB are clipped. No viewing-angle simulation.
 * Shader implementation: public domain.
 */

layout(std140, set = 0, binding = 0) uniform UBO { mat4 MVP; } global;

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

// Effective channel gamma at 10% signal steps, including the source's
// endpoint exponents. Black and white themselves map exactly to 0 and 1.
const vec3 IPS_GAMMA[11] = vec3[](
    vec3(2.170, 2.020, 1.850),
    vec3(2.104, 1.970, 1.775),
    vec3(2.151, 1.958, 1.661),
    vec3(2.125, 1.873, 1.525),
    vec3(2.213, 1.914, 1.502),
    vec3(2.319, 1.951, 1.482),
    vec3(2.475, 2.005, 1.458),
    vec3(2.597, 2.016, 1.316),
    vec3(2.761, 2.099, 1.298),
    vec3(3.221, 2.332, 1.320),
    vec3(4.076, 3.032, 1.887)
);

// GLSL constructor columns are the output contributions of R, G and B.
const mat3 IPS_TO_SRGB = mat3(
    0.85367, 0.05184, 0.00579,
    0.06825, 0.90258, -0.04214,
    -0.06199, 0.07879, 1.11983
);
// 1 / max(IPS_TO_SRGB * vec3(1)), derived from unrounded coefficients.
const float WHITE_NORMALIZATION = 0.92295;

vec3 ips_linear(vec3 code)
{
    vec3 position = clamp(code, 0.0, 1.0) * 10.0;
    ivec3 lo = ivec3(floor(position));
    ivec3 hi = min(lo + ivec3(1), ivec3(10));
    vec3 exponent = mix(vec3(IPS_GAMMA[lo.r].r, IPS_GAMMA[lo.g].g, IPS_GAMMA[lo.b].b),
                        vec3(IPS_GAMMA[hi.r].r, IPS_GAMMA[hi.g].g, IPS_GAMMA[hi.b].b),
                        fract(position));
    return pow(clamp(code, 0.0, 1.0), exponent);
}

vec3 encode_srgb(vec3 linear)
{
    linear = clamp(linear, 0.0, 1.0);
    return mix(1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
               12.92 * linear, lessThanEqual(linear, vec3(0.0031308)));
}

void main()
{
    vec4 color = texture(Source, vTexCoord);
    FragColor = vec4(encode_srgb(WHITE_NORMALIZATION * IPS_TO_SRGB * ips_linear(color.rgb)),
                     color.a);
}
