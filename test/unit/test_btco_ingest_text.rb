# frozen_string_literal: true

# M0-8: pins ingest.rb's pure parts -- excerpt windowing and
# diff_against -- plus strip_html, their front door. No network, no
# ANTHROPIC_API_KEY; the extraction prompt/schema are untouched.

require_relative '../test_helper'
require_relative '../../scripts/btco/ingest_text'

class TestStripHtml < Minitest::Test
  def test_drops_script_style_and_tags
    html = '<html><script>var x=1;</script><style>p{}</style>' \
           '<p>holds <b>1,234</b> bitcoin</p></html>'
    out = Btco.strip_html(html)
    refute_includes out, 'var x'
    refute_includes out, 'p{}'
    assert_includes out, 'holds 1,234 bitcoin'
  end

  def test_entities_and_whitespace_collapse
    assert_equal 'a & b c', Btco.strip_html("a&nbsp;&amp;&#160;b\t\tc")
  end
end

class TestExcerpt < Minitest::Test
  FILLER = 'z' * 100

  def test_no_keywords_returns_head_of_text
    text = FILLER * 100
    assert_equal text[0, 500], Btco.excerpt(text, 500)
  end

  def test_single_hit_windows_around_keyword
    text = ('x' * 5_000) + 'bitcoin' + ('y' * 5_000)
    out = Btco.excerpt(text)
    assert_includes out, 'bitcoin'
    assert_equal 3_000, out.size # +-1500 around the match START, exclusive end
    refute_includes out, '[...]'
  end

  def test_hit_at_document_start_clamps_to_zero
    text = 'bitcoin' + ('y' * 5_000)
    out = Btco.excerpt(text)
    assert out.start_with?('bitcoin')
    assert_equal 1_500, out.size # [0, start+1500)
  end

  def test_far_apart_hits_join_with_ellipsis_marker
    text = 'bitcoin' + ('x' * 10_000) + 'convertible' + ('y' * 5_000)
    out = Btco.excerpt(text)
    assert_includes out, "\n[...]\n"
    assert_includes out, 'bitcoin'
    assert_includes out, 'convertible'
  end

  def test_nearby_hits_merge_into_one_window
    # 2000 chars apart: windows [.., i+1500] and [j-1500, ..] overlap
    # within the 200-char merge slack -> single span, no marker.
    text = ('x' * 3_000) + 'bitcoin' + ('m' * 2_000) + 'convertible' + ('y' * 3_000)
    out = Btco.excerpt(text)
    refute_includes out, '[...]'
    assert_includes out, 'bitcoin'
    assert_includes out, 'convertible'
  end

  def test_cap_truncates_output
    text = (('x' * 3_500) + 'bitcoin') * 20
    assert_equal 2_000, Btco.excerpt(text, 2_000).size
  end
end

class TestDiffAgainst < Minitest::Test
  CUR = { 'ticker' => 'TST', 'btc' => 100, 'shares_basic' => 1_000_000,
          'shares_diluted' => 1_200_000, 'debt_face' => 0, 'pref_liq' => 0,
          'btc_as_of' => '2026-06-01' }.freeze

  def test_numeric_change_recorded_with_from_to
    d = Btco.diff_against(CUR, { 'btc' => 150 })
    assert_equal({ 'btc' => { 'from' => 100, 'to' => 150 } }, d)
  end

  def test_nil_and_equal_values_skipped
    assert_empty Btco.diff_against(CUR, { 'btc' => nil, 'debt_face' => 0 })
    # string/number equality is by to_f -- '100' equals 100, pinned
    assert_empty Btco.diff_against(CUR, { 'btc' => '100' })
  end

  def test_as_of_and_converts_changes
    ext = { 'btc_as_of' => '2026-07-01',
            'converts_add' => [{ 'face' => 1, 'conv_price' => 2, 'label' => 'x' }],
            'converts_remove' => ['old'] }
    d = Btco.diff_against(CUR, ext)
    assert_equal({ 'from' => '2026-06-01', 'to' => '2026-07-01' }, d['btc_as_of'])
    assert_equal 1, d['converts_add'].size
    assert_equal ['old'], d['converts_remove']
  end

  def test_empty_convert_lists_omitted
    d = Btco.diff_against(CUR, { 'converts_add' => [], 'converts_remove' => nil })
    assert_empty d
  end

  def test_no_material_change_yields_empty_diff
    assert_empty Btco.diff_against(CUR, { 'no_material_change' => true,
                                          'confidence' => 'high' })
  end
end
