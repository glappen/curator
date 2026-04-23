require "net/http"
require "uri"

module Curator
  # Fetches http(s) URLs for Curator.ingest_url. Kept deliberately thin —
  # follows redirects, enforces max_bytes, derives a filename and mime
  # type from response headers. SSRF hardening (blocklisting RFC 1918
  # ranges, metadata endpoints, etc.) is a v2 concern; for now the host
  # app decides what URLs it trusts.
  module UrlFetcher
    Fetched = Struct.new(:bytes, :filename, :mime_type, :final_url, keyword_init: true)

    MAX_REDIRECTS    = 5
    OPEN_TIMEOUT     = 10
    READ_TIMEOUT     = 30
    FALLBACK_FILENAME = "download".freeze

    module_function

    def call(url, max_bytes:)
      current = URI(url.to_s)
      unless current.is_a?(URI::HTTP) || current.is_a?(URI::HTTPS)
        raise ArgumentError,
              "Curator.ingest_url only supports http(s) URLs (got #{url.inspect})"
      end

      (MAX_REDIRECTS + 1).times do
        response = get(current)
        case response
        when Net::HTTPSuccess
          body = response.body.to_s
          if body.bytesize > max_bytes
            raise FileTooLargeError,
                  "URL body is #{body.bytesize} bytes; max_document_size is #{max_bytes}."
          end
          return Fetched.new(
            bytes:     body,
            filename:  filename_for(response, current),
            mime_type: mime_for(response),
            final_url: current.to_s
          )
        when Net::HTTPRedirection
          location = response["location"] or
            raise FetchError, "redirect from #{current} missing Location header"
          current = URI.join(current.to_s, location)
        else
          raise FetchError,
                "GET #{current} returned #{response.code} #{response.message}"
        end
      end
      raise FetchError, "too many redirects (>#{MAX_REDIRECTS}) following #{url}"
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => e
      raise FetchError, "fetch failed for #{url}: #{e.class}: #{e.message}"
    end

    def get(uri)
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl:      uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(Net::HTTP::Get.new(uri.request_uri)) }
    end
    private_class_method :get

    # RFC 6266 filename / filename* with a forgiving pattern. Handles
    # unquoted, double-quoted, and RFC 5987 (filename*=UTF-8''foo) forms.
    def filename_for(response, uri)
      disp = response["content-disposition"]
      if disp && (m = disp.match(/filename\*?=(?:UTF-8'')?"?([^"';]+)"?/i))
        name = URI.decode_www_form_component(m[1].strip)
        return name unless name.empty?
      end
      base = File.basename(uri.path.to_s)
      return base unless base.empty? || base == "/"
      FALLBACK_FILENAME
    end
    private_class_method :filename_for

    def mime_for(response)
      ct = response["content-type"]
      ct && !ct.empty? ? ct.split(";").first.strip : nil
    end
    private_class_method :mime_for
  end
end
