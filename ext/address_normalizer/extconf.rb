require "net/http"
require "uri"
require "digest"

# 配布元。あなたのGitHubリポジトリに合わせる
BASE_URL = ENV.fetch("ADDRESS_NORMALIZER_BASE_URL",
                     "https://github.com/RyomaKaneko0118/address_normalizer_v2/releases/download")
VERSION  = "0.2.0"

# 全アセットのSHA-256を1ファイルにまとめたもの（sha256sum(1) の出力形式）
CHECKSUM_FILE = "SHA256SUMS"

# 実行環境(OS/CPU)から、DLすべき配布ファイル名を決める
def asset_name
  cpu = case RbConfig::CONFIG["host_cpu"]
        when /x86_64|x64/    then "x86_64"
        when /arm64|aarch64/ then "aarch64"
        else RbConfig::CONFIG["host_cpu"]
        end
  case RbConfig::CONFIG["host_os"]
  when /darwin/      then "libaddress_normalizer-#{cpu}-apple-darwin.dylib"
  when /linux/       then "libaddress_normalizer-#{cpu}-linux-gnu.so"
  when /mswin|mingw/ then "address_normalizer-#{cpu}-windows-msvc.dll"
  else raise "Unsupported platform: #{RbConfig::CONFIG["host_os"]}"
  end
end

# リダイレクトに追従してDL（GitHubは302で実体へ飛ぶ）
def download(url, limit = 5)
  raise "too many redirects" if limit.zero?
  res = Net::HTTP.get_response(URI(url))
  case res
  when Net::HTTPSuccess     then res.body
  when Net::HTTPRedirection then download(res["location"], limit - 1)
  else raise "download failed: #{res.code} #{res.message} (#{url})"
  end
end

# SHA256SUMS から該当アセットの期待値を引く。"<hex>  <name>" の行が並ぶ
def expected_sha256(name, url)
  sums = begin
    download(url)
  rescue => e
    raise "checksum file not available: #{url} (#{e.message})"
  end

  entry = sums.each_line.find do |line|
    _, file = line.split(/\s+/, 2)
    # sha256sum -b は名前の前に "*" を付ける
    file.to_s.strip.delete_prefix("*") == name
  end
  raise "no checksum entry for #{name} in #{url}" unless entry

  entry.split(/\s+/, 2).first.downcase
end

name         = asset_name
base         = "#{BASE_URL}/v#{VERSION}"
url          = "#{base}/#{name}"
checksum_url = "#{base}/#{CHECKSUM_FILE}"

warn "[address_normalizer] downloading prebuilt binary: #{url}"
binary = download(url)

# 落としたバイトを実行可能な場所に置く前に検証する
warn "[address_normalizer] verifying checksum: #{checksum_url}"
expected = expected_sha256(name, checksum_url)
actual   = Digest::SHA256.hexdigest(binary)
if actual != expected
  raise <<~MSG
    checksum mismatch for #{name}
      expected: #{expected}
      actual:   #{actual}
      source:   #{url}
    配布元が差し替えられたか、ダウンロードが破損している可能性がある。
  MSG
end
warn "[address_normalizer] checksum ok: #{actual}"

File.binwrite(name, binary)

# makeからは、DL済みファイルを $(sitearchdir) に置くだけ
File.write("Makefile", <<~MAKE)
  LIB = #{name}
  all:
  \t@echo "using prebuilt $(LIB)"
  install:
  \tmkdir -p "$(sitearchdir)"
  \tcp "$(LIB)" "$(sitearchdir)/$(LIB)"
  clean:
  \t@echo clean
MAKE
