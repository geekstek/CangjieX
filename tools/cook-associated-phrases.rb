#!/usr/bin/env ruby
# frozen_string_literal: true

require "sqlite3"
require "set"

if ARGV.size != 2
  warn "usage: cook-associated-phrases.rb <source-root> <keykey-db>"
  exit 1
end

source_root = ARGV.fetch(0)
database_path = ARGV.fetch(1)

SIMPLIFIED_ONLY_CHARS = /[们经个样种为会没关问说过现觉开题资库设输仓颉联词这]/

common_phrases = []
seed_path = File.expand_path("common-associated-phrases.txt", __dir__)

if File.file?(seed_path)
  File.foreach(seed_path, encoding: "UTF-8") do |line|
    common_phrases << line
  end
end

common_phrases.concat(%w[
  我們 我的 我是 我會 我要 我想 我在 我有 我可以 我覺得 我需要 我希望
  你好 你們 你的 你是 你會 你要 你可以 你覺得
  他們 他的 他是 她們 她的 它們 它的
  這個 這些 這樣 這裡 這次 這種 這是
  那個 那些 那樣 那裡 那次 那種 那是
  今天 今年 今日 今晚 明天 明年 明白 明顯 昨天 昨晚
  中文 中國 中心 中間 中央 中華 中大 中小
  倉頡 倉頡星 輸入 輸入法 關聯 關係 關鍵 關於 聯想 聯絡 聯繫
  詞語 詞彙 詞庫 繁體 繁簡 簡體 AppleSilicon 蘋果 電腦 電話 電子 電郵
  系統 設定 設計 開源 開發 現代 現在 現場 可以 可能 可用 可愛
  不能 不會 不是 不要 不用 不好 不到 沒有 沒關係 沒問題
  請問 請你 請稍等 謝謝 工作 公司 項目 專案 問題 方案 方法
  使用 用戶 用法 資料 資料庫 學習 學校 學生 生活 生命 時間 時候
  地方 地點 香港 台灣 臺灣 澳門 美國 日本 韓國
])

phrases = []

add_phrase = lambda do |phrase|
  phrase = phrase.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
  phrase = phrase.delete("\uFEFF")
  next if phrase.empty?
  next if phrase.start_with?("#", "%", "-")

  chars = phrase.each_char.to_a
  next if chars.length < 2 || chars.length > 8
  next unless chars.first.match?(/\p{Han}/)
  next if phrase.match?(SIMPLIFIED_ONLY_CHARS)

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
