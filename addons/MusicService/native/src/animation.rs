use std::path::Path;

use godot::prelude::*;

use crate::motion::{self, Output, Pixels};

pub fn is_animated(bytes: &[u8]) -> bool {
    if motion::is_picture(bytes) {
        return motion::is_picture_animated(bytes);
    }
    bytes.get(4..8) == Some(b"ftyp") || bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3])
}

pub fn poster(path: &Path) -> Option<image::DynamicImage> {
    let frame = motion::first_frame(&path.to_string_lossy(), Output::Rgba).ok()?;
    let Some(Pixels::Rgba(pixels)) = frame.pixels else {
        return None;
    };
    image::RgbaImage::from_raw(frame.width, frame.height, pixels).map(image::DynamicImage::ImageRgba8)
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct NariAnimation;

#[godot_api]
impl NariAnimation {
    #[func]
    fn is_animated(bytes: PackedByteArray) -> bool {
        is_animated(bytes.as_slice())
    }

    #[func]
    fn save_poster(source: GString, target: GString, max_size: i32) -> bool {
        let Some(jpeg) = poster(Path::new(&source.to_string())).and_then(|image| crate::library::covers::scaled_jpeg(image, max_size.max(1) as u32)) else {
            return false;
        };
        crate::library::covers::write_atomically(Path::new(&target.to_string()), &jpeg);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_moving_images_count_as_animated() {
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba8(image::RgbaImage::new(2, 2)).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        assert!(!is_animated(&png));
        assert!(is_animated(b"\x00\x00\x00\x20ftypisom"));
    }
}
