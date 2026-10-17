use godot::prelude::*;
use material_colors::color::Rgb;
use material_colors::dynamic_color::DynamicScheme;
use material_colors::hct::Hct;
use material_colors::image::extract_color;
use material_colors::palette::TonalPalette;
use material_colors::scheme::variant::{SchemeMonochrome, SchemeNeutral, SchemeTonalSpot, SchemeVibrant};

const MONOCHROME_BELOW: f64 = 6.0;
const NEUTRAL_BELOW: f64 = 20.0;
const TONAL_SPOT_BELOW: f64 = 70.0;
const MIN_ACCENT_CHROMA_GAP: f64 = 24.0;

fn colorfulness(pixels: &[Rgb]) -> f64 {
    if pixels.is_empty() {
        return 0.0;
    }
    let total = pixels.len() as f64;
    let (mut rg_sum, mut yb_sum, mut rg_squares, mut yb_squares) = (0.0, 0.0, 0.0, 0.0);
    for pixel in pixels {
        let (red, green, blue) = (pixel.red as f64, pixel.green as f64, pixel.blue as f64);
        let rg = (red - green).abs();
        let yb = (0.5 * (red + green) - blue).abs();
        rg_sum += rg;
        yb_sum += yb;
        rg_squares += rg * rg;
        yb_squares += yb * yb;
    }
    let (mean_rg, mean_yb) = (rg_sum / total, yb_sum / total);
    let deviation = ((rg_squares / total - mean_rg * mean_rg).max(0.0) + (yb_squares / total - mean_yb * mean_yb).max(0.0)).sqrt();
    deviation + 0.3 * (mean_rg * mean_rg + mean_yb * mean_yb).sqrt()
}

fn scheme_for(source: Hct, dark: bool, colorfulness: f64) -> DynamicScheme {
    if colorfulness < MONOCHROME_BELOW {
        SchemeMonochrome::new(source, dark, None).scheme
    } else if colorfulness < NEUTRAL_BELOW {
        SchemeNeutral::new(source, dark, None).scheme
    } else if colorfulness < TONAL_SPOT_BELOW {
        SchemeTonalSpot::new(source, dark, None).scheme
    } else {
        SchemeVibrant::new(source, dark, None).scheme
    }
}

fn tone(palette: &TonalPalette, tone: f64) -> Rgb {
    palette.tone(tone.round() as i32)
}

pub fn colors(pixels: &[Rgb], dark: bool) -> Vec<(&'static str, Rgb)> {
    let opaque: Vec<Rgb> = pixels.to_vec();
    let source = Hct::new(extract_color(&opaque));
    let scheme = scheme_for(source, dark, colorfulness(&opaque));
    let (primary, secondary, tertiary) = (&scheme.primary_palette, &scheme.secondary_palette, &scheme.tertiary_palette);
    let (neutral, neutral_variant) = (&scheme.neutral_palette, &scheme.neutral_variant_palette);
    let separation = (1.0 - (primary.chroma() - secondary.chroma()) / MIN_ACCENT_CHROMA_GAP).clamp(0.0, 1.0);
    let lerp = |from: f64, to: f64| from + (to - from) * separation;
    if dark {
        vec![
            ("background", tone(neutral, 6.0)),
            ("background_gradient", tone(neutral, 20.0)),
            ("foreground", tone(neutral_variant, 90.0)),
            ("background_tint", tone(primary, 30.0)),
            ("panel_bg", tone(secondary, 30.0)),
            ("panel_fg", tone(secondary, 90.0)),
            ("panel_gradient", tone(secondary, 40.0)),
            ("accent_bg", tone(primary, lerp(80.0, 90.0))),
            ("accent_fg", tone(primary, 20.0)),
            ("accent_gradient", tone(primary, lerp(70.0, 80.0))),
            ("animbg_color1", tone(primary, 40.0)),
            ("animbg_color2", tone(tertiary, 40.0)),
            ("animbg_color3", tone(secondary, 40.0)),
        ]
    } else {
        vec![
            ("background", tone(neutral, 98.0)),
            ("background_gradient", tone(neutral, 84.0)),
            ("foreground", tone(neutral_variant, 17.0)),
            ("background_tint", tone(primary, 90.0)),
            ("panel_bg", tone(secondary, 40.0)),
            ("panel_fg", tone(secondary, 100.0)),
            ("panel_gradient", tone(secondary, 60.0)),
            ("accent_bg", tone(primary, lerp(40.0, 20.0))),
            ("accent_fg", tone(primary, 100.0)),
            ("accent_gradient", tone(primary, lerp(60.0, 40.0))),
            ("animbg_color1", tone(primary, 70.0)),
            ("animbg_color2", tone(tertiary, 70.0)),
            ("animbg_color3", tone(secondary, 70.0)),
        ]
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct NariPalette;

#[godot_api]
impl NariPalette {
    #[func]
    fn from_pixels(rgba: PackedByteArray, dark: bool) -> VarDictionary {
        let pixels: Vec<Rgb> = rgba
            .as_slice()
            .chunks_exact(4)
            .filter(|pixel| pixel[3] >= 128)
            .map(|pixel| Rgb::new(pixel[0], pixel[1], pixel[2]))
            .collect();
        let mut result = VarDictionary::new();
        if pixels.is_empty() {
            return result;
        }
        for (field, color) in colors(&pixels, dark) {
            result.set(field, Color::from_rgba8(color.red, color.green, color.blue, 255));
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn luminance(color: Rgb) -> f64 {
        0.2126 * color.red as f64 + 0.7152 * color.green as f64 + 0.0722 * color.blue as f64
    }

    #[test]
    fn dark_schemes_flip_background_and_text() {
        let pixels: Vec<Rgb> = (0..64).map(|index| if index % 2 == 0 { Rgb::new(200, 40, 90) } else { Rgb::new(30, 120, 200) }).collect();
        let pick = |list: &[(&str, Rgb)], name: &str| list.iter().find(|(field, _)| *field == name).unwrap().1;
        let light = colors(&pixels, false);
        let dark = colors(&pixels, true);
        assert!(luminance(pick(&light, "background")) > luminance(pick(&light, "foreground")));
        assert!(luminance(pick(&dark, "background")) < luminance(pick(&dark, "foreground")));
        assert!(luminance(pick(&dark, "background")) < 40.0);
    }
}
