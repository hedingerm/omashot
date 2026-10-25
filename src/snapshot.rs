use crate::{Result, config, data, err, meta, run, strings, unique, with_desktop_hidden};
use serde_json::{Value, json};
use std::{fs, path::PathBuf};
fn owned(path: &str) -> Result<PathBuf> {
    let p = crate::checked(path)?;
    let name = p.file_name().unwrap_or_default().to_string_lossy();
    if p.parent() != Some(fs::canonicalize(data())?.as_path())
        || !name.starts_with(".frozen-")
        || p.extension().and_then(|s| s.to_str()) != Some("png")
        || !p.with_extension("json").exists()
    {
        return Err(err("Expected an owned frozen screenshot"));
    }
    Ok(p)
}
pub fn capture(args: &[String]) -> Result<Value> {
    let c = config();
    let mut delay = c["delay"].as_f64().unwrap_or(0.);
    if let Some(i) = args.iter().position(|s| s == "--delay") {
        delay = crate::argument(args, i + 1)?.parse()?;
    }
    if !(0.0..=3600.).contains(&delay) {
        return Err(err("Delay must be0..3600seconds"));
    }
    let cursor = c["cursor"].as_bool().unwrap_or(false) || args.iter().any(|s| s == "--cursor");
    let monitors: Value = serde_json::from_str(&run("hyprctl", &strings(&["-j", "monitors"]))?)?;
    let rows = monitors
        .as_array()
        .ok_or_else(|| err("Invalid monitor geometry"))?;
    if rows.is_empty() {
        return Err(err("No active screens"));
    }
    let mut normalized = Vec::new();
    let (mut min_x, mut min_y, mut max_x, mut max_y) = (
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    );
    let mut scale = 1f64;
    for m in rows {
        let factor = m["scale"].as_f64().unwrap_or(1.).max(0.1);
        let mut w = m["width"]
            .as_f64()
            .ok_or_else(|| err("Missing screen width"))?;
        let mut h = m["height"]
            .as_f64()
            .ok_or_else(|| err("Missing screen height"))?;
        if m["transform"].as_u64().unwrap_or(0) % 2 == 1 {
            std::mem::swap(&mut w, &mut h);
        }
        let (x, y) = (m["x"].as_f64().unwrap_or(0.), m["y"].as_f64().unwrap_or(0.));
        let (lw, lh) = (w / factor, h / factor);
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x + lw);
        max_y = max_y.max(y + lh);
        scale = scale.max(factor);
        let mut v = m.clone();
        v["logicalWidth"] = json!(lw);
        v["logicalHeight"] = json!(lh);
        normalized.push(v);
    }
    let p = unique(".frozen");
    with_desktop_hidden(&c, || {
        std::thread::sleep(std::time::Duration::from_secs_f64(delay));
        let mut argv = strings(&["-s", &scale.to_string()]);
        if cursor {
            argv.push("-c".into());
        }
        argv.push(p.to_string_lossy().into());
        run("grim", &argv)?;
        Ok(())
    })?;
    let mut result = meta(&p)?;
    result["originX"] = json!(min_x);
    result["originY"] = json!(min_y);
    result["logicalWidth"] = json!(max_x - min_x);
    result["logicalHeight"] = json!(max_y - min_y);
    result["scale"] = json!(scale);
    result["monitors"] = json!(normalized);
    fs::write(p.with_extension("json"), serde_json::to_vec(&result)?)?;
    Ok(result)
}
pub fn isolated_window(address: &str, dest: &std::path::Path, cursor: bool) -> Result<Value> {
    let installed = std::env::var_os("OMASHOT_PLUGIN_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".config/omarchy/plugins/omashot")
        })
        .join("WindowCapture.qml");
    let helper = if installed.is_file() {
        installed
    } else {
        std::env::current_dir()?.join("plugin/WindowCapture.qml")
    };
    if !helper.is_file() {
        return Err(err(
            "WindowCapture.qml is missing; install the current plugin",
        ));
    }
    let output = std::process::Command::new("timeout")
        .args(["12", "qs", "-p"])
        .arg(helper)
        .env("OMASHOT_WINDOW_ADDRESS", address)
        .env("OMASHOT_WINDOW_OUTPUT", dest)
        .env("OMASHOT_WINDOW_CURSOR", if cursor { "1" } else { "0" })
        .output()?;
    if !output.status.success() || !dest.is_file() {
        return Err(err(&format!(
            "Isolated window capture unavailable: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let report = stdout
        .lines()
        .find_map(|line| line.split_once("CAPTURE_SOURCE=").map(|(_, json)| json));
    Ok(report
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or(json!({})))
}
pub fn selected_window(geometry: &str) -> Result<String> {
    let (x, y, w, h) = parse_geometry(geometry)?;
    let clients: Value = serde_json::from_str(&run("hyprctl", &strings(&["-j", "clients"]))?)?;
    let mut found = clients
        .as_array()
        .ok_or_else(|| err("Invalid clients"))?
        .iter()
        .filter(|c| {
            c["visible"].as_bool().unwrap_or(true)
                && c["mapped"].as_bool().unwrap_or(true)
                && c["at"][0].as_i64() == Some(x)
                && c["at"][1].as_i64() == Some(y)
                && c["size"][0].as_u64() == Some(w as u64)
                && c["size"][1].as_u64() == Some(h as u64)
        })
        .collect::<Vec<_>>();
    found.sort_by_key(|c| c["focusHistoryID"].as_u64().unwrap_or(u64::MAX));
    found
        .first()
        .and_then(|c| c["address"].as_str())
        .map(str::to_owned)
        .ok_or_else(|| err("The selected window moved or closed; select it again"))
}
pub fn parse_geometry(g: &str) -> Result<(i64, i64, u32, u32)> {
    let (origin, size) = g
        .trim()
        .split_once(' ')
        .ok_or_else(|| err("Geometry must be x,y wxh"))?;
    let (x, y) = origin
        .split_once(',')
        .ok_or_else(|| err("Geometry needs x,y"))?;
    let (w, h) = size
        .trim()
        .split_once('x')
        .ok_or_else(|| err("Geometry needs width x height"))?;
    let result = (x.parse()?, y.parse()?, w.parse()?, h.parse()?);
    if result.2 == 0 || result.3 == 0 || result.2 as u64 * result.3 as u64 > 100_000_000 {
        return Err(err("Invalid capture size"));
    }
    Ok(result)
}
pub fn save(path: &str, geometry: &str) -> Result<Value> {
    let p = owned(path)?;
    let snapshot: Value = serde_json::from_slice(&fs::read(p.with_extension("json"))?)?;
    let (x, y, w, h) = parse_geometry(geometry)?;
    let ox = snapshot["originX"]
        .as_f64()
        .ok_or_else(|| err("Invalid frozen screenshot metadata"))?;
    let oy = snapshot["originY"]
        .as_f64()
        .ok_or_else(|| err("Invalid frozen screenshot metadata"))?;
    let scale = snapshot["scale"]
        .as_f64()
        .ok_or_else(|| err("Invalid frozen screenshot scale"))?;
    let left = ((x as f64 - ox) * scale).floor();
    let top = ((y as f64 - oy) * scale).floor();
    let right = ((x as f64 + w as f64 - ox) * scale).ceil();
    let bottom = ((y as f64 + h as f64 - oy) * scale).ceil();
    let img = image::open(&p)?.to_rgba8();
    if left < 0. || top < 0. || right > img.width() as f64 || bottom > img.height() as f64 {
        return Err(err("Selected area is outside frozen desktop"));
    }
    let format = config()["format"].as_str().unwrap_or("png").to_string();
    let dest =
        unique("capture").with_extension(if ["jpg", "jpeg", "webp"].contains(&format.as_str()) {
            &format
        } else {
            "png"
        });
    let crop = image::imageops::crop_imm(
        &img,
        left as u32,
        top as u32,
        (right - left) as u32,
        (bottom - top) as u32,
    )
    .to_image();
    if ["jpg", "jpeg"].contains(&format.as_str()) {
        image::DynamicImage::ImageRgba8(crop)
            .to_rgb8()
            .save(&dest)?;
    } else {
        crop.save(&dest)?;
    }
    cancel(path)?;
    meta(&dest)
}
pub fn cancel(path: &str) -> Result<Value> {
    let p = owned(path)?;
    fs::remove_file(p.with_extension("json"))?;
    fs::remove_file(p)?;
    Ok(json!({"ok":true}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn geometry_validation() {
        assert_eq!(
            parse_geometry("-120,20 500x300").unwrap(),
            (-120, 20, 500, 300)
        );
        assert!(parse_geometry("0,0 0x30").is_err());
        assert!(parse_geometry("0,0 999999x999999").is_err());
        assert!(parse_geometry("not geometry").is_err());
    }
}
