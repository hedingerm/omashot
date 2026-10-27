import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import "AnnotationGeometry.js" as Geometry

Rectangle {
    id: root
    color: Theme.window
    palette: Theme.controls.palette
    radius: Theme.radius(10)
    clip: true
    property string sourcePath: ""
    property string basePath: sourcePath
    property string backend: "omashot"
    property string tool: "select"
    property int selectedIndex: -1
    readonly property int editableStart: {
        var start = 0;
        operations.forEach(function (o, i) {
            if (["crop", "resize", "rotate", "flip"].indexOf(o.type) >= 0)
                start = i + 1;
        });
        return start;
    }
    property var selectedOperation: selectedIndex >= editableStart && selectedIndex < operations.length ? operations[selectedIndex] : null
    property var gestureBefore: null
    property var gestureOriginal: null
    property real gestureX: 0
    property real gestureY: 0
    property string textStyle: "standard"
    readonly property bool textOptions: tool === "text" || tool === "step" || (selectedOperation && ["text", "step"].indexOf(selectedOperation.type) >= 0)
    property string redactionMode: "pixelate"
    property int redactionStrength: 12
    property bool textEditing: false
    property int editingTextIndex: -1
    property real editingTextX: 0
    property real editingTextY: 0
    property bool cropEditing: false
    property var cropBox: ({
            x: 0,
            y: 0,
            w: 1,
            h: 1
        })
    property string cropRatio: "Freeform"
    property string cropFill: "#00000000"
    property string ink: "#ff657a"
    property real strokeWidth: 4
    property int textSize: 28
    property var operations: []
    property var undoStack: []
    property var undone: []
    property var customPresets: []
    // Last-used tool options and background, kept in config as `editor` and restored on every new edit.
    property var savedSettings: null
    property string lastTool: "select"
    property var lastBackground: null
    property bool applyingSettings: false
    readonly property var tools: ["select", "rectangle", "filled", "ellipse", "line", "arrow", "text", "step", "freehand", "highlight", "spotlight", "pixelate"]
    readonly property var textStyles: ["standard", "rounded", "monospaced", "outlined", "boxed", "rounded_boxed", "monospaced_boxed"]
    readonly property var cropRatios: ["Freeform", "1:1", "4:3", "16:9", "9:16"]
    readonly property var cropFills: ["#00000000", "#ffffff", "#808080", "#000000"]
    signal settingsUsed(var settings)
    onLastToolChanged: remember()
    onInkChanged: remember()
    onStrokeWidthChanged: remember()
    onTextSizeChanged: remember()
    onTextStyleChanged: remember()
    onRedactionModeChanged: remember()
    onRedactionStrengthChanged: remember()
    onCropRatioChanged: remember()
    onCropFillChanged: remember()
    onSidebarVisibleChanged: remember()
    function remember() {
        if (initialized && !applyingSettings)
            settingsTimer.restart();
    }
    Timer {
        id: settingsTimer
        interval: 400
        onTriggered: root.settingsUsed({
            tool: root.lastTool,
            ink: root.ink,
            stroke_width: root.strokeWidth,
            text_size: root.textSize,
            text_style: root.textStyle,
            redaction_mode: root.redactionMode,
            redaction_strength: root.redactionStrength,
            crop_ratio: root.cropRatio,
            crop_fill: root.cropFill,
            sidebar_visible: root.sidebarVisible,
            background: root.lastBackground
        })
    }
    function applySettings() {
        if (settingsTimer.running) {
            settingsTimer.stop();
            settingsTimer.triggered();
        }
        var s = savedSettings;
        if (!s || typeof s !== "object")
            return;
        var color = /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;
        var number = function (v, lo, hi) {
            return typeof v === "number" && v >= lo && v <= hi;
        };
        applyingSettings = true;
        if (tools.indexOf(s.tool) >= 0)
            tool = lastTool = s.tool;
        if (color.test(s.ink || ""))
            ink = s.ink;
        if (number(s.stroke_width, 1, 30))
            strokeWidth = s.stroke_width;
        if (number(s.text_size, 10, 500))
            textSize = Math.round(s.text_size);
        if (textStyles.indexOf(s.text_style) >= 0)
            textStyle = s.text_style;
        if (["pixelate", "blur", "redact"].indexOf(s.redaction_mode) >= 0)
            redactionMode = s.redaction_mode;
        if (number(s.redaction_strength, 2, 60))
            redactionStrength = Math.round(s.redaction_strength);
        if (cropRatios.indexOf(s.crop_ratio) >= 0)
            cropRatio = s.crop_ratio;
        if (color.test(s.crop_fill || ""))
            cropFill = s.crop_fill;
        if (typeof s.sidebar_visible === "boolean")
            sidebarVisible = s.sidebar_visible;
        lastBackground = s.background && s.background.type === "background" ? s.background : null;
        applyingSettings = false;
    }
    // A fresh capture starts with the last-used background; wallpapers removed from the library since are skipped.
    function rememberedBackground() {
        var bg = lastBackground;
        if (!bg || ((bg.mode === "wallpaper" || bg.image_path) && !backgroundPanel.wallpapers.some(function (w) {
            return w.path === bg.image_path;
        })))
            return null;
        return Object.assign({}, bg);
    }
    property var localPresets: customPresets
    onCustomPresetsChanged: localPresets = customPresets
    property string status: "Choose a tool, then draw on your screenshot"
    property bool busy: projectProbe.running || finishing
    readonly property bool geometryChanged: operations.some(function (o) {
        return o.type === "crop" || o.type === "resize" || o.type === "rotate" || o.type === "flip";
    })
    property alias backgroundControl: backgroundPanel
    property bool sidebarVisible: true
    property bool previewOnly: false
    property string previewPath: ""
    property int revision: 0
    property int displayRevision: -1
    readonly property bool previewReady: displayRevision === revision && picture.status === Image.Ready && !!previewPath && picture.loaded === previewPath
    property int renderRevision: -1
    property string renderSource: ""
    // Edits autosave over the capture itself (`render --save`); its project sidecar keeps the original pixels.
    // `savedOperations` is what the file holds once queued saves finish ("" until the project is loaded).
    property string savedOperations: ""
    property string loadedPath: ""
    property var saveQueue: []
    property bool finishing: false
    property bool initialized: false
    // The live scene draws every edit in the next frame; the exact backend render replaces it once it matches `revision`.
    property var exactRect: ({
            w: sourceImage.sourceSize.width,
            h: sourceImage.sourceSize.height,
            content: {
                x: 0,
                y: 0,
                w: sourceImage.sourceSize.width,
                h: sourceImage.sourceSize.height
            }
        })
    property var draft: null
    property var balance: null
    property var baseCache: ({})
    readonly property string prefixKey: editableStart ? JSON.stringify(operations.slice(0, editableStart)) : ""
    readonly property var sourceBase: sourceImage.status === Image.Ready ? {
        path: basePath,
        width: sourceImage.sourceSize.width,
        height: sourceImage.sourceSize.height
    } : null
    // Until the newest transform's flattened base is rendered, the stage before it is drawn through that transform.
    readonly property var liveStage: {
        if (!editableStart || baseCache[prefixKey])
            return {
                start: editableStart,
                base: editableStart ? baseCache[prefixKey] : sourceBase,
                transform: null
            };
        var last = editableStart - 1, start = 0;
        for (var i = 0; i < last; i++)
            if (["crop", "resize", "rotate", "flip"].indexOf(operations[i].type) >= 0)
                start = i + 1;
        var framed = operations.slice(start, last).some(function (o) {
            return o.type === "background";
        });
        return {
            start: start,
            base: framed ? null : start ? baseCache[JSON.stringify(operations.slice(0, start))] || null : sourceBase,
            transform: operations[last]
        };
    }
    readonly property var liveBase: liveStage.base
    readonly property bool liveReady: !!liveBase && live.ready
    readonly property bool liveShown: liveReady && (!previewReady || !!draft)
    readonly property var liveOperations: {
        var list = [];
        for (var i = editableStart; i < operations.length; i++)
            if (operations[i].type !== "background" && !(textEditing && i === editingTextIndex))
                list.push(operations[i]);
        return draft ? list.concat([draft]) : list;
    }
    readonly property var liveBackground: {
        var found = null;
        for (var i = editableStart; i < operations.length; i++)
            if (operations[i].type === "background")
                found = operations[i];
        return found;
    }
    readonly property real renderedWidth: liveReady ? live.layout.w : exactRect.w
    readonly property real renderedHeight: liveReady ? live.layout.h : exactRect.h
    readonly property var contentRect: liveReady ? live.layout.content : exactRect.content
    property real zoom: 0
    property string lastChange: ""
    property real lastChangeAt: 0
    property alias inlineEditor: inlineText
    property alias annotationSurface: imageArea
    property alias annotationToolbar: annotationToolbarViewport
    property alias sizeControl: sizeSpin
    property alias cropToolbar: cropToolbarViewport
    signal saved(string path)
    signal autosaved(string path)
    signal error(string message)
    signal presetsChanged(var presets)
    signal historyRequested

    // Input-to-display latency of edits (`qs ipc call omashot editorLatency`): each input waits for the first swapped frame showing it.
    property var probeInputs: []
    property var probeSamples: ({})
    property int strokeSeq: 0
    property bool probing: false
    function noteInput(kind) {
        if (!probing)
            return;
        probeInputs.push({
            kind: kind,
            at: Date.now(),
            rev: kind === "draw-move" ? strokeSeq : revision
        });
    }
    function visibleRevision() {
        return liveShown ? revision : picture.status === Image.Ready && picture.loaded === previewPath ? displayRevision : -1;
    }
    function latencyStats() {
        var out = {};
        for (var kind in probeSamples) {
            var g = probeSamples[kind].slice().sort(function (a, b) {
                return a - b;
            });
            out[kind] = {
                n: g.length,
                medianMs: g[g.length >> 1],
                p90Ms: g[Math.floor(g.length * .9)],
                worstMs: g[g.length - 1]
            };
        }
        out.operations = operations.length;
        out.pending = probeInputs.length;
        out.idle = previewReady && !renderProcess.running;
        out.state = [liveReady, live.ready, !!liveBase, previewReady, liveShown, revision, displayRevision].join();
        return out;
    }
    function probeItem(name, item) {
        item = item || root;
        if (item.objectName === name)
            return item;
        var kids = item.children || [];
        for (var i = 0; i < kids.length; i++) {
            var found = probeItem(name, kids[i]);
            if (found)
                return found;
        }
        return null;
    }
    function probeRect(name) {
        var item = name === "image" ? imageArea : probeItem(name);
        if (!item)
            return null;
        var p = item.mapToItem(null, 0, 0);
        return {
            x: p.x,
            y: p.y,
            w: item.width,
            h: item.height,
            sx: name === "image" ? imageArea.sx : 0,
            sourceX: name === "image" ? imageArea.sourceX : 0,
            sourceY: name === "image" ? imageArea.sourceY : 0
        };
    }
    // An input counts once the state it produced was synchronized into a frame, and is recorded when that frame swaps.
    Connections {
        target: root.Window.window
        function onAfterAnimating() {
            var visible = root.visibleRevision(), stroke = root.liveShown ? root.strokeSeq : -1;
            root.probeInputs.forEach(function (input) {
                if (!input.synced && (input.kind === "draw-move" ? stroke : visible) >= input.rev)
                    input.synced = 1;
            });
        }
        // Queued from the render thread in order, so the swap after this sync shows the marked state.
        function onAfterSynchronizing() {
            root.probeInputs.forEach(function (input) {
                if (input.synced === 1)
                    input.synced = 2;
            });
        }
        function onFrameSwapped() {
            if (!root.probeInputs.length)
                return;
            var now = Date.now(), keep = [];
            root.probeInputs.forEach(function (input) {
                if (input.synced === 2 || now - input.at > 5000)
                    root.probeSamples[input.kind] = (root.probeSamples[input.kind] || []).concat([now - input.at]);
                else
                    keep.push(input);
            });
            root.probeInputs = keep;
        }
    }

    onSourcePathChanged: resetSource()
    readonly property bool interacting: !!gestureBefore || !!draft || backgroundPanel.pressedSliders > 0
    // A preview render of an outdated state is wasted work; stop it and render the new state when idle.
    property bool renderAborted: false
    function abortPreview() {
        if (renderProcess.running) {
            renderAborted = true;
            renderProcess.running = false;
        }
    }
    onOperationsChanged: {
        abortPreview();
        revision++;
        if (initialized && !gestureBefore)
            previewTimer.restart();
        if (savedOperations && !gestureBefore)
            autosaveTimer.restart();
    }
    onBasePathChanged: {
        baseCache = {};
        revision++;
        if (initialized)
            previewTimer.restart();
    }
    Component.onCompleted: {
        initialized = true;
        resetSource();
    }
    function resetSource() {
        if (!initialized)
            return;
        if (loadedPath && savedOperations && JSON.stringify(operations) !== savedOperations)
            enqueueSave(loadedPath, basePath, JSON.stringify(operations));
        autosaveTimer.stop();
        loadedPath = sourcePath;
        savedOperations = "";
        finishing = false;
        gestureBefore = null;
        gestureOriginal = null;
        basePath = sourcePath;
        operations = [];
        undoStack = [];
        undone = [];
        previewPath = "";
        queuedAuxiliary = null;
        balance = null;
        draft = null;
        previewOnly = false;
        displayRevision = -1;
        lastChange = "";
        selectedIndex = -1;
        textEditing = false;
        cropEditing = false;
        backgroundPanel.restore(null);
        applySettings();
        status = tool === "select" ? "Choose a tool, then draw on your screenshot" : "Draw " + tool + " on the screenshot";
        loadProject();
    }
    function selectAt(x, y) {
        var found = Geometry.hitIndex(operations.slice(editableStart), x, y, 8 / Math.max(.1, imageArea.sx));
        return selectIndex(found < 0 ? -1 : found + editableStart);
    }
    // The topmost editable mark the current drawing tool would edit instead of drawing a new one
    function drawToolHit(x, y) {
        var types = tool === "pixelate" ? ["pixelate", "blur", "redact"] : [tool], tolerance = 8 / Math.max(.1, imageArea.sx);
        for (var i = operations.length - 1; i >= editableStart; i--)
            if (types.indexOf(operations[i].type) >= 0 && Geometry.outlineHit(operations[i], x, y, tolerance))
                return i;
        return -1;
    }
    function selectIndex(index) {
        selectedIndex = index;
        if (selectedOperation) {
            ink = selectedOperation.color || ink;
            textSize = selectedOperation.size || textSize;
            strokeWidth = selectedOperation.width || strokeWidth;
            textStyle = selectedOperation.style || "standard";
            if (["pixelate", "blur", "redact"].indexOf(selectedOperation.type) >= 0) {
                redactionMode = selectedOperation.type;
                redactionStrength = selectedOperation.strength || 12;
            }
        }
        return selectedIndex;
    }
    function beginGesture(index, x, y) {
        if (index < 0 || busy)
            return;
        selectedIndex = index;
        gestureBefore = snapshot();
        gestureOriginal = Geometry.clone(operations[index]);
        gestureX = x;
        gestureY = y;
        previewTimer.stop();
        lockView();
    }
    function setGesture(op) {
        if (!gestureBefore || selectedIndex < 0)
            return;
        var list = operations.slice();
        list[selectedIndex] = fitText(op);
        operations = list;
        noteInput(gestureKind);
    }
    property string gestureKind: "move"
    function moveGesture(x, y) {
        gestureKind = "move";
        if (gestureOriginal)
            setGesture(Geometry.moved(gestureOriginal, x - gestureX, y - gestureY));
    }
    function resizeGesture(key, x, y) {
        gestureKind = "resize";
        if (gestureOriginal)
            setGesture(Geometry.resized(gestureOriginal, key, x, y));
    }
    function endGesture() {
        if (gestureBefore && JSON.stringify(gestureBefore) !== JSON.stringify(operations)) {
            undoStack = undoStack.concat([gestureBefore]);
            undone = [];
        }
        gestureBefore = null;
        gestureOriginal = null;
        previewTimer.restart();
        if (savedOperations)
            autosaveTimer.restart();
        unlockView();
    }
    // While a drag may grow the canvas, the scale and the source origin's place on screen stay fixed, so the
    // pointer keeps mapping to the same source position; the view recenters on release.
    property var viewLock: null
    function lockView() {
        if (viewLock)
            return;
        var s = canvasScroll.imageScale;
        viewLock = {
            scale: s,
            x: picture.x + (contentRect.x - (contentRect.sourceX || 0)) * s,
            y: picture.y + (contentRect.y - (contentRect.sourceY || 0)) * s
        };
    }
    function unlockView() {
        viewLock = null;
    }
    function changeSelected(key, value) {
        if (!selectedOperation || busy)
            return;
        var list = snapshot();
        list[selectedIndex][key] = value;
        fitText(list[selectedIndex]);
        commit(list, "style");
    }
    function deleteSelected() {
        if (selectedIndex < 0 || busy)
            return;
        var list = operations.slice();
        list.splice(selectedIndex, 1);
        commit(list, "delete");
        selectedIndex = -1;
    }
    function editText(x, y, index) {
        if (busy)
            return;
        editingTextIndex = index;
        editingTextX = x;
        editingTextY = y;
        var op = index >= 0 ? operations[index] : null;
        inlineText.text = op ? op.text : "";
        textSize = op ? (op.size || 28) : textSize;
        ink = op ? (op.color || ink) : ink;
        textStyle = op ? (op.style || "standard") : textStyle;
        textEditing = true;
        revision++;
        previewTimer.restart();
        Qt.callLater(function () {
            inlineText.forceActiveFocus();
            inlineText.selectAll();
        });
    }
    function finishText(accept) {
        if (!textEditing)
            return;
        textEditing = false;
        selectionArea.forceActiveFocus();
        revision++;
        previewTimer.restart();
        if (!accept || !inlineText.text.trim())
            return;
        var op = {
            type: "text",
            x: editingTextX,
            y: editingTextY,
            text: inlineText.text,
            color: ink,
            size: textSize,
            style: textStyle,
            overlay: editingTextIndex < 0 || operations[editingTextIndex].overlay === true
        };
        fitText(op);
        if (editingTextIndex >= 0) {
            var list = snapshot();
            list[editingTextIndex] = op;
            commit(list, "text");
            selectedIndex = editingTextIndex;
        } else {
            add(op);
            selectedIndex = operations.length - 1 - (backgroundOperation() ? 1 : 0);
        }
        tool = "select";
    }
    function cancelActiveMode() {
        if (textEditing) {
            finishText(false);
            return true;
        }
        if (cropEditing) {
            cropEditing = false;
            return true;
        }
        if (selectedIndex >= 0) {
            selectedIndex = -1;
            return true;
        }
        return false;
    }
    // The current stage's size and where its canvas starts in source coordinates, including white margins
    // that overlay annotations grew it by (main.rs `render` without a background).
    function documentExtent() {
        var w = sourceImage.sourceSize.width, h = sourceImage.sourceSize.height, stage = [], g;
        function grow() {
            g = Geometry.growth(stage, 0, 0, w, h);
            w += g.l + g.r;
            h += g.t + g.b;
            stage = [];
        }
        operations.forEach(function (o) {
            if (["crop", "resize", "rotate", "flip"].indexOf(o.type) >= 0)
                grow();
            if (Geometry.isOverlay(o))
                stage.push(o);
            else if (o.type === "crop" || o.type === "resize") {
                w = o.w;
                h = o.h;
            } else if (o.type === "rotate" && Math.abs(Number(o.angle || 90)) % 180 === 90) {
                var old = w;
                w = h;
                h = old;
            } else if (o.type === "image") {
                w = Math.max(w, o.x + o.w);
                h = Math.max(h, o.y + o.h);
            }
        });
        grow();
        return {
            x: -g.l,
            y: -g.t,
            w: w,
            h: h
        };
    }
    function beginCrop() {
        if (busy)
            return;
        if (textEditing)
            finishText(true);
        selectedIndex = -1;
        cropEditing = true;
        tool = "select";
        cropBox = documentExtent();
    }
    function setCropDimension(key, value) {
        var next = Object.assign({}, cropBox);
        next[key] = value;
        if (cropRatio !== "Freeform") {
            var parts = cropRatio.split(":"), ratio = Number(parts[0]) / Number(parts[1]);
            if (key === "w")
                next.h = Math.round(value / ratio);
            else
                next.w = Math.round(value * ratio);
        }
        cropBox = next;
    }
    function updateCrop(key, x, y) {
        var next = Geometry.resized(Object.assign({
            type: "rectangle"
        }, cropBox), key, x, y);
        if (cropRatio !== "Freeform") {
            var parts = cropRatio.split(":");
            var ratio = Number(parts[0]) / Number(parts[1]);
            if (key === "n" || key === "s")
                next.w = next.h * ratio;
            else
                next.h = next.w / ratio;
        }
        cropBox = {
            x: Math.round(next.x),
            y: Math.round(next.y),
            w: Math.round(next.w),
            h: Math.round(next.h)
        };
    }
    function cropTransform(operation) {
        if (busy)
            return;
        add(operation);
        selectedIndex = -1;
        cropBox = documentExtent();
    }
    function applyCrop() {
        if (!cropEditing || busy)
            return;
        add(Object.assign({
            type: "crop",
            background_color: cropFill
        }, cropBox));
        cropEditing = false;
        selectedIndex = -1;
    }
    function importLayer(path) {
        if (auxiliaryProcess.running)
            return;
        auxiliaryProcess.kind = "layer";
        auxiliaryProcess.command = [backend, "import", path];
        auxiliaryProcess.running = true;
    }
    function snapshot() {
        return JSON.parse(JSON.stringify(operations));
    }
    function commit(next, kind) {
        if (busy)
            return;
        var instant = Date.now();
        if (!((kind === "background" || kind === "style") && lastChange === kind && instant - lastChangeAt < 700))
            undoStack = undoStack.concat([snapshot()]);
        operations = next;
        if (selectedIndex >= next.length)
            selectedIndex = -1;
        undone = [];
        lastChange = kind || "draw";
        lastChangeAt = instant;
    }
    function annotationOperations() {
        return operations.filter(function (o) {
            return o.type !== "background";
        });
    }
    function backgroundOperation() {
        var found = operations.filter(function (o) {
            return o.type === "background";
        });
        return found.length ? found[found.length - 1] : null;
    }
    function updateBackground(op) {
        var next = annotationOperations();
        if (op)
            next.push(op);
        commit(next, "background");
        noteInput("background");
    }
    function syncBackground() {
        backgroundPanel.restore(backgroundOperation());
    }
    function add(op) {
        var next = annotationOperations();
        next.push(op);
        var bg = backgroundOperation();
        if (bg)
            next.push(bg);
        commit(next, "draw");
    }
    // Zoom by factor while keeping the viewport point (px, py) over the same image pixel; the image sits centered with a 32 px margin.
    function zoomAt(factor, px, py) {
        var v = canvasScroll, s = v.imageScale, w = root.renderedWidth, h = root.renderedHeight;
        var s2 = Math.max(.1, Math.min(4, s * factor));
        var u = (v.contentX + px - Math.max((v.width - w * s) / 2, 32)) / s, t = (v.contentY + py - Math.max((v.height - h * s) / 2, 32)) / s;
        root.zoom = s2;
        v.contentX = Math.max(0, Math.min(v.contentWidth - v.width, u * s2 + Math.max((v.width - w * s2) / 2, 32) - px));
        v.contentY = Math.max(0, Math.min(v.contentHeight - v.height, t * s2 + Math.max((v.height - h * s2) / 2, 32) - py));
    }
    function undo() {
        if (!undoStack.length || busy)
            return;
        undone = undone.concat([snapshot()]);
        operations = undoStack[undoStack.length - 1];
        undoStack = undoStack.slice(0, -1);
        noteInput("undo");
        lastChange = "";
        selectedIndex = -1;
        syncBackground();
        if (cropEditing) {
            cropBox = documentExtent();
        }
    }
    function redo() {
        if (!undone.length || busy)
            return;
        undoStack = undoStack.concat([snapshot()]);
        operations = undone[undone.length - 1];
        undone = undone.slice(0, -1);
        noteInput("redo");
        lastChange = "";
        selectedIndex = -1;
        syncBackground();
        if (cropEditing) {
            cropBox = documentExtent();
        }
    }
    property string projectInput: ""
    property string projectOutput: ""
    function loadProject() {
        if (!sourcePath || projectProbe.running)
            return;
        projectInput = sourcePath;
        projectProbe.command = [backend, "project", sourcePath];
        projectProbe.running = true;
    }
    Process {
        id: projectProbe
        stdout: StdioCollector {
            onStreamFinished: root.projectOutput = text
        }
        onExited: function (code) {
            if (root.projectInput !== root.sourcePath) {
                root.loadProject();
                return;
            }
            var restored = false;
            if (code === 0) {
                try {
                    var project = JSON.parse(root.projectOutput);
                    if (project.source && Array.isArray(project.operations)) {
                        restored = project.saved === true || project.operations.length > 0;
                        root.savedOperations = JSON.stringify(project.operations);
                        root.basePath = project.source;
                        root.operations = project.operations;
                        root.undone = [];
                        var history = [];
                        for (var i = 0; i < project.operations.length; i++)
                            history.push(project.operations.slice(0, i));
                        root.undoStack = history;
                        root.syncBackground();
                    }
                } catch (e) {
                    root.status = "Could not restore edits: " + e;
                }
            }
            var bg = restored || root.operations.length ? null : root.rememberedBackground();
            if (bg) {
                root.operations = [bg];
                root.undoStack = [[]];
                root.syncBackground();
            }
            root.previewTimerStart();
        }
    }
    function previewTimerStart() {
        previewTimer.restart();
    }
    TextMetrics {
        id: textInk
    }
    FontMetrics {
        id: textLine
    }
    // Stores the ink box of a text op as w/h, as LiveScene draws it (ink top at y), so the selection and boxed styles hug the text.
    function fitText(op) {
        if (!op || op.type !== "text")
            return op;
        var style = op.style || "standard", lines = String(op.text || "").split("\n"), right = 0, first = null, last = null;
        textInk.font = textLine.font = Qt.font({
            family: style.indexOf("monospaced") === 0 ? "monospace" : "sans-serif",
            pixelSize: Geometry.clamp(Number(op.size || 28), 6, 500),
            bold: style === "rounded"
        });
        lines.forEach(function (line) {
            textInk.text = line || " ";
            var r = textInk.tightBoundingRect;
            right = Math.max(right, r.x + r.width);
            first = first || r;
            last = r;
        });
        op.w = Math.max(8, Math.ceil(right));
        op.h = Math.max(8, Math.ceil(-first.y + (lines.length - 1) * textLine.lineSpacing + Math.max(0, last.y + last.height)));
        return op;
    }
    Timer {
        id: previewTimer
        interval: 160
        // Exact renders compete for CPU with the frames of an ongoing drag; wait until it ends.
        onTriggered: root.interacting ? restart() : root.startRender(true)
    }
    function render(preview) {
        if (preview)
            previewTimer.restart();
        else
            finish();
    }
    function startRender(preview) {
        if (!sourcePath || projectProbe.running || renderProcess.running)
            return;
        renderRevision = revision;
        renderSource = sourcePath;
        renderProcess.command = ["nice", "-n", "10", backend, "render", basePath, JSON.stringify(textEditing && editingTextIndex >= 0 ? operations.filter(function (o, i) {
                return i !== editingTextIndex;
            }) : operations), "--preview"];
        renderProcess.running = true;
    }
    Timer {
        id: autosaveTimer
        interval: 1000
        onTriggered: root.interacting || root.textEditing ? restart() : root.autosave()
    }
    function autosave() {
        var ops = JSON.stringify(operations);
        if (savedOperations && ops !== savedOperations)
            enqueueSave(sourcePath, basePath, ops);
    }
    // Saves the pending edits, then leaves the editor.
    function finish() {
        if (textEditing)
            finishText(true);
        autosaveTimer.stop();
        finishing = true;
        autosave();
        settleFinish();
    }
    function settleFinish() {
        if (finishing && !saveProcess.running && !saveQueue.length) {
            finishing = false;
            saved(sourcePath);
        }
    }
    function enqueueSave(target, base, ops) {
        if (target === sourcePath)
            savedOperations = ops;
        saveQueue = saveQueue.filter(function (item) {
            return item.target !== target;
        }).concat([{
                target: target,
                base: base,
                ops: ops
            }]);
        pumpSaves();
    }
    function pumpSaves() {
        if (saveProcess.running || !saveQueue.length)
            return;
        var item = saveQueue[0];
        saveQueue = saveQueue.slice(1);
        saveProcess.item = item;
        saveProcess.command = [backend, "render", item.base, item.ops, "--save", item.target];
        saveProcess.running = true;
        if (item.target === sourcePath)
            status = "Saving…";
    }
    Process {
        id: saveProcess
        property var item: null
        property string result: ""
        property string errors: ""
        onStarted: {
            result = "";
            errors = "";
        }
        stdout: StdioCollector {
            onStreamFinished: saveProcess.result = text
        }
        stderr: StdioCollector {
            onStreamFinished: saveProcess.errors = text
        }
        onExited: function (code) {
            var current = item.target === root.sourcePath;
            try {
                var value = JSON.parse(result);
                if (code !== 0 || !value.path)
                    throw new Error(value.error || errors || "Could not save image");
                // The capture now holds edited pixels; later edits start from the original in its sidecar.
                if (current && root.basePath !== value.source)
                    root.basePath = value.source;
                root.saveQueue = root.saveQueue.map(function (queued) {
                    return queued.target === item.target && queued.base === item.target ? Object.assign({}, queued, {
                        base: value.source
                    }) : queued;
                });
                if (current)
                    root.status = "Saved";
                root.autosaved(item.target);
            } catch (e) {
                // Keep the edits marked unsaved so the next change or close retries.
                if (current) {
                    root.savedOperations = "[\"unsaved\"]";
                    root.finishing = false;
                }
                root.status = String(e);
                root.error(root.status);
            }
            root.pumpSaves();
            root.settleFinish();
        }
    }
    Process {
        id: renderProcess
        property string result: ""
        property string errors: ""
        onStarted: {
            result = "";
            errors = "";
        }
        stdout: StdioCollector {
            onStreamFinished: renderProcess.result = text
        }
        stderr: StdioCollector {
            onStreamFinished: renderProcess.errors = text
        }
        onExited: function (code) {
            if (root.renderAborted) {
                root.renderAborted = false;
                previewTimer.restart();
                return;
            }
            try {
                var value = JSON.parse(result);
                if (code !== 0 || !value.path)
                    throw new Error(value.error || errors || "Could not render image");
                if (root.renderSource === root.sourcePath && root.renderRevision === root.revision) {
                    var rect = value.contentRect || {
                        x: 0,
                        y: 0,
                        w: value.width,
                        h: value.height
                    };
                    // Auto-balance trims depend on pixels; the live layout reuses the backend's latest bounds.
                    if (rect.sourceW !== undefined && root.liveBackground)
                        root.balance = {
                            x: rect.sourceX,
                            y: rect.sourceY,
                            w: rect.sourceW,
                            h: rect.sourceH
                        };
                    root.exactRect = {
                        w: value.width,
                        h: value.height,
                        content: rect
                    };
                    root.previewPath = value.path;
                    root.displayRevision = root.renderRevision;
                    root.status = "All changes previewed";
                    if (root.queuedAuxiliary)
                        Qt.callLater(function () {
                            if (root.queuedAuxiliary)
                                root.auxiliary(root.queuedAuxiliary.args, root.queuedAuxiliary.message);
                        });
                }
            } catch (e) {
                root.queuedAuxiliary = null;
                root.status = String(e);
                root.error(root.status);
            }
            if (root.renderRevision !== root.revision || root.renderSource !== root.sourcePath)
                previewTimer.restart();
        }
    }
    Image {
        id: sourceImage
        visible: false
        source: root.basePath ? "file://" + root.basePath : ""
        onStatusChanged: {
            if (status === Image.Ready && !root.previewPath)
                root.exactRect = {
                    w: sourceSize.width,
                    h: sourceSize.height,
                    content: {
                        x: 0,
                        y: 0,
                        w: sourceSize.width,
                        h: sourceSize.height
                    }
                };
        }
    }
    // Transforms (crop, resize, rotate, flip) flatten everything before them; the live scene draws on that exact prefix.
    onPrefixKeyChanged: requestBase()
    function requestBase() {
        if (!prefixKey || baseCache[prefixKey] !== undefined || baseProcess.running || !sourcePath)
            return;
        baseProcess.key = prefixKey;
        baseProcess.source = basePath;
        baseProcess.command = ["nice", "-n", "10", backend, "render", basePath, prefixKey, "--preview"];
        baseProcess.running = true;
    }
    Process {
        id: baseProcess
        property string key: ""
        property string source: ""
        property string result: ""
        stdout: StdioCollector {
            onStreamFinished: baseProcess.result = text
        }
        onExited: function (code) {
            if (source !== root.basePath) {
                root.requestBase();
                return;
            }
            var cache = Object.assign({}, root.baseCache), value = null;
            try {
                value = JSON.parse(result);
            } catch (e) {}
            cache[key] = code === 0 && value && value.path ? {
                path: value.path,
                width: value.width,
                height: value.height
            } : null;
            root.baseCache = cache;
            root.requestBase();
        }
    }
    function exportPath() {
        return previewPath || sourcePath;
    }
    function renderNow() {
        if (displayRevision === revision)
            return;
        previewTimer.stop();
        startRender(true);
    }
    // Copy/export act on the exact render; when it is still catching up they run as soon as it arrives.
    // A null argument stands for that render's path.
    property var queuedAuxiliary: null
    function auxiliary(args, message) {
        if (auxiliaryProcess.running) {
            queuedAuxiliary = null;
            return;
        }
        if (displayRevision !== revision) {
            queuedAuxiliary = {
                args: args,
                message: message
            };
            renderNow();
            return;
        }
        queuedAuxiliary = null;
        auxiliaryProcess.kind = "";
        auxiliaryProcess.command = [backend].concat(args.map(function (a) {
            return a === null ? exportPath() : a;
        }));
        auxiliaryProcess.message = message;
        auxiliaryProcess.running = true;
    }
    Process {
        id: auxiliaryProcess
        property string message: ""
        property string kind: ""
        property string result: ""
        stdout: StdioCollector {
            onStreamFinished: auxiliaryProcess.result = text
        }
        onExited: function (code) {
            if (code === 0) {
                if (kind === "layer") {
                    try {
                        var layer = JSON.parse(result), extent = root.documentExtent();
                        root.add({
                            type: "image",
                            path: layer.path,
                            x: 0,
                            y: extent.y + extent.h,
                            w: layer.width,
                            h: layer.height
                        });
                        root.selectedIndex = root.operations.length - 1 - (root.backgroundOperation() ? 1 : 0);
                        root.tool = "select";
                    } catch (e) {
                        root.error(String(e));
                    }
                    kind = "";
                } else
                    root.status = message;
            } else {
                try {
                    root.status = JSON.parse(result).error || "Action failed";
                } catch (e) {
                    root.status = "Action failed";
                }
                root.error(root.status);
            }
        }
    }
    FileDialog {
        id: exportDialog
        title: "Save screenshot as"
        fileMode: FileDialog.SaveFile
        nameFilters: ["PNG image (*.png)", "JPEG image (*.jpg)", "WebP image (*.webp)"]
        defaultSuffix: "png"
        onAccepted: root.auxiliary(["export", null, decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))], "Screenshot exported")
    }
    ColorDialog {
        id: cropColorDialog
        title: "Crop canvas fill"
        onAccepted: root.cropFill = selectedColor.toString()
    }
    Dialog {
        id: resizeDialog
        palette: Theme.controls.palette
        title: "Resize image"
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Apply | Dialog.Cancel
        onOpened: {
            resizeWidth.text = String(root.documentExtent().w);
            resizeHeight.text = String(root.documentExtent().h);
        }
        onApplied: {
            if (Number(resizeWidth.text) > 0 && Number(resizeHeight.text) > 0) {
                root.add({
                    type: "resize",
                    w: Number(resizeWidth.text),
                    h: Number(resizeHeight.text)
                });
                close();
            }
        }
        RowLayout {
            TextField {
                id: resizeWidth
                implicitWidth: 100
                placeholderText: "Width"
                validator: IntValidator {
                    bottom: 1
                    top: 20000
                }
            }
            Text {
                text: "×"
                color: Theme.textSoft
            }
            TextField {
                id: resizeHeight
                implicitWidth: 100
                placeholderText: "Height"
                validator: IntValidator {
                    bottom: 1
                    top: 20000
                }
            }
        }
    }
    component Divider: Rectangle {
        width: 1
        height: 22
        color: Theme.border
        anchors.verticalCenter: parent.verticalCenter
    }
    component Entry: TextField {
        color: Theme.text
        selectByMouse: true
        font.pixelSize: 12
        implicitHeight: 30
        background: Rectangle {
            radius: Theme.radius(5)
            color: Theme.surface
            border.color: Theme.border
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            color: Theme.panel
            Flickable {
                id: cropToolbarViewport
                visible: root.cropEditing
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                contentWidth: cropToolbarRow.width
                contentHeight: height
                clip: true
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                RowLayout {
                    id: cropToolbarRow
                    width: Math.max(implicitWidth, cropToolbarViewport.width)
                    height: cropToolbarViewport.height
                    spacing: 8
                    Icon {
                        name: "crop"
                        size: 22
                        color: Theme.accent
                    }
                    ComboBox {
                        model: root.cropRatios
                        currentIndex: model.indexOf(root.cropRatio)
                        implicitWidth: 116
                        onActivated: function (index) {
                            root.cropRatio = model[index];
                            root.updateCrop("se", root.cropBox.x + root.cropBox.w, root.cropBox.y + root.cropBox.h);
                        }
                    }
                    SpinBox {
                        from: 1
                        to: 20000
                        editable: true
                        value: root.cropBox.w
                        implicitWidth: 100
                        onValueModified: root.setCropDimension("w", value)
                    }
                    Text {
                        text: "×"
                        color: Theme.textSoft
                    }
                    SpinBox {
                        from: 1
                        to: 20000
                        editable: true
                        value: root.cropBox.h
                        implicitWidth: 100
                        onValueModified: root.setCropDimension("h", value)
                    }
                    IconButton {
                        iconName: "rotate"
                        text: "Rotate 90°"
                        onClicked: root.cropTransform({
                            type: "rotate",
                            angle: 90
                        })
                    }
                    IconButton {
                        id: cropFlipButton
                        iconName: "flip"
                        text: "Flip image"
                        onClicked: cropFlipMenu.open()
                        Menu {
                            id: cropFlipMenu
                            palette: Theme.controls.palette
                            y: cropFlipButton.height
                            MenuItem {
                                text: "Flip horizontally"
                                onTriggered: root.cropTransform({
                                    type: "flip",
                                    axis: "horizontal"
                                })
                            }
                            MenuItem {
                                text: "Flip vertically"
                                onTriggered: root.cropTransform({
                                    type: "flip",
                                    axis: "vertical"
                                })
                            }
                        }
                    }
                    ComboBox {
                        model: ["Transparent", "White", "Gray", "Black", "Custom color…"]
                        currentIndex: root.cropFills.indexOf(root.cropFill) >= 0 ? root.cropFills.indexOf(root.cropFill) : 4
                        implicitWidth: 110
                        onActivated: function (index) {
                            if (index === 4)
                                cropColorDialog.open();
                            else
                                root.cropFill = root.cropFills[index];
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    IconButton {
                        iconName: "reset"
                        text: "Revert crop bounds"
                        onClicked: root.beginCrop()
                    }
                    Button {
                        text: "Cancel"
                        onClicked: root.cropEditing = false
                    }
                    Button {
                        text: "Crop"
                        onClicked: root.applyCrop()
                    }
                }
                ScrollBar.horizontal: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    height: 4
                }
            }
            Flickable {
                id: annotationToolbarViewport
                visible: !root.cropEditing
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                contentWidth: annotationToolbarRow.width
                contentHeight: height
                clip: true
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                RowLayout {
                    id: annotationToolbarRow
                    width: Math.max(implicitWidth, annotationToolbarViewport.width)
                    height: annotationToolbarViewport.height
                    spacing: 5
                    IconButton {
                        iconName: "close"
                        text: "Back to captures"
                        enabled: !root.busy
                        onClicked: root.finish()
                    }
                    IconButton {
                        iconName: "history"
                        text: "Capture history"
                        onClicked: root.historyRequested()
                    }
                    IconButton {
                        iconName: "background"
                        text: "Background styles"
                        selected: root.sidebarVisible
                        onClicked: root.sidebarVisible = !root.sidebarVisible
                    }
                    IconButton {
                        iconName: "crop"
                        text: "Crop"
                        selected: root.tool === "crop"
                        enabled: !root.busy
                        onClicked: root.beginCrop()
                    }
                    IconButton {
                        iconName: "resize"
                        text: "Resize image"
                        enabled: !root.busy
                        onClicked: resizeDialog.open()
                    }
                    ComboBox {
                        visible: root.tool === "text" || (root.selectedOperation && root.selectedOperation.type === "text")
                        implicitWidth: 124
                        implicitHeight: 30
                        font.pixelSize: 11
                        model: ["Standard", "Rounded", "Monospaced", "Outlined", "Boxed", "Rounded boxed", "Monospaced boxed"]
                        currentIndex: ["standard", "rounded", "monospaced", "outlined", "boxed", "rounded_boxed", "monospaced_boxed"].indexOf(root.textStyle)
                        onActivated: function (index) {
                            root.textStyle = ["standard", "rounded", "monospaced", "outlined", "boxed", "rounded_boxed", "monospaced_boxed"][index];
                            root.changeSelected("style", root.textStyle);
                        }
                    }
                    ComboBox {
                        visible: root.tool === "pixelate" || (root.selectedOperation && ["pixelate", "blur", "redact"].indexOf(root.selectedOperation.type) >= 0)
                        implicitWidth: 116
                        implicitHeight: 30
                        font.pixelSize: 11
                        model: ["Pixelate", "Blur (smooth)", "Black out"]
                        currentIndex: ["pixelate", "blur", "redact"].indexOf(root.redactionMode)
                        onActivated: function (index) {
                            root.redactionMode = ["pixelate", "blur", "redact"][index];
                            if (root.selectedOperation)
                                root.changeSelected("type", root.redactionMode);
                        }
                    }
                    Slider {
                        visible: root.tool === "pixelate" || (root.selectedOperation && ["pixelate", "blur"].indexOf(root.selectedOperation.type) >= 0)
                        from: 2
                        to: 60
                        value: root.redactionStrength
                        implicitWidth: 80
                        stepSize: 1
                        onMoved: {
                            root.redactionStrength = value;
                            root.changeSelected("strength", value);
                        }
                        ToolTip.visible: hovered
                        ToolTip.text: "Concealment strength"
                    }
                    IconButton {
                        iconName: "trash"
                        text: "Delete annotation"
                        visible: root.selectedIndex >= 0
                        onClicked: root.deleteSelected()
                    }
                    Rectangle {
                        width: 1
                        Layout.preferredHeight: 24
                        color: Theme.border
                        Layout.leftMargin: 3
                        Layout.rightMargin: 3
                    }
                    Row {
                        id: toolbar
                        Layout.fillWidth: true
                        Layout.minimumWidth: implicitWidth
                        Layout.preferredHeight: 38
                        spacing: 2
                        Repeater {
                            model: root.tools
                            IconButton {
                                required property string modelData
                                iconName: modelData
                                text: modelData === "freehand" ? "Pencil" : modelData.charAt(0).toUpperCase() + modelData.slice(1)
                                size: 34
                                iconSize: 18
                                selected: root.tool === modelData
                                enabled: !root.busy
                                onClicked: {
                                    root.finishText(true);
                                    root.tool = modelData;
                                    root.lastTool = modelData;
                                    root.selectedIndex = -1;
                                    root.status = modelData === "select" ? "Select and drag annotations; double-click text to edit" : "Draw " + modelData + " on the screenshot";
                                }
                            }
                        }
                    }
                    Button {
                        id: colorButton
                        implicitWidth: 34
                        implicitHeight: 32
                        ToolTip.visible: hovered
                        ToolTip.text: "Annotation color"
                        ToolTip.delay: 500
                        Accessible.name: "Annotation color"
                        contentItem: Item {
                            implicitWidth: 16
                            implicitHeight: 16
                            Rectangle {
                                width: 16
                                height: 16
                                radius: Theme.radius(8)
                                color: root.ink
                                border.color: Theme.text
                                anchors.centerIn: parent
                            }
                        }
                        background: Rectangle {
                            radius: Theme.radius(6)
                            color: colorButton.hovered ? Theme.raised : Theme.surface
                        }
                        onClicked: inkPopup.open()
                    }
                    SpinBox {
                        id: sizeSpin
                        from: root.textOptions ? 10 : 1
                        to: root.textOptions ? 500 : 30
                        value: root.textOptions ? root.textSize : root.strokeWidth
                        editable: true
                        wheelEnabled: true
                        implicitWidth: 92
                        implicitHeight: 32
                        font.pixelSize: 11
                        ToolTip.visible: hovered
                        ToolTip.text: root.textOptions ? "Text size" : "Stroke width"
                        ToolTip.delay: 500
                        function apply(v) {
                            if (root.textOptions) {
                                root.textSize = v;
                                root.changeSelected("size", v);
                            } else {
                                root.strokeWidth = v;
                                root.changeSelected("width", v);
                            }
                        }
                        onValueModified: apply(value)
                        // Apply typed sizes as they are typed, not only on Enter or focus loss.
                        Connections {
                            target: sizeSpin.contentItem
                            function onTextEdited() {
                                var v = Number(sizeSpin.contentItem.text);
                                if (Number.isInteger(v) && v >= sizeSpin.from && v <= sizeSpin.to && v !== sizeSpin.value)
                                    sizeSpin.apply(v);
                            }
                        }
                    }
                }
                ScrollBar.horizontal: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    height: 4
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Theme.border
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            BackgroundPanel {
                id: backgroundPanel
                visible: root.sidebarVisible && !root.cropEditing
                Layout.preferredWidth: Math.min(260, root.width * 0.35)
                Layout.minimumWidth: root.width < 650 ? 160 : 210
                Layout.fillHeight: true
                backend: root.backend
                sourcePath: root.basePath
                customPresets: root.localPresets
                enabled: !root.busy
                onChanged: function (operation) {
                    root.lastBackground = operation ? Object.assign({}, operation) : null;
                    root.remember();
                    root.updateBackground(operation);
                }
                onPresetsChanged: function (presets) {
                    root.localPresets = presets;
                    root.presetsChanged(presets);
                }
                onError: function (message) {
                    root.status = message;
                    root.error(message);
                }
            }
            Rectangle {
                visible: root.sidebarVisible
                width: 1
                Layout.fillHeight: true
                color: Theme.border
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 0
                    visible: false
                    color: Theme.panel
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8
                        Icon {
                            name: "text"
                            size: 18
                            color: Theme.textMuted
                        }
                        Entry {
                            id: annotationText
                            Layout.fillWidth: true
                            placeholderText: "Type text, then click the screenshot"
                        }
                    }
                }
                Rectangle {
                    id: viewport
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 0
                    Layout.minimumHeight: 100
                    color: Theme.sunken
                    clip: true
                    DropArea {
                        anchors.fill: parent
                        z: 60
                        onDropped: function (drop) {
                            if (drop.hasUrls && drop.urls.length) {
                                root.importLayer(decodeURIComponent(String(drop.urls[0]).replace(/^file:\/\//, "")));
                                drop.acceptProposedAction();
                            }
                        }
                    }

                    Flickable {
                        id: canvasScroll
                        anchors.fill: parent
                        contentWidth: Math.max(width, root.renderedWidth * imageScale + 64)
                        contentHeight: Math.max(height, root.renderedHeight * imageScale + 64)
                        readonly property real imageScale: root.viewLock ? root.viewLock.scale : root.zoom > 0 ? root.zoom : Math.max(.01, Math.min((width - 64) / Math.max(1, root.renderedWidth), (height - 64) / Math.max(1, root.renderedHeight), 1))
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: false
                        clip: true
                        ScrollBar.horizontal: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }
                        ScrollBar.vertical: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }
                        Item {
                            width: canvasScroll.contentWidth
                            height: canvasScroll.contentHeight
                            // Transparency checkerboard as a tiled image: repainting a Canvas on every resize stalled slider drags.
                            Image {
                                anchors.fill: picture
                                fillMode: Image.Tile
                                smooth: false
                                source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' fill='%23f0f1f3'/><path d='M0 0h12v12H0zM12 12h12v12H12z' fill='%23d3d6dc'/></svg>"
                            }
                            Image {
                                id: picture
                                width: Math.max(1, root.renderedWidth * canvasScroll.imageScale)
                                height: Math.max(1, root.renderedHeight * canvasScroll.imageScale)
                                // Centered, or with the source origin held in place while a drag grows the canvas.
                                x: root.viewLock ? root.viewLock.x - (root.contentRect.x - (root.contentRect.sourceX || 0)) * canvasScroll.imageScale : (parent.width - width) / 2
                                y: root.viewLock ? root.viewLock.y - (root.contentRect.y - (root.contentRect.sourceY || 0)) * canvasScroll.imageScale : (parent.height - height) / 2
                                source: root.previewPath ? "file://" + root.previewPath : sourceImage.source
                                fillMode: Image.Stretch
                                cache: false
                                asynchronous: true
                                visible: !root.liveShown
                                property string loaded: ""
                                onStatusChanged: loaded = status === Image.Ready ? root.previewPath : ""
                            }
                            LiveScene {
                                id: live
                                x: picture.x
                                y: picture.y
                                visible: root.liveShown
                                zoom: canvasScroll.imageScale
                                baseSource: root.liveBase ? "file://" + root.liveBase.path : ""
                                baseWidth: root.liveBase ? root.liveBase.width : 1
                                baseHeight: root.liveBase ? root.liveBase.height : 1
                                operations: root.liveOperations
                                transformOp: root.liveStage.transform
                                preOperations: root.liveStage.transform ? root.operations.slice(root.liveStage.start, root.editableStart - 1).filter(function (o) {
                                    return o.type !== "background";
                                }) : []
                                background: root.liveBackground
                                balance: root.balance
                                gradients: backgroundPanel.gradients
                            }
                            Item {
                                id: imageArea
                                x: picture.x + root.contentRect.x * canvasScroll.imageScale
                                y: picture.y + root.contentRect.y * canvasScroll.imageScale
                                width: root.contentRect.w * canvasScroll.imageScale
                                height: root.contentRect.h * canvasScroll.imageScale
                                readonly property real sourceX: root.contentRect.sourceX || 0
                                readonly property real sourceY: root.contentRect.sourceY || 0
                                readonly property real sx: width / Math.max(1, root.contentRect.sourceW || sourceImage.sourceSize.width)
                                readonly property real sy: height / Math.max(1, root.contentRect.sourceH || sourceImage.sourceSize.height)
                                // Pointer position in source coordinates; with `snap`, positions just past the canvas edge land on it.
                                function sourcePoint(item, x, y, snap) {
                                    var p = item.mapToItem(picture, x, y), e = snap ? 8 : 0;
                                    p.x = p.x < 0 && p.x > -e ? 0 : p.x > picture.width && p.x < picture.width + e ? picture.width : p.x;
                                    p.y = p.y < 0 && p.y > -e ? 0 : p.y > picture.height && p.y < picture.height + e ? picture.height : p.y;
                                    var q = picture.mapToItem(imageArea, p.x, p.y);
                                    return Qt.point(sourceX + q.x / sx, sourceY + q.y / sy);
                                }
                                MouseArea {
                                    id: drawArea
                                    // The whole canvas view: overlay annotations may start or end beyond the screenshot.
                                    x: -imageArea.x
                                    y: -imageArea.y
                                    width: imageArea.parent.width
                                    height: imageArea.parent.height
                                    enabled: !root.busy && !root.cropEditing && !root.textEditing && root.tool !== "select" && (root.liveReady || root.previewReady)
                                    visible: enabled // disabled MouseAreas still claim the cursor
                                    hoverEnabled: true
                                    cursorShape: editIndex >= 0 || hoverIndex >= 0 ? Qt.SizeAllCursor : Qt.CrossCursor
                                    // A press on a same-type mark moves it (a click on text edits it) instead of drawing
                                    property int editIndex: -1
                                    property int hoverIndex: -1
                                    property bool editMoved: false
                                    property point pressPoint
                                    property real startX: 0
                                    property real startY: 0
                                    property real endX: 0
                                    property real endY: 0
                                    property var points: []
                                    function operation() {
                                        var line = root.tool === "line" || root.tool === "arrow";
                                        var result = {
                                            type: root.tool === "pixelate" ? root.redactionMode : root.tool,
                                            x: line ? startX : Math.min(startX, endX),
                                            y: line ? startY : Math.min(startY, endY),
                                            x2: endX,
                                            y2: endY,
                                            w: Math.abs(endX - startX),
                                            h: Math.abs(endY - startY),
                                            color: root.ink,
                                            width: root.strokeWidth,
                                            size: root.textSize,
                                            text: annotationText.text,
                                            style: root.textStyle,
                                            strength: root.redactionStrength,
                                            points: points
                                        };
                                        if (root.tool === "step")
                                            result.centered = true;
                                        if (Geometry.overlayTypes.indexOf(result.type) >= 0)
                                            result.overlay = true;
                                        if (root.tool === "highlight") {
                                            result.h = Math.max(result.h, root.strokeWidth * 4);
                                            result.y = (startY + endY - result.h) / 2;
                                        }
                                        return result;
                                    }
                                    onPressed: function (mouse) {
                                        var p = imageArea.sourcePoint(drawArea, mouse.x, mouse.y, true);
                                        editIndex = root.drawToolHit(p.x, p.y);
                                        if (editIndex >= 0) {
                                            editMoved = false;
                                            pressPoint = Qt.point(mouse.x, mouse.y);
                                            root.selectIndex(editIndex);
                                            root.beginGesture(editIndex, p.x, p.y);
                                            return;
                                        }
                                        root.lockView();
                                        startX = endX = p.x;
                                        startY = endY = p.y;
                                        points = [
                                            {
                                                x: startX,
                                                y: startY
                                            }
                                        ];
                                        if (root.tool !== "text" && root.tool !== "step")
                                            root.draft = operation();
                                    }
                                    onPositionChanged: function (mouse) {
                                        if (pressed && editIndex >= 0) {
                                            editMoved = editMoved || Math.abs(mouse.x - pressPoint.x) + Math.abs(mouse.y - pressPoint.y) > 3;
                                            if (editMoved) {
                                                var q = imageArea.sourcePoint(drawArea, mouse.x, mouse.y, false);
                                                root.moveGesture(q.x, q.y);
                                            }
                                        } else if (!pressed) {
                                            var h = imageArea.sourcePoint(drawArea, mouse.x, mouse.y, false);
                                            hoverIndex = root.drawToolHit(h.x, h.y);
                                        } else {
                                            var p = imageArea.sourcePoint(drawArea, mouse.x, mouse.y, true);
                                            endX = p.x;
                                            endY = p.y;
                                            if (root.tool === "freehand")
                                                points = points.concat([
                                                    {
                                                        x: endX,
                                                        y: endY
                                                    }
                                                ]);
                                            root.strokeSeq++;
                                            if (root.tool !== "text" && root.tool !== "step")
                                                root.draft = operation();
                                            root.noteInput("draw-move");
                                        }
                                    }
                                    onExited: hoverIndex = -1
                                    onReleased: {
                                        if (editIndex >= 0) {
                                            var edited = root.operations[editIndex];
                                            root.endGesture();
                                            if (!editMoved && edited.type === "text")
                                                root.editText(edited.x, edited.y, editIndex);
                                            editIndex = -1;
                                            return;
                                        }
                                        var op = operation();
                                        root.draft = null;
                                        root.unlockView();
                                        if (root.tool === "text" || root.tool === "step") {
                                            op.x = startX;
                                            op.y = startY;
                                            if (root.tool === "step")
                                                op.text = String(root.operations.filter(function (o) {
                                                    return o.type === "step";
                                                }).length + 1);
                                            else {
                                                root.editText(startX, startY, -1);
                                                return;
                                            }
                                        } else if (op.w < 2 && op.h < 2)
                                            return;
                                        root.add(op);
                                        root.noteInput("draw-commit");
                                        root.selectedIndex = root.operations.length - 1 - (root.backgroundOperation() ? 1 : 0);
                                    }
                                    onCanceled: {
                                        if (editIndex >= 0)
                                            root.endGesture();
                                        editIndex = -1;
                                        root.draft = null;
                                        root.unlockView();
                                    }
                                }
                                MouseArea {
                                    id: selectionArea
                                    x: -imageArea.x
                                    y: -imageArea.y
                                    width: imageArea.parent.width
                                    height: imageArea.parent.height
                                    enabled: root.tool === "select" && !root.cropEditing && !root.textEditing && !root.busy
                                    visible: enabled
                                    cursorShape: panning ? Qt.ClosedHandCursor : root.selectedOperation ? Qt.SizeAllCursor : Qt.ArrowCursor
                                    property bool panning: false
                                    property point panStart
                                    property real initialContentX: 0
                                    property real initialContentY: 0
                                    onPressed: function (e) {
                                        forceActiveFocus();
                                        var p = imageArea.sourcePoint(selectionArea, e.x, e.y, false);
                                        var index = root.selectAt(p.x, p.y);
                                        if (index >= 0)
                                            root.beginGesture(index, p.x, p.y);
                                        else {
                                            panning = true;
                                            panStart = mapToItem(viewport, e.x, e.y);
                                            initialContentX = canvasScroll.contentX;
                                            initialContentY = canvasScroll.contentY;
                                        }
                                    }
                                    onPositionChanged: function (e) {
                                        if (pressed && panning) {
                                            var p = mapToItem(viewport, e.x, e.y);
                                            canvasScroll.contentX = Math.max(0, Math.min(canvasScroll.contentWidth - canvasScroll.width, initialContentX + panStart.x - p.x));
                                            canvasScroll.contentY = Math.max(0, Math.min(canvasScroll.contentHeight - canvasScroll.height, initialContentY + panStart.y - p.y));
                                        } else if (pressed && root.gestureOriginal) {
                                            var q = imageArea.sourcePoint(selectionArea, e.x, e.y, false);
                                            root.moveGesture(q.x, q.y);
                                        }
                                    }
                                    onReleased: {
                                        panning = false;
                                        root.endGesture();
                                    }
                                    onCanceled: {
                                        panning = false;
                                        root.endGesture();
                                    }
                                    onDoubleClicked: function (e) {
                                        var p = imageArea.sourcePoint(selectionArea, e.x, e.y, false);
                                        var index = root.selectAt(p.x, p.y);
                                        if (index >= 0 && root.operations[index].type === "text")
                                            root.editText(root.operations[index].x, root.operations[index].y, index);
                                    }
                                }
                                Rectangle {
                                    id: selectionBounds
                                    readonly property var box: root.selectedOperation ? Geometry.bounds(root.selectedOperation) : ({
                                            x: 0,
                                            y: 0,
                                            w: 0,
                                            h: 0
                                        })
                                    x: (box.x - imageArea.sourceX) * imageArea.sx
                                    y: (box.y - imageArea.sourceY) * imageArea.sy
                                    width: box.w * imageArea.sx
                                    height: box.h * imageArea.sy
                                    visible: !!root.selectedOperation && !root.textEditing && !root.cropEditing
                                    color: "transparent"
                                    border.color: Theme.accent
                                    border.width: 1
                                }
                                Repeater {
                                    model: !root.selectedOperation || root.textEditing || root.cropEditing ? 0 : root.selectedOperation.type === "arrow" ? 3 : root.selectedOperation.type === "line" ? 2 : 8
                                    Rectangle {
                                        id: editHandle
                                        required property int index
                                        readonly property var modelData: root.selectedOperation ? Geometry.handles(root.selectedOperation)[index] : ({
                                                key: "se",
                                                x: 0,
                                                y: 0
                                            })
                                        x: (modelData.x - imageArea.sourceX) * imageArea.sx - 5
                                        y: (modelData.y - imageArea.sourceY) * imageArea.sy - 5
                                        width: 10
                                        height: 10
                                        radius: modelData.key === "curve" ? 2 : 5
                                        z: 20
                                        color: Theme.accent
                                        border.color: Theme.lightest
                                        border.width: 1
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            cursorShape: Qt.SizeAllCursor
                                            onPressed: function (e) {
                                                var p = mapToItem(imageArea, e.x, e.y);
                                                root.beginGesture(root.selectedIndex, imageArea.sourceX + p.x / imageArea.sx, imageArea.sourceY + p.y / imageArea.sy);
                                            }
                                            onPositionChanged: function (e) {
                                                if (pressed) {
                                                    var p = mapToItem(imageArea, e.x, e.y);
                                                    root.resizeGesture(editHandle.modelData.key, imageArea.sourceX + p.x / imageArea.sx, imageArea.sourceY + p.y / imageArea.sy);
                                                }
                                            }
                                            onReleased: root.endGesture()
                                            onCanceled: root.endGesture()
                                        }
                                    }
                                }
                                Rectangle {
                                    id: inlineTextBox
                                    visible: root.textEditing
                                    z: 30
                                    x: (root.editingTextX - imageArea.sourceX) * imageArea.sx
                                    y: (root.editingTextY - imageArea.sourceY) * imageArea.sy
                                    width: Math.max(110, inlineText.contentWidth + 18)
                                    height: Math.max(38, inlineText.contentHeight + 12)
                                    color: "#efffffff"
                                    border.color: Theme.accent
                                    border.width: 1
                                    TextEdit {
                                        id: inlineText
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        color: root.ink
                                        font.pixelSize: Math.max(10, root.textSize * imageArea.sy)
                                        font.family: root.textStyle.indexOf("monospaced") >= 0 ? "monospace" : "sans-serif"
                                        selectByMouse: true
                                        wrapMode: TextEdit.NoWrap
                                        Keys.onPressed: function (e) {
                                            if (e.key === Qt.Key_Escape) {
                                                root.finishText(false);
                                                e.accepted = true;
                                            } else if (e.key === Qt.Key_Return && !(e.modifiers & Qt.ShiftModifier)) {
                                                root.finishText(true);
                                                e.accepted = true;
                                            }
                                        }
                                        onActiveFocusChanged: if (!activeFocus && root.textEditing)
                                            root.finishText(true)
                                    }
                                }
                                Item {
                                    id: cropArea
                                    // Covers the whole canvas, which may extend past the screenshot.
                                    x: picture.x - imageArea.x
                                    y: picture.y - imageArea.y
                                    width: picture.width
                                    height: picture.height
                                    visible: root.cropEditing
                                    z: 25
                                    readonly property real cropLeft: (root.cropBox.x - imageArea.sourceX) * imageArea.sx - x
                                    readonly property real cropTop: (root.cropBox.y - imageArea.sourceY) * imageArea.sy - y
                                    readonly property real boxWidth: root.cropBox.w * imageArea.sx
                                    readonly property real boxHeight: root.cropBox.h * imageArea.sy
                                    Rectangle {
                                        x: 0
                                        y: 0
                                        width: parent.width
                                        height: Math.max(0, cropArea.cropTop)
                                        color: "#99000000"
                                    }
                                    Rectangle {
                                        x: 0
                                        y: Math.max(0, cropArea.cropTop)
                                        width: Math.max(0, cropArea.cropLeft)
                                        height: Math.min(parent.height, cropArea.boxHeight)
                                        color: "#99000000"
                                    }
                                    Rectangle {
                                        x: cropArea.cropLeft + cropArea.boxWidth
                                        y: Math.max(0, cropArea.cropTop)
                                        width: Math.max(0, parent.width - x)
                                        height: Math.min(parent.height, cropArea.boxHeight)
                                        color: "#99000000"
                                    }
                                    Rectangle {
                                        x: 0
                                        y: cropArea.cropTop + cropArea.boxHeight
                                        width: parent.width
                                        height: Math.max(0, parent.height - y)
                                        color: "#99000000"
                                    }
                                    Rectangle {
                                        x: cropArea.cropLeft
                                        y: cropArea.cropTop
                                        width: cropArea.boxWidth
                                        height: cropArea.boxHeight
                                        color: "transparent"
                                        border.color: "white"
                                        border.width: 2
                                        Repeater {
                                            model: 2
                                            Rectangle {
                                                required property int index
                                                x: (index + 1) * parent.width / 3
                                                width: 1
                                                height: parent.height
                                                color: "#77ffffff"
                                            }
                                        }
                                        Repeater {
                                            model: 2
                                            Rectangle {
                                                required property int index
                                                y: (index + 1) * parent.height / 3
                                                height: 1
                                                width: parent.width
                                                color: "#77ffffff"
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.SizeAllCursor
                                            property point start
                                            property var initial
                                            onPressed: function (e) {
                                                start = mapToItem(imageArea, e.x, e.y);
                                                initial = Geometry.clone(root.cropBox);
                                            }
                                            onPositionChanged: function (e) {
                                                if (pressed) {
                                                    var p = mapToItem(imageArea, e.x, e.y);
                                                    root.cropBox = {
                                                        x: Math.round(initial.x + (p.x - start.x) / imageArea.sx),
                                                        y: Math.round(initial.y + (p.y - start.y) / imageArea.sy),
                                                        w: initial.w,
                                                        h: initial.h
                                                    };
                                                }
                                            }
                                        }
                                    }
                                    Repeater {
                                        model: 8
                                        Rectangle {
                                            id: cropHandle
                                            required property int index
                                            readonly property var modelData: Geometry.handles(Object.assign({
                                                type: "rectangle"
                                            }, root.cropBox))[index]
                                            x: (modelData.x - imageArea.sourceX) * imageArea.sx - cropArea.x - 5
                                            y: (modelData.y - imageArea.sourceY) * imageArea.sy - cropArea.y - 5
                                            width: 10
                                            height: 10
                                            radius: Theme.radius(3)
                                            color: "white"
                                            border.color: Theme.accent
                                            MouseArea {
                                                anchors.fill: parent
                                                anchors.margins: -7
                                                cursorShape: Qt.SizeFDiagCursor
                                                onPositionChanged: function (e) {
                                                    if (pressed) {
                                                        var p = mapToItem(imageArea, e.x, e.y);
                                                        root.updateCrop(cropHandle.modelData.key, imageArea.sourceX + p.x / imageArea.sx, imageArea.sourceY + p.y / imageArea.sy);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Ctrl+wheel zoom and middle-drag pan for every tool; handlers ignore other input, so tools below still get it.
                    Item {
                        anchors.fill: canvasScroll
                        z: 50
                        WheelHandler {
                            // Qt Wayland reports wl_pointer wheels as TouchPad, which the Mouse-only default rejects.
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            acceptedModifiers: Qt.ControlModifier
                            target: null
                            onWheel: function (e) {
                                root.zoomAt(Math.pow(1.25, e.angleDelta.y / 120), point.position.x, point.position.y);
                            }
                        }
                        DragHandler {
                            acceptedButtons: Qt.MiddleButton
                            target: null
                            cursorShape: Qt.ClosedHandCursor
                            property point start
                            onActiveChanged: if (active)
                                start = Qt.point(canvasScroll.contentX, canvasScroll.contentY)
                            onTranslationChanged: if (active) {
                                canvasScroll.contentX = Math.max(0, Math.min(canvasScroll.contentWidth - canvasScroll.width, start.x - translation.x));
                                canvasScroll.contentY = Math.max(0, Math.min(canvasScroll.contentHeight - canvasScroll.height, start.y - translation.y));
                            }
                        }
                    }
                    Rectangle {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        width: renderLabel.implicitWidth + 20
                        height: 26
                        radius: Theme.radius(13)
                        color: Theme.accentSoft
                        visible: root.finishing
                        Text {
                            id: renderLabel
                            anchors.centerIn: parent
                            text: "Saving…"
                            font.pixelSize: 10
                            color: Theme.text
                        }
                    }
                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 18
                        visible: false
                        text: "Edit saved pixels"
                        font.pixelSize: 11
                        onClicked: {
                            root.basePath = root.sourcePath;
                            root.commit([], "flatten");
                            backgroundPanel.restore(null);
                            root.status = "Editing saved pixels; previous editable project stays in history";
                        }
                    }
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Theme.border
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 43
            color: Theme.panel
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 10
                spacing: 4
                IconButton {
                    iconName: "zoom-out"
                    text: "Zoom out"
                    size: 29
                    iconSize: 16
                    onClicked: root.zoom = Math.max(.1, (root.zoom || canvasScroll.imageScale) / 1.25)
                }
                ComboBox {
                    id: zoomPicker
                    implicitWidth: 84
                    implicitHeight: 29
                    font.pixelSize: 11
                    model: ["Fit", "50%", "75%", "100%", "125%", "150%", "200%"]
                    currentIndex: root.zoom === 0 ? 0 : [.5, .75, 1, 1.25, 1.5, 2].indexOf(root.zoom) + 1
                    displayText: root.zoom === 0 ? Math.round(canvasScroll.imageScale * 100) + "% · Fit" : Math.round(root.zoom * 100) + "%"
                    onActivated: function (index) {
                        root.zoom = [0, .5, .75, 1, 1.25, 1.5, 2][index];
                    }
                }
                IconButton {
                    iconName: "zoom-in"
                    text: "Zoom in"
                    size: 29
                    iconSize: 16
                    onClicked: root.zoom = Math.min(4, (root.zoom || canvasScroll.imageScale) * 1.25)
                }
                Rectangle {
                    width: 1
                    Layout.preferredHeight: 18
                    color: Theme.border
                    Layout.leftMargin: 7
                    Layout.rightMargin: 7
                }
                IconButton {
                    iconName: "undo"
                    text: "Undo · Ctrl+Z"
                    size: 29
                    iconSize: 17
                    enabled: root.undoStack.length > 0 && !root.busy
                    onClicked: root.undo()
                }
                IconButton {
                    iconName: "redo"
                    text: "Redo · Ctrl+Shift+Z"
                    size: 29
                    iconSize: 17
                    enabled: root.undone.length > 0 && !root.busy
                    onClicked: root.redo()
                }
                Item {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.preferredHeight: 32
                    Rectangle {
                        id: dragPill
                        anchors.centerIn: parent
                        width: Math.min(104, parent.width)
                        height: 27
                        radius: Theme.radius(13.5)
                        color: dragMouse.containsMouse ? Theme.raised : Theme.surface
                        border.color: Theme.border
                        // Edits never make the pill look busy: a drag that starts before the exact file exists renders it
                        // right away and hands it over as soon as it is written.
                        readonly property bool ready: !root.busy && root.previewReady
                        Row {
                            anchors.centerIn: parent
                            spacing: 6
                            Icon {
                                name: "drag"
                                size: 13
                                color: Theme.textMuted
                            }
                            Text {
                                text: "Drag Me"
                                color: Theme.textSoft
                                font.pixelSize: 10
                            }
                        }
                        ToolTip.visible: dragMouse.containsMouse
                        ToolTip.text: root.status
                        ToolTip.delay: 400
                        Accessible.name: "Drag the edited screenshot into another application"
                        Drag.active: dragMouse.drag.active && ready
                        Drag.dragType: Drag.Automatic
                        Drag.supportedActions: Qt.CopyAction
                        Drag.mimeData: ({
                                "text/uri-list": "file://" + encodeURI(root.previewPath).replace(/#/g, "%23").replace(/\?/g, "%3F")
                            })
                        MouseArea {
                            id: dragMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.busy
                            cursorShape: Qt.OpenHandCursor
                            drag.target: dragProxy
                            onPressed: {
                                root.renderNow();
                                (root.liveShown ? live : picture).grabToImage(function (result) {
                                    dragPill.Drag.imageSource = result.url;
                                });
                            }
                        }
                        Item {
                            id: dragProxy
                        }
                    }
                }
                Text {
                    visible: root.width > 850
                    text: Math.round(root.renderedWidth) + " × " + Math.round(root.renderedHeight)
                    color: Theme.textMuted
                    font.pixelSize: 10
                    Layout.rightMargin: 9
                }
                IconButton {
                    iconName: "copy"
                    text: "Copy edited image"
                    size: 29
                    iconSize: 17
                    enabled: !root.busy
                    onClicked: root.auxiliary(["copy", null], "Edited image copied")
                }
                IconButton {
                    iconName: "save"
                    text: "Save as…"
                    size: 29
                    iconSize: 17
                    enabled: !root.busy
                    onClicked: exportDialog.open()
                }
                IconButton {
                    iconName: "check"
                    text: "Done · Ctrl+S"
                    size: 31
                    iconSize: 18
                    selected: true
                    enabled: !root.busy
                    onClicked: root.finish()
                }
            }
        }
    }
    Shortcut {
        sequence: "Delete"
        enabled: root.selectedIndex >= 0 && !root.textEditing
        onActivated: root.deleteSelected()
    }
    Shortcut {
        sequence: "Backspace"
        enabled: root.selectedIndex >= 0 && !root.textEditing
        onActivated: root.deleteSelected()
    }
    Popup {
        id: inkPopup
        palette: Theme.controls.palette
        x: Math.max(0, root.width - width - 130)
        y: 48
        width: 210
        height: 122
        padding: 12
        background: Rectangle {
            radius: Theme.radius(9)
            color: Theme.panel
            border.color: Theme.border
        }
        ColumnLayout {
            anchors.fill: parent
            Row {
                spacing: 7
                Repeater {
                    model: ["#ff657a", "#ffd166", "#56d6a0", "#65b8ff", "#b699ff", "#ffffff", "#111111"]
                    Rectangle {
                        required property string modelData
                        width: 20
                        height: 20
                        radius: Theme.radius(10)
                        color: modelData
                        border.color: root.ink === modelData ? Theme.text : Theme.borderStrong
                        border.width: root.ink === modelData ? 2 : 1
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.ink = modelData;
                                root.changeSelected("color", modelData);
                                inkPopup.close();
                            }
                        }
                    }
                }
            }
            Entry {
                Layout.fillWidth: true
                text: root.ink
                placeholderText: "#rrggbb"
                onEditingFinished: {
                    if (/^#[0-9a-fA-F]{6}$/.test(text)) {
                        root.ink = text;
                        root.changeSelected("color", text);
                    }
                }
            }
        }
    }
    Shortcut {
        sequence: "Ctrl+Z"
        enabled: root.visible
        onActivated: root.undo()
    }
    Shortcut {
        sequence: "Ctrl+Shift+Z"
        enabled: root.visible
        onActivated: root.redo()
    }
    Shortcut {
        sequence: "Ctrl+S"
        enabled: root.visible && !root.busy
        onActivated: root.finish()
    }
}
