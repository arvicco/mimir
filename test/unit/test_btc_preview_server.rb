# frozen_string_literal: true

# BTC::PreviewServer pure helpers -- path containment (no traversal out
# of the served root) and MIME mapping. The accept loop itself is
# exercised manually via `rake preview`; no sockets opened here.

require_relative '../test_helper'
require_relative '../../lib/btc/preview_server'

class TestBtcPreviewServer < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_safe_path_resolves_inside_root
    p = BTC::PreviewServer.safe_path(ROOT, '/web/preview.html')
    assert_equal File.join(ROOT, 'web/preview.html'), p
  end

  def test_safe_path_rejects_traversal_and_absolute_escapes
    assert_nil BTC::PreviewServer.safe_path(ROOT, '/../../etc/passwd')
    assert_nil BTC::PreviewServer.safe_path(ROOT, '/web/../../outside')
    assert_nil BTC::PreviewServer.safe_path(ROOT, '/%2e%2e/%2e%2e/etc/passwd')
  end

  def test_safe_path_ignores_query_strings
    p = BTC::PreviewServer.safe_path(ROOT, '/web/preview.html?cache=1')
    assert_equal File.join(ROOT, 'web/preview.html'), p
  end

  def test_mime_types
    assert_equal 'text/html; charset=utf-8', BTC::PreviewServer.mime('a/preview.html')
    assert_equal 'application/json', BTC::PreviewServer.mime('x/index.json')
    assert_equal 'application/octet-stream', BTC::PreviewServer.mime('x/unknown.bin')
  end
end
