import { Controller } from "@hotwired/stimulus"

// Reorders streamed answer chunks by `data-seq`. Each `broadcast_append_to`
// from Curator::ConsoleStreamJob appends a `<span data-seq="N">delta</span>`
// to this element. Action Cable's pubsub does not guarantee in-order
// delivery on a single stream, so spans can land out of order even though
// the server broadcasts them sequentially. We fix it client-side: a
// MutationObserver watches for new spans and, if any landed out of seq
// order, sorts the children numerically. The observer is disconnected
// during the reorder pass so our own appendChild calls don't re-trigger
// the sort.
export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(this.sort.bind(this))
    this.observer.observe(this.element, { childList: true })
  }

  disconnect() {
    this.observer?.disconnect()
    this.observer = null
  }

  sort(mutations) {
    const sawNewSeq = mutations.some(m =>
      Array.from(m.addedNodes).some(n =>
        n.nodeType === Node.ELEMENT_NODE && n.dataset && n.dataset.seq != null
      )
    )
    if (!sawNewSeq) return

    const items = Array.from(this.element.children)
      .filter(el => el.dataset && el.dataset.seq != null)

    let inOrder = true
    for (let i = 1; i < items.length; i++) {
      if (parseInt(items[i].dataset.seq, 10) < parseInt(items[i - 1].dataset.seq, 10)) {
        inOrder = false
        break
      }
    }
    if (inOrder) return

    items.sort((a, b) => parseInt(a.dataset.seq, 10) - parseInt(b.dataset.seq, 10))

    this.observer.disconnect()
    items.forEach(el => this.element.appendChild(el))
    this.observer.observe(this.element, { childList: true })
  }
}
