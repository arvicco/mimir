# frozen_string_literal: true
#
# preview_server.rb -- minimal static file server behind `rake preview`
# (Gate 3 review flow). Pure stdlib: webrick left the standard library
# in Ruby 3.0 and this repo installs no gems, so this is a ~40-line
# TCPServer loop. GET only, binds 127.0.0.1 ONLY (local review tool,
# never exposed), path-contained to the served root (traversal
# attempts get 404). Not part of the analytics runtime.
#
# It ALSO shims the Worker API (web/worker.mjs) so `rake preview` serves
# the production dashboard (web/index.html) for offline review:
#   GET /api/v1/<key> -> data/publish_preview/<key with ':' -> '_'>.json
#   GET /healthz      -> {"ok":true,"worker_ts":"<now iso>"}
# Only keys matching the Worker's allowlist (/^[a-z0-9_]+(?::[a-z0-9_]+)*$/,
# length <= 64) map; anything else falls through to normal static handling
# (which 404s), mirroring the Worker. The allowlist alone forbids traversal
# (no '/', '.', or '%' can appear in a key).
#
#   rake preview   # serves the repo root, prints the preview URL

require 'socket'

module BTC
  module PreviewServer
    MIME = {
      '.html' => 'text/html; charset=utf-8',
      '.json' => 'application/json',
      '.js'   => 'text/javascript',
      '.css'  => 'text/css',
      '.svg'  => 'image/svg+xml',
      '.png'  => 'image/png'
    }.freeze

    # Mirror web/worker.mjs's key allowlist exactly.
    API_RE = %r{\A/api/v1/(.+)\z}
    KEY_RE = /\A[a-z0-9_]+(?::[a-z0-9_]+)*\z/
    KEY_MAX = 64
    PREVIEW_DIR = 'data/publish_preview'

    module_function

    # Filesystem path for GET /api/v1/<key>, or nil when the request is not
    # an api request or the key fails the Worker allowlist -- nil means "fall
    # through to normal static handling". The key regex forbids '/', '.' and
    # '%', so no traversal reaches the filesystem here.
    def api_path(root, req_path)
      clean = req_path.split('?', 2).first.to_s
      m = API_RE.match(clean)
      return nil unless m

      key = m[1]
      return nil if key.length > KEY_MAX || !KEY_RE.match?(key)

      File.join(root, PREVIEW_DIR, "#{key.gsub(':', '_')}.json")
    end

    # Stub of the Worker's /healthz body (no auth, no-store semantics).
    def healthz_body
      %({"ok":true,"worker_ts":"#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}"})
    end

    # Percent-decoded request path resolved under root, or nil if it
    # escapes root (traversal) -- the security property pinned in tests.
    def safe_path(root, req_path)
      clean = req_path.split('?', 2).first.to_s
                      .gsub(/%([0-9a-f]{2})/i) { [Regexp.last_match(1)].pack('H2') }
      full = File.expand_path(clean.sub(%r{\A/+}, ''), root)
      full.start_with?(File.join(root, '')) || full == root ? full : nil
    end

    def mime(path)
      MIME.fetch(File.extname(path).downcase, 'application/octet-stream')
    end

    def write_ok(client, body, content_type)
      # no-store (2026-08-30): a review server must NEVER serve stale
      # assets -- a cached render.js against fresh payloads showed the
      # owner a broken half-old board mid design review.
      client.write "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n" \
                   "Cache-Control: no-store\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      client.write body
    end

    def serve(root, port)
      server = TCPServer.new('127.0.0.1', port)
      puts "serving #{root} on http://localhost:#{port}"
      puts "open http://localhost:#{port}/web/preview.html  (Ctrl-C stops)"
      loop do
        client = server.accept
        begin
          req = client.gets.to_s
          loop do # drain request headers up to the blank line
            line = client.gets
            break if line.nil? || line.strip.empty?
          end
          req_path = req.split(' ')[1].to_s
          is_get = req.start_with?('GET ')
          api = is_get ? api_path(root, req_path) : nil
          path = safe_path(root, req_path)
          if is_get && req_path.split('?', 2).first == '/healthz'
            write_ok(client, healthz_body, 'application/json')
          elsif api && File.file?(api)
            write_ok(client, File.binread(api), 'application/json')
          elsif is_get && path && File.file?(path)
            write_ok(client, File.binread(path), mime(path))
          else
            client.write "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n" \
                         "Connection: close\r\n\r\nnot found"
          end
        rescue StandardError
          nil # a broken client connection never kills the server
        ensure
          client.close
        end
      end
    end
  end
end
