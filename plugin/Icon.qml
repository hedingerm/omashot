import QtQuick
import QtQuick.Effects

// Original 24 px line icons. SVG rendering avoids font dependencies and missing glyphs.
Image {
    id: root
    property string name: "more"
    property color color: Theme.text
    property int size: 20
    width: size
    height: size
    sourceSize.width: size * 2
    sourceSize.height: size * 2
    fillMode: Image.PreserveAspectFit
    smooth: true
    readonly property var drawings: ({
            "capture": '<path d="M8 3H5a2 2 0 0 0-2 2v3m13-5h3a2 2 0 0 1 2 2v3M3 16v3a2 2 0 0 0 2 2h3m13-5v3a2 2 0 0 1-2 2h-3M12 7v10M7 12h10"/>',
            "window": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M7 6.5h.01m3 0h.01"/>',
            "screen": '<rect x="2.5" y="3.5" width="19" height="13" rx="2"/><path d="M8 21h8m-4-4.5V21"/>',
            "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
            "history": '<path d="M3 11a9 9 0 1 1 2.6 7.4M3 5v6h6m3-4v5l3 2"/>',
            "import": '<path d="M12 3v12m-4-4 4 4 4-4M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/>',
            "settings": '<path d="m9 4 1-2h4l1 2 2 1 2-.1 2 3.4-1.1 1.8v3.8l1.1 1.8-2 3.4-2-.1-2 1-1 2h-4l-1-2-2-1-2 .1-2-3.4L4.1 14v-3.8L3 8.4 5 5l2 .1Z"/><circle cx="12" cy="12" r="3"/>',
            "close": '<path d="m6 6 12 12M18 6 6 18"/>',
            "undo": '<path d="m8 5-5 5 5 5M3 10h11a6 6 0 0 1 0 12" transform="translate(0 -2)"/>',
            "redo": '<path d="m16 5 5 5-5 5m5-5H10a6 6 0 0 0 0 12" transform="translate(0 -2)"/>',
            "arrow": '<path d="M4 20 20 4M9 4h11v11"/>',
            "line": '<path d="m4 20 16-16"/>',
            "rectangle": '<rect x="4" y="5" width="16" height="14" rx="1"/>',
            "filled": '<rect x="4" y="5" width="16" height="14" rx="1" fill="currentColor"/>',
            "ellipse": '<ellipse cx="12" cy="12" rx="9" ry="7"/>',
            "text": '<path d="M4 7V4h16v3M12 4v16m-4 0h8"/>',
            "step": '<circle cx="12" cy="12" r="9"/><path d="m10 9 2-2v10m-2 0h4"/>',
            "freehand": '<path d="m4 20 4-1L20 7l-3-3L5 16l-1 4Zm1-4 3 3M14 7l3 3"/>',
            "pencil": '<path d="m4 20 4-1L20 7l-3-3L5 16l-1 4Zm1-4 3 3M14 7l3 3"/>',
            "highlight": '<path d="m7 16 8-11 5 4-8 11-5-4Zm1 1-4 3h7M3 23h18"/>',
            "spotlight": '<path d="m8 8 8-5 5 8-8 5-5-8Zm3 7L5 21m-2-5 2 5 5 1"/>',
            "redact": '<rect x="3" y="7" width="18" height="10" rx="1" fill="currentColor"/><path d="M5 3h7m-7 18h14"/>',
            "pixelate": '<path d="M3 3h6v6H3Zm12 0h6v6h-6ZM9 9h6v6H9ZM3 15h6v6H3Zm12 0h6v6h-6Z" fill="currentColor" stroke-width="1"/>',
            "crop": '<path d="M6 2v14a2 2 0 0 0 2 2h14M2 6h14a2 2 0 0 1 2 2v14"/>',
            "rotate": '<path d="M4 10a8 8 0 1 1 2 8M4 4v6h6"/><path d="M11 9h6v6h-6z"/>',
            "flip": '<path d="M12 2v20M3 6h6v12H3Zm12 0h6v12h-6Z"/>',
            "resize": '<path d="M9 3H3v6m12 12h6v-6M3 3l7 7m11 11-7-7M14 3h7v7M3 14v7h7"/>',
            "background": '<rect x="3" y="3" width="18" height="18" rx="3"/><rect x="7" y="7" width="10" height="10" rx="1"/><path d="m4 9 5-5m6 16 5-5M4 15l3-3m5-5 3-3"/>',
            "copy": '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
            "save": '<path d="M5 3h12l4 4v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"/><path d="M7 3v6h9V3M7 21v-8h10v8"/>',
            "pin": '<path d="m9 3 12 12m-9-9-5 5-3 1 8 8 1-3 5-5M3 21l5-5"/>',
            "ocr": '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5M7 9V7h10v2m-5-2v10m-3 0h6"/>',
            "qr": '<path d="M3 3h6v6H3Zm12 0h6v6h-6ZM3 15h6v6H3Zm12 0h3v3h3v3h-6Zm6-3v3m-9-3v3M3 12h3m6-9v3m0 12v3"/>',
            "trash": '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7"/>',
            "check": '<path d="m4 12 5 5L20 6"/>',
            "more": '<circle cx="5" cy="12" r="1" fill="currentColor"/><circle cx="12" cy="12" r="1" fill="currentColor"/><circle cx="19" cy="12" r="1" fill="currentColor"/>',
            "expand": '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/>',
            "drag": '<path d="m12 2-3 3m3-3 3 3m-3-3v20m0 0-3-3m3 3 3-3M2 12l3-3m-3 3 3 3m-3-3h20m0 0-3-3m3 3-3 3"/>',
            "zoom": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
            "zoom-in": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5M7.5 10.5h6m-3-3v6"/>',
            "zoom-out": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5M7.5 10.5h6"/>',
            "plus": '<path d="M12 4v16M4 12h16"/>',
            "minus": '<path d="M4 12h16"/>',
            "image": '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/>',
            "folder": '<path d="M3 7V5a2 2 0 0 1 2-2h5l3 3h6a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z"/>',
            "chevron": '<path d="m6 9 6 6 6-6"/>',
            "reset": '<path d="M3 10a9 9 0 1 1 2 8M3 4v6h6"/>',
            "blur": '<path d="M12 2C8 7 5 11 5 15a7 7 0 0 0 14 0c0-4-3-8-7-13Z"/><path d="M7 14h10m-9 4h8m-6-8h4" opacity=".55"/>',
            "palette": '<path d="M12 3a9 9 0 1 0 0 18h1a2 2 0 0 0 1-3.7 1.4 1.4 0 0 1 .7-2.6H18a3 3 0 0 0 3-3A9 9 0 0 0 12 3Z"/><circle cx="7" cy="11" r="1" fill="currentColor"/><circle cx="10" cy="7" r="1" fill="currentColor"/><circle cx="15" cy="7" r="1" fill="currentColor"/><circle cx="18" cy="11" r="1" fill="currentColor"/>',
            "select": '<path d="m5 3 14 9-7 1-3 7-4-17Z"/>',
            "search": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>'
        })
    readonly property string resolvedName: name === "chevron-down" ? "chevron" : name === "wallpaper" ? "image" : name
    // Square corners (Theme.rounded off, the Omarchy default): no rect rx, straight corner arcs, square caps.
    readonly property var squareDrawings: ({
            "capture": '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5M12 7v10M7 12h10"/>',
            "import": '<path d="M12 3v12m-4-4 4 4 4-4M4 15v6h16v-6"/>',
            "crop": '<path d="M6 2v16h16M2 6h16v16"/>',
            "copy": '<rect x="8" y="8" width="13" height="13"/><path d="M16 8V3H3v13h5"/>',
            "save": '<path d="M3 3h14l4 4v14H3Z"/><path d="M7 3v6h9V3M7 21v-8h10v8"/>',
            "folder": '<path d="M3 3h7l3 3h8v15H3Z"/>'
        })
    readonly property string drawing: Theme.rounded ? (drawings[resolvedName] || drawings.more) : squareDrawings[resolvedName] || (drawings[resolvedName] || drawings.more).replace(/(<rect[^>]*?) rx="[^"]*"/g, "$1")
    source: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="' + ink + '" color="' + ink + '" stroke-width="1.8" stroke-linecap="' + (Theme.rounded ? "round" : "square") + '" stroke-linejoin="' + (Theme.rounded ? "round" : "miter") + '">' + drawing + '</svg>')
    // Rasterize once in white and tint on the GPU so theme fades never re-render SVGs;
    // the software renderer (offscreen tests) has no shader effects, so bake the color there.
    readonly property bool tinted: GraphicsInfo.api !== GraphicsInfo.Software
    readonly property string ink: tinted ? "#ffffff" : color.toString()
    layer.enabled: tinted
    layer.effect: MultiEffect {
        colorization: 1
        colorizationColor: root.color
    }
}
