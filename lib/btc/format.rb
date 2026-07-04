# frozen_string_literal: true
#
# format.rb -- shared human-output formatting for the gex tools
# (TOOL-REVIEW.md R-6/R-7). Per-tool 'k' formatters are deliberately
# NOT unified: they differ and feed frozen --tmux lines.

module BTC
  module Format
    module_function

    # Signed millions of dollars: '+58.0M', '-3.2M'.
    def musd(v)
      format('%+.1fM', v / 1e6)
    end

    # ASCII bars for the +-15% strike/level profile around spot; bar
    # scale anchored to the +-30% band's max (the `near` hash from
    # Options.walls). label formats the strike/level, padded to label_w.
    def profile_bars(profile, near, spot, label_w, label)
      max_abs = near.values.map(&:abs).max || 1.0
      profile.select { |k, _| (k - spot).abs / spot <= 0.15 }.sort.each do |k, v|
        bar = '#' * [(v.abs / max_abs * 40).round, 40].min
        puts format("%-#{label_w}s %12s  %s%s",
                    label.call(k), musd(v), v.negative? ? '-' : '+', bar)
      end
    end
  end
end
