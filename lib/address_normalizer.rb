require "fiddle"
require "fiddle/import"

module AddressNormalizer
  extend Fiddle::Importer

  def self.asset_name
    cpu = case RbConfig::CONFIG["host_cpu"]
          when /x86_64|x64/    then "x86_64"
          when /arm64|aarch64/ then "aarch64"
          else RbConfig::CONFIG["host_cpu"]
          end
    case RbConfig::CONFIG["host_os"]
    when /darwin/      then "libaddress_normalizer-#{cpu}-apple-darwin.dylib"
    when /linux/       then "libaddress_normalizer-#{cpu}-linux-gnu.so"
    when /mswin|mingw/ then "address_normalizer-#{cpu}-windows-msvc.dll"
    else raise "Unsupported platform"
    end
  end

  name     = asset_name
  lib_path = $LOAD_PATH.map { |d| File.join(d, name) }.find { |p| File.exist?(p) }
  raise "native library not found: #{name}" unless lib_path

  dlload lib_path
  extern "char* normalize_address(const char*)"
  extern "void free_string(char*)"

  def self.normalize(text)
    ptr    = normalize_address(text)
    result = ptr.to_s
    free_string(ptr)
    result.force_encoding("UTF-8")
  end
end
