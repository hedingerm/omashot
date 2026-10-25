import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell.Widgets
import "AnnotationGeometry.js" as Geometry

// Live GPU preview of an edit: base pixels, annotations and background, redrawn in the frame after every change.
// It mirrors the backend render; the editor shows the exact backend pixels instead once they catch up.
Item {
    id: scene
    property url baseSource
    property real baseWidth: 1
    property real baseHeight: 1
    property var operations: []
    // A transform whose flattened base isn't rendered yet: the base and `preOperations` are drawn through it.
    property var transformOp: null
    property var preOperations: []
    property var background: null
    property var balance: null
    property var gradients: []
    property real zoom: 1
    readonly property var stageSize: Geometry.documentSize(baseWidth, baseHeight, preOperations)
    readonly property var change: transformOp ? Geometry.transformOf(transformOp, stageSize.w, stageSize.h) : null
    readonly property var documentSize: change ? Geometry.documentSize(change.w, change.h, operations) : Geometry.documentSize(baseWidth, baseHeight, operations)
    readonly property var layout: Geometry.sceneLayout(documentSize.w, documentSize.h, background, balance)
    readonly property bool ready: base.status === Image.Ready
    width: layout.w * zoom
    height: layout.h * zoom

    Item {
        id: canvas
        width: scene.layout.w
        height: scene.layout.h
        transform: Scale {
            xScale: scene.zoom
            yScale: scene.zoom
        }
        // Rendered at document resolution and scaled like the backend image, so the swap to exact pixels doesn't pop.
        layer.enabled: Math.max(width, height) <= 8192
        layer.smooth: true
        Loader {
            anchors.fill: parent
            // Created up front so enabling a background doesn't pay for component creation mid-drag.
            visible: !!scene.background
            sourceComponent: backdrop
        }
        RectangularShadow {
            readonly property var bg: scene.background || {}
            // Always drawn (transparent without a shadow) so its shader is ready before the first background.
            readonly property bool shown: !!scene.background && bg.shadow !== false
            x: scene.layout.frame.x + Geometry.trunc(Geometry.clamp(Geometry.num(bg, "shadow_offset_x", 0), -100, 100))
            y: scene.layout.frame.y + scene.layout.offset
            width: scene.layout.frame.w
            height: scene.layout.frame.h
            radius: Math.min(width, height) / 2 > 0 ? Math.min(Geometry.clamp(Geometry.num(bg, "radius", 0), 0, 300) + scene.layout.inset, Math.min(width, height) / 2) : 0
            blur: Geometry.clamp(Geometry.num(bg, "shadow_blur", 18), 0, 100) * 2.5
            color: Qt.rgba(0, 0, 0, shown ? Geometry.clamp(Geometry.num(bg, "shadow_strength", .35), 0, 1) : 0)
        }
        Rectangle {
            visible: scene.layout.inset > 0
            x: scene.layout.frame.x
            y: scene.layout.frame.y
            width: scene.layout.frame.w
            height: scene.layout.frame.h
            radius: Math.min(Geometry.clamp(Geometry.num(scene.background, "radius", 0), 0, 300) + scene.layout.inset, width / 2, height / 2)
            color: Geometry.qmlColor(scene.background ? scene.background.inset_color || "#ffffff" : "#ffffff")
        }
        ClippingRectangle {
            id: frame
            x: scene.layout.content.x
            y: scene.layout.content.y
            width: scene.layout.content.w
            height: scene.layout.content.h
            color: "transparent"
            radius: scene.background ? Math.min(Geometry.clamp(Geometry.num(scene.background, "radius", 0), 0, 300), width / 2, height / 2) : 0
            Item {
                id: documentItem
                x: -scene.layout.content.sourceX
                y: -scene.layout.content.sourceY
                width: scene.documentSize.w
                height: scene.documentSize.h
                Rectangle {
                    visible: !!scene.change && !!scene.change.fill
                    width: scene.documentSize.w
                    height: scene.documentSize.h
                    color: scene.change && scene.change.fill ? scene.change.fill : "transparent"
                }
                Item {
                    width: scene.stageSize.w
                    height: scene.stageSize.h
                    transform: Matrix4x4 {
                        readonly property var m: scene.change ? scene.change.m : [1, 0, 0, 0, 1, 0]
                        matrix: Qt.matrix4x4(m[0], m[1], 0, m[2], m[3], m[4], 0, m[5], 0, 0, 1, 0, 0, 0, 0, 1)
                    }
                    Image {
                        id: base
                        width: scene.baseWidth
                        height: scene.baseHeight
                        source: scene.baseSource
                        smooth: true
                    }
                    Repeater {
                        model: scene.preOperations.length
                        Annotation {
                            required property int index
                            op: scene.preOperations[index] || ({})
                        }
                    }
                }
                Repeater {
                    model: scene.operations.length
                    Annotation {
                        required property int index
                        op: scene.operations[index] || ({})
                    }
                }
            }
        }
    }

    component Annotation: Item {
        id: annotation
        property var op
        property var shown: ({})
        property string signature: ""
        // Gestures replace one entry and keep the others by reference; edits elsewhere clone, so compare content.
        onOpChanged: {
            if (op === shown)
                return;
            var next = JSON.stringify(op);
            if (next !== signature) {
                signature = next;
                shown = op;
            }
        }
        readonly property string type: shown.type || ""
        readonly property string ink: Geometry.qmlColor(shown.color)
        readonly property real stroke: Geometry.clamp(Geometry.num(shown, "width", 4), 1, 100)
        readonly property var box: Geometry.rasterBox(shown, scene.documentSize.w, scene.documentSize.h)
        Loader {
            active: ["line", "arrow", "rectangle", "filled", "ellipse", "freehand"].indexOf(annotation.type) >= 0
            sourceComponent: Shape {
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: annotation.ink
                    strokeWidth: annotation.stroke
                    fillColor: annotation.type === "filled" ? annotation.ink : "transparent"
                    joinStyle: ShapePath.MiterJoin
                    capStyle: ShapePath.FlatCap
                    PathSvg {
                        path: Geometry.svgPath(annotation.shown)
                    }
                }
                ShapePath {
                    strokeColor: annotation.type === "arrow" ? annotation.ink : "transparent"
                    strokeWidth: annotation.stroke
                    fillColor: annotation.type === "arrow" ? annotation.ink : "transparent"
                    joinStyle: ShapePath.MiterJoin
                    PathSvg {
                        path: annotation.type === "arrow" ? Geometry.arrowHead(annotation.shown) : ""
                    }
                }
            }
        }
        Loader {
            active: annotation.type === "text" || annotation.type === "step"
            sourceComponent: Item {
                id: textItem
                readonly property string style: typeof annotation.shown.style === "string" ? annotation.shown.style : "standard"
                readonly property real size: Geometry.clamp(Geometry.num(annotation.shown, "size", 28), 6, 500)
                readonly property real x0: Geometry.num(annotation.shown, "x", 0)
                readonly property real y0: Geometry.num(annotation.shown, "y", 0)
                readonly property string label: typeof annotation.shown.text === "string" ? annotation.shown.text : "1"
                readonly property bool boxed: annotation.type === "text" && ["boxed", "rounded_boxed", "monospaced_boxed"].indexOf(style) >= 0
                Rectangle {
                    visible: parent.boxed
                    readonly property real tw: Geometry.num(annotation.shown, "w", Math.max(8, parent.label.length * parent.size * .63))
                    readonly property real th: Geometry.num(annotation.shown, "h", parent.size * 1.4)
                    x: parent.x0 - 8 + .5
                    y: parent.y0 - 4 + .5
                    width: tw + 16
                    height: th + 8
                    radius: parent.style === "rounded_boxed" ? parent.size * .25 : 0
                    color: annotation.ink
                }
                Rectangle {
                    visible: annotation.type === "step"
                    readonly property real r: parent.size * .7 + annotation.stroke / 2
                    x: parent.x0 + .5 - r
                    y: parent.y0 + .5 - r
                    width: r * 2
                    height: r * 2
                    radius: r
                    color: annotation.ink
                }
                // ImageMagick's NorthWest annotate puts the top of the inked first line at y, not the line box.
                TextMetrics {
                    id: ink
                    font: label.font
                    text: textItem.label.split("\n")[0] || " "
                }
                Text {
                    id: label
                    // Centered steps center the label's ink on the dot; older ops keep the fixed offset.
                    readonly property bool centered: annotation.type === "step" && annotation.shown.centered === true
                    x: (centered ? parent.x0 - ink.tightBoundingRect.x - ink.tightBoundingRect.width / 2 : annotation.type === "step" ? parent.x0 - parent.size * .3 : parent.x0) + .5
                    y: (centered ? parent.y0 - ink.tightBoundingRect.height / 2 : annotation.type === "step" ? parent.y0 - parent.size * .65 : parent.y0) - baselineOffset - ink.tightBoundingRect.y
                    text: parent.label
                    textFormat: Text.PlainText
                    color: parent.boxed || annotation.type === "step" ? "white" : annotation.ink
                    font.pixelSize: parent.size
                    font.family: parent.style.indexOf("monospaced") === 0 ? "monospace" : "sans-serif"
                    font.bold: parent.style === "rounded"
                    style: annotation.type === "text" && parent.style === "outlined" ? Text.Outline : Text.Normal
                    styleColor: "white"
                }
            }
        }
        Rectangle {
            visible: annotation.type === "highlight" || annotation.type === "redact"
            x: annotation.box.x
            y: annotation.box.y
            width: annotation.box.w
            height: annotation.box.h
            radius: annotation.type === "highlight" ? Geometry.clamp(Geometry.num(annotation.shown, "radius", height / 2), 0, Math.min(width, height) / 2) : 0
            color: annotation.type === "redact" ? "black" : annotation.ink
            opacity: annotation.type === "redact" ? 1 : Geometry.clamp(Geometry.num(annotation.shown, "opacity", .35), 0, 1)
        }
        Loader {
            active: annotation.type === "spotlight"
            sourceComponent: Shape {
                readonly property var b: annotation.box
                readonly property real r: Geometry.clamp(Geometry.num(annotation.shown, "radius", 12), 0, Math.min(b.w, b.h) / 2)
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillRule: ShapePath.OddEvenFill
                    fillColor: "#b3000000"
                    strokeColor: "transparent"
                    PathSvg {
                        path: "M0 0H" + scene.documentSize.w + "V" + scene.documentSize.h + "H0Z" + Geometry.roundedRect(b.x, b.y, b.w, b.h, r)
                    }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: "white"
                    strokeWidth: 2
                    PathSvg {
                        path: Geometry.roundedRect(b.x + 1, b.y + 1, b.w - 2, b.h - 2, r - 1)
                    }
                }
            }
        }
        Loader {
            active: annotation.type === "pixelate" || annotation.type === "blur"
            x: annotation.box.x
            y: annotation.box.y
            width: annotation.box.w
            height: annotation.box.h
            sourceComponent: Item {
                clip: true
                readonly property bool pixelate: annotation.type === "pixelate"
                readonly property real block: Math.floor(Geometry.clamp(Geometry.num(annotation.shown, "strength", 12), 4, 64))
                readonly property real sigma: Geometry.clamp(Geometry.num(annotation.shown, "strength", 12), 1, 80)
                // Pixelation repeats each block's top-left pixel (texels sample their centers, hence the shift);
                // blur reads beyond the box like the backend's whole-image blur.
                readonly property real margin: pixelate ? 0 : Math.ceil(sigma * 3)
                readonly property size cells: Qt.size(Math.max(1, Math.ceil(width / block)), Math.max(1, Math.ceil(height / block)))
                ShaderEffectSource {
                    id: region
                    x: -parent.margin
                    y: -parent.margin
                    width: parent.pixelate ? parent.cells.width * parent.block : parent.width + parent.margin * 2
                    height: parent.pixelate ? parent.cells.height * parent.block : parent.height + parent.margin * 2
                    sourceItem: base
                    sourceRect: parent.pixelate ? Qt.rect(annotation.box.x + .5 - parent.block / 2, annotation.box.y + .5 - parent.block / 2, width, height) : Qt.rect(annotation.box.x - parent.margin, annotation.box.y - parent.margin, width, height)
                    textureSize: parent.pixelate ? parent.cells : Qt.size(0, 0)
                    smooth: !parent.pixelate
                    visible: parent.pixelate
                }
                MultiEffect {
                    anchors.fill: region
                    visible: !parent.pixelate
                    source: region
                    blurEnabled: true
                    blurMax: 64
                    blur: Math.min(1, parent.sigma * 2.5 / 64)
                    autoPaddingEnabled: false
                }
            }
        }
        Image {
            visible: annotation.type === "image"
            x: Geometry.num(annotation.shown, "x", 0)
            y: Geometry.num(annotation.shown, "y", 0)
            width: Math.max(1, Geometry.num(annotation.shown, "w", 100))
            height: Math.max(1, Geometry.num(annotation.shown, "h", 100))
            source: visible && annotation.shown.path ? "file://" + annotation.shown.path : ""
            asynchronous: true
            smooth: true
        }
    }

    Component {
        id: backdrop
        Item {
            id: back
            readonly property var bg: scene.background || {}
            readonly property string mode: typeof bg.mode === "string" ? bg.mode : "gradient"
            readonly property real blur: Geometry.clamp(Geometry.num(bg, "blur", mode === "blurred" ? 24 : 0), 0, 100)
            readonly property int preset: Math.floor(Geometry.num(bg, "preset", 0)) % 20
            readonly property var presets: ["#6366f1", "#ec4899", "#06b6d4", "#f97316", "#22c55e", "#8b5cf6", "#ef4444", "#0ea5e9", "#eab308", "#14b8a6", "#a855f7", "#f43f5e", "#3b82f6", "#84cc16", "#d946ef", "#64748b", "#fb923c", "#2dd4bf", "#818cf8", "#f472b6"]
            Item {
                id: fill
                anchors.fill: parent
                visible: back.blur <= 0
                Rectangle {
                    anchors.fill: parent
                    visible: back.mode === "solid" || back.mode === "gradient" && back.bg.gradient_version !== 2
                    color: back.mode === "solid" ? Geometry.qmlColor(back.bg.background_color || "#6366f1") : "transparent"
                    gradient: back.mode === "gradient" ? linear : null
                    Gradient {
                        id: linear
                        GradientStop {
                            position: 0
                            color: back.presets[Math.max(0, back.preset)]
                        }
                        GradientStop {
                            position: 1
                            color: "#111827"
                        }
                    }
                }
                Image {
                    anchors.fill: parent
                    readonly property var mesh: scene.gradients[Math.max(0, back.preset)]
                    visible: back.mode === "gradient" && back.bg.gradient_version === 2
                    source: mesh ? "file://" + mesh.path : ""
                    smooth: true
                }
                Image {
                    anchors.fill: parent
                    visible: back.mode === "wallpaper" || back.mode === "blurred"
                    source: !visible ? "" : back.bg.image_path ? "file://" + back.bg.image_path : scene.baseSource
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                }
            }
            MultiEffect {
                anchors.fill: parent
                visible: back.blur > 0
                source: fill
                blurEnabled: true
                blurMax: 64
                blur: Math.min(1, back.blur * 2.5 / 64)
                autoPaddingEnabled: false
            }
        }
    }
}
