#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

#include <algorithm>
#include <cmath>
#include <string>

#include "beauty-shader.h"

namespace {
const char *kVertex = R"GLSL(#version 150
out vec2 uv;
void main()
{
    vec2 p = gl_VertexID == 0 ? vec2(-1.0, -1.0) :
             gl_VertexID == 1 ? vec2(3.0, -1.0) : vec2(-1.0, 3.0);
    uv = p * 0.5 + 0.5;
    gl_Position = vec4(p, 0.0, 1.0);
}
)GLSL";

const char *kFragment = R"GLSL(#version 150
uniform sampler2D inputImage;
uniform vec2 imageSize;
uniform vec4 faceBox;        // center x/y, half width/height
uniform vec4 eyes;           // left x/y, right x/y
uniform vec4 lips;           // center x/y, half width/height
uniform vec4 amountA;        // smooth, whiten, sharpen, slim
uniform vec4 amountB;        // enlarge, basic lipstick, basic blush, warm filter
uniform bool faceValid;
uniform bool eyesValid;
uniform bool lipsValid;
in vec2 uv;
out vec4 fragmentColor;

float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
vec3 straightColor(vec4 c) { return c.a > 0.0001 ? c.rgb / c.a : vec3(0.0); }
vec4 readImage(vec2 p) { return texture(inputImage, clamp(p, vec2(0.0), vec2(1.0))); }
float ellipse(vec2 p, vec2 center, vec2 radius)
{
    return length((p - center) / max(radius, vec2(0.0001)));
}
float softEllipse(vec2 p, vec2 center, vec2 radius)
{
    return 1.0 - smoothstep(0.55, 1.0, ellipse(p, center, radius));
}
float skinProbability(vec3 c)
{
    float cb = 0.5 + dot(c, vec3(-0.168736, -0.331264, 0.5));
    float cr = 0.5 + dot(c, vec3(0.5, -0.418688, -0.081312));
    return smoothstep(0.31, 0.36, cb) * (1.0 - smoothstep(0.51, 0.57, cb)) *
           smoothstep(0.51, 0.56, cr) * (1.0 - smoothstep(0.72, 0.80, cr));
}
vec2 enlargedEye(vec2 p, vec2 center)
{
    vec2 radius = faceBox.zw * vec2(0.29, 0.20);
    float r = ellipse(p, center, radius);
    float falloff = 1.0 - smoothstep(0.0, 1.0, r);
    return center + (p - center) * (1.0 - amountB.x * 0.32 * falloff);
}
vec2 beautyCoordinates(vec2 p)
{
    if (!faceValid)
        return p;
    float boundary = 1.0 - smoothstep(0.98, 1.28, ellipse(p, faceBox.xy, faceBox.zw));
    vec2 cheekRadius = faceBox.zw * vec2(0.55, 0.65);
    vec2 left = faceBox.xy + faceBox.zw * vec2(-0.64, -0.05);
    vec2 right = faceBox.xy + faceBox.zw * vec2(0.64, -0.05);
    vec2 ql = (p - left) / cheekRadius;
    vec2 qr = (p - right) / cheekRadius;
    float wl = exp(-2.0 * dot(ql, ql));
    float wr = exp(-2.0 * dot(qr, qr));
    // Inverse mapping samples outward to bring the two cheek contours inward.
    p.x += (wr - wl) * amountA.w * faceBox.z * 0.12 * boundary;
    if (eyesValid && amountB.x > 0.0001) {
        p = enlargedEye(p, eyes.xy);
        p = enlargedEye(p, eyes.zw);
    }
    return p;
}
vec3 bilateral(vec2 p, vec3 center)
{
    float radius = clamp(min(imageSize.x, imageSize.y) * 0.0035, 1.0, 4.8);
    vec2 stepUV = vec2(radius) / imageSize;
    vec3 sum = center * 1.4;
    float weightSum = 1.4;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            if (x == 0 && y == 0)
                continue;
            vec3 sampleColor = straightColor(readImage(p + vec2(float(x), float(y)) * stepUV));
            vec3 delta = sampleColor - center;
            float spatial = exp(-0.65 * float(x * x + y * y));
            float range = exp(-38.0 * dot(delta, delta) -
                              8.0 * abs(luminance(sampleColor) - luminance(center)));
            float weight = spatial * range;
            sum += sampleColor * weight;
            weightSum += weight;
        }
    }
    return sum / weightSum;
}
void main()
{
    vec2 sampleUV = beautyCoordinates(uv);
    vec4 source = readImage(sampleUV);
    bool localActive = faceValid &&
        (dot(amountA, vec4(1.0)) + amountB.x + amountB.y + amountB.z > 0.0001);
    if (!localActive && amountB.w < 0.0001) {
        fragmentColor = source;
        return;
    }
    vec3 original = straightColor(source);
    vec3 color = original;
    if (faceValid) {
        float faceMask = 1.0 - smoothstep(0.78, 1.05, ellipse(uv, faceBox.xy, faceBox.zw));
        float skinMask = skinProbability(original) * faceMask;
        float detailProtection = 1.0;
        if (eyesValid) {
            vec2 eyeMaskRadius = faceBox.zw * vec2(0.34, 0.18);
            detailProtection *= 1.0 - 0.95 * max(softEllipse(uv, eyes.xy, eyeMaskRadius),
                                                softEllipse(uv, eyes.zw, eyeMaskRadius));
        }
        if (lipsValid)
            detailProtection *= 1.0 - 0.95 * softEllipse(uv, lips.xy, lips.zw * vec2(1.35, 2.0));
        if (faceMask > 0.001 && (amountA.x > 0.0001 || amountA.z > 0.0001)) {
            vec3 blurred = bilateral(sampleUV, original);
            color = mix(color, blurred, amountA.x * 0.68 * skinMask * detailProtection);
            color += (original - blurred) * amountA.z * 0.38 * faceMask;
        }
        vec3 whitened = color + (vec3(1.0) - color) * vec3(0.12, 0.115, 0.10);
        color = mix(color, whitened, amountA.y * skinMask);

        if (lipsValid && amountB.y > 0.0001) {
            float lipMask = 1.0 - smoothstep(0.64, 1.04, ellipse(uv, lips.xy, lips.zw));
            // Reduce the tint on neutral teeth and on the dark mouth opening.
            float lipColor = smoothstep(0.015, 0.08, original.r - original.g);
            lipColor *= smoothstep(0.06, 0.20, luminance(original));
            float light = luminance(color);
            vec3 tint = vec3(0.78, 0.18, 0.29) * (0.65 + 0.45 * light);
            color = mix(color, tint, amountB.y * 0.50 * lipMask * lipColor * faceMask);
        }
        if (amountB.z > 0.0001) {
            float cheekY = faceBox.y;
            if (eyesValid && lipsValid)
                cheekY = mix(lips.y, 0.5 * (eyes.y + eyes.w), 0.60);
            vec2 radius = faceBox.zw * vec2(0.38, 0.22);
            vec2 leftCheek = vec2(faceBox.x - faceBox.z * 0.55, cheekY);
            vec2 rightCheek = vec2(faceBox.x + faceBox.z * 0.55, cheekY);
            float cheekMask = max(softEllipse(uv, leftCheek, radius),
                                  softEllipse(uv, rightCheek, radius));
            vec3 tint = vec3(1.0, 0.40, 0.48);
            color = mix(color, tint, amountB.z * 0.16 * cheekMask * skinMask);
        }
    }
    if (amountB.w > 0.0001) {
        vec3 warm = color * vec3(1.045, 1.012, 0.965);
        warm = (warm - vec3(0.5)) * 1.015 + vec3(0.5);
        warm = mix(vec3(luminance(warm)), warm, 0.98);
        color = mix(color, warm, amountB.w);
    }
    fragmentColor = vec4(clamp(color, 0.0, 1.0) * source.a, source.a);
}
)GLSL";

struct Shader {
    GLuint program = 0;
    GLuint vao = 0;
    GLuint fbo = 0;
    GLint image = -1, size = -1, box = -1, eyes = -1, lips = -1;
    GLint amountA = -1, amountB = -1, faceValid = -1, eyesValid = -1, lipsValid = -1;
    std::string status = "基础美颜着色器尚未初始化";
};

void enabled(GLenum capability, GLboolean value)
{
    if (value)
        glEnable(capability);
    else
        glDisable(capability);
}

struct GLState {
    GLint program, vao, drawFbo, readFbo, viewport[4], activeTexture, texture0;
    GLboolean blend, depth, stencil, cull, scissor, dither, srgb, color[4];
    GLState()
    {
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFbo);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFbo);
        glGetIntegerv(GL_VIEWPORT, viewport);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture0);
        glGetBooleanv(GL_COLOR_WRITEMASK, color);
        blend = glIsEnabled(GL_BLEND);
        depth = glIsEnabled(GL_DEPTH_TEST);
        stencil = glIsEnabled(GL_STENCIL_TEST);
        cull = glIsEnabled(GL_CULL_FACE);
        scissor = glIsEnabled(GL_SCISSOR_TEST);
        dither = glIsEnabled(GL_DITHER);
        srgb = glIsEnabled(GL_FRAMEBUFFER_SRGB);
    }
    ~GLState()
    {
        glUseProgram(GLuint(program));
        glBindVertexArray(GLuint(vao));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(drawFbo));
        glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(readFbo));
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        glBindTexture(GL_TEXTURE_2D, GLuint(texture0));
        glActiveTexture(GLenum(activeTexture));
        glColorMask(color[0], color[1], color[2], color[3]);
        enabled(GL_BLEND, blend);
        enabled(GL_DEPTH_TEST, depth);
        enabled(GL_STENCIL_TEST, stencil);
        enabled(GL_CULL_FACE, cull);
        enabled(GL_SCISSOR_TEST, scissor);
        enabled(GL_DITHER, dither);
        enabled(GL_FRAMEBUFFER_SRGB, srgb);
    }
};

struct TextureSampling {
    GLint minification, magnification, wrapS, wrapT;
    TextureSampling()
    {
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minification);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &magnification);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, &wrapS);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, &wrapT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    ~TextureSampling()
    {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minification);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magnification);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT);
    }
};

GLuint compile(GLenum type, const char *source, std::string &error)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint success = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success) {
        char log[4096] = {};
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        error = log;
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

float amount(NSDictionary *settings, NSString *key)
{
    id value = settings[key];
    if (![value respondsToSelector:@selector(doubleValue)])
        return 0.0f;
    double parsed = [value doubleValue];
    return std::isfinite(parsed) ? float(std::clamp(parsed, 0.0, 1.0)) : 0.0f;
}

bool point(float x, float y)
{
    return std::isfinite(x) && std::isfinite(y) && x >= 0.0f && x <= 1.0f && y >= 0.0f && y <= 1.0f;
}

bool faceUsable(const LBFaceGeometry *face)
{
    return face && face->valid && point(face->center_x, face->center_y) &&
           std::isfinite(face->half_width) && std::isfinite(face->half_height) &&
           face->half_width > 0.005f && face->half_height > 0.005f &&
           face->half_width <= 1.0f && face->half_height <= 1.0f;
}
} // namespace

void *lb_beauty_shader_create(void)
{
    auto *shader = new Shader;
    if (!CGLGetCurrentContext()) {
        shader->status = "基础美颜未就绪：没有当前 OpenGL 上下文";
        return shader;
    }
    std::string error;
    GLuint vertex = compile(GL_VERTEX_SHADER, kVertex, error);
    GLuint fragment = vertex ? compile(GL_FRAGMENT_SHADER, kFragment, error) : 0;
    if (!vertex || !fragment) {
        if (vertex)
            glDeleteShader(vertex);
        shader->status = "基础美颜 GLSL 编译失败：" + error;
        return shader;
    }
    shader->program = glCreateProgram();
    glAttachShader(shader->program, vertex);
    glAttachShader(shader->program, fragment);
    glBindFragDataLocation(shader->program, 0, "fragmentColor");
    glLinkProgram(shader->program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(shader->program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[4096] = {};
        glGetProgramInfoLog(shader->program, sizeof(log), nullptr, log);
        shader->status = std::string("基础美颜 GLSL 链接失败：") + log;
        glDeleteProgram(shader->program);
        shader->program = 0;
        return shader;
    }
    glGenVertexArrays(1, &shader->vao);
    glGenFramebuffers(1, &shader->fbo);
#define LB_UNIFORM(member, name) shader->member = glGetUniformLocation(shader->program, name)
    LB_UNIFORM(image, "inputImage");
    LB_UNIFORM(size, "imageSize");
    LB_UNIFORM(box, "faceBox");
    LB_UNIFORM(eyes, "eyes");
    LB_UNIFORM(lips, "lips");
    LB_UNIFORM(amountA, "amountA");
    LB_UNIFORM(amountB, "amountB");
    LB_UNIFORM(faceValid, "faceValid");
    LB_UNIFORM(eyesValid, "eyesValid");
    LB_UNIFORM(lipsValid, "lipsValid");
#undef LB_UNIFORM
    shader->status = "基础美颜着色器已编译；等待真实人脸几何";
    return shader;
}

bool lb_beauty_shader_render(void *context, uint32_t source, uint32_t target,
                            int width, int height, double timestamp,
                            const char *settingsJSON,
                            const LBFaceGeometry *face)
{
    (void)timestamp;
    auto *shader = static_cast<Shader *>(context);
    if (!shader || !shader->program || !shader->vao || !shader->fbo ||
        !CGLGetCurrentContext() || !source || !target || source == target ||
        width <= 0 || height <= 0)
        return false;
    @autoreleasepool {
        NSData *json = settingsJSON ? [[NSString stringWithUTF8String:settingsJSON] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        id parsed = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nullptr] : nil;
        if (json && ![parsed isKindOfClass:[NSDictionary class]]) {
            shader->status = "基础美颜未就绪：参数 JSON 不是对象";
            return false;
        }
        NSDictionary *settings = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
        bool on = !settings[@"enabled"] || [settings[@"enabled"] boolValue];
        float a[4] = {amount(settings, @"smooth"), amount(settings, @"whiten"),
                      amount(settings, @"sharpen"), amount(settings, @"face_slim")};
        float b[4] = {amount(settings, @"eye_enlarge"), amount(settings, @"lipstick"),
                      amount(settings, @"blush"), amount(settings, @"filter_intensity")};
        if (!on)
            std::fill(a, a + 4, 0.0f), std::fill(b, b + 4, 0.0f);
        const bool hasFace = faceUsable(face);
        LBFaceGeometry geometry = hasFace ? *face : LBFaceGeometry{};
        const float eyeSeparation = std::hypot(geometry.left_eye_x - geometry.right_eye_x,
                                              geometry.left_eye_y - geometry.right_eye_y);
        const bool hasEyes = hasFace && point(geometry.left_eye_x, geometry.left_eye_y) &&
            point(geometry.right_eye_x, geometry.right_eye_y) &&
            eyeSeparation > geometry.half_width * 0.15f && eyeSeparation < geometry.half_width * 2.0f;
        const bool hasLips = hasFace && point(geometry.lip_x, geometry.lip_y) &&
            std::isfinite(geometry.lip_half_width) && std::isfinite(geometry.lip_half_height) &&
            geometry.lip_half_width > 0.001f && geometry.lip_half_height > 0.0005f &&
            geometry.lip_half_width < geometry.half_width && geometry.lip_half_height < geometry.half_height;

        GLState state;
        glBindTexture(GL_TEXTURE_2D, GLuint(source));
        TextureSampling sampling;
        glBindFramebuffer(GL_FRAMEBUFFER, shader->fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, GLuint(target), 0);
        glDrawBuffer(GL_COLOR_ATTACHMENT0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            shader->status = "基础美颜未就绪：输出纹理帧缓冲不完整";
            return false;
        }
        glViewport(0, 0, width, height);
        glDisable(GL_BLEND);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_STENCIL_TEST);
        glDisable(GL_CULL_FACE);
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_DITHER);
        glDisable(GL_FRAMEBUFFER_SRGB);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glUseProgram(shader->program);
        glBindVertexArray(shader->vao);
        glUniform1i(shader->image, 0);
        glUniform2f(shader->size, float(width), float(height));
        glUniform4f(shader->box, geometry.center_x, geometry.center_y, geometry.half_width, geometry.half_height);
        glUniform4f(shader->eyes, geometry.left_eye_x, geometry.left_eye_y, geometry.right_eye_x, geometry.right_eye_y);
        glUniform4f(shader->lips, geometry.lip_x, geometry.lip_y, geometry.lip_half_width, geometry.lip_half_height);
        glUniform4fv(shader->amountA, 1, a);
        glUniform4fv(shader->amountB, 1, b);
        glUniform1i(shader->faceValid, hasFace ? 1 : 0);
        glUniform1i(shader->eyesValid, hasEyes ? 1 : 0);
        glUniform1i(shader->lipsValid, hasLips ? 1 : 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        GLenum error = glGetError();
        if (error != GL_NO_ERROR) {
            shader->status = "基础美颜 OpenGL 绘制失败，错误码 " + std::to_string(error);
            return false;
        }
        shader->status = hasFace ? "READY: 基础美颜已就绪" :
                                  "READY: 未检测到人脸，局部美颜暂停；仅暖色滤镜可用";
        return true;
    }
}

const char *lb_beauty_shader_status(void *context)
{
    return context ? static_cast<Shader *>(context)->status.c_str() : "基础美颜着色器尚未创建";
}

void lb_beauty_shader_destroy(void *context)
{
    auto *shader = static_cast<Shader *>(context);
    if (!shader)
        return;
    if (CGLGetCurrentContext()) {
        if (shader->program)
            glDeleteProgram(shader->program);
        if (shader->vao)
            glDeleteVertexArrays(1, &shader->vao);
        if (shader->fbo)
            glDeleteFramebuffers(1, &shader->fbo);
    }
    delete shader;
}
