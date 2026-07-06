# frozen_string_literal: true

require 'rake/testtask'

RUBY_DIRS = %w[scripts lib publish test].freeze

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.pattern = 'test/**/test_*.rb'
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << 'test'
    t.pattern = 'test/unit/test_*.rb'
    t.warning = false
  end

  Rake::TestTask.new(:contract) do |t|
    t.libs << 'test'
    t.pattern = 'test/contract/test_*.rb'
    t.warning = false
  end
end

desc 'Syntax-check every Ruby file (target: Ruby 3.3+)'
task :compat do
  files = RUBY_DIRS.flat_map { |d| Dir.glob("#{d}/**/*.rb") } + ['Rakefile']
  bad = files.reject { |f| system("ruby -c #{f} > /dev/null 2>&1") }

  if bad.empty?
    puts "compat: OK (#{files.size} files)"
  else
    bad.each { |f| puts "#{f}: syntax error" }
    abort "compat: #{bad.size} problem(s)"
  end
end

desc 'Offline health scan: conventions/interfaces + source-registry integrity'
task :health do
  require_relative 'lib/btc/health'
  scripts = Hash[Dir.glob('{scripts,publish}/**/*.rb').map { |f| [f, File.read(f)] }]
  libs    = Hash[Dir.glob('lib/**/*.rb').map { |f| [f, File.read(f)] }]
  pages   = Hash[%w[web/preview.html web/index.html].map { |f| [f, File.read(f)] }]
  bad = BTC::Health.scan_conventions(scripts) +
        BTC::Health.scan_frozen(libs) +
        BTC::Health.registry_integrity(Dir.pwd) +
        BTC::Health.scan_sri(pages) +
        BTC::Health.scan_ops('ops')

  if bad.empty?
    puts "health: OK (#{scripts.size + libs.size} files, " \
         "#{BTC::Health::SOURCES.size} sources registered)"
  else
    puts bad
    abort "health: #{bad.size} problem(s)"
  end
end

namespace :health do
  desc 'Probe every registered upstream data source (NETWORK, read-only)'
  task :sources do
    require_relative 'lib/btc/health'
    fails = 0
    BTC::Health::SOURCES.each do |s|
      status, msg = BTC::Health.probe(s)
      puts format('%-22s %-5s %s', s[:name], status.to_s.upcase, msg)
      fails += 1 if status == :fail
    end
    abort "health:sources: #{fails} source(s) degraded" if fails > 0
    puts 'health:sources: all live sources OK'
  end
end

namespace :fixtures do
  # Print [[file, status, note]] rows in the aligned digest format and
  # return the number of :fail rows.
  def print_fixture_rows(rows)
    fails = 0
    rows.each do |file, status, note|
      puts format('%-26s %-5s %s', file, status.to_s.upcase, note)
      fails += 1 if status == :fail
    end
    fails
  end

  desc 'Refresh recorded API fixtures (NETWORK -- run manually)'
  task :record do
    require_relative 'lib/btc/fixtures'
    puts 'Recording live API responses into test/fixtures/ ...'
    fails = print_fixture_rows(BTC::Fixtures.record_all('test/fixtures'))
    abort "fixtures:record: #{fails} failure(s)" if fails > 0

    puts "\nVerify digest (check the numbers against your screen, then commit):"
    print_fixture_rows(BTC::Fixtures.verify('test/fixtures'))
  end

  desc 'Offline fixture digest + safety checks (no network)'
  task :verify do
    require_relative 'lib/btc/fixtures'
    fails = print_fixture_rows(BTC::Fixtures.verify('test/fixtures'))
    abort "fixtures:verify: #{fails} failure(s)" if fails > 0
  end
end

desc 'Serve the repo for web/preview.html review (stdlib TCPServer, localhost only)'
task :preview do
  require_relative 'lib/btc/preview_server'
  BTC::PreviewServer.serve(Dir.pwd, (ENV['PORT'] || 8000).to_i)
end

namespace :golden do
  desc 'Bless chart goldens after visual review in preview.html (deterministic: regenerates from test/fixtures/payloads/)'
  task :approve do
    require_relative 'publish/chart_specs'
    require 'json'
    require 'fileutils'
    FileUtils.mkdir_p('test/golden')
    Publish::Charts::CHARTS.each do |name, spec|
      payloads = spec[:inputs].map { |f| JSON.parse(File.read(File.join('test/fixtures/payloads', f))) }
      option = Publish::Charts.public_send(spec[:fn], *payloads)
      File.write(File.join('test/golden', "chart_#{name}.json"),
                 JSON.pretty_generate(option) + "\n")
      puts "blessed chart_#{name}.json"
    end
  end
end

namespace :web do
  desc 'Worker API tests (node built-in runner, zero npm); WARN-skips without node'
  task :test do
    if system('node --version', out: File::NULL, err: File::NULL)
      files = Dir.glob('test/web/*.test.mjs')
      sh "node --test #{files.join(' ')}" unless files.empty?
    else
      warn 'web:test SKIP: node not found (Worker API tests not run)'
    end
  end
end

desc 'Deploy the Worker to Cloudflare (OWNER-RUN; never in CI -- Golden ' \
     'Rule 3). Pre-flight, generate wrangler.generated.toml (gitignored, ' \
     'never committed), wrangler deploy, post-deploy smoke. ' \
     'DEPLOY_DRY_RUN=1 assembles without deploying; DEPLOY_SKIP_CHECKS=1 ' \
     'skips tree/gate on re-runs. Not in the default gate.'
task :deploy do
  require_relative 'lib/btc/deploy'
  begin
    code = BTC::Deploy.run
  rescue BTC::Deploy::Error => e
    abort BTC::Env.redact(e.message)
  end
  exit code
end

task default: %i[compat health fixtures:verify test web:test]
