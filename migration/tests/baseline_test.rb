# frozen_string_literal: true

SOURCE_ROOT = ARGV.shift or abort "usage: baseline_test.rb <pinned-source-root> <legacy-probe>"
LEGACY_PROBE = ARGV.shift or abort "missing legacy-probe executable"
require "minitest/autorun"
require_relative "reference"

class BaselineTest < Minitest::Test
  FIXTURE = JSON.parse(File.read(File.expand_path("../baseline/cases.json", __dir__)))

  def test_reference_sources_are_the_recorded_unpatched_version
    FIXTURE.fetch("source_sha256").each do |path, digest|
      assert_equal digest, Digest::SHA256.file(File.join(SOURCE_ROOT, path)).hexdigest, path
    end
  end

  M2_FIXTURE = JSON.parse(File.read(File.expand_path("../baseline/m2-cases.json", __dir__)))
  M3_FIXTURE = JSON.parse(File.read(File.expand_path("../baseline/m3-live-cases.json", __dir__)))
  FULL_FIXTURE = JSON.parse(File.read(File.expand_path("../baseline/m3-full-cases.json", __dir__)))
  MODULE_FIXTURES = %w[simplex-cases correction-cases simplex-full-cases].map { |name| JSON.parse(File.read(File.expand_path("../baseline/#{name}.json", __dir__))) }
  MODULE_MODES = MODULE_FIXTURES.flat_map { |fixture| fixture.fetch("cases").map { |scenario| [scenario.fetch("id"), fixture.fetch("legacy_mode")] } }.to_h
  def test_new_module_sources_are_unmodified
    MODULE_FIXTURES.each do |fixture|
      fixture.fetch("source_sha256").each do |path, digest|
        assert_equal digest, Digest::SHA256.file(File.join(SOURCE_ROOT, path)).hexdigest, path
      end
    end
  end
  SCENARIOS = FIXTURE.fetch("cases") + M2_FIXTURE.fetch("cases") + M3_FIXTURE.fetch("cases") + FULL_FIXTURE.fetch("cases") + MODULE_FIXTURES.flat_map { |fixture| fixture.fetch("cases") }
  raise "duplicate baseline scenario ids" unless SCENARIOS.map { |scenario| scenario.fetch("id") }.uniq.size == SCENARIOS.size

  SCENARIOS.each do |scenario|
    define_method("test_#{scenario.fetch('id')}") do
      output = if MODULE_MODES.key?(scenario.fetch("id"))
        mode = MODULE_MODES.fetch(scenario.fetch("id"))
        if mode == "--simplex-full"
          Dir.mktmpdir("simplex-test-learning-") { |directory| LegacyReference.command(LEGACY_PROBE, LegacyReference.database(SOURCE_ROOT), "#{mode}=#{directory}", *scenario.fetch("events")) }
        else
          LegacyReference.command(LEGACY_PROBE, LegacyReference.database(SOURCE_ROOT), mode, *scenario.fetch("events"))
        end
      elsif scenario.fetch("id").start_with?("live_", "full_")
        Dir.mktmpdir("cjx-test-learning-") do |directory|
          LegacyReference.command(LEGACY_PROBE, LegacyReference.database(SOURCE_ROOT), "--#{scenario.fetch("id").start_with?("full_") ? "full" : "live"}=#{directory}", *scenario.fetch("events"))
        end
      else
        LegacyReference.command(LEGACY_PROBE, LegacyReference.database(SOURCE_ROOT), *scenario.fetch("events"))
      end
      actual = output.lines.map { |line| JSON.parse(line) }
      assert_equal scenario.fetch("expected"), actual, scenario.fetch("description")
    end
  end
end
