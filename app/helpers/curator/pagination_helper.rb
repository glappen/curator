module Curator
  module PaginationHelper
    Page = Struct.new(:records, :page, :per, :total, :pages, keyword_init: true)

    PER_MAX = 100

    # Hand-rolled pagination. Returns a Page struct usable directly by
    # `_pagination.html.erb`. We avoid a runtime dependency on kaminari
    # because the chunk inspector and doc index need only prev/next +
    # page-N links — no window-of-pages, no theme integration. Easy to
    # swap in a richer paginator later if filtering grows tabular.
    #
    # `page` and `per` are clamped at the helper boundary so callers can
    # forward `params[:page]` / `params[:per]` blind.
    def paginate(scope, page:, per:)
      per   = clamp(per.to_i, 1, PER_MAX, default: 25)
      total = scope.count
      pages = [ (total.to_f / per).ceil, 1 ].max
      page  = clamp(page.to_i, 1, pages, default: 1)

      records = scope.offset((page - 1) * per).limit(per)

      Page.new(records: records, page: page, per: per, total: total, pages: pages)
    end

    private

    def clamp(value, min, max, default:)
      return default if value <= 0

      value.clamp(min, max)
    end
  end
end
