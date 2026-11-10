import {isEditable} from "../composer/keys.js"

export const PREFIX_TIMEOUT_MS = 1000
const DRAWER = "#dashboard-drawer"

// Typing in a field, or focus inside a non-modal dialog (the composer's inputs popover),
// owns the keyboard — the same rule as the canvas hook. The overlay drawer is a dialog too,
// but its links are exactly what the shortcuts click.
export const typing = target =>
  isEditable(target) || Boolean(target?.closest?.(`[role='dialog']:not(${DRAWER})`))

export const modalOpen = doc => Boolean(doc.querySelector(`[aria-modal='true']:not(${DRAWER})`))

// What one keydown does. `pending` is the armed prefix or null.
export function decide({key, altKey, metaKey, ctrlKey, repeat, isComposing, typing, modal, pending, prefixes, hintsKey}) {
  if (altKey || metaKey || ctrlKey || repeat || isComposing || typing) return {type: "ignore"}
  if (key === "Escape") return {type: "hide"}
  if (modal) return pending ? {type: "clear"} : {type: "ignore"}
  if (pending) return {type: "go", combo: `${pending} ${key}`}
  if (key === hintsKey) return {type: "hints"}
  if (prefixes.includes(key)) return {type: "arm", prefix: key}
  return {type: "ignore"}
}
