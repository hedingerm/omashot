use crate::{Result, err, n};
use image::{GenericImage, GrayImage, ImageBuffer, Luma, Pixel, Rgba, RgbaImage, imageops};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};

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
fn threads() -> u32 {
    std::thread::available_parallelism().map_or(1, |n| n.get() as u32)
}
// Per-pixel pure fill split into row bands across threads; identical to RgbaImage::from_fn.
fn fill<P: Pixel<Subpixel = u8>>(
    w: u32,
    h: u32,
    f: impl Fn(u32, u32) -> P + Sync,
) -> ImageBuffer<P, Vec<u8>> {
    let mut img = ImageBuffer::new(w, h);
    let rows = h.div_ceil(threads()).max(1) as usize;
    let (f, w, c) = (&f, w as usize, P::CHANNEL_COUNT as usize);
    std::thread::scope(|s| {
        for (i, band) in img.chunks_mut(rows * w * c).enumerate() {
            s.spawn(move || {
                for (j, p) in band.chunks_exact_mut(c).enumerate() {
                    let k = i * rows * w + j;
                    p.copy_from_slice(f((k % w) as u32, (k / w) as u32).channels());
                }
            });
        }
    });
    img
}
// At least the radius of the kernel imageops::blur builds for `sigma`.
pub fn blur_halo(sigma: f32) -> u32 {
    let s = if sigma == 0. { 0.8 } else { sigma };
    ((s - 0.8) / 0.3 + 3.).max(3.) as u32
}
// imageops::blur on tiles with a halo of real pixels: its separable clamp-edge kernel computes
// every output sample with the same arithmetic, so the result is bit-identical, but parallel and
// cache-friendly.
pub fn blur<P: Pixel<Subpixel = u8> + Send + Sync + 'static>(
    img: &ImageBuffer<P, Vec<u8>>,
    sigma: f32,
) -> ImageBuffer<P, Vec<u8>> {
    let (w, h) = img.dimensions();
    let halo = blur_halo(sigma);
    let tile = (halo * 8).max(512);
    if w <= tile && h <= tile {
        return imageops::blur(img, sigma);
    }
    let tiles: Vec<_> = (0..h)
        .step_by(tile as usize)
        .flat_map(|y| (0..w).step_by(tile as usize).map(move |x| (x, y)))
        .collect();
    let next = AtomicUsize::new(0);
    let out = std::sync::Mutex::new(ImageBuffer::new(w, h));
    std::thread::scope(|s| {
        for _ in 0..threads() {
            s.spawn(|| {
                while let Some(&(x, y)) = tiles.get(next.fetch_add(1, Ordering::Relaxed)) {
                    let (l, t) = (x.saturating_sub(halo), y.saturating_sub(halo));
                    let (r, d) = ((x + tile + halo).min(w), (y + tile + halo).min(h));
                    let b = imageops::blur(
                        &imageops::crop_imm(img, l, t, r - l, d - t).to_image(),
                        sigma,
                    );
                    let core =
                        imageops::crop_imm(&b, x - l, y - t, tile.min(w - x), tile.min(h - y));
                    out.lock().unwrap().copy_from(&*core, x, y).unwrap();
                }
            });
        }
    });
    out.into_inner().unwrap()
}
// imageops::overlay (per-pixel Rgba::blend) in parallel row bands.
fn overlay(bottom: &mut RgbaImage, top: &RgbaImage, x: i64, y: i64) {
    let w = bottom.width() as usize;
    let rows = bottom.height().div_ceil(threads()).max(1) as usize;
    std::thread::scope(|s| {
        for (i, band) in bottom.chunks_mut(rows * w * 4).enumerate() {
            s.spawn(move || {
                for (j, p) in band.as_chunks_mut::<4>().0.iter_mut().enumerate() {
                    let k = i * rows * w + j;
                    let (tx, ty) = ((k % w) as i64 - x, (k / w) as i64 - y);
                    if tx >= 0 && ty >= 0 && tx < top.width() as i64 && ty < top.height() as i64 {
                        let mut q = Rgba(*p);
                        q.blend(top.get_pixel(tx as u32, ty as u32));
                        *p = q.0;
                    }
                }
            });
        }
    });
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
    fill(w, h, |x, y| {
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
#[cfg(test)]
pub fn compose(img: &RgbaImage, op: &Value) -> Result<(RgbaImage, Value)> {
    compose_grown(img, op, &|_, _, _, _| [0; 4])
}
/// `grow(tx, ty, w, h)` returns extra (left, top, right, bottom) canvas for overlay annotations, given where the
/// source origin lands on the unextended `w`x`h` canvas.
pub fn compose_grown(
    img: &RgbaImage,
    op: &Value,
    grow: &dyn Fn(i64, i64, u32, u32) -> [u32; 4],
) -> Result<(RgbaImage, Value)> {
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
    let alignment = op["alignment"].as_str().unwrap_or("center");
    let mut x = (w - frame_w) / 2;
    let mut y = (h - frame_h) / 2;
    // v2: an axis without aspect-ratio slack still moves, down to half the padding on the aligned side.
    let edge = |spare: u32| match op["alignment_version"].as_u64() {
        Some(2) => pad.min(spare - pad - pad.div_ceil(2)),
        _ => pad,
    };
    let (mx, my) = (edge(w - frame_w), edge(h - frame_h));
    match alignment {
        "top-left" => {
            x = mx;
            y = my;
        }
        "top" => y = my,
        "top-right" => {
            x = w - frame_w - mx;
            y = my;
        }
        "left" => x = mx,
        "center" => {}
        "right" => x = w - frame_w - mx,
        "bottom-left" => {
            x = mx;
            y = h - frame_h - my;
        }
        "bottom" => y = h - frame_h - my,
        "bottom-right" => {
            x = w - frame_w - mx;
            y = h - frame_h - my;
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
    let [gl, gt, gr, gb] = grow(
        (x + inset) as i64 - balanced.0 as i64,
        (y + inset) as i64 - balanced.1 as i64,
        w,
        h,
    );
    let (x, y, w, h) = (x + gl, y + gt, w + gl + gr, h + gt + gb);
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
                fill(w, h, |_, y| {
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
        bg = self::blur(&bg, blur);
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
        // Only the alpha of the black shadow varies, and it is zero beyond the mask plus the blur
        // radius: blur that alpha region alone; the composite is identical to a full-canvas blur.
        let strength = n(op, "shadow_strength", 0.35).clamp(0., 1.);
        let sigma = n(op, "shadow_blur", 18.).clamp(0., 100.) as f32;
        let sx = x as i64 + n(op, "shadow_offset_x", 0.).clamp(-100., 100.) as i64;
        let sy = y as i64 + offset;
        let halo = blur_halo(sigma) as i64;
        let (x0, y0) = (
            (sx - halo).clamp(0, w as i64),
            (sy - halo).clamp(0, h as i64),
        );
        let x1 = (sx + frame_w as i64 + halo).clamp(0, w as i64);
        let y1 = (sy + frame_h as i64 + halo).clamp(0, h as i64);
        if x1 > x0 && y1 > y0 {
            let alpha: GrayImage = fill((x1 - x0) as u32, (y1 - y0) as u32, |px, py| {
                let (mx, my) = (px as i64 + x0 - sx, py as i64 + y0 - sy);
                let mut p = Rgba([0, 0, 0, 0]);
                if (0..frame_w as i64).contains(&mx) && (0..frame_h as i64).contains(&my) {
                    let a = frame.get_pixel(mx as u32, my as u32)[3];
                    p.blend(&Rgba([0, 0, 0, (a as f64 * strength) as u8]));
                }
                Luma([p[3]])
            });
            let alpha = self::blur(&alpha, sigma);
            let shadow = fill(alpha.width(), alpha.height(), |px, py| {
                Rgba([0, 0, 0, alpha.get_pixel(px, py)[0]])
            });
            overlay(&mut bg, &shadow, x0, y0);
        }
    }
    overlay(&mut bg, &frame, x as i64, y as i64);
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
    fn tiled_blur_matches_imageops_blur() {
        let img = RgbaImage::from_fn(1100, 600, |x, y| {
            Rgba([
                (x * 7 % 256) as u8,
                (y * 3 % 256) as u8,
                ((x ^ y) % 256) as u8,
                (x % 200) as u8,
            ])
        });
        for sigma in [0., 5.5, 18.] {
            assert_eq!(
                blur(&img, sigma),
                imageops::blur(&img, sigma),
                "sigma {sigma}"
            );
        }
        let gray = GrayImage::from_fn(1100, 530, |x, y| Luma([((x * y) % 251) as u8]));
        assert_eq!(blur(&gray, 3.), imageops::blur(&gray, 3.));
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
        let auto = |alignment: &str, version: u64| {
            let op = json!({"padding":11,"alignment":alignment,"alignment_version":version,"shadow":false});
            let (bg, rect) = compose(&source, &op).unwrap();
            (
                bg.dimensions(),
                rect["x"].as_u64().unwrap(),
                rect["y"].as_u64().unwrap(),
            )
        };
        assert_eq!(auto("top-left", 1), ((62, 52), 11, 11));
        assert_eq!(auto("top-left", 2), ((62, 52), 5, 5));
        assert_eq!(auto("bottom-right", 2), ((62, 52), 17, 17));
        assert_eq!(auto("center", 2), ((62, 52), 11, 11));
        let (_, wide) = compose(
            &source,
            &json!({"padding":10,"aspect_ratio":1,"alignment":"top-left","alignment_version":2,"shadow":false}),
        )
        .unwrap();
        assert_eq!(
            (wide["x"].as_u64(), wide["y"].as_u64()),
            (Some(5), Some(10))
        );
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
