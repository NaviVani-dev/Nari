#ifndef AYN_THOR_RENDERER_H
#define AYN_THOR_RENDERER_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

#ifdef __ANDROID__
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/native_window.h>
#endif

namespace godot {

class AynThorRenderer : public Node {
    GDCLASS(AynThorRenderer, Node)

private:
#ifdef __ANDROID__
    EGLDisplay egl_display = EGL_NO_DISPLAY;
    EGLContext egl_context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    ANativeWindow* window = nullptr;

    GLuint program = 0;
    GLuint vertex_array = 0;
    GLuint sampler = 0;
    GLint rotation_location = -1;
#endif

    bool initialized = false;
    void* last_window = nullptr;

    int target_fps = 0;
    uint64_t last_frame_time_usec = 0;
    int rotation_degrees = 180;

    void _init_gl();
    void _cleanup_gl();
    bool _create_program();

protected:
    static void _bind_methods();

public:
    AynThorRenderer();
    ~AynThorRenderer();

    bool is_window_available();
    void fill_color(float r, float g, float b);
    void draw_viewport_texture(RID texture_rid);
    Vector2i get_second_screen_size();

    void set_target_fps(int p_fps);
    int get_target_fps() const;

    void set_rotation_degrees(int p_degrees);
    int get_rotation_degrees() const;
};

}

#endif
