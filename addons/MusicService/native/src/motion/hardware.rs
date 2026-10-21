use ffmpeg::codec::{threading, Context};
use ffmpeg::format::Pixel;
use ffmpeg::util::frame::video::Video;
use ffmpeg::{decoder, Stream};
use ffmpeg_next as ffmpeg;

const MAX_THREADS: usize = 8;

pub struct Opened {
    pub decoder: decoder::Video,
    pub name: String,
    pub hardware: bool,
    pub device: bool,
}

fn text(error: ffmpeg::Error) -> String {
    error.to_string()
}

pub fn open(stream: &Stream, hardware: bool) -> Result<Opened, String> {
    if hardware {
        if let Some(opened) = accelerated(stream) {
            return Ok(opened);
        }
    }
    let mut context = Context::from_parameters(stream.parameters()).map_err(text)?;
    let threads = std::thread::available_parallelism().map_or(2, |count| count.get().min(MAX_THREADS));
    context.set_threading(threading::Config { kind: threading::Type::Frame, count: threads, ..Default::default() });
    let mut decoder = context.decoder();
    decoder.set_packet_time_base(stream.time_base());
    let decoder = decoder.video().map_err(text)?;
    Ok(Opened { name: name_of(&decoder), decoder, hardware: false, device: false })
}

pub fn name_of(decoder: &decoder::Video) -> String {
    decoder.codec().map_or_else(|| "unknown".into(), |codec| codec.name().to_string())
}

pub fn is_hardware_frame(format: Pixel) -> bool {
    matches!(format, Pixel::D3D11 | Pixel::D3D11VA_VLD | Pixel::DXVA2_VLD | Pixel::VIDEOTOOLBOX)
}

pub fn transfer(source: &Video, target: &mut Video) -> Result<(), String> {
    unsafe {
        ffmpeg::ffi::av_frame_unref(target.as_mut_ptr());
        let result = ffmpeg::ffi::av_hwframe_transfer_data(target.as_mut_ptr(), source.as_ptr(), 0);
        if result < 0 {
            return Err(text(ffmpeg::Error::from(result)));
        }
        ffmpeg::ffi::av_frame_copy_props(target.as_mut_ptr(), source.as_ptr());
    }
    Ok(())
}

#[cfg(target_os = "android")]
fn accelerated(stream: &Stream) -> Option<Opened> {
    use std::sync::Once;

    extern "C" {
        fn av_jni_set_java_vm(vm: *mut std::ffi::c_void, log: *mut std::ffi::c_void) -> std::ffi::c_int;
    }

    static JNI: Once = Once::new();
    let vm = crate::android::java_vm()?;
    JNI.call_once(|| unsafe {
        av_jni_set_java_vm(vm, std::ptr::null_mut());
    });
    let name = format!("{}_mediacodec", stream.parameters().id().name());
    let codec = decoder::find_by_name(&name)?;
    let mut decoder = Context::from_parameters(stream.parameters()).ok()?.decoder();
    decoder.set_packet_time_base(stream.time_base());
    let decoder = decoder.open_as(codec).ok()?.video().ok()?;
    Some(Opened { decoder, name, hardware: true, device: false })
}

#[cfg(any(windows, target_os = "macos"))]
fn accelerated(stream: &Stream) -> Option<Opened> {
    use ffmpeg::ffi::{av_hwdevice_ctx_create, AVBufferRef, AVCodecContext, AVHWDeviceType, AVPixelFormat};

    #[cfg(windows)]
    const DEVICE: (AVHWDeviceType, AVPixelFormat, &str) = (AVHWDeviceType::AV_HWDEVICE_TYPE_D3D11VA, AVPixelFormat::AV_PIX_FMT_D3D11, "d3d11va");
    #[cfg(target_os = "macos")]
    const DEVICE: (AVHWDeviceType, AVPixelFormat, &str) =
        (AVHWDeviceType::AV_HWDEVICE_TYPE_VIDEOTOOLBOX, AVPixelFormat::AV_PIX_FMT_VIDEOTOOLBOX, "videotoolbox");

    unsafe extern "C" fn pick(_context: *mut AVCodecContext, formats: *const AVPixelFormat) -> AVPixelFormat {
        let mut cursor = formats;
        while *cursor != AVPixelFormat::AV_PIX_FMT_NONE {
            if *cursor == DEVICE.1 {
                return DEVICE.1;
            }
            cursor = cursor.add(1);
        }
        *formats
    }

    let mut context = Context::from_parameters(stream.parameters()).ok()?;
    unsafe {
        let mut device: *mut AVBufferRef = std::ptr::null_mut();
        if av_hwdevice_ctx_create(&mut device, DEVICE.0, std::ptr::null(), std::ptr::null_mut(), 0) < 0 {
            return None;
        }
        let raw = context.as_mut_ptr();
        (*raw).hw_device_ctx = device;
        (*raw).get_format = Some(pick);
    }
    let id = stream.parameters().id();
    let codec = if id == ffmpeg::codec::Id::AV1 { decoder::find_by_name("av1") } else { decoder::find(id) }?;
    let mut decoder = context.decoder();
    decoder.set_packet_time_base(stream.time_base());
    let decoder = decoder.open_as(codec).ok()?.video().ok()?;
    let name = format!("{} ({})", name_of(&decoder), DEVICE.2);
    Some(Opened { decoder, name, hardware: true, device: true })
}

#[cfg(not(any(target_os = "android", windows, target_os = "macos")))]
fn accelerated(_stream: &Stream) -> Option<Opened> {
    None
}
