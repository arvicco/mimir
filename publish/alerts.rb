# frozen_string_literal: true
#
# alerts.rb -- transition-alert dispatch from a completed REAL publish
# run (M12-5, Q-17). Reads the run summary the pipeline already built
# (envelopes + health markers -- nothing is re-fetched) and hands each
# alert KIND's current state to BTC::Ntfy.notify_transition, which
# pushes only on CHANGE (and is a no-op while NTFY_TOPIC is unset --
# the D12-a dormant ship).
#
# KINDS (the D12-a taxonomy):
#   regime         -- the scenario regime band (BASE, FLUSH, ...)
#   lppl           -- the LPPL suite verdict (STRESSED, FALSIFIED, ...)
#   gamma_flip     -- which side of the BTC gamma flip spot sits on
#   publish_health -- the OLD:/BLIND: marker set ('clean' when none)
#
# NEVER raises and never alters the publish outcome: the alert channel
# must not become an alarm source. Callers invoke it ONLY on real
# (non-dry) runs -- previews, replays and backfills never alert.

require_relative '../lib/btc/ntfy'

module Publish
  module Alerts
    module_function

    def dispatch(summary, ntfy: BTC::Ntfy)
      env = summary[:envelopes] || {}

      if (p = healthy_payload(env, 'scenario:latest')) && p['regime']
        ntfy.notify_transition('regime', p['regime'],
                               format('mimir: scenario regime -> %s (%+.2f)',
                                      p['regime'], p['composite'].to_f))
      end

      if (p = healthy_payload(env, 'lppl:latest')) && p['verdict']
        ntfy.notify_transition('lppl', p['verdict'],
                               format('mimir: LPPL verdict -> %s (%+.2f)',
                                      p['verdict'], p['composite'].to_f))
      end

      if (p = healthy_payload(env, 'gex:combined'))
        spot = p['btc_spot'].to_f
        flip = p.dig('combined', 'gamma_flip').to_f
        if spot.positive? && flip.positive?
          side = spot >= flip ? 'above' : 'below'
          ntfy.notify_transition('gamma_flip', side,
                                 format('mimir: spot is %s the gamma flip (spot %.0f, flip %.0f)',
                                        side, spot, flip))
        end
      end

      marks = []
      old = summary[:old_keys] || []
      blind = summary[:blind_tails] || []
      marks << "OLD:#{old.join(',')}" unless old.empty?
      marks << "BLIND:#{blind.join(',')}" unless blind.empty?
      state = marks.empty? ? 'clean' : marks.join(' ')
      msg = marks.empty? ? 'mimir: publish health back to clean' :
              "mimir: publish health #{state}"
      ntfy.notify_transition('publish_health', state, msg)
      true
    rescue StandardError => e
      warn "alerts: skipped (#{e.class})" # redacted; never break the publish
      false
    end

    # The key's payload, or nil when absent or an honest fail-soft.
    def healthy_payload(env, key)
      p = env.dig(key, 'payload')
      p.is_a?(Hash) && !p['unavailable'] ? p : nil
    end
  end
end
