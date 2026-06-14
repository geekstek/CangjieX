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

MAX_TAILS_PER_HEAD = 160

common_phrases = []
seed_path = File.expand_path("common-associated-phrases.txt", __dir__)
jieba_dictionary_path = File.expand_path("vendor/jieba/dict.txt.big", __dir__)
opencc_dictionary_dir = File.expand_path("vendor/opencc", __dir__)
opencc_dictionary_files = {
  "STPhrases.txt" => :values,
  "TSPhrases.txt" => :keys,
  "TWPhrasesIT.txt" => :values_then_keys,
  "TWPhrasesName.txt" => :values_then_keys,
  "TWPhrasesOther.txt" => :values_then_keys,
  "TWVariantsRevPhrases.txt" => :values_then_keys,
  "HKVariantsRevPhrases.txt" => :values_then_keys,
}

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
  next unless phrase.match?(/\A\p{Han}{2,8}\z/)
  next unless AssociatedPhraseQuality.traditional_phrase?(phrase)

  phrases << phrase
end

common_phrases.each(&add_phrase)

abort "missing Jieba associated phrase source: #{jieba_dictionary_path}" unless File.file?(jieba_dictionary_path)

jieba_phrases = []
File.foreach(jieba_dictionary_path, encoding: "UTF-8") do |line|
  line = line.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
  next if line.empty? || line.start_with?("#")

  phrase, frequency = line.split(/\s+/, 3)
  next if phrase.to_s.empty?

  jieba_phrases << [phrase, frequency.to_i]
end

jieba_phrases
  .sort_by { |phrase, frequency| [-frequency, phrase.each_char.count, phrase] }
  .each { |phrase, _frequency| add_phrase.call(phrase) }

opencc_dictionary_files.each do |filename, mode|
  path = File.join(opencc_dictionary_dir, filename)
  abort "missing OpenCC associated phrase source: #{path}" unless File.file?(path)

  File.foreach(path, encoding: "UTF-8") do |line|
    line = line.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
    next if line.empty? || line.start_with?("#")

    columns = line.split(/\t+/)
    next if columns.empty?

    value_columns = columns[1, columns.length - 1] || []
    candidates = case mode
                 when :values
                   value_columns
                 when :keys
                   [columns.first]
                 when :values_then_keys
                   value_columns + [columns.first]
                 else
                   columns
                 end

    candidates.each do |candidate|
      candidate.to_s.split(/\s+/).each(&add_phrase)
    end
  end
end

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

prioritize_tails = lambda do |head, values|
  preferred_tails = (
    AssociatedPhraseQuality::ORDERED_TAIL_PREFIXES.fetch(head, []) +
    AssociatedPhraseQuality::REQUIRED_TAILS.fetch(head, [])
  ).uniq
  preferred_tail_set = preferred_tails.to_set
  preferred = preferred_tails.select { |tail| values.include?(tail) }
  remaining = values.each_with_index.reject { |tail, _index| preferred_tail_set.include?(tail) }
  ordered_remaining = remaining.sort_by { |tail, index| [tail.each_char.count, index] }.map(&:first)

  preferred + ordered_remaining
end

associated.each do |head, values|
  associated[head] = prioritize_tails.call(head, values).first(MAX_TAILS_PER_HEAD)
end

final_phrases = associated.each_with_object([]) do |(head, tails), result|
  tails.each { |tail| result << "#{head}#{tail}" }
end

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

  final_phrases.each_with_index do |phrase, index|
    insert_unigram.execute("", phrase, -1.0 - (index * 0.000001), 0.0)
  end

  insert_associated.close
  insert_unigram.close
end

if associated.empty?
  warn "no associated phrases were generated"
  exit 1
end

puts "Cooked #{final_phrases.size} associated phrases into #{associated.size} associated phrase heads."
