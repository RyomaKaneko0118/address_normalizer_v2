# address_normalizer

Rust で書かれた住所正規化ロジックを、**ビルド済みバイナリ配布**の Ruby gem として提供する。
インストール先のマシンに Rust ツールチェインは不要。

- Rust 側: `cdylib` としてビルドし、C ABI の関数を 2 つだけ公開する
- Ruby 側: [Fiddle](https://docs.ruby-lang.org/ja/latest/library/fiddle.html) で共有ライブラリを直接 `dlopen` する（C 拡張のコンパイルは行わない）
- 配布: GitHub Releases に上げたプラットフォーム別バイナリを、gem インストール時に HTTP でダウンロードする

---

## アーキテクチャ

```
[リリース時]  git tag v0.2.0
                  │
                  ▼
        GitHub Actions (matrix: 5 target)
        cross build --release
                  │
                  ▼
        GitHub Releases /v0.2.0/
          libaddress_normalizer-aarch64-apple-darwin.dylib
          libaddress_normalizer-x86_64-linux-gnu.so   ... 等
          SHA256SUMS                                  ... 全アセットのSHA-256

[インストール時]  bundle install（git ソース）
                  │
                  ▼
        ext/address_normalizer/extconf.rb
          1. host_os / host_cpu からアセット名を決定
          2. Releases から該当バイナリを DL（302 追従）
          3. SHA256SUMS と照合（不一致なら中断）
          4. コピーするだけの Makefile を生成
                  │
                  ▼
        $(sitearchdir)/libaddress_normalizer-<triple>.<ext>

[実行時]  require "address_normalizer"
                  │
                  ▼
        $LOAD_PATH からアセットを探索 → Fiddle.dlload
                  │
                  ▼
        normalize_address() / free_string()
```

ポイントは、`extconf.rb` が**コンパイルを一切せず**、ダウンロードとインストールだけを行う Makefile を吐くこと。
`s.extensions` の仕組みには乗るが、実体は「バイナリ取得フック」として使っている。

---

## 正規化仕様

`normalize()` は入力文字列を 1 文字ずつ走査し、以下の写像を適用する。それ以外の文字は素通し。

| 入力 | コードポイント | 出力 | 備考 |
|---|---|---|---|
| `０`–`９` | U+FF10–U+FF19 | `0`–`9` | 全角数字 → 半角数字 |
| `ヶ` | U+30F6 | `ケ` | 小書きケ → 大書きケ（例: 八ヶ岳 → 八ケ岳） |
| `ー` | U+30FC | `-` | 長音記号 |
| `－` | U+FF0D | `-` | 全角ハイフンマイナス |
| `−` | U+2212 | `-` | 数学記号のマイナス |

実装上の性質:

- 変換は文字単位の `match` のみで、辞書引きも状態も持たない。出力長は入力の文字数と常に一致する
- Unicode 正規化（NFKC 等）は**行わない**。上表以外の全角英字・全角空白・異体字はそのまま残る
- 都道府県の補完、丁目・番地の桁揃え、漢数字変換などは実装していない

既知の制約として、`ー`(U+30FC) を無条件に `-` へ落とすため、住所中のカタカナ長音（例: `タワー` → `タワ-`）も破壊される。丁目区切りの長音を潰す意図の変換だが、適用範囲は文字種で絞られていない。

---

## FFI インターフェース

Rust 側が公開するシンボルは 2 つ。`#[unsafe(no_mangle)] pub extern "C"`（edition 2024 の記法）で定義される。

```c
char *normalize_address(const char *input);
void  free_string(char *ptr);
```

### `normalize_address`

- 引数は NUL 終端の UTF-8 文字列。`CStr::from_ptr` で読み取る
- 戻り値は **呼び出し側が所有権を持つ** ヒープ上の `CString`（`into_raw()`）
- 以下の場合は `NULL` を返す
  - `input` が `NULL`
  - `input` が妥当な UTF-8 でない

### `free_string`

- `normalize_address` が返したポインタのみを渡すこと（内部で `CString::from_raw` により再構築して drop する）
- `NULL` を渡した場合は何もしない（no-op）

### メモリ契約

確保は Rust 側、解放も Rust 側（`free_string`）で行う。呼び出し側の `free(3)` で解放してはならない。
Ruby ラッパーは `normalize` 1 回につき必ず `free_string` を呼ぶため、リークしない。

> 注意: 現在の Ruby ラッパーは戻り値の `NULL` を検査していない。不正な UTF-8 バイト列を渡した場合の挙動は未定義。

---

## Ruby API

```ruby
require "address_normalizer"

AddressNormalizer.normalize("東京都渋谷区１丁目−２")
# => "東京都渋谷区1丁目-2"
```

`AddressNormalizer.normalize(text)` の内部処理:

1. `normalize_address(text)` を呼び `Fiddle::Pointer` を得る
2. `ptr.to_s` で Ruby の String にコピー
3. `free_string(ptr)` でネイティブ側のバッファを解放
4. `force_encoding("UTF-8")` を適用して返す

`Fiddle` 経由のため、返る String は ASCII-8BIT で来る。`force_encoding` は再エンコードではなくタグ付けのみ（Rust 側の出力は常に妥当な UTF-8 であるため安全）。

ライブラリの探索は `AddressNormalizer.asset_name` が決めたファイル名を `$LOAD_PATH` 上で `File.exist?` して行う。見つからなければ `require` 時点で `RuntimeError: native library not found: ...` を送出する。

---

## 対応プラットフォームとアセット命名

アセット名は `RbConfig::CONFIG["host_os"]` / `["host_cpu"]` から組み立てる。この規則は `extconf.rb`（DL 側）と `lib/address_normalizer.rb`（ロード側）に**同一ロジックが二重に実装されている**ため、変更時は両方を揃える必要がある。

| OS 判定 (`host_os`) | CPU 判定 (`host_cpu`) | アセット名 | Rust target |
|---|---|---|---|
| `/darwin/` | `x86_64\|x64` | `libaddress_normalizer-x86_64-apple-darwin.dylib` | `x86_64-apple-darwin` |
| `/darwin/` | `arm64\|aarch64` | `libaddress_normalizer-aarch64-apple-darwin.dylib` | `aarch64-apple-darwin` |
| `/linux/` | `x86_64\|x64` | `libaddress_normalizer-x86_64-linux-gnu.so` | `x86_64-unknown-linux-gnu` |
| `/linux/` | `arm64\|aarch64` | `libaddress_normalizer-aarch64-linux-gnu.so` | `aarch64-unknown-linux-gnu` |
| `/mswin\|mingw/` | `x86_64\|x64` | `address_normalizer-x86_64-windows-msvc.dll` | `x86_64-pc-windows-msvc` |

上記に当てはまらない環境では `Unsupported platform` で失敗する。
Linux は glibc 前提（`-linux-gnu`）。musl（Alpine 等）向けバイナリは配布していない。

---

## インストール

**この gem は RubyGems.org には公開していない。** `gem install address_normalizer` は解決できない。
Gemfile に git ソースとして書く。

```ruby
gem "address_normalizer",
    git: "https://github.com/RyomaKaneko0118/address_normalizer_v2.git",
    tag: "v0.2.0"
```

Bundler は git 取得した gem に対しても `s.extensions` を実行するため、`extconf.rb` によるバイナリ取得はこの経路でも動く。

`tag:` は必ず指定すること。`extconf.rb` の `VERSION` はハードコードで、DL 先の Release を決めるのはチェックアウトしたリビジョンではなくこの定数である。ブランチ追従にすると、コードと取得するバイナリのバージョンが食い違い得る。

Bundler を介さずローカルで試す場合は、リポジトリを clone して gem を組み立てる。

```sh
gem build address_normalizer.gemspec
gem install address_normalizer-0.2.0.gem
```

### バイナリの取得

`extconf.rb` は次の URL からバイナリを取得する。

```
{BASE_URL}/v{VERSION}/{asset_name}
```

- `BASE_URL` — 既定値 `https://github.com/RyomaKaneko0118/address_normalizer_v2/releases/download`
- `VERSION` — `extconf.rb` 内のハードコード値（現在 `0.2.0`）

ダウンロードは `Net::HTTP` を使い、最大 5 回までリダイレクトを追従する（GitHub Releases は実体の CDN へ 302 を返すため必須）。

### チェックサム検証

バイナリを取得したら、同じディレクトリに置かれた `SHA256SUMS` と照合してから書き出す。

```
{BASE_URL}/v{VERSION}/SHA256SUMS
```

`sha256sum(1)` の出力形式（`<hex>  <ファイル名>`）で全アセット分の行が並ぶ。`extconf.rb` は自分が必要とするアセットの行だけを引き、`Digest::SHA256` で計算した値と比較する。

**検証は必須で、省略する手段はない。** 以下はいずれもインストールを中断させる。

| 状況 | 挙動 |
|---|---|
| ハッシュ不一致 | `checksum mismatch` — expected / actual / 取得元 URL を表示して中断 |
| `SHA256SUMS` が 404 | `checksum file not available` で中断 |
| `SHA256SUMS` に該当アセットの行がない | `no checksum entry for ...` で中断 |

不一致の時点で中断するため、検証に失敗したバイトがディスクに書かれることはない（`File.binwrite` は検証の後）。

### 環境変数

| 変数 | 用途 |
|---|---|
| `ADDRESS_NORMALIZER_BASE_URL` | 配布元のベース URL を差し替える。社内ミラーやローカルの HTTP サーバを指定してオフライン/検証用に使う |

差し替え先にも `v{VERSION}/` 配下にバイナリと `SHA256SUMS` の両方を置く必要がある。

```sh
mkdir -p v0.2.0 && cd v0.2.0
cp .../libaddress_normalizer-aarch64-apple-darwin.dylib .
sha256sum * > SHA256SUMS      # macOS なら shasum -a 256 * > SHA256SUMS
cd .. && python3 -m http.server 8000
```

```sh
ADDRESS_NORMALIZER_BASE_URL=http://localhost:8000 bundle install
```

> セキュリティ上の注意: 検証しているのは**転送の完全性**（破損・取り違え・配布元での差し替え）だけである。`SHA256SUMS` 自体はバイナリと同じ場所から同じ経路で取得するため、配布元そのものを掌握した攻撃者は両方を差し替えられる。これを防ぐには署名（cosign / minisign 等）が必要だが、未実装。信頼できる `BASE_URL` のみを指定すること。

---

## リリース手順

`v` から始まるタグの push で `.github/workflows/release.yml` が起動する。

```sh
# 1. バージョンを 3 箇所すべて揃える
#    - address_normalizer.gemspec       s.version
#    - ext/address_normalizer/extconf.rb VERSION
#    - ext/address_normalizer/Cargo.toml [package] version
# 2. タグを打って push
git tag v0.2.0
git push origin v0.2.0
```

ワークフローは 2 つのジョブからなる。`permissions: contents: write` が必要。

| ジョブ | 内容 |
|---|---|
| `build` | 5 つの target を matrix でビルドし、`cross build --release` の成果物を配布名にリネームして `softprops/action-gh-release@v2` で同名タグの Release にアップロード |
| `checksums` | `needs: build`。`gh release download` で 5 アセットを回収し、`sha256sum` でまとめた `SHA256SUMS` を同じ Release にアップロード |

`checksums` は matrix の外（ubuntu-latest 1 台）で全アセットを揃えてからハッシュを取る。各ジョブが個別に `.sha256` を吐く方式にしていないのは、ランナーごとに `sha256sum` / `shasum` / `Get-FileHash` とコマンドが割れるため。

**バージョンは 3 ファイルで独立に管理されている。** `extconf.rb` の `VERSION` が実際に打ったタグと食い違うと、存在しない URL を叩いてインストールが失敗する。

---

## ソースからのビルド

```sh
cd ext/address_normalizer
cargo build --release
# => target/release/libaddress_normalizer.{dylib,so}
```

生成物を `$LOAD_PATH` 上のディレクトリに配布名でコピーすれば、リリースを経ずに動作確認できる。

```sh
cp target/release/libaddress_normalizer.dylib \
   ../../lib/libaddress_normalizer-aarch64-apple-darwin.dylib

cd ../..
ruby -Ilib -raddress_normalizer -e 'puts AddressNormalizer.normalize("１−２ヶ丘")'
# => 1-2ケ丘
```

Cargo の設定:

| 項目 | 値 |
|---|---|
| edition | 2024 |
| crate-type | `cdylib` |
| 依存クレート | なし（`std` のみ） |

---

## リポジトリ構成

```
address_normalizer.gemspec          gem 定義。s.extensions で extconf.rb を指す
lib/
  address_normalizer.rb             Fiddle によるロードと public API
ext/address_normalizer/
  extconf.rb                        バイナリ DL + インストール用 Makefile 生成
  Cargo.toml                        cdylib 設定
  src/lib.rs                        正規化ロジックと C ABI エクスポート
.github/workflows/release.yml       タグ push によるクロスビルドとリリース
```
