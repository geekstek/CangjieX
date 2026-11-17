# frozen_string_literal: true

SOURCE_ROOT = ARGV.shift or abort "usage: extraction_test.rb <pinned-source-root>"
require "minitest/autorun"
require_relative "reference"
require_relative "../../tools/extract-cangjie"
require_relative "../../tools/extract-migration-compatibility"

class ExtractionTest < Minitest::Test
  DATA_DIR = File.expand_path("../data", __dir__)
  SOURCE = File.join(SOURCE_ROOT, "DataTables/cj-ext.cin")

  def test_extraction_is_reproducible_including_manifest_and_licenses
    Dir.mktmpdir do |directory|
      manifest = CangjieExtraction.extract(SOURCE, directory)
      %w[cangjie.tsv keynames.tsv manifest.json].each do |name|
        assert_equal File.binread(File.join(DATA_DIR, name)), File.binread(File.join(directory, name)), name
      end
      assert_equal 82_873, manifest.fetch(:entry_count)
      assert_equal 65_732, manifest.fetch(:distinct_code_count)
      assert_equal 8, manifest.fetch(:duplicate_entry_count)
      assert_equal File.binread(File.join(File.dirname(SOURCE_ROOT), "LICENSE.txt")),
                   File.binread(File.join(DATA_DIR, "LICENSE.KeyKey.txt"))
    end
  end

  def test_every_entry_and_keyname_matches_the_original_sqlite_cooker_in_order
    database = LegacyReference.database(SOURCE_ROOT)
    rows = JSON.parse(LegacyReference.command("sqlite3", "-json", database,
      "SELECT key,value FROM 'Generic-cj-cin' WHERE substr(key,1,11) != '__property_' ORDER BY rowid;"))
    actual = rows.map { |row| [row.fetch("key"), row.fetch("value")] }
    expected = File.readlines(File.join(DATA_DIR, "cangjie.tsv"), chomp: true).map { |line| line.split("\t", 2) }
    assert_equal expected, actual

    keynames = JSON.parse(LegacyReference.command("sqlite3", "-json", database,
      "SELECT substr(key,20) AS code,value FROM 'Generic-cj-cin' WHERE substr(key,1,19) = '__property_keyname-' ORDER BY rowid;"))
    expected_keynames = File.readlines(File.join(DATA_DIR, "keynames.tsv"), chomp: true).map { |line| line.split("\t", 2) }
    assert_equal expected_keynames, keynames.map { |row| [row.fetch("code"), row.fetch("value")] }
  end

  def test_additional_modules_are_pinned_reproducible_and_match_original_sqlite_cooker
    Dir.mktmpdir do |directory|
      manifest = CangjieExtraction.extract_modules(SOURCE_ROOT, directory)
      %w[simplex.tsv simplex-keynames.tsv bopomofo-correction.tsv modules-manifest.json].each do |name|
        assert_equal File.binread(File.join(DATA_DIR, name)), File.binread(File.join(directory, name)), name
      end
      assert_equal 63_234, manifest.fetch(:tables).fetch("simplex").fetch(:entry_count)
      assert_equal 133, manifest.fetch(:tables).fetch("bopomofo-correction").fetch(:entry_count)
      {"simplex" => "Generic-simplex-cin", "bopomofo-correction" => "OVAFBopomofoCorrection-bopomofo-correction-cin"}.each do |name, table|
        actual = JSON.parse(LegacyReference.command("sqlite3", "-json", LegacyReference.database(SOURCE_ROOT),
          "SELECT key,value FROM '#{table}' WHERE substr(key,1,11) != '__property_' ORDER BY rowid;"))
        assert_equal File.readlines(File.join(DATA_DIR, "#{name}.tsv"), chomp: true), actual.map { |row| [row.fetch("key"), row.fetch("value")].join("\t") }
      end
      assert_equal File.binread(File.join(DATA_DIR, "keynames.tsv")), File.binread(File.join(DATA_DIR, "simplex-keynames.tsv"))
    end
  end

  def minimal_cin(rows = "a 日\na 曰\n")
    "%encoding UTF-8\n%keyname begin\na 日\n%keyname end\n%chardef begin\n#{rows}%chardef end\n"
  end

  def test_preserves_hash_percent_punctuation_and_duplicate_rows
    data = CangjieExtraction.parse(minimal_cin("# ＃\n% ％\n' 、\n' 、\n"))
    assert_equal [["#", "＃"], ["%", "％"], ["'", "、"], ["'", "、"]], data.fetch(:entries)
  end

  def test_rejects_invalid_utf8_and_nul
    [minimal_cin.b + "\xff".b, minimal_cin + "\0"].each do |text|
      assert_raises(ArgumentError) { CangjieExtraction.parse(text) }
    end
  end

  def test_rejects_missing_nested_duplicate_and_empty_sections
    [
      minimal_cin.sub("%chardef end", ""),
      minimal_cin + "%chardef begin\na 日\n%chardef end\n",
      minimal_cin.sub("%keyname end", "%chardef begin"),
      minimal_cin(""),
      minimal_cin.sub("%keyname begin\na 日\n%keyname end\n", "")
    ].each do |text|
      assert_raises(ArgumentError) { CangjieExtraction.parse(text) }
    end
  end

  def test_rejects_malformed_rows_and_duplicate_keynames
    ["abcdef 字\n", "a\n", "中 字\n", "a 字\t字\n"].each do |row|
      assert_raises(ArgumentError) { CangjieExtraction.parse(minimal_cin(row)) }
    end
    assert_raises(ArgumentError) do
      CangjieExtraction.parse(minimal_cin.sub("a 日\n%keyname end", "a 日\na 月\n%keyname end"))
    end
  end

  def test_refuses_a_different_source_before_creating_output
    Dir.mktmpdir do |directory|
      source = File.join(directory, "changed.cin")
      destination = File.join(directory, "output")
      File.write(source, minimal_cin)
      assert_raises(ArgumentError) { CangjieExtraction.extract(source, destination) }
      refute File.exist?(destination)
    end
  end

  def test_output_checksums_match_manifest
    manifest = JSON.parse(File.read(File.join(DATA_DIR, "manifest.json")))
    manifest.fetch("output_sha256").each do |name, digest|
      assert_equal digest, Digest::SHA256.file(File.join(DATA_DIR, name)).hexdigest
    end
  end

  def test_compatibility_tables_match_pinned_sources_and_cooker
    manifest = JSON.parse(File.read(File.join(DATA_DIR, "compatibility-manifest.json")))
    manifest.fetch("sources").each do |path, digest|
      assert_equal digest, Digest::SHA256.file(File.join(SOURCE_ROOT, path)).hexdigest
    end
    manifest.fetch("output_sha256").each do |name, digest|
      assert_equal digest, Digest::SHA256.file(File.join(DATA_DIR, name)).hexdigest
    end
    rows = JSON.parse(LegacyReference.command("sqlite3", "-json", LegacyReference.database(SOURCE_ROOT),
      "SELECT key,value FROM 'Punctuations-cj-halfwidth-cin' WHERE substr(key,1,11) != '__property_' ORDER BY rowid;"))
    assert_equal File.readlines(File.join(DATA_DIR, "punctuation-halfwidth.tsv"), chomp: true),
                 rows.map { |row| [row.fetch("key"), row.fetch("value")].join("\t") }
  end

  def test_all_conversion_pairs_match_the_original_output_filter
    rows = File.readlines(File.join(DATA_DIR, "tc2sc.tsv"), chomp: true).map { |line| line.split("\t").map { |hex| hex.to_i(16) } }
    initialized = rows.reject { |from, _to| from.zero? }
    input = initialized.map(&:first).pack("U*") + "𨈍ASCII"
    expected = initialized.map(&:last).pack("U*") + "𨈍ASCII"
    probe = File.expand_path("../../build/migration/legacy-probe", __dir__)
    assert_equal expected, LegacyReference.command(probe, "--convert", input)
  end

  def test_public_phrase_extraction_is_reproducible_when_release_cache_is_available
    database = File.expand_path("../../.source/Yahoo! KeyKey.app/Contents/Resources/Databases/KeyKey.db", __dir__)
    # CI uses the committed, checksummed public table; no binary download is required.
    return unless File.exist?(database)
    Dir.mktmpdir do |directory|
      CompatibilityExtraction.extract(SOURCE_ROOT, database, directory)
      %w[punctuation-halfwidth.tsv tc2sc.tsv associated-phrases.tsv LICENSE.HanConvert.txt].each do |name|
        assert_equal File.binread(File.join(DATA_DIR, name)), File.binread(File.join(directory, name)), name
      end
    end
  end
end
