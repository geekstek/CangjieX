#!/usr/bin/env ruby
# frozen_string_literal: true

require "sqlite3"
require "set"
require_relative "associated-phrase-quality"

if ARGV.size != 2
  warn "usage: cook-associated-phrases.rb <source-root> <keykey-db>"
  exit 1
end

source_root = ARGV.fetch(0)
database_path = ARGV.fetch(1)

common_phrases = []
seed_path = File.expand_path("common-associated-phrases.txt", __dir__)

if File.file?(seed_path)
  File.foreach(seed_path, encoding: "UTF-8") do |line|
    common_phrases << line
  end
end

phrases = []

add_phrase = lambda do |phrase|
  phrase = phrase.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
  phrase = phrase.delete("\uFEFF")
  next if phrase.empty?
  next if phrase.start_with?("#", "%", "-")

  chars = phrase.each_char.to_a
  next if chars.length < 2 || chars.length > 8
  next unless chars.first.match?(/\p{Han}/)
  next unless AssociatedPhraseQuality.traditional_phrase?(phrase)

  phrases << phrase
end

common_phrases.each(&add_phrase)

Dir.glob(File.join(source_root, "Distributions/Takao/DataSource/Addendum/*.txt")).sort.each do |path|
  File.foreach(path, encoding: "UTF-8") do |line|
    add_phrase.call(line)
  end
end

Dir.glob(File.join(source_root, "Distributions/Takao/DataSource/Overrides/*.txt")).sort.each do |path|
  File.foreach(path, encoding: "UTF-8") do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#", "-")

    case line
    when /^\+\s+(.+)$/
      add_phrase.call(Regexp.last_match(1))
    when /^\+bpmf\s+(\S+)/
      add_phrase.call(Regexp.last_match(1))
    when /^\+2\s+(\S+)\s+(\S+)/
      add_phrase.call("#{Regexp.last_match(1)}#{Regexp.last_match(2)}")
    when /^promote-highest\s+(.+)$/
      add_phrase.call(Regexp.last_match(1))
    when /^ensure-order\s+(.+)$/
      Regexp.last_match(1).split(/\s+/).each(&add_phrase)
    end
  end
end

Dir.glob(File.join(source_root, "ModulePackages/OVAFPhraseConverter/Phrases*.cin")).sort.each do |path|
  in_chardef = false

  File.foreach(path, encoding: "UTF-8") do |line|
    line = line.strip

    if line == "%chardef begin"
      in_chardef = true
      next
    end

    next unless in_chardef
    next if line.empty? || line.start_with?("%", "#")

    add_phrase.call(line.split(/\s+/).first)
  end
end

associated = Hash.new { |hash, key| hash[key] = [] }
seen_phrases = Set.new

phrases.each do |phrase|
  next unless seen_phrases.add?(phrase)

  chars = phrase.each_char.to_a
  head = chars.first
  tail = chars[1, chars.length - 1].join
  next if tail.empty?

  associated[head] << tail unless associated[head].include?(tail)
end

associated.transform_values! { |values| values.first(80) }

db = SQLite3::Database.new(database_path)
db.execute_batch(<<~SQL)
  DROP INDEX IF EXISTS associated_phrases_index;
  DROP TABLE IF EXISTS associated_phrases;
  CREATE TABLE associated_phrases (headchar, data);
  CREATE INDEX associated_phrases_index ON associated_phrases (headchar);

  DROP INDEX IF EXISTS unigrams_index;
  DROP INDEX IF EXISTS unigrams_current_index;
  DROP TABLE IF EXISTS unigrams;
  CREATE TABLE unigrams (qstring, current, probability, backoff);
  CREATE INDEX unigrams_index ON unigrams (qstring);
  CREATE INDEX unigrams_current_index ON unigrams (current);
SQL

db.transaction do
  insert_associated = db.prepare("INSERT INTO associated_phrases VALUES(?, ?)")
  insert_unigram = db.prepare("INSERT INTO unigrams VALUES(?, ?, ?, ?)")

  associated.keys.sort.each do |head|
    insert_associated.execute(head, associated.fetch(head).join(","))
  end

  seen_phrases.each_with_index do |phrase, index|
    insert_unigram.execute("", phrase, -1.0 - (index * 0.000001), 0.0)
  end

  insert_associated.close
  insert_unigram.close
end

if associated.empty?
  warn "no associated phrases were generated"
  exit 1
end

puts "Cooked #{seen_phrases.size} phrases into #{associated.size} associated phrase heads."
