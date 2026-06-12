#!/usr/bin/env ruby
# frozen_string_literal: true

require "sqlite3"
require_relative "associated-phrase-quality"

if ARGV.size != 1
  warn "usage: validate-associated-phrases.rb <keykey-db>"
  exit 1
end

database_path = ARGV.fetch(0)
db = SQLite3::Database.new(database_path)

failures = []

associated_phrase_count = db.get_first_value("SELECT COUNT(*) FROM associated_phrases").to_i
if associated_phrase_count < AssociatedPhraseQuality::MIN_ASSOCIATED_HEADS
  failures << "associated_phrases has #{associated_phrase_count} heads, expected at least #{AssociatedPhraseQuality::MIN_ASSOCIATED_HEADS}"
end

unigram_table_count = db.get_first_value("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'unigrams'").to_i
failures << "missing unigrams table required by associated phrase module" unless unigram_table_count == 1

bad_rows = []
db.execute("SELECT headchar, data FROM associated_phrases") do |headchar, data|
  value = "#{headchar}#{data}"
  bad_rows << "#{headchar}:#{data}" unless AssociatedPhraseQuality.traditional_phrase?(value)
end

unless bad_rows.empty?
  failures << "simplified-only characters found in associated phrases: #{bad_rows.first(8).join(' / ')}"
end

AssociatedPhraseQuality::REQUIRED_TAILS.each do |headchar, required_tails|
  data = db.get_first_value("SELECT data FROM associated_phrases WHERE headchar = ?", headchar).to_s
  actual_tails = data.split(",")
  missing_tails = required_tails - actual_tails

  failures << "#{headchar} is missing required tails: #{missing_tails.join(',')}" unless missing_tails.empty?
end

AssociatedPhraseQuality::ORDERED_TAIL_PREFIXES.each do |headchar, expected_prefix|
  data = db.get_first_value("SELECT data FROM associated_phrases WHERE headchar = ?", headchar).to_s
  actual_prefix = data.split(",").first(expected_prefix.length)

  next if actual_prefix == expected_prefix

  failures << "#{headchar} prefix is #{actual_prefix.join(',')}, expected #{expected_prefix.join(',')}"
end

if failures.any?
  warn "associated phrase validation failed:"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end

puts "associated phrase validation passed (#{associated_phrase_count} heads)"
