require "nokogiri"

module Curator
  module Extractors
    # Dependency-free extractor for plain text formats. Handles text/plain,
    # text/markdown, text/csv, text/html (tags stripped via Nokogiri).
    #
    # Anything outside this whitelist raises UnsupportedMimeError pointing
    # the user at `config.extractor = :kreuzberg`.
    class Basic
      EXTENSIONS = {
        ".txt"      => "text/plain",
        ".md"       => "text/markdown",
        ".markdown" => "text/markdown",
        ".csv"      => "text/csv",
        ".html"     => "text/html",
        ".htm"      => "text/html"
      }.freeze

      def extract(path)
        path = path.to_s
        ext  = File.extname(path).downcase
        mime = EXTENSIONS[ext] or
          raise UnsupportedMimeError,
                "Basic extractor cannot handle #{ext.empty? ? path : ext.inspect}. " \
                "For PDF, Office, and other rich formats set `config.extractor = :kreuzberg`."

        raw = File.read(path, encoding: "utf-8")
        content = mime == "text/html" ? strip_html(raw) : raw

        ExtractionResult.new(content: content, mime_type: mime, pages: [])
      end

      private

      def strip_html(html)
        Nokogiri::HTML(html).text.strip
      end
    end
  end
end
