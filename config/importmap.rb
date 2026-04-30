# Engine importmap. Merged into the host app's importmap by the
# `curator.importmap` initializer in lib/curator/engine.rb. Host pins
# (e.g. `@hotwired/stimulus`) win on collision because host pins load
# after engine pins; this file only contributes engine-owned modules.

pin "curator", to: "curator.js", preload: true
pin "controllers/curator/kb_switcher_controller",
    to: "controllers/curator/kb_switcher_controller.js", preload: true
pin "controllers/curator/drag_drop_controller",
    to: "controllers/curator/drag_drop_controller.js", preload: true
