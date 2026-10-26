// Global shortcuts for Omarchy 4's Lua Hyprland config. OmaShot owns a generated file plus one
// marked block in hypr/bindings.lua that loads it; nothing else in the user's config is edited.
use crate::{Result, err, run, strings};
use serde_json::{Map, Value, json};
use std::{env, fs, path::PathBuf};

pub const ACTIONS: [(&str, &str); 9] = [
    ("open", "OmaShot launcher"),
    ("region", "OmaShot area"),
    ("window", "OmaShot window"),
    ("active", "OmaShot active window"),
    ("fullscreen", "OmaShot fullscreen"),
    ("repeat", "OmaShot repeat area"),
    ("history", "OmaShot history"),
    ("ocr", "OmaShot text recognition"),
    ("qr", "OmaShot QR code"),
];
// Hyprland modmask bits, in the order chords are written.
const MODS: [(&str, u64); 4] = [("SUPER", 64), ("CTRL", 4), ("ALT", 8), ("SHIFT", 1)];
const BEGIN: &str = "-- BEGIN OMASHOT";
const END: &str = "-- END OMASHOT";

fn config_root() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".config"))
}
fn hypr_bindings() -> PathBuf {
    config_root().join("hypr/bindings.lua")
}
fn state_path() -> PathBuf {
    config_root().join("omashot/keybindings.json")
}
fn lua_path() -> PathBuf {
    config_root().join("omashot/hyprland-bindings.lua")
}
fn lua_safe(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "/._- +:".contains(c))
}

/// Parses "super + shift + s" into ("SUPER + SHIFT + S", modmask, key).
pub fn parse_chord(s: &str) -> Result<(String, u64, String)> {
    let parts: Vec<&str> = s.split('+').map(str::trim).collect();
    if parts.len() > 5 || parts.iter().any(|p| p.is_empty()) {
        return Err(err(&format!("Invalid shortcut: {s}")));
    }
    let (key, mods) = parts.split_last().unwrap();
    let mut mask = 0;
    for m in mods {
        mask |= match m.to_ascii_uppercase().as_str() {
            "SUPER" | "WIN" | "LOGO" | "META" | "MOD4" => 64,
            "CTRL" | "CONTROL" => 4,
            "ALT" | "MOD1" => 8,
            "SHIFT" => 1,
            _ => return Err(err(&format!("Unknown modifier {m} in {s}"))),
        };
    }
    let code = key
        .strip_prefix("code:")
        .is_some_and(|n| (1..=3).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_digit()));
    if !code
        && (key.len() > 32
            || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            || ["SUPER", "CTRL", "CONTROL", "ALT", "SHIFT"]
                .contains(&key.to_ascii_uppercase().as_str()))
    {
        return Err(err(&format!("Invalid key {key} in {s}")));
    }
    let key = if key.len() == 1 {
        key.to_ascii_uppercase()
    } else {
        key.to_string()
    };
    Ok((chord(mask, &key), mask, key))
}
fn chord(mask: u64, key: &str) -> String {
    let mut parts: Vec<&str> = MODS
        .iter()
        .filter(|(_, bit)| mask & bit != 0)
        .map(|(name, _)| *name)
        .collect();
    parts.push(key);
    parts.join(" + ")
}
fn same(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}
fn read_state() -> Value {
    fs::read(state_path())
        .ok()
        .and_then(|v| serde_json::from_slice::<Value>(&v).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({"bindings":{},"replaced":{}}))
}
// Every global bind Hyprland currently has, as canonical chords, without OmaShot's own.
fn hypr_binds() -> Option<Vec<Value>> {
    let binds: Value =
        serde_json::from_str(&run("hyprctl", &strings(&["-j", "binds"])).ok()?).ok()?;
    Some(
        binds
            .as_array()?
            .iter()
            .filter_map(|b| {
                let mask = b["modmask"].as_u64()?;
                if mask & !(64 | 4 | 8 | 1) != 0
                    || b["mouse"].as_bool().unwrap_or(false)
                    || !b["submap"].as_str().unwrap_or("").is_empty()
                {
                    return None;
                }
                let key = match b["key"].as_str().unwrap_or("") {
                    "" => format!("code:{}", b["keycode"].as_u64().filter(|c| *c > 0)?),
                    k if k.len() == 1 => k.to_ascii_uppercase(),
                    k => k.to_string(),
                };
                Some(json!({
                    "keys": chord(mask, &key),
                    "description": b["description"].as_str().unwrap_or(""),
                    "command": format!("{} {}", b["dispatcher"].as_str().unwrap_or(""), b["arg"].as_str().unwrap_or("")).trim(),
                }))
            })
            .collect(),
    )
}
fn launcher() -> String {
    // The installer puts omashot-ui next to the backend; fall back to PATH (development builds).
    env::current_exe()
        .ok()
        .and_then(|p| Some(p.parent()?.join("omashot-ui")))
        .filter(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
        .filter(|p| lua_safe(p) && !p.contains(' '))
        .unwrap_or_else(|| "omashot-ui".into())
}
fn status() -> Value {
    let state = read_state();
    let hook = fs::read_to_string(hypr_bindings()).ok();
    let mut v = json!({
        "available": hook.is_some(),
        "installed": hook.as_deref().is_some_and(|t| t.contains(BEGIN)),
        "actions": ACTIONS.iter().map(|(id, label)| json!({"id":id,"label":label})).collect::<Vec<_>>(),
        "bindings": state["bindings"],
        "replaced": state["replaced"],
        "taken": [],
        "hyprland": false,
        "file": hypr_bindings(),
    });
    if hook.is_none() {
        v["reason"] = json!(format!(
            "Shortcuts need Omarchy 4's Lua config ({} not found)",
            hypr_bindings().display()
        ));
    }
    if let Some(binds) = hypr_binds() {
        v["hyprland"] = json!(true);
        v["taken"] = json!(
            binds
                .into_iter()
                .filter(|b| !b["command"].as_str().unwrap_or("").contains("omashot-ui"))
                .collect::<Vec<_>>()
        );
    }
    v
}
fn write_hook(enabled: bool) -> Result<()> {
    let path = hypr_bindings();
    let text = fs::read_to_string(&path)?;
    let mut kept = String::new();
    let mut inside = false;
    for line in text.lines() {
        if line.starts_with(BEGIN) {
            inside = true;
        } else if inside && line.trim_end() == END {
            inside = false;
        } else if !inside {
            kept.push_str(line);
            kept.push('\n');
        }
    }
    if inside {
        return Err(err(&format!(
            "Unterminated OmaShot block in {}",
            path.display()
        )));
    }
    if enabled {
        let lua = lua_path().to_string_lossy().into_owned();
        if !lua_safe(&lua) {
            return Err(err("Config path contains characters unsafe for Lua"));
        }
        // pcall keeps Hyprland's config loading if the generated file is removed by hand.
        if !kept.is_empty() && !kept.ends_with("\n\n") {
            kept.push('\n');
        }
        kept.push_str(&format!(
            "{BEGIN} (managed by OmaShot Preferences)\npcall(dofile, \"{lua}\")\n{END}\n"
        ));
    }
    let kept = if enabled {
        kept
    } else {
        kept.trim_end().to_string() + "\n"
    };
    if kept != text {
        // fs::write keeps a symlinked bindings.lua (dotfile managers) pointing at its target.
        fs::write(&path, kept)?;
    }
    Ok(())
}
fn reload() -> Value {
    match run("hyprctl", &strings(&["reload"])) {
        Ok(_) => json!(true),
        Err(_) => json!(false),
    }
}

pub fn command(a: &[String]) -> Result<Value> {
    match a.get(1).map(String::as_str) {
        None => Ok(status()),
        Some("remove") => {
            if hypr_bindings().exists() {
                write_hook(false)?;
            }
            let _ = fs::remove_file(lua_path());
            let mut v = status();
            v["reloaded"] = reload();
            Ok(v)
        }
        Some("set") => {
            let wanted: Value =
                serde_json::from_str(a.get(2).ok_or_else(|| err("Missing bindings JSON"))?)?;
            let wanted = wanted
                .as_object()
                .ok_or_else(|| err("Bindings must be an object"))?;
            if !hypr_bindings().exists() {
                return Err(err(status()["reason"]
                    .as_str()
                    .unwrap_or("Hyprland bindings.lua missing")));
            }
            let mut bindings = Map::new();
            for (id, keys) in wanted {
                if !ACTIONS.iter().any(|(a, _)| a == id) {
                    return Err(err(&format!("Unknown shortcut action: {id}")));
                }
                let keys = keys
                    .as_str()
                    .ok_or_else(|| err("Shortcuts must be strings"))?;
                if keys.trim().is_empty() {
                    continue;
                }
                let canonical = parse_chord(keys)?.0;
                if let Some((other, _)) = bindings
                    .iter()
                    .find(|(_, v)| same(v.as_str().unwrap_or(""), &canonical))
                {
                    return Err(err(&format!(
                        "{canonical} is used for both {other} and {id}"
                    )));
                }
                bindings.insert(id.clone(), json!(canonical));
            }
            let old = read_state();
            let taken = status()["taken"].clone();
            let mut replaced = Map::new();
            for (id, keys) in &bindings {
                let keys = keys.as_str().unwrap_or("");
                let hit = taken
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|b| same(b["keys"].as_str().unwrap_or(""), keys));
                let description = match hit {
                    Some(b) => json!(match b["description"].as_str().unwrap_or("") {
                        "" => b["command"].clone(),
                        d => json!(d),
                    }),
                    // A replaced default no longer shows in Hyprland's list after the first save.
                    None if same(old["bindings"][id].as_str().unwrap_or(""), keys) => {
                        old["replaced"][id].clone()
                    }
                    None => Value::Null,
                };
                if !description.is_null() {
                    replaced.insert(id.clone(), description);
                }
            }
            let launcher = launcher();
            let mut lua = String::from(
                "-- Generated by OmaShot Preferences; changes made here are overwritten.\n",
            );
            for (id, label) in ACTIONS {
                if let Some(keys) = bindings.get(id).and_then(Value::as_str) {
                    // Unbinding first replaces an existing bind instead of firing both.
                    lua.push_str(&format!(
                        "hl.unbind(\"{keys}\")\no.bind(\"{keys}\", \"{label}\", \"{launcher} {id}\")\n"
                    ));
                }
            }
            fs::create_dir_all(state_path().parent().unwrap())?;
            fs::write(
                state_path(),
                serde_json::to_vec_pretty(&json!({"bindings":bindings,"replaced":replaced}))?,
            )?;
            if bindings.is_empty() {
                let _ = fs::remove_file(lua_path());
            } else {
                fs::write(lua_path(), lua)?;
            }
            write_hook(!bindings.is_empty())?;
            let reloaded = reload();
            let mut v = status();
            v["reloaded"] = reloaded;
            // Verify against Hyprland itself: a bind missing after reload means the Lua failed.
            if let Some(binds) = hypr_binds() {
                let missing: Vec<&String> = bindings
                    .iter()
                    .filter(|(id, keys)| {
                        !binds.iter().any(|b| {
                            same(
                                b["keys"].as_str().unwrap_or(""),
                                keys.as_str().unwrap_or(""),
                            ) && b["command"]
                                .as_str()
                                .unwrap_or("")
                                .ends_with(&format!("omashot-ui {id}"))
                        })
                    })
                    .map(|(id, _)| id)
                    .collect();
                v["missing"] = json!(missing);
                v["configErrors"] =
                    json!(run("hyprctl", &strings(&["configerrors"])).unwrap_or_default());
            }
            Ok(v)
        }
        Some(other) => Err(err(&format!(
            "Expected bindings, bindings set JSON or bindings remove, got {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chords_are_canonical_and_validated() {
        assert_eq!(
            parse_chord("shift+super + s").unwrap(),
            ("SUPER + SHIFT + S".into(), 65, "S".into())
        );
        assert_eq!(parse_chord("Print").unwrap().0, "Print");
        assert_eq!(parse_chord("CTRL + ALT + code:107").unwrap().1, 12);
        for bad in [
            "",
            "SUPER +",
            "SUPER + HYPER + S",
            "SUPER + \"x",
            "SUPER + a b",
            "SUPER + SHIFT",
            "code:1234",
            "SUPER + S\")os.execute(\"x",
        ] {
            assert!(parse_chord(bad).is_err(), "{bad}");
        }
    }
}
