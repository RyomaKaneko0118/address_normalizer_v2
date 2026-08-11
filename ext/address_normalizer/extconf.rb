require "net/http"
require "uri"

# 配布元。あなたのGitHubリポジトリに合わせる
BASE_URL = ENV.fetch("ADDRESS_NORMALIZER_BASE_URL",
                     "https://github.com/RyomaKaneko0118/address_normalizer/releases/download")
VERSION  = "0.1.0"

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

name = asset_name
url  = "#{BASE_URL}/v#{VERSION}/#{name}"
warn "[address_normalizer] downloading prebuilt binary: #{url}"
File.binwrite(name, download(url))

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
