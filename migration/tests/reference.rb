# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "tmpdir"

module LegacyReference
  def self.command(*arguments, **options)
    output, error, status = Open3.capture3(*arguments, **options)
    raise "Command failed: #{arguments.first}: #{error}" unless status.success?
    output
  end

  def self.database(source_root)
    @database ||= begin
      directory = Dir.mktmpdir("cangjiex-baseline-")
      Minitest.after_run { FileUtils.remove_entry(directory) }
      path = File.join(directory, "baseline.db")
      command("sqlite3", path, "CREATE TABLE 'Generic-cj-cin' (key, value);")
      sql = command("ruby", File.join(source_root, "Frameworks/OpenVanilla/Tools/cin-to-sqlite.rb"),
                    File.join(source_root, "DataTables/cj-ext.cin"), "Generic-cj-cin")
      command("sqlite3", path, stdin_data: sql)
      command("sqlite3", path, "CREATE INDEX cj_key ON 'Generic-cj-cin' (key);")
      { "simplex-ext.cin" => "Generic-simplex-cin", "bopomofo-correction.cin" => "OVAFBopomofoCorrection-bopomofo-correction-cin" }.each do |source, name|
        command("sqlite3", path, "CREATE TABLE '#{name}' (key, value);")
        sql = command("ruby", File.join(source_root, "Frameworks/OpenVanilla/Tools/cin-to-sqlite.rb"),
                      File.join(source_root, "DataTables", source), name)
        command("sqlite3", path, stdin_data: sql)
        command("sqlite3", path, "CREATE INDEX '#{name}-key' ON '#{name}' (key);")
      end
      command("sqlite3", path, "CREATE TABLE 'Punctuations-cj-halfwidth-cin' (key, value);")
      sql = command("ruby", File.join(source_root, "Frameworks/OpenVanilla/Tools/cin-to-sqlite.rb"),
                    File.join(source_root, "DataTables/cj-punctuations-halfwidth.cin"), "Punctuations-cj-halfwidth-cin")
      command("sqlite3", path, stdin_data: sql)

      command("sqlite3", path, "CREATE TABLE unigrams (qstring, current, probability, backoff); CREATE TABLE associated_phrases(headchar,data);")
      phrases = File.readlines(File.expand_path("../data/associated-phrases.tsv", __dir__), chomp: true)
      sql = phrases.map do |line|
        head, data = line.split("\t", 2)
        "INSERT INTO associated_phrases VALUES('#{head.gsub("'", "''")}', '#{data.gsub("'", "''")}');"
      end.join("\n")
      command("sqlite3", path, stdin_data: "BEGIN;\n" + sql + "\nCOMMIT;")
      path
    end
  end
end
