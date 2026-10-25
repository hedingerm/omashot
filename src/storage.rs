use crate::{Result, err, meta, original_path};
use serde_json::{Value, json};
use std::{
    fs,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
fn numeric_id(id: &str) -> bool {
    let Some((time, pid)) = id.rsplit_once('-') else {
        return false;
    };
    !time.is_empty()
        && !pid.is_empty()
        && time.chars().all(|c| c.is_ascii_digit())
        && pid.chars().all(|c| c.is_ascii_digit())
}
pub fn managed_name(name: &str) -> bool {
    let Some((stem, ext)) = name.rsplit_once('.') else {
        return false;
    };
    if !["png", "jpg", "jpeg", "webp"].contains(&ext) {
        return false;
    }
    ["capture-", "import-", "edited-", "scroll-"]
        .iter()
        .any(|prefix| stem.strip_prefix(prefix).is_some_and(numeric_id))
}
fn expired(modified: u64, now: u64, days: u64) -> bool {
    days > 0 && now.saturating_sub(modified) >= days.min(3650) * 86400
}
fn age(path: &Path, now: u64) -> u64 {
    let secs = fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(now);
    now.saturating_sub(secs)
}
pub fn asset_dir(p: &Path) -> std::path::PathBuf {
    p.with_file_name(format!(
        ".{}.assets",
        p.file_name().unwrap_or_default().to_string_lossy()
    ))
}
pub fn remove_capture(p: &Path) -> Result<()> {
    fs::remove_file(p)?;
    let _ = fs::remove_file(p.with_extension("project.json"));
    let _ = fs::remove_file(original_path(p));
    let assets = asset_dir(p);
    if assets.is_dir() && !assets.is_symlink() {
        fs::remove_dir_all(assets)?;
    }
    Ok(())
}
pub fn cleanup(dir: &Path, days: u64, now: u64) -> Result<usize> {
    let mut removed = 0;
    for entry in fs::read_dir(dir)? {
        let p = entry?.path();
        let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !p.is_file() {
            continue;
        }
        if managed_name(name) {
            let modified = now.saturating_sub(age(&p, now));
            if expired(modified, now, days) {
                remove_capture(&p)?;
                removed += 1;
            }
            continue;
        }
        if age(&p, now) < 86400 {
            continue;
        }
        let temporary = [
            ".preview-",
            ".render-",
            ".scroll-frame-",
            ".scroll-",
            ".frozen-",
        ]
        .iter()
        .any(|prefix| {
            name.strip_prefix(prefix)
                .and_then(|s| s.rsplit_once('.'))
                .is_some_and(|(id, ext)| numeric_id(id) && ["png", "json"].contains(&ext))
        });
        let orphan_source = name
            .strip_prefix('.')
            .and_then(|s| s.strip_suffix(".source.png"))
            .is_some_and(|base| managed_name(base) && !dir.join(base).exists());
        let orphan_project = name.strip_suffix(".project.json").is_some_and(|stem| {
            ["png", "jpg", "jpeg", "webp"]
                .iter()
                .any(|ext| managed_name(&format!("{stem}.{ext}")))
                && !["png", "jpg", "jpeg", "webp"]
                    .iter()
                    .any(|ext| dir.join(format!("{stem}.{ext}")).exists())
        });
        if temporary || orphan_source || orphan_project {
            fs::remove_file(&p)?;
            removed += 1;
        }
    }
    Ok(removed)
}
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn references(v: &Value, path: &str) -> bool {
    match v {
        Value::String(s) => s == path,
        Value::Array(a) => a.iter().any(|v| references(v, path)),
        Value::Object(o) => o.values().any(|v| references(v, path)),
        _ => false,
    }
}
pub fn wallpaper(args: &[String], dir: &Path, config: &Value) -> Result<Value> {
    let wall = dir.join("wallpapers");
    fs::create_dir_all(&wall)?;
    match crate::argument(args, 1)? {
        "import" => {
            let p = crate::checked(crate::argument(args, 2)?)?;
            let dest = wall.join(crate::unique("wallpaper").file_name().unwrap());
            image::open(&p)?.save(&dest)?;
            let name = p
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            fs::write(
                dest.with_extension("json"),
                serde_json::to_vec(&json!({"name":name}))?,
            )?;
            let mut v = meta(&dest)?;
            v["name"] = json!(name);
            Ok(v)
        }
        "list" => {
            let mut out = Vec::new();
            for entry in fs::read_dir(&wall)? {
                let p = entry?.path();
                if p.extension().and_then(|s| s.to_str()) != Some("png") {
                    continue;
                }
                if let Ok(mut v) = meta(&p) {
                    let label: Value = fs::read(p.with_extension("json"))
                        .ok()
                        .and_then(|b| serde_json::from_slice(&b).ok())
                        .unwrap_or(json!({}));
                    v["name"] = label["name"].clone();
                    out.push(v);
                }
            }
            out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
            Ok(json!(out))
        }
        "delete" => {
            let p = crate::checked(crate::argument(args, 2)?)?;
            let expected = fs::canonicalize(&wall)?;
            let filename = p.file_name().unwrap_or_default().to_string_lossy();
            if p.parent() != Some(expected.as_path())
                || !filename
                    .strip_prefix("wallpaper-")
                    .and_then(|s| s.strip_suffix(".png"))
                    .is_some_and(numeric_id)
            {
                return Err(err("Only imported wallpapers may be deleted"));
            }
            let path = p.to_string_lossy();
            if references(config, &path) {
                return Err(err("Wallpaper is used by a saved style"));
            }
            for entry in fs::read_dir(dir)? {
                let p = entry?.path();
                if p.to_string_lossy().ends_with(".project.json")
                    && let Ok(v) = fs::read(&p).and_then(|b| {
                        serde_json::from_slice::<Value>(&b).map_err(std::io::Error::other)
                    })
                    && references(&v, &path)
                {
                    return Err(err("Wallpaper is used by an editable project"));
                }
            }
            fs::remove_file(&p)?;
            let _ = fs::remove_file(p.with_extension("json"));
            Ok(json!({"ok":true}))
        }
        _ => Err(err("Expected wallpaper import PATH, list, or delete PATH")),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::FileTimes;
    fn dir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "omashot-cleanup-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&d).unwrap();
        d
    }
    fn old(p: &Path, age: u64, now: u64) {
        fs::write(p, b"fixture").unwrap();
        fs::File::options()
            .write(true)
            .open(p)
            .unwrap()
            .set_times(
                FileTimes::new()
                    .set_modified(UNIX_EPOCH + std::time::Duration::from_secs(now - age)),
            )
            .unwrap();
    }
    #[test]
    fn expiry_boundaries_and_owned_files() {
        assert!(!expired(100, 100 + 86400 - 1, 1));
        assert!(expired(100, 100 + 86400, 1));
        assert!(!expired(100, u64::MAX, 0));
        assert!(!managed_name("capture-not-owned.png"));
        assert!(managed_name("edited-123-4.webp"));
        let d = dir();
        let now = 2_000_000_000;
        old(&d.join("capture-123-4.png"), 86400, now);
        old(&d.join("capture-123-4.project.json"), 86400, now);
        old(&d.join(".capture-123-4.png.source.png"), 86400, now);
        old(&d.join("capture-124-4.png"), 86399, now);
        old(&d.join("keep.png"), 999999, now);
        old(&d.join(".preview-125-4.png"), 86400, now);
        old(&d.join(".scroll-126-4.json"), 86400, now);
        old(&d.join(".scroll-126-4.png"), 86400, now);
        cleanup(&d, 1, now).unwrap();
        assert!(!d.join("capture-123-4.png").exists());
        assert!(!d.join("capture-123-4.project.json").exists());
        assert!(!d.join(".capture-123-4.png.source.png").exists());
        assert!(d.join("capture-124-4.png").exists());
        assert!(d.join("keep.png").exists());
        assert!(!d.join(".preview-125-4.png").exists());
        assert!(!d.join(".scroll-126-4.json").exists());
        assert!(!d.join(".scroll-126-4.png").exists());
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn imported_wallpaper_is_durable_and_delete_is_owned() {
        let d = dir();
        let original = d.join("original.png");
        image::RgbaImage::from_pixel(10, 10, image::Rgba([1, 2, 3, 255]))
            .save(&original)
            .unwrap();
        let imported = wallpaper(
            &crate::strings(&["wallpaper", "import", &original.to_string_lossy()]),
            &d,
            &json!({}),
        )
        .unwrap();
        let path = imported["path"].as_str().unwrap();
        fs::remove_file(&original).unwrap();
        assert_eq!(image::image_dimensions(path).unwrap(), (10, 10));
        assert!(
            wallpaper(
                &crate::strings(&["wallpaper", "delete", path]),
                &d,
                &json!({"background_presets":[{"image_path":path}]})
            )
            .is_err()
        );
        fs::write(
            d.join("edited-123-4.project.json"),
            serde_json::to_vec(&json!({"operations":[{"type":"background","image_path":path}]}))
                .unwrap(),
        )
        .unwrap();
        assert!(
            wallpaper(
                &crate::strings(&["wallpaper", "delete", path]),
                &d,
                &json!({})
            )
            .is_err()
        );
        fs::remove_file(d.join("edited-123-4.project.json")).unwrap();
        assert_eq!(
            wallpaper(&crate::strings(&["wallpaper", "list"]), &d, &json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        wallpaper(
            &crate::strings(&["wallpaper", "delete", path]),
            &d,
            &json!({}),
        )
        .unwrap();
        assert!(!Path::new(path).exists());
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn unlimited_history_preserves_old_images() {
        let d = dir();
        let now = 2_000_000_000;
        old(&d.join("capture-123-4.png"), 86400 * 100, now);
        cleanup(&d, 0, now).unwrap();
        assert!(d.join("capture-123-4.png").exists());
        fs::remove_dir_all(d).unwrap();
    }
}
