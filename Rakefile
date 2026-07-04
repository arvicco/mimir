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
  scripts = Hash[Dir.glob('scripts/**/*.rb').map { |f| [f, File.read(f)] }]
  libs    = Hash[Dir.glob('lib/**/*.rb').map { |f| [f, File.read(f)] }]
  bad = BTC::Health.scan_conventions(scripts) +
        BTC::Health.scan_frozen(libs) +
        BTC::Health.registry_integrity(Dir.pwd)

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
  desc 'Refresh recorded API fixtures (NETWORK -- run manually, review diff)'
  task :record do
    puts 'This task performs live API calls and overwrites test/fixtures/.'
    puts 'Implemented in Phase 1 alongside lib/btc/http.rb. Aborting for now.'
    abort
  end
end

namespace :golden do
  desc 'Approve regenerated chart specs after visual review in preview.html'
  task :approve do
    src = 'data/publish_preview'
    abort "no #{src}/ -- run PUBLISH_DRY_RUN=1 first" unless Dir.exist?(src)

    require 'fileutils'
    FileUtils.mkdir_p('test/golden')
    Dir.glob("#{src}/chart_*.json").each do |f|
      FileUtils.cp(f, File.join('test/golden', File.basename(f)))
      puts "approved #{File.basename(f)}"
    end
  end
end

task default: %i[compat health test]
