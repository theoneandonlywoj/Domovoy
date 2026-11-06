const EDITABLE_TAGS = new Set(["INPUT", "TEXTAREA", "SELECT"])

export const isEditable = target =>
  Boolean(target) && (EDITABLE_TAGS.has(target.tagName) || target.isContentEditable === true)

export const isUndo = event =>
  Boolean(event.metaKey || event.ctrlKey) && !event.shiftKey && event.key.toLowerCase() === "z"

// What one Escape closes, innermost first. `null` leaves it to the browser. Escape while
// typing must not drop the selection, and the inspector you are typing in with it.
export function escapeAction({picker, confirmation, gesture, tools, selection, editable}) {
  if (picker) return "picker"
  if (confirmation) return "confirmation"
  if (gesture) return "gesture"
  if (tools && !editable) return "tools"
  if (selection && !editable) return "selection"
  return null
}
