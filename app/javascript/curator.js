// Curator engine entry point. Loaded by the engine layout via
// `javascript_importmap_tags "curator"`. Boots a *private* Stimulus
// `Application` instance and registers the two engine-owned
// controllers under their existing identifiers.
//
// The application is intentionally not assigned to `window.Stimulus`
// so it cannot conflict with a host-app Stimulus instance running on
// the same page. The identifiers (`kb-switcher`, `curator--drag-drop`)
// are scoped to engine views, so even on shared DOMs the two
// applications do not fight over the same elements.

import { Application } from "@hotwired/stimulus"
import KbSwitcherController from "controllers/curator/kb_switcher_controller"
import DragDropController from "controllers/curator/drag_drop_controller"

const application = Application.start()
application.debug = false
application.register("kb-switcher", KbSwitcherController)
application.register("curator--drag-drop", DragDropController)

export { application }
