import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell.Io

Rectangle {
    id: root
    color: "#202330"
    property string backend: "omashot"
    property var customPresets: []
    property var wallpapers: []
    property var gradients: []
    property string sourcePath: ""
    property bool gradientsExpanded: true
    readonly property real tileSize: Math.floor((width - 28 - 32) / 5)
    readonly property var blurredSources: {
        let choices = [];
        if (wallpapers.length)
            choices.push({
                path: wallpapers[0].path,
                name: wallpapers[0].name || "Wallpaper",
                blur: 24,
                source: false
            });
        if (sourcePath) {
            let levels = choices.length ? [20, 52] : [12, 28, 56];
            levels.forEach(function (level) {
                choices.push({
                    path: sourcePath,
                    name: "Screenshot",
                    blur: level,
                    source: true
                });
            });
        }
        return choices.slice(0, 3);
    }
    property bool backgroundEnabled: false
    property bool restoring: false
    property var settings: defaults()
    property string message: ""
    signal changed(var operation)
    signal presetsChanged(var presets)
    signal error(string message)

    function defaults() {
        return {
            type: "background",
            mode: "gradient",
            preset: 0,
            gradient_version: 2,
            background_color: "#6366f1",
            padding: 64,
            inset: 0,
            inset_color: "#ffffff",
            radius: 16,
            shadow: true,
            shadow_strength: 0.35,
            shadow_blur: 18,
            shadow_offset: 8,
            blur: 0,
            alignment: "center",
            auto_balance: true,
            aspect_ratio: 0,
            image_path: ""
        };
    }
    function restore(operation) {
        restoring = true;
        var next = defaults();
        if (operation)
            Object.keys(operation).forEach(function (key) {
                next[key] = operation[key];
            });
        if (operation && operation.gradient_version === undefined)
            next.gradient_version = 1;
        settings = next;
        backgroundEnabled = !!operation;
        restoring = false;
    }
    function update(key, value) {
        var next = Object.assign({}, settings);
        next[key] = value;
        if (key === "mode" && value === "blurred" && next.blur === 0)
            next.blur = 24;
        settings = next;
        backgroundEnabled = true;
        if (!restoring)
            changed(Object.assign({}, settings));
    }
    function selectGradient(index) {
        var next = Object.assign({}, settings);
        next.mode = "gradient";
        next.preset = index;
        next.gradient_version = 2;
        next.blur = 0;
        settings = next;
        backgroundEnabled = true;
        changed(next);
    }
    function disable() {
        backgroundEnabled = false;
        changed(null);
    }
    function saveStyle(name) {
        if (!backgroundEnabled || !name.trim())
            return;
        presetsChanged(customPresets.concat([Object.assign({
                name: name.trim().slice(0, 60)
            }, settings)]));
    }
    function applyStyle(style) {
        var next = Object.assign({}, style);
        delete next.name;
        restore(next);
        changed(Object.assign({}, settings));
    }
    function run(args, kind) {
        if (wallpaperProcess.running)
            return;
        wallpaperProcess.kind = kind;
        wallpaperProcess.command = [backend].concat(args);
        wallpaperProcess.running = true;
    }
    function refreshWallpapers() {
        run(["wallpaper", "list"], "list");
    }
    Component.onCompleted: {
        refreshWallpapers();
        backgroundProbe.running = true;
    }
    Process {
        id: backgroundProbe
        command: [root.backend, "backgrounds"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let value = JSON.parse(text);
                    if (Array.isArray(value))
                        root.gradients = value;
                    else
                        root.message = value.error || "Could not load backgrounds";
                } catch (e) {
                    root.message = "Could not load background previews";
                }
            }
        }
    }
    function selectSolid(value) {
        let next = Object.assign({}, settings);
        next.mode = "solid";
        next.background_color = value;
        next.blur = 0;
        settings = next;
        backgroundEnabled = true;
        changed(next);
    }
    ColorDialog {
        id: backgroundColorPicker
        title: "Background color"
        onAccepted: {
            let color = selectedColor;
            let value = "#" + [color.r, color.g, color.b, color.a].map(function (c) {
                return Math.round(c * 255).toString(16).padStart(2, "0");
            }).join("");
            root.selectSolid(value);
        }
    }
    Process {
        id: wallpaperProcess
        property string kind: "list"
        property string result: ""
        property string stderrText: ""
        onStarted: {
            result = "";
            stderrText = "";
        }
        stdout: StdioCollector {
            onStreamFinished: wallpaperProcess.result = text
        }
        stderr: StdioCollector {
            onStreamFinished: wallpaperProcess.stderrText = text
        }
        onExited: function (code) {
            try {
                var value = JSON.parse(result);
                if (code !== 0)
                    throw new Error(value.error || stderrText || "Wallpaper operation failed");
                if (kind === "list")
                    root.wallpapers = value;
                else if (kind === "import") {
                    var next = Object.assign({}, root.settings);
                    next.mode = "wallpaper";
                    next.image_path = value.path;
                    next.blur = 0;
                    root.settings = next;
                    root.backgroundEnabled = true;
                    root.changed(next);
                    Qt.callLater(root.refreshWallpapers);
                } else
                    Qt.callLater(root.refreshWallpapers);
            } catch (e) {
                root.message = String(e);
                root.error(root.message);
            }
        }
    }
    FileDialog {
        id: wallpaperPicker
        title: "Add your wallpaper"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp)"]
        onAccepted: root.run(["wallpaper", "import", decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))], "import")
    }
    Dialog {
        id: savePreset
        title: "Save background style"
        modal: true
        anchors.centerIn: parent
        width: Math.min(300, root.width + 60)
        standardButtons: Dialog.Save | Dialog.Cancel
        onOpened: {
            presetName.text = "My style " + (root.customPresets.length + 1);
            presetName.forceActiveFocus();
            presetName.selectAll();
        }
        onAccepted: {
            root.saveStyle(presetName.text);
        }
        TextField {
            id: presetName
            width: parent.width
            selectByMouse: true
            placeholderText: "Style name"
            maximumLength: 60
        }
    }
    component Thumb: Item {
        id: thumb
        property string imageSource: ""
        property bool selected: false
        property string title: ""
        signal activated
        implicitWidth: root.tileSize
        implicitHeight: root.tileSize
        Accessible.role: Accessible.Button
        Accessible.name: title
        onImageSourceChanged: {
            if (imageSource)
                thumbnail.loadImage(imageSource);
            thumbnail.requestPaint();
        }
        Canvas {
            id: thumbnail
            anchors.fill: parent
            anchors.margins: 2
            antialiasing: true
            onImageLoaded: requestPaint()
            onPaint: {
                let c = getContext("2d"), r = 7, w = width, h = height;
                c.reset();
                c.beginPath();
                c.moveTo(r, 0);
                c.lineTo(w - r, 0);
                c.quadraticCurveTo(w, 0, w, r);
                c.lineTo(w, h - r);
                c.quadraticCurveTo(w, h, w - r, h);
                c.lineTo(r, h);
                c.quadraticCurveTo(0, h, 0, h - r);
                c.lineTo(0, r);
                c.quadraticCurveTo(0, 0, r, 0);
                c.closePath();
                c.clip();
                c.fillStyle = "#333747";
                c.fillRect(0, 0, w, h);
                if (thumb.imageSource && isImageLoaded(thumb.imageSource))
                    c.drawImage(thumb.imageSource, 0, 0, w, h);
            }
            Component.onCompleted: {
                if (thumb.imageSource)
                    loadImage(thumb.imageSource);
            }
        }
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: 10
            border.width: thumb.selected ? 2 : 1
            border.color: thumb.selected ? "#9d9aff" : "#4a4e60"
        }
        MouseArea {
            id: thumbMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: thumb.activated()
        }
        ToolTip.visible: thumbMouse.containsMouse
        ToolTip.text: title
        ToolTip.delay: 500
    }
    component Caption: Text {
        color: "#aeb6c9"
        font.pixelSize: 11
        font.weight: Font.Medium
        Layout.fillWidth: true
    }
    component SettingSlider: ColumnLayout {
        id: control
        property string label: ""
        property string suffix: "px"
        property real from: 0
        property real to: 100
        property real value: 0
        property real stepSize: 1
        signal moved(real value)
        spacing: 2
        Layout.fillWidth: true
        RowLayout {
            Layout.fillWidth: true
            Caption {
                text: control.label
            }
            Text {
                text: Math.round(control.value) + control.suffix
                color: "#7f899f"
                font.pixelSize: 10
            }
        }
        Slider {
            id: slide
            Layout.fillWidth: true
            implicitHeight: 22
            from: control.from
            to: control.to
            value: control.value
            stepSize: control.stepSize
            onMoved: control.moved(value)
            background: Rectangle {
                x: slide.leftPadding
                y: slide.topPadding + slide.availableHeight / 2 - 2
                width: slide.availableWidth
                height: 4
                radius: 2
                color: "#414757"
                Rectangle {
                    width: slide.visualPosition * parent.width
                    height: parent.height
                    radius: 2
                    color: "#8b87ff"
                }
            }
            handle: Rectangle {
                x: slide.leftPadding + slide.visualPosition * (slide.availableWidth - width)
                y: slide.topPadding + slide.availableHeight / 2 - height / 2
                width: 13
                height: 13
                radius: 6.5
                color: "#e6e6f2"
                border.color: "#9ca1b9"
            }
        }
    }
    ScrollView {
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: root.width - 28
            x: 14
            spacing: 14
            Item {
                Layout.preferredHeight: 1
            }
            RowLayout {
                Layout.fillWidth: true
                ComboBox {
                    id: presetPicker
                    palette.base: "#303542"
                    palette.text: "#d2d7e4"
                    palette.button: "#353a49"
                    palette.buttonText: "#b8c1d6"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    implicitHeight: 29
                    font.pixelSize: 10
                    model: ["Background presets"].concat(root.customPresets.map(function (p) {
                        return p.name || "Saved style";
                    }))
                    onActivated: function (index) {
                        if (!index)
                            return;
                        root.applyStyle(root.customPresets[index - 1]);
                    }
                }
                IconButton {
                    iconName: "trash"
                    text: "Delete selected preset"
                    size: 26
                    iconSize: 14
                    enabled: presetPicker.currentIndex > 0
                    onClicked: {
                        var next = root.customPresets.slice();
                        next.splice(presetPicker.currentIndex - 1, 1);
                        presetPicker.currentIndex = 0;
                        root.presetsChanged(next);
                    }
                }
                IconButton {
                    iconName: "plus"
                    text: "Save current style as preset"
                    size: 26
                    iconSize: 15
                    enabled: root.backgroundEnabled
                    onClicked: savePreset.open()
                }
            }
            Button {
                Layout.fillWidth: true
                implicitHeight: 30
                text: "None"
                font.pixelSize: 11
                checked: !root.backgroundEnabled
                checkable: true
                onClicked: root.disable()
                background: Rectangle {
                    radius: 5
                    color: !root.backgroundEnabled ? "#41415c" : "#303440"
                    border.color: !root.backgroundEnabled ? "#8980d9" : "transparent"
                }
                contentItem: Text {
                    text: "None"
                    color: "#d9dce8"
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 9
                RowLayout {
                    Layout.fillWidth: true
                    Caption {
                        text: "Gradients"
                    }
                    ToolButton {
                        text: root.gradientsExpanded ? "Show less" : "Show all"
                        font.pixelSize: 10
                        palette.buttonText: "#aeb6c9"
                        onClicked: root.gradientsExpanded = !root.gradientsExpanded
                        implicitHeight: 22
                        contentItem: Row {
                            spacing: 4
                            Text {
                                text: root.gradientsExpanded ? "Show less" : "Show all"
                                color: "#aeb6c9"
                                font.pixelSize: 10
                            }
                            Icon {
                                name: "chevron"
                                size: 12
                                color: "#aeb6c9"
                                rotation: root.gradientsExpanded ? 180 : 0
                            }
                        }
                    }
                }
                GridLayout {
                    columns: 5
                    columnSpacing: 8
                    rowSpacing: 8
                    Layout.fillWidth: true
                    Repeater {
                        model: root.gradientsExpanded ? 20 : 5
                        Thumb {
                            required property int index
                            Layout.preferredWidth: root.tileSize
                            Layout.preferredHeight: root.tileSize
                            imageSource: root.gradients[index] ? "file://" + root.gradients[index].path : ""
                            title: root.gradients[index] ? root.gradients[index].name : "Gradient " + (index + 1)
                            selected: root.backgroundEnabled && root.settings.mode === "gradient" && root.settings.gradient_version >= 2 && root.settings.preset === index
                            onActivated: root.selectGradient(index)
                        }
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 7
                Caption {
                    text: "Wallpapers"
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: root.wallpapers
                        Thumb {
                            required property var modelData
                            width: root.tileSize
                            height: root.tileSize
                            imageSource: "file://" + modelData.path
                            title: modelData.name || "Wallpaper"
                            selected: root.backgroundEnabled && root.settings.mode === "wallpaper" && root.settings.image_path === modelData.path
                            onActivated: {
                                let next = Object.assign({}, root.settings);
                                next.mode = "wallpaper";
                                next.image_path = modelData.path;
                                next.blur = 0;
                                root.settings = next;
                                root.backgroundEnabled = true;
                                root.changed(next);
                            }
                        }
                    }
                    Item {
                        width: root.tileSize
                        height: root.tileSize
                        Canvas {
                            anchors.fill: parent
                            onPaint: {
                                let c = getContext("2d");
                                c.reset();
                                c.strokeStyle = "#70778c";
                                c.lineWidth = 1.5;
                                c.setLineDash([4, 4]);
                                let left = 3, top = 3, right = width - 3, bottom = height - 3, r = 7;
                                c.beginPath();
                                c.moveTo(left + r, top);
                                c.lineTo(right - r, top);
                                c.quadraticCurveTo(right, top, right, top + r);
                                c.lineTo(right, bottom - r);
                                c.quadraticCurveTo(right, bottom, right - r, bottom);
                                c.lineTo(left + r, bottom);
                                c.quadraticCurveTo(left, bottom, left, bottom - r);
                                c.lineTo(left, top + r);
                                c.quadraticCurveTo(left, top, left + r, top);
                                c.closePath();
                                c.stroke();
                            }
                        }
                        Icon {
                            anchors.centerIn: parent
                            name: "plus"
                            size: 20
                            color: "#c2c7d6"
                        }
                        MouseArea {
                            id: addWallpaperMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: wallpaperPicker.open()
                        }
                        Accessible.role: Accessible.Button
                        Accessible.name: "Add your own wallpaper"
                        ToolTip.visible: addWallpaperMouse.containsMouse
                        ToolTip.text: "Add your own wallpaper"
                        ToolTip.delay: 500
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 9
                Caption {
                    text: "Blurred"
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: root.blurredSources
                        Item {
                            required property var modelData
                            width: root.tileSize
                            height: root.tileSize
                            Image {
                                anchors.fill: parent
                                anchors.margins: 2
                                source: "file://" + modelData.path
                                sourceSize: Qt.size(Math.max(3, Math.round(200 / modelData.blur)), Math.max(3, Math.round(200 / modelData.blur)))
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                radius: 9
                                border.width: root.backgroundEnabled && root.settings.mode === "blurred" && root.settings.image_path === (modelData.source ? "" : modelData.path) && root.settings.blur === modelData.blur ? 2 : 1
                                border.color: "#73758e"
                            }
                            MouseArea {
                                id: blurMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    let next = Object.assign({}, root.settings);
                                    next.mode = "blurred";
                                    next.blur = modelData.blur;
                                    next.image_path = modelData.source ? "" : modelData.path;
                                    root.settings = next;
                                    root.backgroundEnabled = true;
                                    root.changed(next);
                                }
                            }
                            ToolTip.visible: blurMouse.containsMouse
                            ToolTip.text: "Blur " + modelData.name + " · " + modelData.blur + " px"
                            ToolTip.delay: 500
                            Accessible.role: Accessible.Button
                            Accessible.name: "Blur " + modelData.name
                        }
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 7
                Caption {
                    text: "Plain color"
                }
                GridLayout {
                    columns: 9
                    columnSpacing: 6
                    rowSpacing: 7
                    Layout.alignment: Qt.AlignLeft
                    Repeater {
                        model: ["#111111", "#ffffff", "#e13257", "#f68a27", "#f4b82f", "#169a76", "#149de8", "#8d4ff0", "#00000000", "#3b4149", "#e6e9f1", "#f5b5c1", "#ffcf99", "#ffeba6", "#a9e7ca", "#a7dbf7", "#d3c0f4", "custom"]
                        Rectangle {
                            required property string modelData
                            width: 20
                            height: 20
                            radius: 10
                            color: modelData === "custom" || modelData === "#00000000" ? "transparent" : modelData
                            Canvas {
                                anchors.fill: parent
                                visible: modelData === "custom" || modelData === "#00000000"
                                onPaint: {
                                    let c = getContext("2d");
                                    c.reset();
                                    c.beginPath();
                                    c.arc(width / 2, height / 2, width / 2, 0, 2 * Math.PI);
                                    c.clip();
                                    if (modelData === "custom") {
                                        let gradient = c.createLinearGradient(0, 0, width, height);
                                        let colors = ["#e65c92", "#ffca58", "#8de2a1", "#3eabf7", "#bc68f1"];
                                        for (let i = 0; i < colors.length; i++)
                                            gradient.addColorStop(i / (colors.length - 1), colors[i]);
                                        c.fillStyle = gradient;
                                        c.fillRect(0, 0, width, height);
                                    } else {
                                        for (let y = 0; y < 2; y++)
                                            for (let x = 0; x < 2; x++) {
                                                c.fillStyle = (x + y) % 2 ? "#89909e" : "#edf0f6";
                                                c.fillRect(x * width / 2, y * height / 2, width / 2, height / 2);
                                            }
                                    }
                                }
                            }
                            border.width: root.backgroundEnabled && root.settings.mode === "solid" && root.settings.background_color === modelData ? 2 : 1
                            border.color: root.backgroundEnabled && root.settings.mode === "solid" && root.settings.background_color === modelData ? "#aaa4ff" : "#5b5f70"
                            MouseArea {
                                id: solidMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: modelData === "custom" ? backgroundColorPicker.open() : root.selectSolid(modelData)
                            }
                            ToolTip.visible: solidMouse.containsMouse
                            ToolTip.text: modelData === "custom" ? "Choose a color" : modelData === "#00000000" ? "Transparent" : modelData
                            ToolTip.delay: 500
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData === "custom" ? "Choose a background color" : modelData === "#00000000" ? "Transparent background" : modelData + " background"
                        }
                    }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: "#343846"
            }
            SettingSlider {
                label: "Padding"
                from: 0
                to: 240
                value: root.settings.padding
                onMoved: function (value) {
                    root.update("padding", Math.round(value));
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                SettingSlider {
                    label: "Inset"
                    from: 0
                    to: 64
                    value: root.settings.inset
                    onMoved: function (value) {
                        root.update("inset", Math.round(value));
                    }
                }
                CheckBox {
                    text: "Auto-balance"
                    checked: root.settings.auto_balance
                    font.pixelSize: 10
                    palette.windowText: "#aeb6c9"
                    Layout.alignment: Qt.AlignBottom
                    implicitHeight: 28
                    onClicked: root.update("auto_balance", checked)
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                SettingSlider {
                    label: "Shadow"
                    suffix: "%"
                    from: 0
                    to: 100
                    value: root.settings.shadow ? root.settings.shadow_strength * 100 : 0
                    onMoved: function (value) {
                        let next = Object.assign({}, root.settings);
                        next.shadow = value > 0;
                        next.shadow_strength = value / 100;
                        root.settings = next;
                        root.backgroundEnabled = true;
                        root.changed(next);
                    }
                }
                SettingSlider {
                    label: "Corners"
                    from: 0
                    to: 64
                    value: root.settings.radius
                    onMoved: function (value) {
                        root.update("radius", Math.round(value));
                    }
                }
            }
            SettingSlider {
                visible: root.settings.mode === "wallpaper" || root.settings.mode === "blurred" || root.settings.blur > 0
                label: "Background blur"
                from: 0
                to: 80
                value: root.settings.blur
                onMoved: function (value) {
                    root.update("blur", Math.round(value));
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 18
                ColumnLayout {
                    spacing: 7
                    Caption {
                        text: "Alignment"
                    }
                    GridLayout {
                        columns: 3
                        columnSpacing: 5
                        rowSpacing: 5
                        Repeater {
                            model: ["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right"]
                            Rectangle {
                                required property string modelData
                                required property int index
                                width: 27
                                height: 21
                                radius: 4
                                color: root.settings.alignment === modelData ? "#6557c8" : "transparent"
                                border.color: root.settings.alignment === modelData ? "#8f82ea" : "#686f83"
                                Rectangle {
                                    width: 11
                                    height: 7
                                    radius: 1
                                    color: root.settings.alignment === modelData ? "#ffffff" : "#949db1"
                                    x: index % 3 === 0 ? 3 : index % 3 === 1 ? 8 : 13
                                    y: index < 3 ? 3 : index < 6 ? 7 : 11
                                }
                                MouseArea {
                                    id: alignmentMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.update("alignment", modelData)
                                }
                                Accessible.role: Accessible.Button
                                Accessible.name: "Align " + modelData
                                ToolTip.visible: alignmentMouse.containsMouse
                                ToolTip.text: modelData
                                ToolTip.delay: 500
                            }
                        }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 7
                    Caption {
                        text: "Ratio"
                    }
                    ComboBox {
                        palette.base: "#303542"
                        palette.text: "#d2d7e4"
                        palette.button: "#353a49"
                        palette.buttonText: "#b8c1d6"
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        implicitHeight: 29
                        font.pixelSize: 10
                        model: ["Auto", "1:1", "16:9", "4:5", "9:16", "4:3", "3:2"]
                        currentIndex: {
                            let values = [0, 1, 16 / 9, 4 / 5, 9 / 16, 4 / 3, 3 / 2];
                            let found = values.findIndex(function (v) {
                                return Math.abs(v - root.settings.aspect_ratio) < 0.001;
                            });
                            return found < 0 ? 0 : found;
                        }
                        onActivated: function (index) {
                            root.update("aspect_ratio", [0, 1, 16 / 9, 4 / 5, 9 / 16, 4 / 3, 3 / 2][index]);
                        }
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: root.message.length > 0
                text: root.message
                color: "#e1a6b2"
                wrapMode: Text.Wrap
                font.pixelSize: 10
            }
            Item {
                Layout.preferredHeight: 12
            }
        }
    }
}
