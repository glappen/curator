module Curator
  module Tasks
    # Shared rake-task implementation for `curator:retrievals:export` and
    # `curator:evaluations:export`. Reads ENV-style args (`FORMAT`, `KB`,
    # `SINCE`) and dispatches to the supplied exporter class. Filters
    # are deliberately limited to the CLI subset spelled out in
    # `features/m7-evaluations.md` — the full filter UI lives on the
    # admin views.
    #
    # `KB` and `SINCE` are mapped onto the keys each exporter exposes
    # via its `CLI_KB_KEY` / `CLI_SINCE_KEY` constants — retrievals call
    # them `:kb_slug` / `:from`, evaluations call them `:kb` / `:since`,
    # and the CLI accepts a single `KB=<slug>` / `SINCE=<iso8601>` shape
    # either way. A future third exporter declares its own constants
    # and is automatically supported here.
    module Export
      module_function

      def run(exporter:, env:, io:)
        format = env["FORMAT"].to_s.downcase
        unless %w[csv json].include?(format)
          abort "FORMAT is required and must be csv|json (got #{env['FORMAT'].inspect})"
        end

        exporter.stream(io: io, format: format, filters: build_filters(exporter, env))
      end

      def build_filters(exporter, env)
        filters = {}
        if (kb = env["KB"]) && !kb.empty?
          filters[exporter::CLI_KB_KEY] = kb
        end
        if (since = env["SINCE"]) && !since.empty?
          filters[exporter::CLI_SINCE_KEY] = since
        end
        filters
      end
    end
  end
end
