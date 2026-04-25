require "net/http"
require "ipaddr"
require "resolv"
require "uri"

module Curator
  # Fetches http(s) URLs for Curator.ingest. Follows redirects,
  # enforces max_bytes, derives a filename and mime type from response
  # headers, and rejects loopback/private-network targets so user-supplied
  # URLs cannot pivot into local infrastructure.
  module UrlFetcher
    Fetched = Struct.new(:bytes, :filename, :mime_type, :final_url, keyword_init: true)

    MAX_REDIRECTS    = 5
    OPEN_TIMEOUT     = 10
    READ_TIMEOUT     = 30
    FALLBACK_FILENAME = "download".freeze
    BLOCKED_HOSTNAMES = %w[localhost localhost.localdomain].freeze
    BLOCKED_IP_RANGES = [
      IPAddr.new("0.0.0.0/8"),
      IPAddr.new("10.0.0.0/8"),
      IPAddr.new("100.64.0.0/10"),
      IPAddr.new("127.0.0.0/8"),
      IPAddr.new("169.254.0.0/16"),
      IPAddr.new("172.16.0.0/12"),
      IPAddr.new("192.168.0.0/16"),
      IPAddr.new("224.0.0.0/4"),
      IPAddr.new("::/128"),
      IPAddr.new("::1/128"),
      IPAddr.new("fc00::/7"),
      IPAddr.new("fe80::/10"),
      IPAddr.new("ff00::/8")
    ].freeze
    # Strip C0/C1 control chars, NULs, and path separators from filenames
    # parsed out of attacker-controlled headers.
    UNSAFE_FILENAME_CHARS = /[\x00-\x1f\x7f\/\\]/.freeze

    module_function

    def call(url, max_bytes:)
      current = ensure_safe_uri!(ensure_http!(URI(url.to_s), context: url))

      (MAX_REDIRECTS + 1).times do
        body = nil
        response = stream(current, max_bytes: max_bytes) { |b| body = b }

        case response
        when Net::HTTPSuccess
          return Fetched.new(
            bytes:     body,
            filename:  filename_for(response, current),
            mime_type: mime_for(response),
            final_url: current.to_s
          )
        when Net::HTTPRedirection
          location = response["location"] or
            raise FetchError, "redirect from #{current} missing Location header"
          current = ensure_safe_uri!(ensure_http!(URI.join(current.to_s, location), context: location))
        else
          raise FetchError,
                "GET #{current} returned #{response.code} #{response.message}"
        end
      end
      raise FetchError, "too many redirects (>#{MAX_REDIRECTS}) following #{url}"
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => e
      raise FetchError, "fetch failed for #{url}: #{e.class}: #{e.message}"
    end

    def ensure_http!(uri, context:)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise ArgumentError,
              "Curator URL ingest only supports http(s) URLs (got #{context.inspect})"
      end
      uri
    end
    private_class_method :ensure_http!

    def ensure_safe_uri!(uri)
      host = uri.host.to_s
      if BLOCKED_HOSTNAMES.include?(host.downcase)
        raise FetchError, "refusing to fetch #{uri}: host resolves to a blocked local address"
      end

      resolved_addresses(host).each do |address|
        ip = IPAddr.new(address)
        next unless blocked_ip?(ip)

        raise FetchError, "refusing to fetch #{uri}: #{address} is in a blocked network range"
      end

      uri
    end
    private_class_method :ensure_safe_uri!

    def resolved_addresses(host)
      return [ host ] if ip_literal?(host)

      Resolv.getaddresses(host).tap do |addresses|
        raise FetchError, "fetch failed: #{host.inspect} did not resolve to an IP address" if addresses.empty?
      end
    rescue Resolv::ResolvError => e
      raise FetchError, "fetch failed resolving #{host.inspect}: #{e.message}"
    end
    private_class_method :resolved_addresses

    def ip_literal?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError
      false
    end
    private_class_method :ip_literal?

    def blocked_ip?(ip)
      BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
    end
    private_class_method :blocked_ip?

    # Streams the response body, accumulating into a String buffer that
    # aborts as soon as max_bytes is exceeded. For redirect responses we
    # don't read the body — callers only need headers.
    def stream(uri, max_bytes:)
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl:      uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        http.request(request) do |response|
          if response.is_a?(Net::HTTPSuccess)
            declared = response["content-length"]
            if declared && declared.to_i > max_bytes
              raise FileTooLargeError,
                    "URL body is #{declared} bytes; max_document_size is #{max_bytes}."
            end

            buffer = String.new(capacity: 4_096)
            response.read_body do |chunk|
              buffer << chunk
              if buffer.bytesize > max_bytes
                raise FileTooLargeError,
                      "URL body exceeded #{max_bytes} bytes mid-stream."
              end
            end
            yield buffer
          end
          return response
        end
      end
    end
    private_class_method :stream

    # RFC 6266 filename / filename* with a forgiving pattern. Handles
    # unquoted, double-quoted, and RFC 5987 (filename*=UTF-8''foo) forms.
    # Header content is attacker-controlled — strip path separators and
    # control chars before returning so the result is safe to pass to
    # ActiveStorage / Marcel / File.basename downstream.
    def filename_for(response, uri)
      disp = response["content-disposition"]
      if disp && (m = disp.match(/filename\*?=(?:UTF-8'')?"?([^"';]+)"?/i))
        name = sanitize_filename(URI.decode_www_form_component(m[1].strip))
        return name unless name.empty?
      end
      base = sanitize_filename(File.basename(uri.path.to_s))
      return base unless base.empty? || base == "/"
      FALLBACK_FILENAME
    end
    private_class_method :filename_for

    def sanitize_filename(name)
      File.basename(name.to_s.gsub(UNSAFE_FILENAME_CHARS, "")).strip
    end
    private_class_method :sanitize_filename

    def mime_for(response)
      ct = response["content-type"]
      ct && !ct.empty? ? ct.split(";").first.strip : nil
    end
    private_class_method :mime_for
  end
end
