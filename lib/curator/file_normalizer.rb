require "pathname"

module Curator
  # Normalizes the many shapes of "a file" that Curator.ingest accepts
  # into a single `Normalized` value object with bytes/filename/mime_type.
  #
  # Accepts: String path, Pathname, File, IO, StringIO,
  # ActionDispatch::Http::UploadedFile, ActiveStorage::Blob.
  module FileNormalizer
    Normalized = Struct.new(:bytes, :filename, :mime_type, keyword_init: true) do
      def byte_size
        bytes.bytesize
      end
    end

    module_function

    def call(input, filename: nil)
      case input
      when String, Pathname
        normalize_path(input, filename)
      when ActionDispatch::Http::UploadedFile
        normalize_uploaded_file(input, filename)
      when ActiveStorage::Blob
        normalize_blob(input, filename)
      when IO, StringIO
        normalize_io(input, filename)
      else
        raise ArgumentError,
              "Curator.ingest cannot normalize #{input.class}. " \
              "Pass a String path, Pathname, File, IO, StringIO, " \
              "ActionDispatch::Http::UploadedFile, or ActiveStorage::Blob."
      end
    end

    def normalize_path(input, filename_override)
      path  = Pathname.new(input.to_s)
      fname = filename_override || path.basename.to_s
      bytes = path.binread
      mime  = Marcel::MimeType.for(path, name: fname)
      Normalized.new(bytes: bytes, filename: fname, mime_type: mime)
    end
    private_class_method :normalize_path

    def normalize_uploaded_file(input, filename_override)
      fname = filename_override || input.original_filename
      bytes = input.read
      input.rewind if input.respond_to?(:rewind)
      mime = input.content_type.presence ||
             Marcel::MimeType.for(StringIO.new(bytes), name: fname)
      Normalized.new(bytes: bytes, filename: fname, mime_type: mime)
    end
    private_class_method :normalize_uploaded_file

    def normalize_blob(input, filename_override)
      fname = filename_override || input.filename.to_s
      bytes = input.download
      mime  = input.content_type.presence ||
              Marcel::MimeType.for(StringIO.new(bytes), name: fname)
      Normalized.new(bytes: bytes, filename: fname, mime_type: mime)
    end
    private_class_method :normalize_blob

    def normalize_io(input, filename_override)
      path  = input.respond_to?(:path) ? input.path : nil
      fname = filename_override || (path && File.basename(path)) ||
              raise(ArgumentError,
                    "Curator.ingest cannot infer a filename for #{input.class}; " \
                    "pass filename:")
      input.rewind if input.respond_to?(:rewind)
      bytes = input.read
      bytes = bytes.b if bytes.respond_to?(:b)
      mime  = Marcel::MimeType.for(StringIO.new(bytes), name: fname)
      Normalized.new(bytes: bytes, filename: fname, mime_type: mime)
    end
    private_class_method :normalize_io
  end
end
