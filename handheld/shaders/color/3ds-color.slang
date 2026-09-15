#version 450

/*
 * Representative face-on Nintendo 3DS TN color response, sRGB output.
 * One measured original-3DS top panel is used for both physical screens;
 * this is not an average of all 3DS-family panels.
 *
 * Data: pica200, 2024-12-21, Calibrite Display Plus HL / HCFR,
 * warmed display, no ambient lighting, white set to approximately 80 cd/m2.
 * Measurement report and Brankale's derived gamma/primary data:
 * https://github.com/Brankale/Handheld-Color-Space-Project/tree/ae3e37036965b11028e2bfc96450adf2aca34d29/handhelds/Nintendo%203DS/%5B2024-12-21%5D%5BTop%5D%5Bpica200%5D
 *
 * Matrix = XYZ-to-linear-sRGB * measured RGB-to-XYZ, without chromatic
 * adaptation. Constants are rounded computational results, not claims of
 * measurement precision. Retain the panel's cool white; normalize its largest
 * white RGB component to 1. Absolute brightness and black leakage are omitted.
 * Colors outside sRGB are clipped. No viewing-angle or IPS simulation.
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

// Effective channel gamma at 10% signal steps. Endpoint exponents repeat
// the adjacent sample; black and white themselves map exactly to 0 and 1.
const vec3 TN_GAMMA[11] = vec3[](
    vec3(1.748, 1.651, 1.520),
    vec3(1.748, 1.651, 1.520),
    vec3(1.762, 1.653, 1.424),
    vec3(1.775, 1.657, 1.329),
    vec3(1.826, 1.674, 1.242),
    vec3(1.817, 1.673, 1.109),
    vec3(1.843, 1.666, 0.957),
    vec3(1.881, 1.667, 0.768),
    vec3(1.905, 1.653, 0.499),
    vec3(1.999, 1.662, 0.108),
    vec3(1.999, 1.662, 0.108)
);

// GLSL constructor columns are the output contributions of R, G and B.
const mat3 TN_TO_SRGB = mat3(
     0.93425, 0.05773,  0.02480,
     0.07187, 0.85978, -0.03933,
    -0.04793, 0.03861,  1.57233
);
// 1 / max(TN_TO_SRGB * vec3(1)), derived from unrounded coefficients.
const float WHITE_NORMALIZATION = 0.64193;

vec3 tn_linear(vec3 code)
{
    vec3 position = clamp(code, 0.0, 1.0) * 10.0;
    ivec3 lo = ivec3(floor(position));
    ivec3 hi = min(lo + ivec3(1), ivec3(10));
    vec3 exponent = mix(vec3(TN_GAMMA[lo.r].r, TN_GAMMA[lo.g].g, TN_GAMMA[lo.b].b),
                        vec3(TN_GAMMA[hi.r].r, TN_GAMMA[hi.g].g, TN_GAMMA[hi.b].b),
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
    FragColor = vec4(encode_srgb(WHITE_NORMALIZATION * TN_TO_SRGB * tn_linear(color.rgb)),
                     color.a);
}
