#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

module CompatibilityExtraction
  SOURCES = {
    "ModulePackages/OVOFHanConvert/VXHCTC2SCTable.c" => "42afe38f09cfc4c82f39fafc409bab0c03fe7e686061d6c8553fbcc33f402ce3",
    "DataTables/cj-punctuations-halfwidth.cin" => "977ab6362fb872aed7375fffe18c3813c2fded44cda518358bca31b8aebbb540"
  }.freeze
  DATABASE_SHA256 = "3d11ab1c0bfb66cb2c695e863bc773558ac4f33908652989131f992bbc6b72a0"

  def self.extract(source_root, database, destination)
    SOURCES.each do |path, digest|
      raise "Compatibility source checksum differs: #{path}" unless Digest::SHA256.file(File.join(source_root, path)).hexdigest == digest
    end
    raise "Public phrase database checksum differs" unless Digest::SHA256.file(database).hexdigest == DATABASE_SHA256
    table = File.read(File.join(source_root, SOURCES.keys.first))
    numbers = table.split("={", 2).last.split("}", 2).first.scan(/0x[0-9a-fA-F]+/).map { |value| value.to_i(16) }
    raise "Unexpected conversion table size" unless numbers.size == 3058 * 2
    conversion = (numbers + [0, 0]).each_slice(2).map { |from, to| "%04x\t%04x\n" % [from, to] }.join
    punctuation = File.read(File.join(source_root, "DataTables/cj-punctuations-halfwidth.cin"))
      .split("%chardef begin", 2).last.split("%chardef end", 2).first.lines
      .reject { |line| line.strip.empty? }.map { |line| line.strip.split(/\s+/, 2) }
    output, error, status = Open3.capture3("sqlite3", "-readonly", "-json", database,
      "SELECT headchar,data FROM associated_phrases ORDER BY rowid;")
    raise error unless status.success?
    rows = JSON.parse(output)
    raise "Unexpected phrase count" unless rows.size == 6006
    phrases = rows.map do |row|
      head, data = row.fetch("headchar"), row.fetch("data")
      raise "Invalid phrase row" unless head.each_char.count == 1 && !(head + data).match?(/[\t\r\n\0]/)
      "#{head}\t#{data}\n"
    end.join
    outputs = { "punctuation-halfwidth.tsv" => punctuation.map { |row| row.join("\t") + "\n" }.join,
                "tc2sc.tsv" => conversion, "associated-phrases.tsv" => phrases }
    FileUtils.mkdir_p(destination)
    outputs.each { |name, data| File.binwrite(File.join(destination, name), data) }
    File.write(File.join(destination, "LICENSE.HanConvert.txt"), table.split("unsigned short", 2).first)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: extract-migration-compatibility.rb <pinned-source-root> <public-KeyKey.db> <output-directory>" unless ARGV.size == 3
  CompatibilityExtraction.extract(*ARGV)
end
