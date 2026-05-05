import { Controller } from "@hotwired/stimulus"

// Mutual-exclusion guard for the Retrievals filter form's two
// rating-related controls: the `rating` <select> and the `unrated`
// checkbox. Selecting a rating disables the "Unrated only" toggle
// (a row can't be both rated X and unrated); checking "Unrated
// only" disables the rating dropdown for the same reason.
//
// The server still has the precedence rule (rating wins when both
// arrive), so the JS is purely a UX nudge — a host without JS gets
// the same data, just without the visual lockout.
export default class extends Controller {
  static targets = ["rating", "unrated"]

  connect() {
    this.sync()
  }

  sync() {
    const ratingSelected = this.hasRatingTarget && this.ratingTarget.value !== ""
    const unratedChecked = this.hasUnratedTarget && this.unratedTarget.checked

    if (this.hasUnratedTarget) {
      this.unratedTarget.disabled = ratingSelected
    }
    if (this.hasRatingTarget) {
      this.ratingTarget.disabled = unratedChecked
    }
  }
}
