use crate::{Result, err, n};
use image::{Rgba, RgbaImage, imageops};
use serde_json::{Value, json};

pub const PRESETS: [&str; 20] = [
    "#6366f1", "#ec4899", "#06b6d4", "#f97316", "#22c55e", "#8b5cf6", "#ef4444", "#0ea5e9",
    "#eab308", "#14b8a6", "#a855f7", "#f43f5e", "#3b82f6", "#84cc16", "#d946ef", "#64748b",
    "#fb923c", "#2dd4bf", "#818cf8", "#f472b6",
];
pub const NAMES: [&str; 20] = [
    "Berry glow",
    "Evening silk",
    "Deep lagoon",
    "Sea glass",
    "Apricot bloom",
    "Prism",
    "Porcelain rose",
    "Cloud peach",
    "Azure aurora",
    "Midnight mist",
    "Dune horizon",
    "Dusk",
    "Violet tides",
    "Ember",
    "Electric ink",
    "Iris",
    "Solar flare",
    "Coastal gold",
    "Chromatic haze",
    "Candy sky",
];
// Original procedural artwork. Positions and colors are our own, not extracted vendor assets.
const PALETTES: [[u32; 5]; 20] = [
    [0x2c174a, 0xff5b8a, 0x673bb2, 0x242d85, 0xf3a8d5],
    [0x122b92, 0x687ce5, 0xc48ce4, 0xe4a2d8, 0x343c9e],
    [0x031643, 0x063a81, 0x008fc2, 0x19adb0, 0x020f28],
    [0x0b617a, 0x6ed9c8, 0xd0ebc7, 0x28b5c2, 0x176f86],
    [0xf64e8c, 0xffa269, 0xf8cb79, 0xf77072, 0xee496e],
    [0x4542c1, 0xbc72e5, 0xf4dca0, 0x00b6d1, 0x7122af],
    [0xc5d0d9, 0xf4c4d8, 0xe8edf2, 0xd5dedf, 0xf2edec],
    [0xb2c7d5, 0xe3d8cf, 0xf6b79c, 0xc0dcda, 0xe2dce5],
    [0x2795ec, 0xb3edfa, 0x7063ef, 0x26cbe1, 0x4a3bd5],
    [0x07042a, 0x30236e, 0x776ee8, 0x99a3ed, 0x09082c],
    [0x034f77, 0x006ba4, 0xadc7d9, 0xf2bf7a, 0x295a7b],
    [0x3f86be, 0x8bbde4, 0xd4b7d9, 0xf5aeba, 0x668cc5],
    [0xa482db, 0xc6b4ee, 0x4eaed5, 0xe5c3d7, 0x6641a7],
    [0x231731, 0x8e274a, 0xf14d5b, 0x6b2942, 0x231a31],
    [0x030a30, 0x004f91, 0x00b2cd, 0x823bb3, 0xee2759],
    [0x7d8af6, 0xccabff, 0xfe91c3, 0xae65ee, 0xd4cafb],
    [0xe8323f, 0xff773c, 0xffdc6d, 0xfaecbf, 0xc7296d],
    [0x007bad, 0x139fc9, 0xebb35a, 0xf8d57b, 0x5752bd],
    [0x273049, 0xd9ccce, 0xf76f5f, 0x3c2655, 0x121d31],
    [0xff5fbb, 0xf25a84, 0xffb876, 0x6d8de4, 0xa98cec],
];
fn rgb(c: u32) -> [f64; 3] {
    [
        ((c >> 16) & 255) as f64,
        ((c >> 8) & 255) as f64,
        (c & 255) as f64,
    ]
}
pub fn gradient(preset: usize, w: u32, h: u32) -> RgbaImage {
    let index = preset % 20;
    let palette = PALETTES[index];
    let points = [
        (0.03, 0.05),
        (0.87, 0.02),
        (0.55, 0.55),
        (0.98, 0.97),
        (0.02, 0.95),
    ];
    RgbaImage::from_fn(w, h, |x, y| {
        let mut u = x as f64 / (w - 1).max(1) as f64;
        let mut v = y as f64 / (h - 1).max(1) as f64;
        if index == 12 || index == 5 || index == 18 {
            u += 0.13 * (v * 7. + index as f64).sin();
            v += 0.09 * (u * 8.).cos();
        }
        let mut out = [0.; 3];
        let mut total = 0.;
        for (i, (px, py)) in points.iter().enumerate() {
            let distance = (u - px).powi(2) + (v - py).powi(2);
            let weight = (-distance * (if index == 6 || index == 7 { 2.8 } else { 4.2 })).exp();
            let color = rgb(palette[i]);
            for k in 0..3 {
                out[k] += color[k] * weight;
            }
            total += weight;
        }
        Rgba([
            (out[0] / total).round() as u8,
            (out[1] / total).round() as u8,
            (out[2] / total).round() as u8,
            255,
        ])
    })
}
pub fn thumbnails(dir: &std::path::Path) -> Result<Value> {
    let dir = dir.join("backgrounds-v2");
    std::fs::create_dir_all(&dir)?;
    let mut values = Vec::new();
    for (index, name) in NAMES.iter().enumerate() {
        let path = dir.join(format!("mesh-{:02}.png", index + 1));
        if !path.exists() {
            gradient(index, 96, 96).save(&path)?;
        }
        values.push(json!({"index":index,"name":name,"path":path,"width":96,"height":96}));
    }
    Ok(json!(values))
}
// Balance only demonstrably uniform empty borders. Content is never stretched.
fn balance_bounds(img: &RgbaImage) -> (u32, u32, u32, u32) {
    let (w, h) = img.dimensions();
    if w < 8 || h < 8 {
        return (0, 0, w, h);
    }
    let corners = [
        img.get_pixel(0, 0),
        img.get_pixel(w - 1, 0),
        img.get_pixel(0, h - 1),
        img.get_pixel(w - 1, h - 1),
    ];
    let color = corners[0];
    if corners
        .iter()
        .any(|p| (0..4).any(|k| p[k].abs_diff(color[k]) > 12))
    {
        return (0, 0, w, h);
    }
    let mut bounds = (w, h, 0, 0);
    let mut found = false;
    for (x, y, p) in img.enumerate_pixels() {
        if (0..4).any(|k| p[k].abs_diff(color[k]) > 22) {
            bounds.0 = bounds.0.min(x);
            bounds.1 = bounds.1.min(y);
            bounds.2 = bounds.2.max(x);
            bounds.3 = bounds.3.max(y);
            found = true;
        }
    }
    if !found {
        return (0, 0, w, h);
    }
    let left = bounds.0;
    let right = w - 1 - bounds.2;
    let top = bounds.1;
    let bottom = h - 1 - bounds.3;
    let horizontal = left.min(right);
    let vertical = top.min(bottom);
    // Tiny imbalances are anti-aliasing/noise, not whitespace to trim.
    let crop_x = if left.abs_diff(right) > 8 {
        left - horizontal
    } else {
        0
    };
    let crop_r = if left.abs_diff(right) > 8 {
        right - horizontal
    } else {
        0
    };
    let crop_y = if top.abs_diff(bottom) > 8 {
        top - vertical
    } else {
        0
    };
    let crop_b = if top.abs_diff(bottom) > 8 {
        bottom - vertical
    } else {
        0
    };
    (crop_x, crop_y, w - crop_x - crop_r, h - crop_y - crop_b)
}
pub fn parse_color(s: &str) -> Result<Rgba<u8>> {
    if !s.starts_with('#')
        || ![4, 7, 9].contains(&s.len())
        || !s[1..].chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err(err("Background color must be hexadecimal"));
    }
    let s = if s.len() == 4 {
        s[1..].chars().flat_map(|c| [c, c]).collect::<String>()
    } else {
        s[1..].to_string()
    };
    let mut out = [0, 0, 0, 255];
    for (i, byte) in out.iter_mut().enumerate().take(s.len() / 2) {
        *byte = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)?;
    }
    Ok(Rgba(out))
}
fn rounded(img: &mut RgbaImage, radius: f64) {
    let r = radius
        .max(0.)
        .min(img.width().min(img.height()) as f64 / 2.);
    if r == 0. {
        return;
    }
    let (w, h) = (img.width() as f64, img.height() as f64);
    for (x, y, p) in img.enumerate_pixels_mut() {
        let (px, py) = (x as f64 + 0.5, y as f64 + 0.5);
        let cx = px.clamp(r, w - r);
        let cy = py.clamp(r, h - r);
        let coverage = (r - ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() + 0.5).clamp(0., 1.);
        p[3] = (p[3] as f64 * coverage) as u8;
    }
}
fn cover(img: &RgbaImage, w: u32, h: u32) -> RgbaImage {
    let scale = (w as f64 / img.width() as f64).max(h as f64 / img.height() as f64);
    let nw = (img.width() as f64 * scale).ceil() as u32;
    let nh = (img.height() as f64 * scale).ceil() as u32;
    let resized = imageops::resize(img, nw, nh, imageops::FilterType::Lanczos3);
    imageops::crop_imm(&resized, (nw - w) / 2, (nh - h) / 2, w, h).to_image()
}
pub fn compose(img: &RgbaImage, op: &Value) -> Result<(RgbaImage, Value)> {
    let pad = n(op, "padding", 64.).clamp(0., 2000.) as u32;
    let inset = n(op, "inset", 0.).clamp(0., 200.) as u32;
    let balanced = if op["gradient_version"].as_u64() == Some(2)
        && op["auto_balance"].as_bool().unwrap_or(true)
    {
        balance_bounds(img)
    } else {
        (0, 0, img.width(), img.height())
    };
    let balanced_image =
        imageops::crop_imm(img, balanced.0, balanced.1, balanced.2, balanced.3).to_image();
    let img = &balanced_image;
    let (iw, ih) = img.dimensions();
    let frame_w = iw + inset * 2;
    let frame_h = ih + inset * 2;
    let (mut w, mut h) = (frame_w + pad * 2, frame_h + pad * 2);
    let aspect = n(op, "aspect_ratio", 0.).clamp(0., 10.);
    if aspect > 0.1 {
        if w as f64 / h as f64 > aspect {
            h = (w as f64 / aspect).ceil() as u32;
        } else {
            w = (h as f64 * aspect).ceil() as u32;
        }
    }
    if w as u64 * h as u64 > 100_000_000 || w > 30000 || h > 30000 {
        return Err(err("Background canvas too large"));
    }
    let mode = op["mode"].as_str().unwrap_or("gradient");
    let mut bg = match mode {
        "gradient" => {
            let p = n(op, "preset", 0.) as usize % PRESETS.len();
            if op["gradient_version"].as_u64() == Some(2) {
                gradient(p, w, h)
            } else {
                let a = parse_color(PRESETS[p])?;
                let b = parse_color("#111827")?;
                RgbaImage::from_fn(w, h, |_, y| {
                    let t = y as f64 / (h - 1).max(1) as f64;
                    Rgba(std::array::from_fn(|i| {
                        (a[i] as f64 * (1. - t) + b[i] as f64 * t) as u8
                    }))
                })
            }
        }
        "solid" => RgbaImage::from_pixel(
            w,
            h,
            parse_color(op["background_color"].as_str().unwrap_or("#6366f1"))?,
        ),
        "wallpaper" => {
            let path = op["image_path"]
                .as_str()
                .ok_or_else(|| err("Wallpaper background requires image_path"))?;
            let image = image::open(crate::checked(path)?)?.to_rgba8();
            cover(&image, w, h)
        }
        "blurred" => {
            if let Some(path) = op["image_path"].as_str().filter(|s| !s.is_empty()) {
                cover(&image::open(crate::checked(path)?)?.to_rgba8(), w, h)
            } else {
                cover(img, w, h)
            }
        }
        _ => return Err(err("Unknown background mode")),
    };
    let blur = n(op, "blur", if mode == "blurred" { 24. } else { 0. }).clamp(0., 100.) as f32;
    if blur > 0. {
        bg = imageops::blur(&bg, blur);
    }
    let alignment = op["alignment"].as_str().unwrap_or("center");
    let mut x = (w - frame_w) / 2;
    let mut y = (h - frame_h) / 2;
    match alignment {
        "top-left" => {
            x = pad;
            y = pad;
        }
        "top" => y = pad,
        "top-right" => {
            x = w - frame_w - pad;
            y = pad;
        }
        "left" => x = pad,
        "center" => {}
        "right" => x = w - frame_w - pad,
        "bottom-left" => {
            x = pad;
            y = h - frame_h - pad;
        }
        "bottom" => y = h - frame_h - pad,
        "bottom-right" => {
            x = w - frame_w - pad;
            y = h - frame_h - pad;
        }
        _ => return Err(err("Invalid background alignment")),
    }
    let offset = n(op, "shadow_offset", 8.).clamp(-100., 100.) as i64;
    if op["auto_balance"].as_bool().unwrap_or(true)
        && alignment == "center"
        && h > frame_h + pad * 2
    {
        y = (y as i64 - offset / 2).clamp(pad as i64, (h - frame_h - pad) as i64) as u32;
    }
    let radius = n(op, "radius", 0.).clamp(0., 300.);
    let mut frame = RgbaImage::from_pixel(
        frame_w,
        frame_h,
        parse_color(op["inset_color"].as_str().unwrap_or("#ffffff"))?,
    );
    let mut screenshot = img.clone();
    rounded(&mut screenshot, radius);
    if inset == 0 {
        frame = screenshot;
    } else {
        rounded(&mut frame, radius + inset as f64);
        imageops::overlay(&mut frame, &screenshot, inset as i64, inset as i64);
    }
    if op["shadow"].as_bool().unwrap_or(true) {
        let strength = n(op, "shadow_strength", 0.35).clamp(0., 1.);
        let mut shadow = RgbaImage::new(w, h);
        let mut mask = frame.clone();
        for p in mask.pixels_mut() {
            *p = Rgba([0, 0, 0, (p[3] as f64 * strength) as u8]);
        }
        imageops::overlay(
            &mut shadow,
            &mask,
            x as i64 + n(op, "shadow_offset_x", 0.).clamp(-100., 100.) as i64,
            y as i64 + offset,
        );
        let shadow = imageops::blur(&shadow, n(op, "shadow_blur", 18.).clamp(0., 100.) as f32);
        imageops::overlay(&mut bg, &shadow, 0, 0);
    }
    imageops::overlay(&mut bg, &frame, x as i64, y as i64);
    let mut rect = json!({"x":x+inset,"y":y+inset,"w":iw,"h":ih});
    // Always expose the source domain for v2; the editor uses it for object handles and new strokes.
    if op["gradient_version"].as_u64() == Some(2) {
        rect["sourceX"] = json!(balanced.0);
        rect["sourceY"] = json!(balanced.1);
        rect["sourceW"] = json!(iw);
        rect["sourceH"] = json!(ih);
    }
    Ok((bg, rect))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mesh_is_spatial_and_balances_asymmetric_whitespace() {
        let image = gradient(8, 96, 96);
        assert_ne!(image.get_pixel(0, 48), image.get_pixel(95, 48));
        assert_ne!(image.get_pixel(48, 0), image.get_pixel(48, 95));
        let mut source = RgbaImage::from_pixel(100, 100, Rgba([255, 255, 255, 255]));
        for y in 10..40 {
            for x in 10..90 {
                source.put_pixel(x, y, Rgba([20, 20, 20, 255]));
            }
        }
        let (balanced, rect) = compose(
            &source,
            &json!({"gradient_version":2,"padding":10,"shadow":false,"auto_balance":true}),
        )
        .unwrap();
        assert_eq!(balanced.dimensions(), (120, 70));
        assert_eq!(rect["sourceH"], 50);
        let (unchanged, _) = compose(
            &source,
            &json!({"gradient_version":2,"padding":10,"shadow":false,"auto_balance":false}),
        )
        .unwrap();
        assert_eq!(unchanged.dimensions(), (120, 120));
        for alignment in ["top-left", "top-right", "bottom-left", "bottom-right"] {
            assert!(
                compose(
                    &source,
                    &json!({"alignment":alignment,"aspect_ratio":2,"shadow":false})
                )
                .is_ok()
            );
        }
    }
    #[test]
    fn twenty_gradients_have_distinct_real_pixels() {
        let source = RgbaImage::from_pixel(40, 30, Rgba([250, 0, 0, 255]));
        let mut starts = std::collections::HashSet::new();
        for preset in 0..20 {
            let (bg, rect) = compose(
                &source,
                &json!({"preset":preset,"padding":10,"shadow":false}),
            )
            .unwrap();
            assert_eq!(bg.dimensions(), (60, 50));
            assert_eq!(rect, json!({"x":10,"y":10,"w":40,"h":30}));
            starts.insert(bg.get_pixel(0, 0).0);
            assert_eq!(bg.get_pixel(25, 25).0, [250, 0, 0, 255]);
        }
        assert_eq!(starts.len(), 20);
    }
    #[test]
    fn solid_radius_inset_and_alignment() {
        let source = RgbaImage::from_pixel(40, 30, Rgba([250, 0, 0, 255]));
        let(bg,rect)=compose(&source,&json!({"mode":"solid","background_color":"#123456","padding":10,"inset":2,"radius":10,"shadow":false})).unwrap();
        assert_eq!(bg.dimensions(), (64, 54));
        assert_eq!(rect, json!({"x":12,"y":12,"w":40,"h":30}));
        assert_eq!(bg.get_pixel(0, 0).0, [18, 52, 86, 255]);
        assert_ne!(bg.get_pixel(12, 12).0, [250, 0, 0, 255]);
        assert_eq!(bg.get_pixel(32, 27).0, [250, 0, 0, 255]);
        let (_, top) = compose(
            &source,
            &json!({"padding":10,"aspect_ratio":1,"alignment":"top","shadow":false}),
        )
        .unwrap();
        let (_, bottom) = compose(
            &source,
            &json!({"padding":10,"aspect_ratio":1,"alignment":"bottom","shadow":false}),
        )
        .unwrap();
        assert!(top["y"].as_u64() < bottom["y"].as_u64());
    }
    #[test]
    fn wallpaper_blur_and_shadow_are_real_pixels() {
        let source = RgbaImage::from_pixel(40, 30, Rgba([250, 0, 0, 255]));
        let path =
            std::env::temp_dir().join(format!("omashot-wallpaper-{}.png", std::process::id()));
        let wallpaper = RgbaImage::from_fn(60, 50, |x, y| {
            if (x + y) % 2 == 0 {
                Rgba([0, 0, 0, 255])
            } else {
                Rgba([255, 255, 255, 255])
            }
        });
        wallpaper.save(&path).unwrap();
        let (sharp, _) = compose(
            &source,
            &json!({"mode":"wallpaper","image_path":path,"padding":10,"shadow":false}),
        )
        .unwrap();
        let (blurred, _) = compose(
            &source,
            &json!({"mode":"wallpaper","image_path":path,"padding":10,"shadow":false,"blur":5}),
        )
        .unwrap();
        assert_ne!(sharp.get_pixel(0, 0), blurred.get_pixel(0, 0));
        let (no_shadow, _) = compose(
            &source,
            &json!({"mode":"solid","background_color":"#ffffff","padding":20,"shadow":false}),
        )
        .unwrap();
        let(shadow,_)=compose(&source,&json!({"mode":"solid","background_color":"#ffffff","padding":20,"shadow":true,"shadow_strength":0.8,"shadow_blur":4,"shadow_offset":8})).unwrap();
        assert!(shadow.get_pixel(40, 55)[0] < no_shadow.get_pixel(40, 55)[0]);
        std::fs::remove_file(path).unwrap();
    }
}
