#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT
export HOME="$test_home" XDG_DATA_HOME="$test_home/.local/share" XDG_CONFIG_HOME="$test_home/.config"
mkdir -p "$HOME/.config/omarchy"
cat > "$HOME/.config/omarchy/shell.json" <<'JSON'
{"version":1,"idle":{"lock":987},"bar":{"position":"bottom","layout":{"right":[{"id":"omarchy.audio"}]}},"plugins":[{"id":"example.other","setting":42}]}
JSON
printf '#!/bin/sh\necho test-backend\n' > "$test_home/backend"
chmod +x "$test_home/backend"
"$repo/scripts/install.sh" --binary "$test_home/backend" --no-reload
"$repo/scripts/install.sh" --binary "$test_home/backend" --no-reload
python3 - <<'PY'
import json, pathlib
h=pathlib.Path.home()
c=json.loads((h/'.config/omarchy/shell.json').read_text())
assert c['idle']['lock']==987 and c['bar']['position']=='bottom'
assert c['plugins']==[{'id':'example.other','setting':42},{'id':'omashot'}]
assert len(list((h/'.config/omarchy').glob('shell.json.omashot-backup-*')))==2
assert (h/'.local/bin/omashot').stat().st_mode & 0o111
assert (h/'.config/omarchy/plugins/omashot/manifest.json').is_file()
assert c['bar']['layout']['right']==[{'id':'omashot'},{'id':'omarchy.audio'}]
c['bar']['layout']['right']=[{'id':'omarchy.audio'}]
(h/'.config/omarchy/shell.json').write_text(json.dumps(c))
PY
# A bar icon the user removed stays removed on updates.
"$repo/scripts/install.sh" --binary "$test_home/backend" --no-reload
python3 - <<'PY'
import json, pathlib
p=pathlib.Path.home()/'.config/omarchy/shell.json';c=json.loads(p.read_text())
assert c['bar']['layout']['right']==[{'id':'omarchy.audio'}]
c['bar']['layout']['right'].append('omashot');p.write_text(json.dumps(c))
PY
# Added QML types must restart the cached host once; an update without QML changes only rescans.
mkdir -p "$test_home/update-bin"
cat > "$test_home/update-bin/omarchy" <<'MOCK'
#!/usr/bin/env bash
printf 'omarchy %s\n' "$*" >> "$TEST_UPDATE_LOG"
MOCK
cat > "$test_home/update-bin/omarchy-shell" <<'MOCK'
#!/usr/bin/env bash
printf 'shell %s\n' "$*" >> "$TEST_UPDATE_LOG"
MOCK
chmod +x "$test_home/update-bin/omarchy" "$test_home/update-bin/omarchy-shell"
python3 - <<'PY_CACHE'
import json,pathlib
h=pathlib.Path.home();receipt=h/'.local/share/omashot/install.json'
v=json.loads(receipt.read_text());file=h/'.config/omarchy/plugins/omashot/Retention.qml'
del v['files'][str(file)];file.unlink();receipt.write_text(json.dumps(v))
PY_CACHE
export TEST_UPDATE_LOG="$test_home/update.log"
PATH="$test_home/update-bin:$PATH" "$repo/scripts/install.sh" --binary "$test_home/backend"
PATH="$test_home/update-bin:$PATH" "$repo/scripts/install.sh" --binary "$test_home/backend"
[[ $(grep -Ec '^omarchy restart shell$' "$TEST_UPDATE_LOG") == 1 ]]
[[ $(grep -Ec '^shell shell rescanPlugins$' "$TEST_UPDATE_LOG") == 2 ]]
# A new qmldir registers types/singletons (Theme), so it restarts the host too.
python3 - <<'PY_QMLDIR'
import json,pathlib
h=pathlib.Path.home();receipt=h/'.local/share/omashot/install.json'
v=json.loads(receipt.read_text());file=h/'.config/omarchy/plugins/omashot/qmldir'
del v['files'][str(file)];file.unlink();receipt.write_text(json.dumps(v))
PY_QMLDIR
PATH="$test_home/update-bin:$PATH" "$repo/scripts/install.sh" --binary "$test_home/backend"
[[ $(grep -Ec '^omarchy restart shell$' "$TEST_UPDATE_LOG") == 2 ]]
[[ -f "$HOME/.config/omarchy/plugins/omashot/qmldir" && -f "$HOME/.config/omarchy/plugins/omashot/Theme.qml" ]]
# Singletons outlive a plugin rescan, so an updated Theme.qml restarts the host as well.
python3 - <<'PY_SINGLETON'
import hashlib,json,pathlib
h=pathlib.Path.home();receipt=h/'.local/share/omashot/install.json'
v=json.loads(receipt.read_text());file=h/'.config/omarchy/plugins/omashot/Theme.qml'
file.write_text(file.read_text()+'// older release\n');v['files'][str(file)]=hashlib.sha256(file.read_bytes()).hexdigest();receipt.write_text(json.dumps(v))
PY_SINGLETON
PATH="$test_home/update-bin:$PATH" "$repo/scripts/install.sh" --binary "$test_home/backend"
[[ $(grep -Ec '^omarchy restart shell$' "$TEST_UPDATE_LOG") == 3 ]]
cmp -s "$repo/plugin/Theme.qml" "$HOME/.config/omarchy/plugins/omashot/Theme.qml"
# A rescan keeps the host's cached Editor type, so any changed QML component restarts the host too.
python3 - <<'PY_COMPONENT'
import hashlib,json,pathlib
h=pathlib.Path.home();receipt=h/'.local/share/omashot/install.json'
v=json.loads(receipt.read_text());file=h/'.config/omarchy/plugins/omashot/Editor.qml'
file.write_text(file.read_text()+'// older release\n');v['files'][str(file)]=hashlib.sha256(file.read_bytes()).hexdigest();receipt.write_text(json.dumps(v))
PY_COMPONENT
PATH="$test_home/update-bin:$PATH" "$repo/scripts/install.sh" --binary "$test_home/backend"
[[ $(grep -Ec '^omarchy restart shell$' "$TEST_UPDATE_LOG") == 4 ]]
cmp -s "$repo/plugin/Editor.qml" "$HOME/.config/omarchy/plugins/omashot/Editor.qml"

# Capture data and unrelated files must survive uninstall. Modified installed code survives too.
mkdir -p "$XDG_DATA_HOME/omashot"
printf 'capture' > "$XDG_DATA_HOME/omashot/capture.png"
printf 'custom' > "$HOME/.config/omarchy/plugins/omashot/user-note.txt"
printf '\n// local edit\n' >> "$HOME/.config/omarchy/plugins/omashot/Main.qml"
if "$repo/scripts/install.sh" --binary "$test_home/backend" --no-reload; then echo 'FAIL: overwrite of local edit accepted' >&2; exit 1; fi
# Uninstall removes only the shortcut block OmaShot Preferences added to hypr/bindings.lua.
mkdir -p "$HOME/.config/hypr"
printf -- '-- mine\no.bind("SUPER + B", "Browser", "chromium")\n\n-- BEGIN OMASHOT (managed by OmaShot Preferences)\npcall(dofile, "%s")\n-- END OMASHOT\n' "$HOME/.config/omashot/hyprland-bindings.lua" > "$HOME/.config/hypr/bindings.lua"
"$repo/scripts/uninstall.sh" --no-reload
[[ $(cat "$HOME/.config/hypr/bindings.lua") == $'-- mine\no.bind("SUPER + B", "Browser", "chromium")' ]]
python3 - <<'PY'
import json, pathlib
h=pathlib.Path.home()
c=json.loads((h/'.config/omarchy/shell.json').read_text())
assert c['plugins']==[{'id':'example.other','setting':42}]
assert c['bar']['layout']['right']==[{'id':'omarchy.audio'}]
assert c['idle']['lock']==987 and c['bar']['position']=='bottom'
assert not (h/'.local/bin/omashot').exists()
assert not (h/'.local/bin/omashot-ui').exists()
assert (h/'.config/omarchy/plugins/omashot/Main.qml').is_file()
assert (h/'.config/omarchy/plugins/omashot/user-note.txt').read_text()=='custom'
assert (h/'.local/share/omashot/capture.png').read_text()=='capture'
PY
# Fresh installation must not overwrite arbitrary binaries.
printf 'unowned' > "$HOME/.local/bin/omashot"
if "$repo/scripts/install.sh" --binary "$test_home/backend" --no-reload; then echo 'FAIL: unowned collision accepted' >&2; exit 1; fi
[[ $(cat "$HOME/.local/bin/omashot") == unowned ]]
# Malformed configuration must not be replaced.
printf '{invalid' > "$HOME/.config/omarchy/shell.json"
if "$repo/scripts/install.sh" --binary "$test_home/backend" --no-reload; then echo 'FAIL: malformed config accepted' >&2; exit 1; fi
[[ $(cat "$HOME/.config/omarchy/shell.json") == '{invalid' ]]
# Launcher must distinguish a successful host summon from an unknown plugin and route modes.
mkdir -p "$test_home/mock-bin"
cat > "$test_home/mock-bin/omarchy-shell" <<'MOCK'
#!/usr/bin/env bash
printf 'host %s\n' "$*" >> "$TEST_LOG"
if [[ $1 == shell ]]; then echo "$TEST_HOST"; fi
if [[ $1 == omashot && $2 == status ]]; then
  count=0
  [[ ! -f $TEST_READY_COUNT ]] || read -r count < "$TEST_READY_COUNT"
  count=$((count+1));printf '%s\n' "$count" > "$TEST_READY_COUNT"
  if ((count==1));then echo 'Target not found.';exit 1;fi
  echo '{"opened":false}'
fi
MOCK
cat > "$test_home/mock-bin/qs" <<'MOCK'
#!/usr/bin/env bash
printf 'standalone %s\n' "$*" >> "$TEST_LOG"
exit 0
MOCK
chmod +x "$test_home/mock-bin/omarchy-shell" "$test_home/mock-bin/qs"
export PATH="$test_home/mock-bin:$PATH" TEST_LOG="$test_home/launcher.log" TEST_HOST=ok TEST_READY_COUNT="$test_home/ready-count"
"$repo/scripts/omashot-ui" fullscreen
grep -Eq '^host omashot capture fullscreen$' "$TEST_LOG"
grep -Fqx 'host shell summon omashot {"mode":"fullscreen"}' "$TEST_LOG"
[[ $(grep -Ec '^host omashot status$' "$TEST_LOG") == 2 ]]
"$repo/scripts/omashot-ui" history
grep -Eq '^host omashot history$' "$TEST_LOG"
"$repo/scripts/omashot-ui" preferences
grep -Eq '^host omashot preferences$' "$TEST_LOG"
"$repo/scripts/omashot-ui" scroll
grep -Eq '^host omashot capture scroll$' "$TEST_LOG"
export TEST_HOST=unknown
"$repo/scripts/omashot-ui" region
grep -Eq 'standalone ipc -p .*/plugin call omashot capture region$' "$TEST_LOG"
! grep -Eq 'call omashot open$' "$TEST_LOG"
"$repo/scripts/omashot-ui" history
grep -Eq 'standalone ipc -p .*/plugin call omashot history$' "$TEST_LOG"
echo 'PASS: isolated installation, updates, ownership, config preservation, uninstall and launcher routing' 
