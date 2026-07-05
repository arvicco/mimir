# frozen_string_literal: true

# M3-1: chart-spec builders. Two layers of pinning:
#   1. GOLDEN: each registered chart regenerates from its committed
#      payload fixtures and byte-diffs against test/golden/ -- a red
#      diff is presented for human review (preview.html), never
#      auto-blessed; `rake golden:approve` re-blesses after review.
#   2. Targeted assertions on the load-bearing structure (series
#      shape, markLines, determinism) so failures localize.

require_relative '../test_helper'
require_relative '../../publish/chart_specs'

class TestChartSpecs < Minitest::Test
  PAYLOADS = File.expand_path('../fixtures/payloads', __dir__)
  GOLDEN   = File.expand_path('../golden', __dir__)

  def build(name)
    spec = Publish::Charts::CHARTS.fetch(name)
    payloads = spec[:inputs].map { |f| JSON.parse(File.read(File.join(PAYLOADS, f))) }
    Publish::Charts.public_send(spec[:fn], *payloads)
  end

  # ---- golden harness (every registered chart) -------------------------

  Publish::Charts::CHARTS.each_key do |name|
    define_method("test_golden_#{name}") do
      golden = File.join(GOLDEN, "chart_#{name}.json")
      assert File.exist?(golden),
             "no golden for #{name} -- generate + review, then rake golden:approve"
      got = JSON.pretty_generate(build(name)) + "\n"
      assert_equal File.read(golden), got,
                   "chart '#{name}' drifted from its golden. Review the rendered " \
                   'result in preview.html; if the change is intended, re-bless ' \
                   'with rake golden:approve. NEVER approve without looking.'
    end

    define_method("test_#{name}_is_deterministic_and_json_safe") do
      a = build(name)
      assert_equal a, build(name)
      assert_equal a, JSON.parse(JSON.generate(a)) # nothing non-serializable
    end
  end

  # ---- gex_profile structure -------------------------------------------

  def gex_payload
    @gex_payload ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_gex_combined.json')))
  end

  def test_gex_profile_two_series_per_venue_stacked_by_side
    opt = build('gex_profile')
    venues = gex_payload['profiles'].keys
    assert_equal venues.size * 2, opt['series'].size
    assert_equal venues.map { |v| ["#{v} calls", "#{v} puts"] }.flatten,
                 opt['series'].map { |s| s['name'] }
    assert_equal %w[calls puts], opt['series'].map { |s| s['stack'] }.uniq
  end

  def test_gex_profile_marklines_flip_and_walls
    opt = build('gex_profile')
    marks = opt['series'].first['markLine']['data']
    labels = marks.map { |m| m['label']['formatter'] }
    assert_equal %w[flip CW PW], labels # the fixture payload has all three
    marks.each { |m| assert_match(/\A\d+(\.\d)?k\z/, m['xAxis']) } # snapped to category
  end

  def test_gex_profile_no_flip_markline_when_absent
    p2 = JSON.parse(JSON.generate(gex_payload))
    p2['combined']['gamma_flip'] = nil
    marks = Publish::Charts.gex_profile(p2)['series'].first['markLine']['data']
    refute_includes marks.map { |m| m['label']['formatter'] }, 'flip'
  end

  def test_gex_profile_levels_ascend_and_data_aligns
    opt = build('gex_profile')
    labels = opt['xAxis']['data']
    assert_equal labels, labels.sort_by { |l| l.to_f } # ascending BTC axis
    opt['series'].each do |s|
      next unless s['type'] == 'bar'

      assert_equal labels.size, s['data'].size, "#{s['name']} misaligned with axis"
    end
  end
end
