import { Controller } from "@hotwired/stimulus"

// Bridges the Console's thumbs UI to the standard Rails form submit.
// Either thumb is a `type="button"` (so it doesn't submit on its own);
// `setRating` writes the chosen rating into the hidden `rating`
// target and then asks the form to submit. The server returns a
// turbo_stream that swaps `#console-evaluation` with the rating-aware
// form partial.
//
// We keep the thumbs as plain buttons (rather than `type="submit"`
// with `name="rating" value="..."`) so the rating-aware form can use
// the same control to *flip* an existing rating without colliding with
// a hidden `rating` field — Rails param-merging order between hidden
// inputs and submitter buttons is implementation-specific and
// surprised us once already.
export default class extends Controller {
  static targets = ["form", "rating"]

  setRating(event) {
    const rating = event.params.rating
    if (!rating) return
    this.ratingTarget.value = rating
    // Flipping :negative -> :positive while categories are still checked
    // would post an invalid combo (the model rejects categories on
    // anything other than :negative, by design). Clear them client-side
    // so the flip "just works"; the server re-renders the form in
    // :positive shape, where the categories fieldset isn't drawn.
    if (rating === "positive") this.clearFailureCategories()
    this.formTarget.requestSubmit()
  }

  clearFailureCategories() {
    this.formTarget
      .querySelectorAll('input[name="failure_categories[]"]:checked')
      .forEach(cb => { cb.checked = false })
  }
}
