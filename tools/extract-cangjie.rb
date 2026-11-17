#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module CangjieExtraction
  COMMIT = "81e05f070c070af65cac21e8da28ca4ff2d58905"
  SOURCE_PATH = "YahooKeyKey-Source-1.1.2528/DataTables/cj-ext.cin"
  SOURCE_SHA256 = "bb30b57550e796aeb255e0efe92749c1ea28b74cd42fed7a6c22282091bd44e6"

  def self.parse(bytes, unicode_keys: false)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise ArgumentError, "CIN is not valid UTF-8" unless text.valid_encoding?
    raise ArgumentError, "CIN contains NUL" if text.include?("\0")

    sections = { "keyname" => [], "chardef" => [] }
    completed = []
    properties = {}
    section = nil
    text.each_line.with_index(1) do |raw_line, number|
      line = raw_line.strip
      next if line.empty?

      if (marker = line.match(/\A%(keyname|chardef)\s+(begin|end)\z/))
        name, action = marker.captures
        if action == "begin"
          raise ArgumentError, "duplicate/nested section at line #{number}" if section || completed.include?(name)
          section = name
        else
          raise ArgumentError, "unexpected section end at line #{number}" unless section == name
          completed << name
          section = nil
        end
      elsif section
        key, value = line.split(/\s+/, 2)
        valid_key = key && (key.match?(/\A[!-~]{1,5}\z/) || (unicode_keys && key.match?(/\A[\u3105-\u3129\u02c7\u02ca\u02cb\u02d9]{1,5}\z/)))
        unless valid_key && value && !value.match?(/[\t\r\n]/)
          raise ArgumentError, "invalid #{section} row at line #{number}"
        end
        sections.fetch(section) << [key, value]
      elsif line.start_with?("%")
        key, value = line.delete_prefix("%").split(/\s+/, 2)
        raise ArgumentError, "duplicate property #{key}" if properties.key?(key)
        properties[key] = value.to_s
      elsif !line.start_with?("#")
        raise ArgumentError, "unexpected content at line #{number}"
      end
    end

    unless section.nil? && completed.sort == %w[chardef keyname] && sections.values.none?(&:empty?)
      raise ArgumentError, "missing, empty or unterminated CIN section"
    end
    raise ArgumentError, "expected UTF-8 encoding" unless properties["encoding"] == "UTF-8"
    raise ArgumentError, "duplicate keyname" unless sections["keyname"].map(&:first).uniq.size == sections["keyname"].size

    { properties: properties, keynames: sections["keyname"], entries: sections["chardef"] }
  end

  def self.extract(source, destination)
    bytes = File.binread(source)
    raise ArgumentError, "source SHA256 differs from pinned upstream" unless Digest::SHA256.hexdigest(bytes) == SOURCE_SHA256

    data = parse(bytes)
    outputs = {
      "cangjie.tsv" => data.fetch(:entries).map { |row| row.join("\t") + "\n" }.join,
      "keynames.tsv" => data.fetch(:keynames).map { |row| row.join("\t") + "\n" }.join
    }
    manifest = {
      schema_version: 1,
      upstream_repository: "https://github.com/YahooArchive/KeyKey",
      upstream_commit: COMMIT,
      source_path: SOURCE_PATH,
      source_url: "https://raw.githubusercontent.com/YahooArchive/KeyKey/#{COMMIT}/#{SOURCE_PATH}",
      source_sha256: SOURCE_SHA256,
      license_file: "LICENSE.KeyKey.txt",
      source_notes: bytes.force_encoding("UTF-8").lines.take_while { |line| line.start_with?("#") || line.strip.empty? }.join,
      properties: data.fetch(:properties),
      entry_count: data.fetch(:entries).size,
      distinct_code_count: data.fetch(:entries).map(&:first).uniq.size,
      duplicate_entry_count: data.fetch(:entries).size - data.fetch(:entries).uniq.size,
      keyname_count: data.fetch(:keynames).size,
      output_sha256: outputs.transform_values { |content| Digest::SHA256.hexdigest(content) }
    }
    FileUtils.mkdir_p(destination)
    outputs.each { |name, content| File.binwrite(File.join(destination, name), content) }
    File.write(File.join(destination, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
    manifest
  end

  MODULE_SOURCES = {
    "simplex-ext.cin" => "8d925bfbd524dbc6042a1ce89912aadc17d8aa34109410a22948fd07c2d006e9",
    "bopomofo-correction.cin" => "76caa12eac8042e501426f0c8d66dca85c0cddcb19e0ccc98c369491d878e699"
  }.freeze

  def self.extract_modules(source_root, destination)
    outputs, tables = {}, {}
    MODULE_SOURCES.each do |name, digest|
      bytes = File.binread(File.join(source_root, "DataTables", name))
      raise ArgumentError, "module source SHA256 differs: #{name}" unless Digest::SHA256.hexdigest(bytes) == digest
      data = parse(bytes, unicode_keys: name == "bopomofo-correction.cin")
      stem = name == "simplex-ext.cin" ? "simplex" : "bopomofo-correction"
      outputs["#{stem}.tsv"] = data.fetch(:entries).map { |row| row.join("\t") + "\n" }.join
      outputs["simplex-keynames.tsv"] = data.fetch(:keynames).map { |row| row.join("\t") + "\n" }.join if stem == "simplex"
      tables[stem] = { source_path: "DataTables/#{name}", source_sha256: digest, properties: data.fetch(:properties),
        entry_count: data.fetch(:entries).size, distinct_code_count: data.fetch(:entries).map(&:first).uniq.size }
    end
    manifest = { schema_version: 1, upstream_repository: "https://github.com/YahooArchive/KeyKey", upstream_commit: COMMIT,
      license_file: "LICENSE.KeyKey.txt", tables: tables, output_sha256: outputs.transform_values { |content| Digest::SHA256.hexdigest(content) } }
    FileUtils.mkdir_p(destination)
    outputs.each { |name, content| File.binwrite(File.join(destination, name), content) }
    File.write(File.join(destination, "modules-manifest.json"), JSON.pretty_generate(manifest) + "\n")
    manifest
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "--modules" && ARGV.size == 3
    CangjieExtraction.extract_modules(ARGV[1], ARGV[2])
    exit
  end
  abort "usage: extract-cangjie.rb <pinned-cj-ext.cin> <output-directory>" unless ARGV.size == 2
  manifest = CangjieExtraction.extract(*ARGV)
  puts "Extracted #{manifest.fetch(:entry_count)} entries; preserved source order and duplicates."
end
