# Continuous Development Log

## 概要

**homura-examples** — Sinatra TODOアプリを2つのプラットフォームで動かすモノレポ例。

- **sinatra-app/** — 普通のSinatraアプリ（CRuby + Puma + SQLite + Sequel）
- **homura-app/** — homura化版（Opal + Sinatra + Cloudflare Workers + D1 + Sequel）

## 経緯

kazuph/homura（Real Ruby + Sinatra on Cloudflare Workers via Opal）のモノレポ例リポジトリとして、同じTODOアプリをsinatra-app（標準環境）とhomura-app（Cloudflare Workers環境）の2つで作成。homura-appはhomuraの最新gem（opal-homura、homura-runtime、sinatra-homura、sequel-d1）をRubyGemsまたはpath参照で使用するstandalone構成。

## 完了済みの作業

### 1. sinatra-app（完了 ✅）
- CRuby + Sinatra + Puma + SQLite + Sequelの構成
- TODO追加・完了切替・削除の全機能動作確認済み
- `http://127.0.0.1:4567` で稼働中

### 2. homura-app（完了 ✅）
- Opal + Sinatra + Cloudflare Workers + D1 + Sequel構成
- bundle install / build / wrangler devで動作確認済み
- TODO追加・完了切替・削除の全機能動作確認済み
- `http://127.0.0.1:8787` で稼働中

### 3. README.md / .gitignore / continuous.md 作成（完了 ✅）

## 解決した問題・発見

### Blocker 1: `params['id']` がOpal版Sinatraで動作しない → 解決 ✅
- **原因**: MustermannのOpal互換性に問題があったが、sinatra-homura 0.2.7でpatch済み
- **検証**: `GET /api/params-test/42` → `{"id":"42","id_class":"String"}` を確認
- **結論**: `params['id'].to_i` で正常にURLパラメータ取得可能

### Blocker 2: `# await: true`ファイルで`redirect`が使えない → 解決 ✅
- **原因**: Opalのasync boundaryで`catch :halt`が効かず、`HaltResponse`例外をPromise rejectionとして処理する必要があった
- **修正**: sinatra-homura 0.2.7で`wrap_async_halt_result`を導入。async routeからの`throw :halt`をPromise.catchで捕捉し、payload（Rack tuple）を返す
- **検証**: `POST /` → `302 Found` + `Location: /` を確認。redirect後に正常に画面遷移
- **発見**: multi-line backtickをRubyメソッドの末尾式にすると、Opalがstatement扱いして`undefined`を返す。single-lineにするかlocal変数に代入してreturnする必要がある

### Blocker 3: sequel-d1公開gemにOpal用Sequelサブセットが含まれていない → 解決 ✅
- **原因**: sequel-d1 0.1.0にOpal用Sequelファイルが同梱されていなかった
- **修正**: sequel-d1 0.2.3でvendor/sequel以下のOpal用ファイルを同梱。Gemfileに`gem 'sequel-d1'`を追加
- **検証**: `db[:todos].all.__await__`、`db.execute(...)`、`db[:todos].insert(...)`、`db[:todos].where(...).update(...)`、`db[:todos].where(...).delete` すべて正常動作
- **発見**: D1 adapterの`js_object_to_hash`がnested object（meta等）を再帰変換していなかった。homura-runtimeの`Cloudflare.js_object_to_hash`を修正して再帰変換に対応

## 残存のworkaround・制約

### toggleロジックのboolean handling
- SQLiteのINTEGERカラム（0/1）に対してRubyの`!`演算子を使うと、`!0`→`false`（0のまま）となりtoggleが機能しない
- **workaround**: `todo[:completed].to_i == 0 ? 1 : 0` で明示的に反転
- **備考**: これはSQLiteの特性であり、homura固有の問題ではない

### POSTデータのフォーマット
- HTML formの`application/x-www-form-urlencoded`ではなく、`application/json`でPOST
- **理由**: `request.body.read` + `JSON.parse` で確実にパースできる
- **備考**: formデータのパースも可能だが、JSONの方がOpal/JS境界での互換性が高い

## この後の開発ロードマップ

1. **テスト追加**
   - homura-appのwrangler dev自動テスト（CRUDフローの検証）
   
2. **sinatra-appとの整合性向上**
   - 両方のアプリで同じルート構成にする
   - ERBテンプレートの共通化

3. **パフォーマンス最適化**
   - D1クエリのN+1問題対策（必要に応じて）

## 環境情報

- Ruby: 3.4.9 (arm64-darwin25)
- Node: 22.x
- homura-runtime: 0.2.4（path参照: homurabi/gems/homura-runtime）
- sinatra-homura: 0.2.7（path参照: homurabi/gems/sinatra-homura）
- opal-homura: 1.8.3.rc1.2
- sequel-d1: 0.2.3（path参照: homurabi/gems/sequel-d1）

## 重要ファイル

```
homura-examples/
├── README.md
├── .gitignore
├── continuous.md          ← このファイル
├── sinatra-app/
│   ├── Gemfile            ← sinatra, puma, sequel, sqlite3
│   ├── app/app.rb         ← Sinatra TODOアプリ
│   ├── views/             ← ERBテンプレート（yield使用）
│   ├── config.ru
│   ├── db/
│   └── public/
└── homura-app/
    ├── Gemfile            ← opal-homura, homura-runtime, sinatra-homura, sequel-d1
    ├── package.json
    ├── wrangler.toml      ← D1バインド
    ├── app/hello.rb       ← Opal版Sinatra TODOアプリ
    ├── views/             ← ERBテンプレート（yield使用）
    ├── cf-runtime/        ← setup-node-crypto.mjs, worker_module.mjs
    ├── db/migrations/     ← D1マイグレーション
    └── public/
```
