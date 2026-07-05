# frozen_string_literal: true
#
# preview_server.rb -- minimal static file server behind `rake preview`
# (Gate 3 review flow). Pure stdlib: webrick left the standard library
# in Ruby 3.0 and this repo installs no gems, so this is a ~40-line
# TCPServer loop. GET only, binds 127.0.0.1 ONLY (local review tool,
# never exposed), path-contained to the served root (traversal
# attempts get 404). Not part of the analytics runtime.
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

    module_function

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
          path = safe_path(root, req.split(' ')[1].to_s)
          if req.start_with?('GET ') && path && File.file?(path)
            body = File.binread(path)
            client.write "HTTP/1.1 200 OK\r\nContent-Type: #{mime(path)}\r\n" \
                         "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
            client.write body
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
