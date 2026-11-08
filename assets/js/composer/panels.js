// Docking the inspector. A pinned inspector takes its width from the canvas, so it docks
// only while the canvas keeps at least CANVAS_MIN px beside the dock and the PIN_GAP between
// them (0.75rem in app.css); otherwise it stays an overlay.
export const PIN_MIN = 320
export const PIN_MAX = 440
export const PIN_DEFAULT = 384
export const CANVAS_MIN = 600
export const PIN_GAP = 12

export const clampWidth = width => Math.min(PIN_MAX, Math.max(PIN_MIN, width))

export const canPin = (contentWidth, width) => contentWidth - width - PIN_GAP >= CANVAS_MIN
