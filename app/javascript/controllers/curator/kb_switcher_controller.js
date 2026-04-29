import { Controller } from "@hotwired/stimulus"

// Topbar KB switcher. Listens for `change` on its <select> and rewrites
// the slug segment immediately following `/kbs/` in the current URL,
// then navigates with Turbo. Falls back to a full page load if Turbo
// is not on `window` (host apps that haven't pulled it in yet).
export default class extends Controller {
  change(event) {
    const newSlug = event.target.value
    if (!newSlug) return

    const url = new URL(window.location.href)
    const rewritten = url.pathname.replace(
      /\/kbs\/[^/]+/,
      `/kbs/${encodeURIComponent(newSlug)}`
    )
    if (rewritten === url.pathname) return

    url.pathname = rewritten
    const target = url.toString()

    if (window.Turbo && typeof window.Turbo.visit === "function") {
      window.Turbo.visit(target)
    } else {
      window.location.assign(target)
    }
  }
}
