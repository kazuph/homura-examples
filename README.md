# homura-examples

Sinatra TODOアプリを2つのプラットフォームで動かすモノレポ例。

## 構成

- **sinatra-app/** — 普通のSinatraアプリ（CRuby + Puma + SQLite + Sequel）
- **homura-app/** — homura化版（Opal + Sinatra + Cloudflare Workers + KV）

## sinatra-app

通常のSinatraアプリ。CRuby上でPumaを使って動作。

```bash
cd sinatra-app
bundle install
bundle exec puma -p 4567
```

http://127.0.0.1:4567 でアクセス。

## homura-app

homura（Opal + Sinatra + Cloudflare Workers）版。RubyコードをOpalでJSにコンパイルし、Cloudflare Workers上でSinatraを動かす。

```bash
cd homura-app
bundle install
npm install
npm run build
npm run dev
```

http://127.0.0.1:8787 でアクセス。

## 差分ポイント

| 項目 | sinatra-app | homura-app |
|---|---|---|
| ランタイム | CRuby + Puma | Opal + Cloudflare Workers |
| DB | SQLite (Sequel) | Workers KV |
| ERB | Tilt（リアルタイム評価） | ビルド時プリコンパイル |
| yield | `yield`可能 | `<%= @content %>`のみ |
| redirect | `redirect '/path'`可能 | `# await: true`ファイルでは使えない |
| params | `params['id']`で動作 | `params['id']`未対応 → `request.path_info`で回避 |

## homura の制約

- `# await: true`マジックコメント付きファイルではSinatraの`redirect`/`halt`が使えない（Opal async boundary問題）
- ERBテンプレートで`yield`が使えない（Opalのyield制限）。`@content`パターンを使う
- `params['id']`などのURLパラメータがOpal版Sinatraで正しく動かない場合あり（`request.path_info`で回避可能）
