const EDITABLE_TAGS = new Set(["INPUT", "TEXTAREA", "SELECT"])

// A slider keeps focus after a drag but has no text to undo or escape from.
export const isEditable = target =>
  Boolean(target) && target.type !== "range" &&
  (EDITABLE_TAGS.has(target.tagName) || target.isContentEditable === true)

export const isUndo = event =>
  Boolean(event.metaKey || event.ctrlKey) && !event.shiftKey && event.key.toLowerCase() === "z"

// What one Escape closes, innermost first. `null` leaves it to the browser. Escape while
// typing must not drop the selection, and the inspector you are typing in with it.
// Canvas only is left last, once nothing inside it is open.
export function escapeAction({picker, confirmation, gesture, tools, outline, selection, canvasOnly, editable}) {
  if (picker) return "picker"
  if (confirmation) return "confirmation"
  if (gesture) return "gesture"
  if (tools && !editable) return "tools"
  if (outline && !editable) return "outline"
  if (selection && !editable) return "selection"
  if (canvasOnly && !editable) return "canvasOnly"
  return null
}
