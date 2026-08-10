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

  # ---- /api/v1 shim: allowlisted key -> data/publish_preview file --------

  def test_api_path_maps_plain_and_namespaced_keys
    assert_equal File.join(ROOT, 'data/publish_preview', 'index.json'),
                 BTC::PreviewServer.api_path(ROOT, '/api/v1/index')
    assert_equal File.join(ROOT, 'data/publish_preview', 'chart_gex_btc.json'),
                 BTC::PreviewServer.api_path(ROOT, '/api/v1/chart:gex_btc')
    assert_equal File.join(ROOT, 'data/publish_preview', 'gex_combined.json'),
                 BTC::PreviewServer.api_path(ROOT, '/api/v1/gex:combined')
  end

  def test_api_path_ignores_query_strings
    assert_equal File.join(ROOT, 'data/publish_preview', 'index.json'),
                 BTC::PreviewServer.api_path(ROOT, '/api/v1/index?ts=1')
  end

  def test_api_path_nil_for_non_api_paths
    assert_nil BTC::PreviewServer.api_path(ROOT, '/web/index.html')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/healthz')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v2/index')
  end

  def test_api_path_rejects_keys_outside_the_allowlist
    # uppercase, dots, slashes, percent-escapes, trailing colon, over-length
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/Index')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/chart:GEX')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/chart:gex.profile')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/chart:')
    assert_nil BTC::PreviewServer.api_path(ROOT, "/api/v1/#{'a' * 65}")
  end

  def test_api_path_rejects_traversal_attempts
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/../../etc/passwd')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/..%2f..%2fetc%2fpasswd')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/foo/bar')
    assert_nil BTC::PreviewServer.api_path(ROOT, '/api/v1/..')
  end

  def test_healthz_body_is_valid_ok_json
    body = BTC::PreviewServer.healthz_body
    obj = JSON.parse(body)
    assert_equal true, obj['ok']
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, obj['worker_ts'])
  end
end
