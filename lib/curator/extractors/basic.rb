require "nokogiri"

module Curator
  module Extractors
    # Dependency-free extractor for plain text formats. Handles text/plain,
    # text/markdown, text/csv, text/html (tags stripped via Nokogiri).
    #
    # Anything outside this whitelist raises UnsupportedMimeError pointing
    # the user at `config.extractor = :kreuzberg`.
    class Basic
      SUPPORTED_MIME_TYPES = %w[
        text/plain
        text/markdown
        text/csv
        text/html
      ].freeze

      # Dispatches by mime_type rather than file extension: ActiveStorage
      # tempfile paths and URL fetches don't always carry a meaningful
      # extension, but the document already has a Marcel-derived mime_type
      # from FileNormalizer. Pass it in.
      def extract(path, mime_type:)
        unless SUPPORTED_MIME_TYPES.include?(mime_type)
          raise UnsupportedMimeError,
                "Basic extractor cannot handle #{mime_type.inspect}. " \
                "For PDF, Office, and other rich formats set `config.extractor = :kreuzberg`."
        end

        raw     = File.read(path.to_s, encoding: "utf-8")
        content = mime_type == "text/html" ? strip_html(raw) : raw

        ExtractionResult.new(content: content, mime_type: mime_type, pages: [])
      end

      private

      def strip_html(html)
        Nokogiri::HTML(html).text.strip
      end
    end
  end
end
