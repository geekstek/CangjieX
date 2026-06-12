#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"

script_path = ENV.fetch("SOURCE_PROBE_SCRIPT", File.expand_path("probe-upstream-source.sh", __dir__))
manifest_path = ENV.fetch("SOURCE_PATCH_MANIFEST", File.expand_path("source-patches/manifest.tsv", __dir__))

allowed_categories = Set.new(%w[
  behavior
  branding
  compile
  crypto
  database
  input
  legacy
  link
  ui
])

failures = []

unless File.file?(script_path)
  failures << "source probe script is missing: #{script_path}"
end

unless File.file?(manifest_path)
  failures << "source patch manifest is missing: #{manifest_path}"
end

if failures.any?
  warn "source patch check failed:"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end

script = File.read(script_path)
manifest_lines = File.readlines(manifest_path, chomp: true)

script_commit = script[/SOURCE_UPSTREAM_COMMIT="\$\{SOURCE_UPSTREAM_COMMIT:-([0-9a-f]{40})\}"/, 1]
manifest_commit = manifest_lines.map { |line| line[/^#\s+upstream\s+([0-9a-f]{40})$/, 1] }.compact.first

failures << "unable to find default SOURCE_UPSTREAM_COMMIT in #{script_path}" if script_commit.nil?
failures << "unable to find upstream commit header in #{manifest_path}" if manifest_commit.nil?

if script_commit && manifest_commit && script_commit != manifest_commit
  failures << "upstream commit mismatch: script has #{script_commit}, manifest has #{manifest_commit}"
end

manifest_ids = []
manifest_id_set = Set.new

manifest_lines.each_with_index do |line, index|
  next if line.empty? || line.start_with?("#")

  line_number = index + 1
  id, category, target, purpose = line.split("\t", 4)

  if [id, category, target, purpose].any? { |value| value.to_s.empty? }
    failures << "manifest line #{line_number} must have id, category, target, and purpose"
    next
  end

  failures << "manifest line #{line_number} has invalid id: #{id}" unless id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
  failures << "manifest line #{line_number} has unknown category: #{category}" unless allowed_categories.include?(category)

  if manifest_id_set.include?(id)
    failures << "manifest line #{line_number} duplicates id: #{id}"
  else
    manifest_id_set.add(id)
    manifest_ids << id
  end
end

script_ids = script.scan(/source_patch_applied\s+"([^"]+)"/).flatten
script_id_set = Set.new(script_ids)
script_id_counts = Hash.new(0)
script_ids.each { |id| script_id_counts[id] += 1 }
duplicate_script_ids = script_id_counts.select { |_id, count| count > 1 }.keys

unless duplicate_script_ids.empty?
  failures << "source probe script applies duplicate patch ids: #{duplicate_script_ids.join(', ')}"
end

missing_manifest_ids = script_id_set.to_a - manifest_ids
unused_manifest_ids = manifest_ids - script_id_set.to_a

unless missing_manifest_ids.empty?
  failures << "script patch ids missing from manifest: #{missing_manifest_ids.join(', ')}"
end

unless unused_manifest_ids.empty?
  failures << "manifest patch ids not used by script: #{unused_manifest_ids.join(', ')}"
end

if manifest_ids.empty?
  failures << "manifest has no patch entries"
end

if failures.any?
  warn "source patch check failed:"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end

puts "source patch manifest check passed (#{manifest_ids.length} patches, upstream #{manifest_commit})"
