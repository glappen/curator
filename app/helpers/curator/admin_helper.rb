module Curator
  module AdminHelper
    KbSwitcher = Struct.new(:current, :all, keyword_init: true)

    # Resolves the data needed to render the topbar KB switcher. Returns
    # nil when no KB-scoped slug is present in params, so the layout can
    # `if`-guard the switcher render. Inside any `kbs/:slug/*` request
    # (Phase 4 nested resources), `params[:knowledge_base_slug]` is set
    # by Rails — find the matching KB or raise (a stale slug in the URL
    # is a real bug, not a UI fallback case).
    def current_kb_for_switcher
      slug = params[:knowledge_base_slug]
      return nil if slug.blank?

      KbSwitcher.new(
        current: Curator::KnowledgeBase.find_by!(slug: slug),
        all:     Curator::KnowledgeBase.order(:name)
      )
    end
  end
end
