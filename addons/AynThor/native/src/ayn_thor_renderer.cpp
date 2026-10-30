#include "ayn_thor_renderer.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/time.hpp>
#include <mutex>

#ifdef __ANDROID__
#include <android/native_window.h>
extern ANativeWindow* g_second_window;
extern std::mutex g_window_mutex;
#else
extern void* g_second_window;
extern std::mutex g_window_mutex;
#endif

namespace godot {

#ifdef __ANDROID__
static const char* VERTEX_SHADER = R"(#version 300 es
uniform int rotation;
out vec2 uv;
void main() {
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    vec2 screen = vec2(corner.x, 1.0 - corner.y);
    if (rotation == 1) {
        uv = vec2(screen.y, 1.0 - screen.x);
    } else if (rotation == 2) {
        uv = 1.0 - screen;
    } else if (rotation == 3) {
        uv = vec2(1.0 - screen.y, screen.x);
    } else {
        uv = screen;
    }
}
)";

static const char* FRAGMENT_SHADER = R"(#version 300 es
precision mediump float;
uniform sampler2D source;
in vec2 uv;
out vec4 color;
void main() {
    color = vec4(texture(source, uv).rgb, 1.0);
}
)";

static const GLenum SAVED_CAPABILITIES[] = {GL_BLEND, GL_CULL_FACE, GL_DEPTH_TEST, GL_SCISSOR_TEST, GL_STENCIL_TEST, GL_RASTERIZER_DISCARD};
static const int SAVED_CAPABILITY_COUNT = sizeof(SAVED_CAPABILITIES) / sizeof(SAVED_CAPABILITIES[0]);

struct GLState {
    EGLSurface draw_surface;
    EGLSurface read_surface;
    GLint program;
    GLint vertex_array;
    GLint active_texture;
    GLint texture;
    GLint sampler;
    GLint draw_framebuffer;
    GLint read_framebuffer;
    GLint viewport[4];
    GLboolean color_mask[4];
    GLboolean capabilities[SAVED_CAPABILITY_COUNT];

    void save() {
        draw_surface = eglGetCurrentSurface(EGL_DRAW);
        read_surface = eglGetCurrentSurface(EGL_READ);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertex_array);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active_texture);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_framebuffer);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
        glGetIntegerv(GL_VIEWPORT, viewport);
        glGetBooleanv(GL_COLOR_WRITEMASK, color_mask);
        for (int i = 0; i < SAVED_CAPABILITY_COUNT; i++) {
            capabilities[i] = glIsEnabled(SAVED_CAPABILITIES[i]);
        }
    }

    void restore() {
        for (int i = 0; i < SAVED_CAPABILITY_COUNT; i++) {
            if (capabilities[i]) {
                glEnable(SAVED_CAPABILITIES[i]);
            } else {
                glDisable(SAVED_CAPABILITIES[i]);
            }
        }
        glColorMask(color_mask[0], color_mask[1], color_mask[2], color_mask[3]);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_framebuffer);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, read_framebuffer);
        glBindSampler(0, sampler);
        glBindTexture(GL_TEXTURE_2D, texture);
        glActiveTexture(active_texture);
        glBindVertexArray(vertex_array);
        glUseProgram(program);
    }
};

static GLuint compile_shader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[512] = {};
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        UtilityFunctions::printerr("AynThorPlugin: shader compilation failed: ", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}
#endif

void AynThorRenderer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("is_window_available"), &AynThorRenderer::is_window_available);
    ClassDB::bind_method(D_METHOD("draw_viewport_texture", "texture_rid"), &AynThorRenderer::draw_viewport_texture);
    ClassDB::bind_method(D_METHOD("fill_color", "r", "g", "b"), &AynThorRenderer::fill_color);
    ClassDB::bind_method(D_METHOD("get_second_screen_size"), &AynThorRenderer::get_second_screen_size);

    ClassDB::bind_method(D_METHOD("set_target_fps", "fps"), &AynThorRenderer::set_target_fps);
    ClassDB::bind_method(D_METHOD("get_target_fps"), &AynThorRenderer::get_target_fps);

    ClassDB::bind_method(D_METHOD("set_rotation_degrees", "degrees"), &AynThorRenderer::set_rotation_degrees);
    ClassDB::bind_method(D_METHOD("get_rotation_degrees"), &AynThorRenderer::get_rotation_degrees);

    ADD_PROPERTY(PropertyInfo(Variant::INT, "target_fps"), "set_target_fps", "get_target_fps");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "rotation_degrees"), "set_rotation_degrees", "get_rotation_degrees");
}

AynThorRenderer::AynThorRenderer() {}

AynThorRenderer::~AynThorRenderer() {
    _cleanup_gl();
}

void AynThorRenderer::set_target_fps(int p_fps) { target_fps = p_fps; }
int AynThorRenderer::get_target_fps() const { return target_fps; }

void AynThorRenderer::set_rotation_degrees(int p_degrees) { rotation_degrees = p_degrees; }
int AynThorRenderer::get_rotation_degrees() const { return rotation_degrees; }

bool AynThorRenderer::is_window_available() {
    std::lock_guard<std::mutex> lock(g_window_mutex);
    return g_second_window != nullptr;
}

Vector2i AynThorRenderer::get_second_screen_size() {
    std::lock_guard<std::mutex> lock(g_window_mutex);
#ifdef __ANDROID__
    if (g_second_window) {
        return Vector2i(ANativeWindow_getWidth(g_second_window), ANativeWindow_getHeight(g_second_window));
    }
#endif
    return Vector2i(0, 0);
}

bool AynThorRenderer::_create_program() {
#ifdef __ANDROID__
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, VERTEX_SHADER);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, FRAGMENT_SHADER);
    if (!vertex || !fragment) {
        glDeleteShader(vertex);
        glDeleteShader(fragment);
        return false;
    }

    program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);

    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[512] = {};
        glGetProgramInfoLog(program, sizeof(log), nullptr, log);
        UtilityFunctions::printerr("AynThorPlugin: shader link failed: ", log);
        glDeleteProgram(program);
        program = 0;
        return false;
    }

    rotation_location = glGetUniformLocation(program, "rotation");
    GLint previous_program = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &previous_program);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "source"), 0);
    glUseProgram(previous_program);

    glGenVertexArrays(1, &vertex_array);
    glGenSamplers(1, &sampler);
    glSamplerParameteri(sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glSamplerParameteri(sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glSamplerParameteri(sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glSamplerParameteri(sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return true;
#else
    return false;
#endif
}

void AynThorRenderer::_init_gl() {
#ifdef __ANDROID__
    if (initialized) return;

    egl_display = eglGetCurrentDisplay();
    egl_context = eglGetCurrentContext();
    if (egl_display == EGL_NO_DISPLAY || egl_context == EGL_NO_CONTEXT) {
        UtilityFunctions::printerr("AynThorPlugin: no current EGL context. The plugin requires the GL Compatibility renderer.");
        return;
    }

    g_window_mutex.lock();
    if (!g_second_window) {
        g_window_mutex.unlock();
        return;
    }
    window = g_second_window;
    ANativeWindow_acquire(window);
    last_window = window;
    g_window_mutex.unlock();

    EGLint config_id = 0;
    eglQueryContext(egl_display, egl_context, EGL_CONFIG_ID, &config_id);
    const EGLint config_attributes[] = {EGL_CONFIG_ID, config_id, EGL_NONE};
    EGLConfig config = nullptr;
    EGLint config_count = 0;
    if (!eglChooseConfig(egl_display, config_attributes, &config, 1, &config_count) || config_count == 0) {
        UtilityFunctions::printerr("AynThorPlugin: could not find the EGL config of Godot's context.");
        _cleanup_gl();
        return;
    }

    EGLint format = 0;
    if (eglGetConfigAttrib(egl_display, config, EGL_NATIVE_VISUAL_ID, &format) && format) {
        ANativeWindow_setBuffersGeometry(window, 0, 0, format);
    }

    surface = eglCreateWindowSurface(egl_display, config, window, nullptr);
    if (surface == EGL_NO_SURFACE) {
        UtilityFunctions::printerr("AynThorPlugin: eglCreateWindowSurface failed: ", (int64_t)eglGetError());
        _cleanup_gl();
        return;
    }

    if (!_create_program()) {
        _cleanup_gl();
        return;
    }

    EGLSurface draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface read_surface = eglGetCurrentSurface(EGL_READ);
    if (eglMakeCurrent(egl_display, surface, surface, egl_context)) {
        eglSwapInterval(egl_display, 0);
        eglMakeCurrent(egl_display, draw_surface, read_surface, egl_context);
    }

    initialized = true;
#endif
}

void AynThorRenderer::draw_viewport_texture(RID texture_rid) {
#ifdef __ANDROID__
    if (target_fps > 0) {
        uint64_t current_time = Time::get_singleton()->get_ticks_usec();
        if ((current_time - last_frame_time_usec) < (1000000 / target_fps)) {
            return;
        }
        last_frame_time_usec = current_time;
    }

    g_window_mutex.lock();
    void* current_window = g_second_window;
    g_window_mutex.unlock();

    if (!current_window) {
        if (initialized) _cleanup_gl();
        return;
    }

    if (initialized && (current_window != last_window || eglGetCurrentContext() != egl_context)) {
        _cleanup_gl();
    }

    if (!initialized) {
        _init_gl();
        if (!initialized) return;
    }

    GLuint source_texture = (GLuint)RenderingServer::get_singleton()->texture_get_native_handle(texture_rid);
    if (!source_texture) return;

    GLState state;
    state.save();

    if (!eglMakeCurrent(egl_display, surface, surface, egl_context)) {
        state.restore();
        _cleanup_gl();
        return;
    }

    EGLint width = 0;
    EGLint height = 0;
    eglQuerySurface(egl_display, surface, EGL_WIDTH, &width);
    eglQuerySurface(egl_display, surface, EGL_HEIGHT, &height);

    for (int i = 0; i < SAVED_CAPABILITY_COUNT; i++) {
        glDisable(SAVED_CAPABILITIES[i]);
    }
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, width, height);
    glUseProgram(program);
    glUniform1i(rotation_location, (((180 - rotation_degrees) / 90) % 4 + 4) % 4);
    glBindVertexArray(vertex_array);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, source_texture);
    glBindSampler(0, sampler);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    bool lost = !eglSwapBuffers(egl_display, surface);

    eglMakeCurrent(egl_display, state.draw_surface, state.read_surface, egl_context);
    state.restore();

    if (lost) {
        _cleanup_gl();
    }
#endif
}

void AynThorRenderer::_cleanup_gl() {
#ifdef __ANDROID__
    if (egl_context != EGL_NO_CONTEXT && eglGetCurrentContext() == egl_context) {
        if (program) glDeleteProgram(program);
        if (vertex_array) glDeleteVertexArrays(1, &vertex_array);
        if (sampler) glDeleteSamplers(1, &sampler);
    }
    program = 0;
    vertex_array = 0;
    sampler = 0;
    rotation_location = -1;
    if (surface != EGL_NO_SURFACE) {
        eglDestroySurface(egl_display, surface);
        surface = EGL_NO_SURFACE;
    }
    if (window) {
        ANativeWindow_release(window);
        window = nullptr;
    }
    egl_display = EGL_NO_DISPLAY;
    egl_context = EGL_NO_CONTEXT;
    last_window = nullptr;
#endif
    initialized = false;
}

void AynThorRenderer::fill_color(float r, float g, float b) {}

}
