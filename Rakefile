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

desc 'Syntax-check every Ruby file and scan for post-2.5 constructs'
task :compat do
  files = RUBY_DIRS.flat_map { |d| Dir.glob("#{d}/**/*.rb") } + ['Rakefile']
  bad = []

  files.each do |f|
    ok = system("ruby -c #{f} > /dev/null 2>&1")
    bad << "#{f}: syntax error" unless ok
  end

  # Regexps whose literal source would match themselves are built from
  # split strings, so this file passes its own scan.
  patterns = {
    'filter_map'                  => Regexp.new('\.filter_' + 'map\b'),
    'endless method'              => /^\s*def\s+\w+[?!]?\s*(\([^)]*\))?\s*=[^=~>]/,
    'to_h with block'             => /\.to_h\s*\{/,
    'numbered block param'        => /\b_1\b/,
    'then/yield_self'             => /\.(then|yield_self)\b/,
    'pattern matching (case/in)'  => /^\s*in\s+.+\bthen\b|^\s+in\s+\[/,
    'tally'                       => Regexp.new('\.tal' + 'ly\b'),
    'Hash#except'                 => /\.except\(/,
    'keyword-init Struct'         => Regexp.new('keyword' + '_init')
  }

  files.each do |f|
    File.readlines(f).each_with_index do |line, i|
      next if line.strip.start_with?('#')

      patterns.each do |name, re|
        bad << "#{f}:#{i + 1}: #{name}" if line =~ re
      end
    end
  end

  if bad.empty?
    puts "compat: OK (#{files.size} files)"
  else
    puts bad
    abort "compat: #{bad.size} problem(s)"
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

task default: %i[compat test]
