# frozen_string_literal: true
#
# ntfy.rb -- transition push alerts via ntfy.sh (M12-5, Q-17). The
# dashboard is pull-only; this closes the loop: when something CHANGES,
# the owner's phone learns without them looking.
#
# GOVERNANCE / D12-a (taxonomy shipped as the loop's recommendation,
# 2026-08-30): alerts fire on TRANSITIONS ONLY, never levels --
#   scenario regime band change, LPPL verdict change, spot crossing the
#   BTC gamma flip, publish-health OLD/BLIND appearing or clearing.
# NEVER pushes: levels, routine publishes, WARMUP states, anything under
# --as-of/backfill. Hard cap 8 pushes per UTC day; overflow collapses
# into a single 'muted' notice. DORMANT BY DEFAULT: without NTFY_TOPIC
# in the env every call is a no-op -- the OWNER enables by choosing a
# topic, adding it to ~/.config/mimir/env and subscribing in the ntfy
# app (the enablement step IS the D12-a acceptance; see the Gate-12
# runbook).
#
# SECRETS: the topic name is effectively a credential (anyone knowing it
# can read the alerts). It is read from ENV only, never logged, and
# every error path is redacted. A dead/slow ntfy.sh NEVER breaks the
# calling agent: push failures are swallowed (fail-soft), the alarm
# channel must not become an alarm source.
#
# STATE: `notify_transition(kind, state, message)` remembers the last
# pushed state per kind in <data>/ntfy/state.json and pushes only when
# `state` differs (once per transition, across process restarts). The
# daily cap counter lives beside it. Both are plain JSON in the data
# home -- agents on the live clone share them.

require 'net/http'
require 'json'
require 'time'
require 'fileutils'
require_relative 'env'

module BTC
  module Ntfy
    HOST      = 'https://ntfy.sh'
    DAILY_CAP = 8

    module_function

    def topic
      t = ENV['NTFY_TOPIC'].to_s
      t.empty? ? nil : t
    end

    def enabled? = !topic.nil?

    def state_dir
      BTC::Env.data_dir('ntfy', File.join(Dir.home, '.local', 'share', 'mimir', 'ntfy'))
    end

    def state_file = File.join(state_dir, 'state.json')

    def load_state
      JSON.parse(File.read(state_file))
    rescue StandardError
      {}
    end

    def save_state(st)
      FileUtils.mkdir_p(state_dir)
      File.write(state_file, JSON.generate(st))
    end

    # Push `message` when `state` (a short string encoding the CURRENT
    # state of `kind`) differs from the last state pushed for that kind.
    # First observation of a kind RECORDS without pushing (arming): the
    # first run after enablement must not fire a burst of "transitions"
    # from unknown -> current. Returns :pushed | :armed | :unchanged |
    # :capped | :dormant. now/http injectable for tests.
    def notify_transition(kind, state, message, now: Time.now.utc, http: nil)
      return :dormant unless enabled?

      st = load_state
      last = st.dig('kinds', kind.to_s)
      if last.nil?
        (st['kinds'] ||= {})[kind.to_s] = state.to_s
        save_state(st)
        return :armed
      end
      return :unchanged if last == state.to_s

      (st['kinds'] ||= {})[kind.to_s] = state.to_s
      day = now.strftime('%Y-%m-%d')
      st['cap'] = { 'day' => day, 'n' => 0 } unless st.dig('cap', 'day') == day
      st['cap']['n'] += 1
      n = st['cap']['n']
      save_state(st)

      if n > DAILY_CAP
        # exactly one overflow notice per day (on the first capped push)
        push("mimir: further alerts muted today (cap #{DAILY_CAP})", http: http) if n == DAILY_CAP + 1
        return :capped
      end
      push(message, http: http)
      :pushed
    end

    # Fire-and-forget POST. Failures are swallowed (fail-soft) -- but the
    # error class is warned WITHOUT the topic or body (redaction).
    def push(message, http: nil)
      t = topic
      return false unless t

      if http
        http.call(t, message)
      else
        uri = URI("#{HOST}/#{t}")
        req = Net::HTTP::Post.new(uri)
        req.body = message.to_s
        req['Title'] = 'mimir'
        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                        open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
      end
      true
    rescue StandardError => e
      warn "ntfy: push failed (#{e.class})" # never the topic, never the body
      false
    end
  end
end
