mod background;
mod snapshot;
mod storage;
use image::{DynamicImage, ImageFormat, RgbaImage};
use serde_json::{Value, json};
use std::{
    env, fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn err(s: &str) -> Box<dyn std::error::Error> {
    s.to_owned().into()
}
fn run(program: &str, args: &[String]) -> Result<String> {
    let out = Command::new(program).args(args).output()?;
    if !out.status.success() {
        return Err(err(&format!(
            "{program}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8(out.stdout)?.trim().to_string())
}
fn run_input(program: &str, args: &[String], input: &[u8]) -> Result<String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(input)?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(err(&format!(
            "{program}: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}
fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| s.to_string()).collect()
}
fn data() -> PathBuf {
    env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".local/share")
        })
        .join("omashot")
}
fn config_path() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".config"))
        .join("omashot/config.json")
}
fn default_config() -> Value {
    json!({"delay":0,"cursor":false,"format":"png","ocr_language":"eng","retention_days":30,"hide_desktop_icons":false,"desktop_hide_argv":[],"desktop_restore_argv":[],"show_overlay":true,"copy_after_capture":false,"save_after_capture":false,"annotate_after_capture":false,"pin_after_capture":false,"export_directory":"","overlay_size":240,"overlay_screen":"active","dismiss_after_drop":true,"window_transparent":false,"freeze_capture":true,"show_crosshair":true,"show_magnifier":true})
}
fn config() -> Value {
    let mut c = fs::read(config_path())
        .ok()
        .and_then(|v| serde_json::from_slice::<Value>(&v).ok())
        .unwrap_or_else(default_config);
    if let Some(o) = c.as_object_mut() {
        o.remove("upload_url");
        o.remove("upload_token");
    }
    c
}
// Provider hooks are explicit argv arrays. The backend never guesses an icon process
// or terminates desktop applications. Omarchy's default desktop has no icons.
fn desktop_hook(c: &Value, key: &str) -> Result<Vec<String>> {
    let values = c[key]
        .as_array()
        .ok_or_else(|| err(&format!("{key} must be an argv array")))?;
    if values.is_empty() || values.len() > 100 {
        return Err(err(&format!("{key} requires 1..100 argv entries")));
    }
    let mut argv = Vec::new();
    for value in values {
        let s = value
            .as_str()
            .ok_or_else(|| err("Hook argv entries must be strings"))?;
        if s.contains('\0') {
            return Err(err("Hook argv may not contain NUL"));
        }
        argv.push(s.to_string());
    }
    if argv[0].is_empty() {
        return Err(err("Hook executable may not be empty"));
    }
    Ok(argv)
}
fn validate_config(c: &Value) -> Result<()> {
    if !c.is_object() {
        return Err(err("Config must be object"));
    }
    for key in ["cursor", "hide_desktop_icons"] {
        if !c[key].is_null() && !c[key].is_boolean() {
            return Err(err(&format!("{key} must be boolean")));
        }
    }
    if !c["delay"].is_null()
        && !c["delay"]
            .as_f64()
            .is_some_and(|n| (0.0..=3600.).contains(&n))
    {
        return Err(err("delay must be 0..3600 seconds"));
    }
    if !c["retention_days"].is_null() && !c["retention_days"].as_u64().is_some_and(|n| n <= 3650) {
        return Err(err(
            "retention_days must be an integer 0..3650 (0 keeps forever)",
        ));
    }
    if c["hide_desktop_icons"].as_bool().unwrap_or(false) {
        desktop_hook(c, "desktop_hide_argv")?;
        desktop_hook(c, "desktop_restore_argv")?;
    }
    Ok(())
}
fn with_desktop_hidden<T>(c: &Value, action: impl FnOnce() -> Result<T>) -> Result<T> {
    validate_config(c)?;
    if !c["hide_desktop_icons"].as_bool().unwrap_or(false) {
        return action();
    }
    let hide = desktop_hook(c, "desktop_hide_argv")?;
    let restore = desktop_hook(c, "desktop_restore_argv")?;
    // Even a failed hide command may have changed desktop state, so restore
    // after every attempted hide, including selector cancellation/capture errors.
    let result = run(&hide[0], &hide[1..]).and_then(|_| action());
    let restored = run(&restore[0], &restore[1..]);
    match (result, restored) {
        (Ok(v), Ok(_)) => Ok(v),
        (Err(e), Ok(_)) => Err(e),
        (Ok(_), Err(e)) => Err(err(&format!("Desktop restore failed: {e}"))),
        (Err(e), Err(r)) => Err(err(&format!("{e}; desktop restore also failed: {r}"))),
    }
}
fn original_path(p: &Path) -> PathBuf {
    p.with_file_name(format!(
        ".{}.source.png",
        p.file_name().unwrap_or_default().to_string_lossy()
    ))
}
fn unique(prefix: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let mut last = LAST.load(Ordering::Relaxed);
    let id = loop {
        let next = now.max(last.saturating_add(1));
        match LAST.compare_exchange_weak(last, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => break next,
            Err(actual) => last = actual,
        }
    };
    data().join(format!("{prefix}-{id}-{}.png", std::process::id()))
}
fn meta(path: &Path) -> Result<Value> {
    let (w, h) = image::image_dimensions(path)?;
    Ok(json!({"path":path.to_string_lossy(),"width":w,"height":h}))
}
fn checked(path: &str) -> Result<PathBuf> {
    let p = fs::canonicalize(path)?;
    if !p.is_file() {
        return Err(err("Expected image file"));
    }
    image::image_dimensions(&p)?;
    Ok(p)
}
fn copy_text(text: &[u8], mime: &str) -> Result<()> {
    let mut c = Command::new("wl-copy")
        .args(["--type", mime])
        .stdin(Stdio::piped())
        .spawn()?;
    c.stdin.take().unwrap().write_all(text)?;
    if !c.wait()?.success() {
        return Err(err("Clipboard failed"));
    }
    Ok(())
}
fn geometry(mode: &str) -> Result<Option<String>> {
    match mode {
        "fullscreen" => Ok(None),
        "region" => {
            let g = run("slurp", &[])?;
            fs::write(data().join(".last-selection"), &g)?;
            Ok(Some(g))
        }
        "repeat" => Ok(Some(fs::read_to_string(data().join(".last-selection"))?)),
        "window" => {
            let clients: Value =
                serde_json::from_str(&run("hyprctl", &strings(&["-j", "clients"]))?)?;
            let clients = clients
                .as_array()
                .ok_or_else(|| err("Invalid Hyprland client list"))?;
            let mut rectangles = String::new();
            for client in clients {
                if client["hidden"].as_bool().unwrap_or(false)
                    || !client["mapped"].as_bool().unwrap_or(true)
                    || !client["visible"].as_bool().unwrap_or(true)
                {
                    continue;
                }
                let at = client["at"].as_array();
                let size = client["size"].as_array();
                if let (Some(at), Some(size)) = (at, size)
                    && at.len() == 2
                    && size.len() == 2
                {
                    let x = at[0].as_i64().unwrap_or(0);
                    let y = at[1].as_i64().unwrap_or(0);
                    let w = size[0].as_i64().unwrap_or(0);
                    let h = size[1].as_i64().unwrap_or(0);
                    if w > 0 && h > 0 {
                        rectangles.push_str(&format!("{x},{y} {w}x{h}\n"));
                    }
                }
            }
            if rectangles.is_empty() {
                return Err(err("No visible windows to capture"));
            }
            Ok(Some(run_input(
                "slurp",
                &strings(&["-r"]),
                rectangles.as_bytes(),
            )?))
        }
        "active" => {
            let v: Value =
                serde_json::from_str(&run("hyprctl", &strings(&["-j", "activewindow"]))?)?;
            let a = v["at"].as_array().ok_or_else(|| err("No active window"))?;
            if a.len() != 2 {
                return Err(err("Invalid active window coordinates"));
            }
            let s = v["size"]
                .as_array()
                .ok_or_else(|| err("No active window"))?;
            if s.len() != 2 || s.iter().any(|v| v.as_i64().unwrap_or(0) <= 0) {
                return Err(err("Invalid active window size"));
            }
            Ok(Some(format!("{},{} {}x{}", a[0], a[1], s[0], s[1])))
        }
        _ => Err(err(
            "Capture mode must be region, repeat, window, active, fullscreen",
        )),
    }
}
fn capture_to(path: &Path, geo: Option<String>, cursor: bool) -> Result<()> {
    // Level 1 keeps identical pixels at a fraction of grim's default level-6 encoding time.
    let mut args = vec!["-l".into(), "1".into()];
    if cursor {
        args.push("-c".into());
    }
    if let Some(g) = geo {
        if g.trim().is_empty() {
            return Err(err("Capture cancelled"));
        }
        args.extend(["-g".into(), g]);
    }
    args.push(path.to_string_lossy().into());
    run("grim", &args)?;
    Ok(())
}
fn n(v: &Value, k: &str, d: f64) -> f64 {
    v[k].as_f64().unwrap_or(d)
}
fn color(v: &Value) -> Result<String> {
    let c = v["color"].as_str().unwrap_or("#f05a70");
    if !(c.starts_with('#')
        && [4, 7, 9].contains(&c.len())
        && c[1..].chars().all(|c| c.is_ascii_hexdigit()))
    {
        return Err(err("Color must be hexadecimal"));
    }
    Ok(c.to_string())
}
fn number(v: &Value, k: &str, d: f64) -> Result<f64> {
    let x = n(v, k, d);
    if !x.is_finite() || x.abs() > 100000. {
        return Err(err("Invalid drawing coordinate"));
    }
    Ok(x)
}
fn raster_op(img: &mut RgbaImage, op: &Value) -> Result<bool> {
    let typ = op["type"].as_str().unwrap_or("");
    if !["redact", "pixelate", "highlight", "spotlight", "blur"].contains(&typ) {
        return Ok(false);
    }
    let x = n(op, "x", 0.).max(0.) as u32;
    let y = n(op, "y", 0.).max(0.) as u32;
    let w = (n(op, "w", 1.).max(1.) as u32).min(img.width().saturating_sub(x));
    let h = (n(op, "h", 1.).max(1.) as u32).min(img.height().saturating_sub(y));
    if x >= img.width() || y >= img.height() {
        return Err(err("Selection outside image"));
    }
    if typ == "spotlight" {
        let radius = n(op, "radius", 12.).clamp(0., w.min(h) as f64 / 2.);
        let cx = x as f64 + w as f64 / 2.;
        let cy = y as f64 + h as f64 / 2.;
        for (px, py, p) in img.enumerate_pixels_mut() {
            let qx = (px as f64 + 0.5 - cx).abs() - (w as f64 / 2. - radius);
            let qy = (py as f64 + 0.5 - cy).abs() - (h as f64 / 2. - radius);
            let distance = qx.max(0.).hypot(qy.max(0.)) + qx.max(qy).min(0.) - radius;
            if distance > 0. {
                for channel in p.0.iter_mut().take(3) {
                    *channel = (*channel as f64 * 0.3) as u8;
                }
            } else if distance > -2. {
                let coverage = (2. + distance).clamp(0., 1.);
                for channel in p.0.iter_mut().take(3) {
                    *channel = (*channel as f64 * (1. - coverage) + 255. * coverage) as u8;
                }
            }
        }
    } else {
        // Blur only the selection plus the kernel radius (clamped at image edges like a full blur).
        let (old, ox, oy) = if typ == "blur" {
            let sigma = n(op, "strength", 12.).clamp(1., 80.) as f32;
            let halo = background::blur_halo(sigma);
            let (ox, oy) = (x.saturating_sub(halo), y.saturating_sub(halo));
            let (ow, oh) = (
                (x + w + halo).min(img.width()) - ox,
                (y + h + halo).min(img.height()) - oy,
            );
            let area = image::imageops::crop_imm(img, ox, oy, ow, oh).to_image();
            (background::blur(&area, sigma), ox, oy)
        } else {
            (img.clone(), 0, 0)
        };
        let ink = background::parse_color(op["color"].as_str().unwrap_or("#ffe629"));
        for py in y..y + h {
            for px in x..x + w {
                let p = img.get_pixel_mut(px, py);
                match typ {
                    "redact" => *p = image::Rgba([0, 0, 0, 255]),
                    "blur" => *p = *old.get_pixel(px - ox, py - oy),
                    "highlight" => {
                        let radius = n(op, "radius", h as f64 / 2.).clamp(0., w.min(h) as f64 / 2.);
                        let lx = px as f64 + 0.5 - x as f64;
                        let ly = py as f64 + 0.5 - y as f64;
                        let dx = lx - lx.clamp(radius, w as f64 - radius);
                        let dy = ly - ly.clamp(radius, h as f64 - radius);
                        if dx.hypot(dy) > radius {
                            continue;
                        }
                        let ink = ink.as_ref().map_err(|e| err(&e.to_string()))?;
                        let alpha = n(op, "opacity", 0.35).clamp(0., 1.) * ink[3] as f64 / 255.;
                        for k in 0..3 {
                            p[k] =
                                (p[k] as f64 * (1. - alpha) + ink[k] as f64 * alpha).round() as u8;
                        }
                    }
                    _ => {
                        let block = n(op, "strength", 12.).clamp(4., 64.) as u32;
                        *p = *old.get_pixel(
                            x + ((px - x) / block) * block,
                            y + ((py - y) / block) * block,
                        );
                    }
                }
            }
        }
    }
    Ok(true)
}
fn magick(args: &[String], input: &[u8]) -> Result<Vec<u8>> {
    let mut child = Command::new("magick")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().unwrap();
    // Feed stdin from a thread so large images cannot deadlock against a full stdout pipe.
    let out = std::thread::scope(|s| {
        s.spawn(move || stdin.write_all(input));
        child.wait_with_output()
    })?;
    if !out.status.success() {
        return Err(err(&format!(
            "magick: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(out.stdout)
}
fn encode_png(img: &DynamicImage) -> Result<Vec<u8>> {
    use image::codecs::png::{CompressionType, FilterType, PngEncoder};
    let mut out = Vec::new();
    img.write_with_encoder(PngEncoder::new_with_quality(
        &mut out,
        CompressionType::Uncompressed,
        FilterType::NoFilter,
    ))?;
    Ok(out)
}
// Current image as RGBA, decoding magick's last PNG if that is the newest state.
fn take_rgba(img: &mut DynamicImage, png: &mut Option<Vec<u8>>) -> Result<RgbaImage> {
    if let Some(b) = png.take() {
        *img = image::load_from_memory_with_format(&b, ImageFormat::Png)?;
    }
    Ok(std::mem::replace(img, DynamicImage::new_rgba8(0, 0)).into_rgba8())
}
fn render(input: &Path, ops: &Value, output: &Path) -> Result<Option<Value>> {
    let ops = ops
        .as_array()
        .ok_or_else(|| err("Operations must be array"))?;
    if ops.len() > 1000 {
        return Err(err("Too many operations"));
    }
    // The working image stays in memory. `png` holds magick's last output verbatim, so the next
    // magick op reads exactly the PNG (colour type, page offset, chunks) it would have read from disk.
    let mut img = image::open(input)?;
    let mut png: Option<Vec<u8>> = None;
    let mut fonts = std::collections::HashMap::new();
    let mut content_rect = None;
    for op in ops {
        let typ = op["type"].as_str().unwrap_or("");
        if ["redact", "pixelate", "highlight", "spotlight", "blur"].contains(&typ) {
            let mut rgba = take_rgba(&mut img, &mut png)?;
            raster_op(&mut rgba, op)?;
            img = rgba.into();
            continue;
        }
        if typ == "background" {
            let (result, rect) = background::compose(&take_rgba(&mut img, &mut png)?, op)?;
            img = result.into();
            content_rect = Some(rect);
            continue;
        }
        let x = number(op, "x", 0.)?;
        let y = number(op, "y", 0.)?;
        let w = number(op, "w", 100.)?.max(1.);
        let h = number(op, "h", 100.)?.max(1.);
        let x2 = number(op, "x2", x + w)?;
        let y2 = number(op, "y2", y + h)?;
        if typ == "crop" {
            if w * h > 100_000_000. {
                return Err(err("Crop canvas too large"));
            }
            let fill = op["background_color"].as_str().unwrap_or("#00000000");
            let fill = background::parse_color(fill)?;
            let mut canvas = RgbaImage::from_pixel(w as u32, h as u32, fill);
            let source = take_rgba(&mut img, &mut png)?;
            image::imageops::overlay(&mut canvas, &source, -(x as i64), -(y as i64));
            img = canvas.into();
            content_rect = Some(
                json!({"x":0,"y":0,"w":w as u32,"h":h as u32,"sourceX":0,"sourceY":0,"sourceW":w as u32,"sourceH":h as u32}),
            );
            continue;
        }
        if typ == "image" {
            if w * h > 100_000_000. {
                return Err(err("Image layer too large"));
            }
            let path = checked(
                op["path"]
                    .as_str()
                    .ok_or_else(|| err("Image layer requires path"))?,
            )?;
            let layer = image::imageops::resize(
                &image::open(path)?.to_rgba8(),
                w as u32,
                h as u32,
                image::imageops::FilterType::Lanczos3,
            );
            let mut base = take_rgba(&mut img, &mut png)?;
            let nw = base.width().max((x + w).max(1.) as u32);
            let nh = base.height().max((y + h).max(1.) as u32);
            if nw as u64 * nh as u64 > 100_000_000 {
                return Err(err("Composed image too large"));
            }
            if nw != base.width() || nh != base.height() {
                let mut expanded = RgbaImage::new(nw, nh);
                image::imageops::overlay(&mut expanded, &base, 0, 0);
                base = expanded;
            }
            image::imageops::overlay(&mut base, &layer, x as i64, y as i64);
            img = base.into();
            content_rect = Some(
                json!({"x":0,"y":0,"w":nw,"h":nh,"sourceX":0,"sourceY":0,"sourceW":nw,"sourceH":nh}),
            );
            continue;
        }
        let mut args = strings(&["-regard-warnings", "png:-"]);
        match typ {
            "rotate" => args.extend(strings(&[
                "-rotate",
                &number(op, "angle", 90.)?.to_string(),
            ])),
            "flip" => args.push(
                if op["axis"].as_str() == Some("horizontal") {
                    "-flop"
                } else {
                    "-flip"
                }
                .into(),
            ),
            "freehand" => {
                let pts = op["points"]
                    .as_array()
                    .ok_or_else(|| err("freehand requires points array"))?;
                if pts.len() > 10000 {
                    return Err(err("Too many points"));
                }
                let stride = (pts.len() / 500).max(1);
                let mut points = pts
                    .iter()
                    .step_by(stride)
                    .map(|p| Ok((number(p, "x", 0.)?, number(p, "y", 0.)?)))
                    .collect::<Result<Vec<_>>>()?;
                if let Some(last) = pts.last() {
                    let point = (number(last, "x", 0.)?, number(last, "y", 0.)?);
                    if points.last() != Some(&point) {
                        points.push(point);
                    }
                }
                if op["smooth"].as_bool().unwrap_or(true) && points.len() > 2 {
                    for _ in 0..2 {
                        let mut smoothed = vec![points[0]];
                        for pair in points.windows(2) {
                            let (a, b) = (pair[0], pair[1]);
                            smoothed.push((a.0 * 0.75 + b.0 * 0.25, a.1 * 0.75 + b.1 * 0.25));
                            smoothed.push((a.0 * 0.25 + b.0 * 0.75, a.1 * 0.25 + b.1 * 0.75));
                        }
                        smoothed.push(*points.last().unwrap());
                        points = smoothed;
                    }
                }
                let coordinates = points
                    .iter()
                    .map(|(x, y)| format!("{x:.3},{y:.3}"))
                    .collect::<Vec<_>>();
                args.extend(strings(&[
                    "-stroke",
                    &color(op)?,
                    "-strokewidth",
                    &n(op, "width", 4.).clamp(1., 100.).to_string(),
                    "-fill",
                    "none",
                    "-draw",
                    &format!("polyline {}", coordinates.join(" ")),
                ]));
            }
            "resize" => {
                if w * h > 100_000_000. {
                    return Err(err("Image too large"));
                }
                args.extend(strings(&[
                    "-resize",
                    &format!("{}x{}!", w as u32, h as u32),
                ]));
            }

            "line" | "arrow" | "rectangle" | "filled" | "ellipse" | "text" | "step" => {
                let c = color(op)?;
                let stroke = n(op, "width", 4.).clamp(1., 100.);
                args.extend(strings(&[
                    "-stroke",
                    &c,
                    "-strokewidth",
                    &stroke.to_string(),
                    "-fill",
                    "none",
                ]));
                if typ == "filled" {
                    args.extend(strings(&["-fill", &c]));
                }
                let draw = match typ {
                    "filled" | "rectangle" => format!("rectangle {x},{y} {},{}", x + w, y + h),
                    "ellipse" => format!(
                        "ellipse {},{} {},{} 0,360",
                        x + w / 2.,
                        y + h / 2.,
                        w / 2.,
                        h / 2.
                    ),
                    "text" | "step" => String::new(),
                    "arrow" if op["cx"].is_number() && op["cy"].is_number() => format!(
                        "path 'M {x},{y} Q {},{} {x2},{y2}'",
                        number(op, "cx", 0.)?,
                        number(op, "cy", 0.)?
                    ),
                    _ => format!("line {x},{y} {x2},{y2}"),
                };
                if !draw.is_empty() {
                    args.extend(["-draw".into(), draw]);
                }
                if typ == "arrow" {
                    let angle = if op["cx"].is_number() && op["cy"].is_number() {
                        (y2 - number(op, "cy", y)?).atan2(x2 - number(op, "cx", x)?)
                    } else {
                        (y2 - y).atan2(x2 - x)
                    };
                    let len = stroke * 4.;
                    let a = (
                        x2 - len * (angle - 0.5).cos(),
                        y2 - len * (angle - 0.5).sin(),
                    );
                    let b = (
                        x2 - len * (angle + 0.5).cos(),
                        y2 - len * (angle + 0.5).sin(),
                    );
                    args.extend(strings(&[
                        "-fill",
                        &c,
                        "-draw",
                        &format!("polygon {x2},{y2} {},{} {},{}", a.0, a.1, b.0, b.1),
                    ]));
                }
                if typ == "text" || typ == "step" {
                    let style = op["style"].as_str().unwrap_or("standard");
                    let family = if style.starts_with("monospaced") {
                        "monospace"
                    } else if style == "rounded" {
                        "sans:weight=bold"
                    } else {
                        "sans"
                    };
                    if !fonts.contains_key(family) {
                        let file = run("fc-match", &strings(&["-f", "%{file}", family]))?;
                        fonts.insert(family, file);
                    }
                    let font = &fonts[family];
                    if !Path::new(&font).is_file() {
                        return Err(err("No readable sans font found via fontconfig"));
                    }
                    let text = op["text"].as_str().unwrap_or("1");
                    let size = n(op, "size", 28.).clamp(6., 500.);
                    if typ == "text"
                        && ["boxed", "rounded_boxed", "monospaced_boxed"].contains(&style)
                    {
                        let tw = n(op, "w", (text.chars().count() as f64 * size * 0.63).max(8.));
                        let th = n(op, "h", size * 1.4);
                        let shape = if style == "rounded_boxed" {
                            format!(
                                "roundrectangle {},{} {},{} {},{}",
                                x - 8.,
                                y - 4.,
                                x + tw + 8.,
                                y + th + 4.,
                                size * 0.25,
                                size * 0.25
                            )
                        } else {
                            format!(
                                "rectangle {},{} {},{}",
                                x - 8.,
                                y - 4.,
                                x + tw + 8.,
                                y + th + 4.
                            )
                        };
                        args.extend(strings(&[
                            "-stroke", "none", "-fill", &c, "-draw", &shape, "-fill", "white",
                        ]));
                    } else if typ == "step" {
                        args.extend(strings(&[
                            "-fill",
                            &c,
                            "-draw",
                            &format!("circle {x},{y} {},{y}", x + size * 0.7),
                            "-fill",
                            "white",
                        ]));
                    } else {
                        args.extend(strings(&["-fill", &c]));
                    }
                    // Text is a separate annotation argument; escape ImageMagick percent-property expansion.
                    let text = text.replace('%', "%%");
                    let text = if text.starts_with('@') {
                        format!("\\{text}")
                    } else {
                        text
                    };
                    // Centered steps (new ops) center the label's measured ink on the dot; older ops keep the fixed offset.
                    let (ax, ay) = if typ == "step" && op["centered"].as_bool() == Some(true) {
                        let pad = size.ceil() as usize;
                        let canvas = format!("{}x{}", pad * (text.chars().count() + 2), pad * 3);
                        let ink = run(
                            "magick",
                            &strings(&[
                                "-size",
                                &canvas,
                                "xc:black",
                                "-fill",
                                "white",
                                "-font",
                                font,
                                "-pointsize",
                                &size.to_string(),
                                "-gravity",
                                "NorthWest",
                                "-annotate",
                                &format!("+{pad}+{pad}"),
                                &text,
                                "-trim",
                                "-format",
                                "%w %h %X %Y",
                                "info:",
                            ]),
                        )?;
                        let v: Vec<f64> = ink
                            .split_whitespace()
                            .filter_map(|s| s.parse().ok())
                            .collect();
                        if v.len() != 4 {
                            return Err(err("Could not measure step label"));
                        }
                        let pad = pad as f64;
                        (x - (v[2] - pad) - v[0] / 2., y - (v[3] - pad) - v[1] / 2.)
                    } else if typ == "step" {
                        (x - size * 0.3, y - size * 0.65)
                    } else {
                        (x, y)
                    };
                    let outlined = typ == "text" && style == "outlined";
                    args.extend(strings(&[
                        "-stroke",
                        if outlined { "#ffffff" } else { "none" },
                        "-strokewidth",
                        if outlined { "2" } else { "0" },
                        "-font",
                        font,
                        "-pointsize",
                        &size.to_string(),
                        "-gravity",
                        "NorthWest",
                        "-annotate",
                        &format!("+{ax}+{ay}"),
                        &text,
                    ]));
                }
            }
            _ => return Err(err(&format!("Unknown operation: {typ}"))),
        }
        // Uncompressed PNG over pipes: same decoded state as the former temp file, minus zlib.
        args.extend(strings(&["-define", "png:compression-level=0", "png:-"]));
        let input = match png.take() {
            Some(b) => b,
            None => encode_png(&img)?,
        };
        let out = png.insert(magick(&args, &input)?);
        if ["resize", "rotate", "flip"].contains(&typ) {
            let (w, h) =
                image::ImageReader::with_format(std::io::Cursor::new(out), ImageFormat::Png)
                    .into_dimensions()?;
            content_rect = Some(
                json!({"x":0,"y":0,"w":w,"h":h,"sourceX":0,"sourceY":0,"sourceW":w,"sourceH":h}),
            );
        }
    }
    match png {
        Some(b) => image::load_from_memory_with_format(&b, ImageFormat::Png)?,
        None => img,
    }
    .save(output)?;
    Ok(content_rect)
}
fn stitch(a: &RgbaImage, b: &RgbaImage) -> Result<RgbaImage> {
    if a.width() != b.width() {
        return Err(err("Scroll frames have different widths"));
    }
    let max = a.height().min(b.height());
    if max < 8 || b.width() < 8 {
        return Err(err("Scroll frame too small"));
    }
    let mut best = (f64::INFINITY, 0u32);
    // Sample the central content to tolerate stationary scrollbars and window borders.
    for overlap in 8..=max {
        let mut score = 0u64;
        let mut count = 0u64;
        for by in (0..overlap).step_by((overlap as usize / 32).max(1)) {
            for x in (b.width() / 10..b.width() * 9 / 10).step_by((b.width() as usize / 80).max(1))
            {
                let p = a.get_pixel(x, a.height() - overlap + by);
                let q = b.get_pixel(x, by);
                for k in 0..3 {
                    score += p[k].abs_diff(q[k]) as u64;
                    count += 1;
                }
            }
        }
        let score = score as f64 / count.max(1) as f64;
        if score <= best.0 {
            best = (score, overlap);
        }
    }
    if best.0 > 12. {
        return Err(err(
            "No matching overlap found. Scroll less and append again.",
        ));
    }
    let height = a.height() + b.height() - best.1;
    if height > 100000 || height as u64 * a.width() as u64 > 100_000_000 {
        return Err(err("Scrolling capture too large"));
    }
    let mut out = RgbaImage::new(a.width(), height);
    image::imageops::replace(&mut out, a, 0, 0);
    for y in best.1..b.height() {
        for x in 0..b.width() {
            out.put_pixel(x, a.height() + y - best.1, *b.get_pixel(x, y));
        }
    }
    Ok(out)
}
fn session_file(id: &str) -> Result<PathBuf> {
    if !id.chars().all(|c| c.is_ascii_digit() || c == '-') || id.is_empty() {
        return Err(err("Invalid scroll session"));
    }
    Ok(data().join(format!(".scroll-{id}.json")))
}
fn argument(args: &[String], i: usize) -> Result<&str> {
    args.get(i)
        .map(String::as_str)
        .ok_or_else(|| err("Missing argument; run omashot help"))
}
fn dispatch(a: &[String]) -> Result<Value> {
    fs::create_dir_all(data())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(data(), fs::Permissions::from_mode(0o700))?;
    }
    if !["config", "cleanup"].contains(&argument(a, 0)?) {
        storage::cleanup(
            &data(),
            config()["retention_days"].as_u64().unwrap_or(30),
            storage::now(),
        )?;
    }
    match argument(a, 0)? {
        "help" | "--help" => Ok(
            json!({"commands":["capture region|repeat|window|active|fullscreen [--delay N] [--cursor]","import PATH","history","cleanup","snapshot","capture-frozen PATH GEOMETRY","snapshot-cancel PATH","backgrounds","wallpaper import PATH|list|delete PATH","copy PATH","ocr PATH","qr PATH","export PATH DEST","delete PATH","render INPUT JSON_OR_FILE OUTPUT_OR_DASH_OR_--preview","scroll start [--geometry G] [--horizontal]","scroll append SESSION","scroll finish SESSION","scroll cancel SESSION","project IMAGE","config [JSON]"],"version":env!("CARGO_PKG_VERSION")}),
        ),
        "capture" => {
            let mode = argument(a, 1)?;
            let c = config();
            let mut delay = c["delay"].as_f64().unwrap_or(0.);
            if let Some(i) = a.iter().position(|s| s == "--delay") {
                delay = argument(a, i + 1)?.parse()?;
            }
            if !(0.0..=3600.).contains(&delay) {
                return Err(err("Delay must be 0..3600 seconds"));
            }
            with_desktop_hidden(&c, || {
                let geo = geometry(mode)?;
                std::thread::sleep(std::time::Duration::from_secs_f64(delay));
                let p = unique("capture");
                let cursor =
                    a.iter().any(|s| s == "--cursor") || c["cursor"].as_bool().unwrap_or(false);
                let mut window_source = None;
                if ["window", "active"].contains(&mode)
                    && c["window_transparent"].as_bool().unwrap_or(false)
                {
                    let address = if mode == "active" {
                        let client: Value = serde_json::from_str(&run(
                            "hyprctl",
                            &strings(&["-j", "activewindow"]),
                        )?)?;
                        client["address"]
                            .as_str()
                            .ok_or_else(|| err("No active window"))?
                            .to_string()
                    } else {
                        snapshot::selected_window(
                            geo.as_deref()
                                .ok_or_else(|| err("Missing window geometry"))?,
                        )?
                    };
                    window_source = Some(snapshot::isolated_window(&address, &p, cursor)?);
                } else {
                    capture_to(&p, geo, cursor)?;
                }
                let format = c["format"].as_str().unwrap_or("png");
                if ["jpg", "jpeg", "webp"].contains(&format) {
                    let dest = p.with_extension(format);
                    let source = image::open(&p)?.to_rgba8();
                    if ["jpg", "jpeg"].contains(&format) {
                        let mut matte = RgbaImage::from_pixel(
                            source.width(),
                            source.height(),
                            image::Rgba([255, 255, 255, 255]),
                        );
                        image::imageops::overlay(&mut matte, &source, 0, 0);
                        image::DynamicImage::ImageRgba8(matte)
                            .to_rgb8()
                            .save(&dest)?;
                    } else {
                        source.save(&dest)?;
                    }
                    fs::remove_file(&p)?;
                    let mut result = meta(&dest)?;
                    if let Some(source) = window_source {
                        result["captureSource"] = source;
                    }
                    Ok(result)
                } else {
                    let mut result = meta(&p)?;
                    if let Some(source) = window_source {
                        result["captureSource"] = source;
                    }
                    Ok(result)
                }
            })
        }
        "import" => {
            let p = checked(argument(a, 1)?)?;
            let dest = unique("import");
            image::open(p)?.save(&dest)?;
            meta(&dest)
        }
        "cleanup" => Ok(
            json!({"removed":storage::cleanup(&data(),config()["retention_days"].as_u64().unwrap_or(30),storage::now())?}),
        ),
        "snapshot" => snapshot::capture(a),
        "snapshot-cancel" => snapshot::cancel(argument(a, 1)?),
        "capture-frozen" => snapshot::save(argument(a, 1)?, argument(a, 2)?),
        "backgrounds" => background::thumbnails(&data()),
        "wallpaper" => storage::wallpaper(a, &data(), &config()),
        "history" => {
            let mut entries = Vec::new();
            for entry in fs::read_dir(data())? {
                let p = entry?.path();
                if !storage::managed_name(&p.file_name().unwrap_or_default().to_string_lossy()) {
                    continue;
                }
                if let Ok(mut v) = meta(&p) {
                    v["modified"] = json!(
                        fs::metadata(&p)?
                            .modified()?
                            .duration_since(UNIX_EPOCH)?
                            .as_secs()
                    );
                    v["modifiedNs"] = json!(
                        fs::metadata(&p)?
                            .modified()?
                            .duration_since(UNIX_EPOCH)?
                            .as_nanos()
                            .min(u64::MAX as u128) as u64
                    );
                    entries.push(v);
                }
            }
            entries.sort_by(|a, b| {
                b["modifiedNs"]
                    .as_u64()
                    .cmp(&a["modifiedNs"].as_u64())
                    .then_with(|| b["path"].as_str().cmp(&a["path"].as_str()))
            });
            Ok(json!(entries))
        }
        "delete" => {
            let p = checked(argument(a, 1)?)?;
            if p.parent() != Some(fs::canonicalize(data())?.as_path())
                || !storage::managed_name(&p.file_name().unwrap_or_default().to_string_lossy())
            {
                return Err(err("Only history images may be deleted"));
            }
            storage::remove_capture(&p)?;
            Ok(json!({"ok":true}))
        }
        "copy" => {
            let p = checked(argument(a, 1)?)?;
            let mut bytes = std::io::Cursor::new(Vec::new());
            image::open(p)?.write_to(&mut bytes, image::ImageFormat::Png)?;
            copy_text(&bytes.into_inner(), "image/png")?;
            Ok(json!({"ok":true}))
        }
        "ocr" => {
            let p = checked(argument(a, 1)?)?;
            let lang = config()["ocr_language"]
                .as_str()
                .unwrap_or("eng")
                .to_string();
            let text = run(
                "tesseract",
                &strings(&[&p.to_string_lossy(), "stdout", "-l", &lang]),
            )?;
            copy_text(text.as_bytes(), "text/plain;charset=utf-8")?;
            Ok(json!({"text":text}))
        }
        "qr" => {
            let p = checked(argument(a, 1)?)?;
            let text = run(
                "zbarimg",
                &strings(&["--quiet", "--raw", &p.to_string_lossy()]),
            )?;
            copy_text(text.as_bytes(), "text/plain;charset=utf-8")?;
            Ok(json!({"text":text}))
        }
        "export" => {
            let p = checked(argument(a, 1)?)?;
            let dest = PathBuf::from(argument(a, 2)?);
            if dest.exists() {
                return Err(err("Destination already exists"));
            }
            let fmt = image::ImageFormat::from_path(&dest)?;
            if ![
                image::ImageFormat::Png,
                image::ImageFormat::Jpeg,
                image::ImageFormat::WebP,
            ]
            .contains(&fmt)
            {
                return Err(err("Export supports PNG, JPEG, WebP"));
            }
            let original = image::open(p)?.to_rgba8();
            if fmt == image::ImageFormat::Jpeg {
                let mut flat = RgbaImage::from_pixel(
                    original.width(),
                    original.height(),
                    image::Rgba([255, 255, 255, 255]),
                );
                image::imageops::overlay(&mut flat, &original, 0, 0);
                image::DynamicImage::ImageRgba8(flat)
                    .to_rgb8()
                    .save_with_format(&dest, fmt)?;
            } else {
                original.save_with_format(&dest, fmt)?;
            }
            meta(&dest)
        }
        "render" => {
            let p = checked(argument(a, 1)?)?;
            let s = argument(a, 2)?;
            let operations_text = if s.trim_start().starts_with('[') {
                s.to_owned()
            } else {
                fs::read_to_string(s)?
            };
            let mut ops: Value = serde_json::from_str(&operations_text)?;
            let preview = argument(a, 3)? == "--preview";
            let dest = if preview {
                unique(".preview")
            } else if argument(a, 3)? == "-" {
                unique("edited")
            } else {
                PathBuf::from(argument(a, 3)?)
            };
            if dest.exists() && !preview {
                return Err(err("Output already exists"));
            }
            let content_rect = render(&p, &ops, &dest)?;
            if !preview {
                let source = original_path(&dest);
                image::open(&p)?.save(&source)?;
                if let Some(items) = ops.as_array_mut() {
                    for (index, item) in items.iter_mut().enumerate() {
                        if item["type"].as_str() == Some("image") {
                            let path = checked(
                                item["path"]
                                    .as_str()
                                    .ok_or_else(|| err("Image layer requires path"))?,
                            )?;
                            let asset =
                                storage::asset_dir(&dest).join(format!("layer-{index}.png"));
                            fs::create_dir_all(asset.parent().unwrap())?;
                            image::open(path)?.save(&asset)?;
                            item["path"] = json!(asset);
                        }
                    }
                }
                fs::write(
                    dest.with_extension("project.json"),
                    serde_json::to_vec_pretty(&json!({"source":source,"operations":ops}))?,
                )?;
            }
            let mut result = meta(&dest)?;
            if let Some(rect) = content_rect {
                result["contentRect"] = rect;
            }
            Ok(result)
        }
        "project" => {
            let p = checked(argument(a, 1)?)?;
            if p.with_extension("project.json").exists() {
                let project: Value =
                    serde_json::from_slice(&fs::read(p.with_extension("project.json"))?)?;
                if project["source"]
                    .as_str()
                    .and_then(|s| checked(s).ok())
                    .is_some()
                {
                    Ok(project)
                } else {
                    Ok(
                        json!({"source":p,"operations":[],"warning":"Original project source missing; restored flattened image"}),
                    )
                }
            } else {
                Ok(json!({"source":p,"operations":[]}))
            }
        }
        "config" => {
            if let Some(s) = a.get(1) {
                let mut v: Value = serde_json::from_str(s)?;
                if let Some(obj) = v.as_object_mut() {
                    obj.remove("upload_url");
                    obj.remove("upload_token");
                }
                validate_config(&v)?;
                let p = config_path();
                fs::create_dir_all(p.parent().unwrap())?;
                fs::write(&p, serde_json::to_vec_pretty(&v)?)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&p, fs::Permissions::from_mode(0o600))?;
                }
            }
            let c = config();
            validate_config(&c)?;
            Ok(c)
        }
        "scroll" => match argument(a, 1)? {
            "start" => {
                let geo = if let Some(i) = a.iter().position(|s| s == "--geometry") {
                    argument(a, i + 1)?.to_string()
                } else {
                    geometry("region")?.unwrap()
                };
                let id = format!(
                    "{}-{}",
                    SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),
                    std::process::id()
                );
                let frame = data().join(format!(".scroll-{id}.png"));
                capture_to(&frame, Some(geo.clone()), false)?;
                fs::write(
                    session_file(&id)?,
                    serde_json::to_vec(
                        &json!({"geometry":geo,"path":frame,"axis":if a.iter().any(|v|v=="--horizontal"){ "horizontal" }else{"vertical"}}),
                    )?,
                )?;
                Ok(json!({"session":id,"geometry":geo}))
            }
            "cancel" => {
                let id = argument(a, 2)?;
                let sf = session_file(id)?;
                let _ = fs::remove_file(sf);
                let _ = fs::remove_file(data().join(format!(".scroll-{id}.png")));
                Ok(json!({"ok":true}))
            }
            "append" | "finish" => {
                let id = argument(a, 2)?;
                let sf = session_file(id)?;
                let state: Value = serde_json::from_slice(&fs::read(&sf)?)?;
                let frame = data().join(format!(".scroll-{id}.png"));
                if state["path"].as_str() != Some(frame.to_string_lossy().as_ref()) {
                    return Err(err("Invalid scroll state"));
                }
                if a[1] == "append" {
                    let next = unique(".scroll-frame");
                    capture_to(
                        &next,
                        Some(
                            state["geometry"]
                                .as_str()
                                .ok_or_else(|| err("Missing geometry"))?
                                .to_string(),
                        ),
                        false,
                    )?;
                    let first = image::open(&frame)?.to_rgba8();
                    let second = image::open(&next)?.to_rgba8();
                    let result = if state["axis"] == "horizontal" {
                        stitch(
                            &image::imageops::rotate90(&first),
                            &image::imageops::rotate90(&second),
                        )
                        .map(|i| image::imageops::rotate270(&i))
                    } else {
                        stitch(&first, &second)
                    };
                    let _ = fs::remove_file(next);
                    result?.save(&frame)?;
                    meta(&frame)
                } else {
                    let dest = unique("scroll");
                    fs::rename(frame, &dest)?;
                    fs::remove_file(sf)?;
                    meta(&dest)
                }
            }
            _ => Err(err("Expected scroll start, append or finish")),
        },
        _ => Err(err("Unknown command; run omashot help")),
    }
}
fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match dispatch(&args) {
        Ok(v) => println!("{v}"),
        Err(e) => {
            println!("{}", json!({"error":e.to_string()}));
            std::process::exit(1);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refuses_external_delete_and_bad_drawing_color() {
        let p =
            std::env::temp_dir().join(format!("omashot-delete-test-{}.png", std::process::id()));
        RgbaImage::new(8, 8).save(&p).unwrap();
        assert!(dispatch(&strings(&["delete", &p.to_string_lossy()])).is_err());
        assert!(p.exists());
        fs::remove_file(p).unwrap();
        assert!(color(&json!({"color":"red; image over 0,0 0,0 '/etc/passwd'"})).is_err());
    }
    #[test]
    fn default_preferences_and_cli_discovery() {
        let prefs = default_config();
        assert_eq!(prefs["delay"], 0);
        assert_eq!(prefs["cursor"], false);
        assert_eq!(prefs["format"], "png");
        assert_eq!(prefs["ocr_language"], "eng");
        assert_eq!(prefs["retention_days"], 30);
        let help = dispatch(&strings(&["help"])).unwrap().to_string();
        assert!(help.contains("region|repeat|window|active|fullscreen"));
        assert!(help.contains("--horizontal"));
        assert!(help.contains("project IMAGE"));
    }
    #[test]
    fn desktop_provider_restores_after_capture_and_hide_errors() {
        let trace = std::env::temp_dir().join(format!(
            "omashot-hook-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut c = json!({"hide_desktop_icons":true,"desktop_hide_argv":["sh","-c","printf hide >> \"$1\"","hook",trace],"desktop_restore_argv":["sh","-c","printf restore >> \"$1\"","hook",trace]});
        let failed: Result<()> = with_desktop_hidden(&c, || Err(err("Capture cancelled")));
        assert!(
            failed
                .unwrap_err()
                .to_string()
                .contains("Capture cancelled")
        );
        assert_eq!(fs::read_to_string(&trace).unwrap(), "hiderestore");
        c["desktop_hide_argv"] =
            json!(["sh", "-c", "printf hide >> \"$1\"; exit 1", "hook", trace]);
        let failed: Result<()> =
            with_desktop_hidden(&c, || panic!("Capture may not run after hide failure"));
        assert!(failed.is_err());
        assert_eq!(
            fs::read_to_string(&trace).unwrap(),
            "hiderestorehiderestore"
        );
        fs::remove_file(trace).unwrap();
        assert!(
            validate_config(&json!({"hide_desktop_icons":true,"desktop_hide_argv":["true"]}))
                .is_err()
        );
        assert!(validate_config(&json!({"hide_desktop_icons":true,"desktop_hide_argv":"bad","desktop_restore_argv":["true"]})).is_err());
        for days in [0, 1, 30, 3650] {
            assert!(validate_config(&json!({"retention_days":days})).is_ok());
        }
        assert!(validate_config(&json!({"retention_days":-1})).is_err());
        assert!(validate_config(&json!({"retention_days":3651})).is_err());
        assert!(validate_config(&json!({"delay":3601})).is_err());
        assert!(validate_config(&default_config()).is_ok());
    }
    #[test]
    fn generated_managed_ids_are_unique() {
        let ids: std::collections::HashSet<_> = (0..1000).map(|_| unique("capture")).collect();
        assert_eq!(ids.len(), 1000);
        assert!(
            ids.iter()
                .all(|p| storage::managed_name(&p.file_name().unwrap().to_string_lossy()))
        );
    }
    #[test]
    fn rejects_path_traversal() {
        assert!(session_file("../../etc").is_err());
        assert!(session_file("12-44").is_ok());
    }
    #[test]
    fn stitch_exact_overlap() {
        let mut full = RgbaImage::new(120, 300);
        for (x, y, p) in full.enumerate_pixels_mut() {
            *p = image::Rgba([
                (x * y % 251) as u8,
                (y % 251) as u8,
                (x * 3 % 251) as u8,
                255,
            ]);
        }
        let a = image::imageops::crop_imm(&full, 0, 0, 120, 200).to_image();
        let b = image::imageops::crop_imm(&full, 0, 100, 120, 200).to_image();
        assert_eq!(stitch(&a, &b).unwrap(), full);
    }
    #[test]
    fn horizontal_and_duplicate_stitch() {
        let mut full = RgbaImage::new(300, 120);
        for (x, y, p) in full.enumerate_pixels_mut() {
            *p = image::Rgba([
                (x % 251) as u8,
                (x * y % 251) as u8,
                (y * 3 % 251) as u8,
                255,
            ]);
        }
        let a = image::imageops::crop_imm(&full, 0, 0, 200, 120).to_image();
        let b = image::imageops::crop_imm(&full, 100, 0, 200, 120).to_image();
        let joined = stitch(
            &image::imageops::rotate90(&a),
            &image::imageops::rotate90(&b),
        )
        .unwrap();
        assert_eq!(image::imageops::rotate270(&joined), full);
        assert_eq!(stitch(&a, &a).unwrap(), a);
    }
    #[test]
    fn opaque_redaction() {
        let mut image = RgbaImage::from_pixel(20, 20, image::Rgba([255, 100, 50, 255]));
        raster_op(
            &mut image,
            &json!({"type":"redact","x":2,"y":3,"w":5,"h":6}),
        )
        .unwrap();
        assert_eq!(image.get_pixel(2, 3).0, [0, 0, 0, 255]);
        assert_eq!(image.get_pixel(1, 3).0, [255, 100, 50, 255]);
    }
    #[test]
    fn jpeg_input_render() {
        fs::create_dir_all(data()).unwrap();
        let input = unique(".test").with_extension("jpg");
        let output = unique(".test-result");
        image::RgbImage::from_pixel(32, 32, image::Rgb([200, 20, 40]))
            .save(&input)
            .unwrap();
        render(&input, &json!([]), &output).unwrap();
        assert_eq!(image::image_dimensions(&output).unwrap(), (32, 32));
        let _ = fs::remove_file(input);
        let _ = fs::remove_file(output);
    }
    #[test]
    fn annotations_change_real_pixels_and_geometry() {
        fs::create_dir_all(data()).unwrap();
        let input = unique(".test-blank");
        let blank = RgbaImage::from_pixel(200, 120, image::Rgba([255, 255, 255, 255]));
        blank.save(&input).unwrap();
        for typ in [
            "text",
            "step",
            "arrow",
            "line",
            "rectangle",
            "ellipse",
            "highlight",
            "spotlight",
            "redact",
        ] {
            let output = unique(".test-drawn");
            render(&input,&json!([{"type":typ,"x":30,"y":30,"w":80,"h":50,"x2":110,"y2":80,"text":"Visible","color":"#ff0000","size":24}]),&output).unwrap();
            let rendered = image::open(&output).unwrap().to_rgba8();
            let changed = blank
                .pixels()
                .zip(rendered.pixels())
                .filter(|(a, b)| a != b)
                .count();
            assert!(changed > 10, "{typ} did not draw pixels");
            fs::remove_file(output).unwrap();
        }
        for (op, expected) in [
            (json!({"type":"crop","x":10,"y":10,"w":60,"h":40}), (60, 40)),
            (json!({"type":"resize","w":80,"h":50}), (80, 50)),
        ] {
            let output = unique(".test-drawn");
            render(&input, &json!([op]), &output).unwrap();
            assert_eq!(image::image_dimensions(&output).unwrap(), expected);
            fs::remove_file(output).unwrap();
        }
        fs::remove_file(input).unwrap();
    }
    #[test]
    fn blur_and_pixelation_modify_pattern() {
        let mut pattern = RgbaImage::new(40, 40);
        for (x, y, p) in pattern.enumerate_pixels_mut() {
            let value = if (x + y) % 2 == 0 { 0 } else { 255 };
            *p = image::Rgba([value, value, value, 255]);
        }
        for typ in ["blur", "pixelate"] {
            let mut rendered = pattern.clone();
            raster_op(
                &mut rendered,
                &json!({"type":typ,"x":10,"y":10,"w":20,"h":20}),
            )
            .unwrap();
            assert_ne!(rendered, pattern, "{typ} did not modify pixels");
            assert_eq!(rendered.get_pixel(0, 0), pattern.get_pixel(0, 0));
        }
    }
    #[test]
    fn render_pipeline() {
        fs::create_dir_all(data()).unwrap();
        let input = unique(".test");
        let output = unique(".test-result");
        RgbaImage::from_pixel(200, 120, image::Rgba([250, 250, 250, 255]))
            .save(&input)
            .unwrap();
        render(&input,&json!([{"type":"arrow","x":10,"y":10,"x2":90,"y2":90},{"type":"text","x":20,"y":20,"text":"Test 100%"},{"type":"redact","x":3,"y":3,"w":10,"h":10},{"type":"background","padding":20,"preset":2,"shadow":true}]),&output).unwrap();
        assert_eq!(image::image_dimensions(&output).unwrap(), (240, 160));
        let _ = fs::remove_file(input);
        let _ = fs::remove_file(output);
    }
}
