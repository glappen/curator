// Curator drag-drop upload controller.
//
// Progressive enhancement on top of the upload form. The form works
// without JS — the file <input> is functional on its own. This
// controller adds:
//   - drop-zone highlight on dragenter/dragleave
//   - mirroring dataTransfer.files into the file <input>
//   - auto-submit after a successful drop
//
// Wired via `data-controller="curator--drag-drop"` on the <form>, with
// `data-curator--drag-drop-target="dropzone|input"` on the dropzone div
// and the file input.
//
// JS pipeline wiring (importmap pin or bundler entry) is host-app
// territory until M9. Hosts that haven't wired the engine's JS bundle
// fall back to the plain file picker — the data-* attributes are inert.

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropzone", "input"]

  connect() {
    this.preventBrowserNavigationOnDrop()
  }

  disconnect() {
    this.restoreBrowserDropBehavior()
  }

  dragEnter(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("is-dragging")
  }

  dragOver(event) {
    event.preventDefault()
  }

  dragLeave(event) {
    if (event.target === this.dropzoneTarget) {
      this.dropzoneTarget.classList.remove("is-dragging")
    }
  }

  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("is-dragging")

    const files = event.dataTransfer && event.dataTransfer.files
    if (!files || files.length === 0) return

    this.inputTarget.files = files
    this.element.requestSubmit()
  }

  // Without these, dropping a file outside the dropzone makes the
  // browser navigate to it, abandoning whatever the user was doing.
  preventBrowserNavigationOnDrop() {
    this._windowDragOver = (e) => e.preventDefault()
    this._windowDrop     = (e) => e.preventDefault()
    window.addEventListener("dragover", this._windowDragOver)
    window.addEventListener("drop",     this._windowDrop)
  }

  restoreBrowserDropBehavior() {
    window.removeEventListener("dragover", this._windowDragOver)
    window.removeEventListener("drop",     this._windowDrop)
  }
}
