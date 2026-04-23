# [%174] homura-examples 調査・修正 振り返りレポート

> 日時: 2026-04-23
> 担当: 174番（Sisyphus）
> 対象: homura-app（Opal + Sinatra + Cloudflare Workers + D1 + sequel-d1）

---

## 1. 174番が最初に何を見て、どの順序で何を検証したか

### 1-1. 最初に確認したもの（入り口）

1. **`continuous.md`**
   - 3つのBlocker（`params['id']`、redirect/halt、sequel-d1）が記載されていた
   - それぞれに「%170へ報告済み」と書かれており、%170での修正が完了している前提だった

2. **`homura-app/Gemfile`**
   - 既に最新版（opal-homura 1.8.3.rc1.2、homura-runtime 0.2.4、sinatra-homura 0.2.7、sequel-d1 0.2.3）が指定済み
   - ただし、%170のローカル修正がrubygems.orgに反映されていない可能性を考慮し、path指定への切り替えを実施

3. **`app/hello.rb`**
   - `# await: true` マジックコメント付き
   - `db[:todos].all.__await__` などasyncパターンが使われている
   - `redirect '/'` がコメントアウトされてJSONレスポンスにフォールバックしていた

### 1-2. 検証の順序

```
Step 1: bundle install + npm install
        → 依存解決確認

Step 2: npm run build（cloudflare-workers-build --standalone --with-db）
        → build成功を確認

Step 3: wrangler dev起動
        → 最初は $respond_to? エラーで落ちる
        → path指定したhomura-runtimeが古いバージョンだったのが原因
        → git pullで%170の最新修正（7ae92d2）を取り込んで解決

Step 4: healthエンドポイント確認
        → GET /api/health → {"status":"ok"} OK

Step 5: DBクエリ確認
        → GET /api/todos → 空レスポンス（200 OKだがボディなし）
        → ここから本格的な調査が始まる

Step 6: async routeの切り分け
        → /api/async-test を追加
        → Promise.resolve("async-ok").__await__ も空レスポンス
        → async route自体に問題があることが判明

Step 7: 原因特定
        → sinatra_opal_patches.rb の wrap_async_halt_result
        → multi-line backtick が Opal で statement 扱いされ undefined を返していた

Step 8: 修正適用
        → wrap_async_halt_result を single-line backtick に変更
        → async-test が "async-ok" を返すようになる
        → /api/todos も {"todos":[]} を返すようになる

Step 9: TODO作成テスト
        → POST / で ParserError（JSON.parseにformデータが入っていた）
        → application/json に変更して解決

Step 10: DB insertテスト
        → db.execute("INSERT ...", [text, ...]) でエラー
        → Sequel::Database#execute のシグネチャが (sql, opts={}, &block) であり、
          第2引数を opts[:arguments] として解釈する必要があった
        → db.execute(sql, arguments: [text, ...]).__await__ に変更

Step 11: toggleテスト
        → !0 が false になり toggle できない
        → .to_i == 0 ? 1 : 0 に変更

Step 12: params['id'] 検証
        → /api/params-test/:id を追加
        → params['id'].to_i → 42 と正しく取得できることを確認

Step 13: redirect 検証
        → /api/redirect-test を追加
        → redirect '/api/health' → 302 Found + Location ヘッダーを確認

Step 14: js_object_to_hash の再帰変換
        → D1 run()結果の meta（nested JS object）がOpalのHashになっていなかった
        → Cloudflare.js_object_to_hash を再帰的に修正

Step 15: 全フロー検証
        → 作成 → 一覧 → toggle → 削除 の一連の流れを確認
        → HTMLレンダリングも確認
```

---

## 2. どこをどう直した / どの修正が本当に効いたか

### 2-1. 本当に効いた修正（根本原因）

#### A. `wrap_async_halt_result` の single-line 化

**ファイル**: `homurabi/gems/sinatra-homura/lib/sinatra_opal_patches.rb`

**変更前（multi-line）**:
```ruby
wrapped = `#{res}.catch(function(error) {
  try {
    ...
  } catch (_) {}
  throw error;
})`
wrapped
```

**変更後（single-line）**:
```ruby
`#{res}.catch(function(error) { try { ... } catch (_) {} throw error; })`
```

**なぜ効いたか**:
- Opalはmulti-line backtickを「statement」としてコンパイルし、メソッドの戻り値を`undefined`にする
- single-lineにすると「expression」として扱われ、`return res.catch(...)` となる
- これによりasync routeの戻り値Promiseが`apply_invoke_result`に正しく届くようになった

#### B. `Cloudflare.js_object_to_hash` の再帰変換

**ファイル**: `homurabi/gems/homura-runtime/lib/cloudflare_workers.rb`

**変更前**: shallow copy（ネストしたJSオブジェクトをそのまま入れる）
**変更後**: nested plain objectを再帰的にHashに変換

**なぜ効いたか**:
- D1 `run()` の結果は `{ 'meta' => { 'last_row_id' => 7, ... } }` の形
- `meta` がJSオブジェクトのままだと、`raw['meta'].is_a?(Hash)` が false になる
- `d1_meta_value` で `raw['meta']` に対してRubyメソッドを呼ぼうとしてTypeErrorが出ていた

### 2-2. ややこしかったが最終的に不要だった修正

#### `route_eval` のオーバーライド（デバッグ用）

調査中に`route_eval`にデバッグログを仕込んだが、これは根本原因ではなく、問題の切り分け用だった。最終的には元の実装（`throw :halt, yield`）に戻した。

### 2-3. 検証で発見したがアプリ側で対応した点

#### toggleロジックのboolean handling

SQLiteのINTEGER（0/1）に対してRubyの`!`を使うと`!0`→`false`（0のまま）となる。
```ruby
# 変更前（動かない）
db[:todos].where(id: target_id).update(completed: !todo[:completed]).__await__

# 変更後（動く）
new_val = todo[:completed].to_i == 0 ? 1 : 0
db[:todos].where(id: target_id).update(completed: new_val).__await__
```

これはhomuraの問題ではなく、SQLite + Rubyの一般的な落とし穴。

#### POSTデータのフォーマット

HTML formの`application/x-www-form-urlencoded`ではなく、`application/json`でPOSTする必要があった。`JSON.parse(request.body.read)`が確実に動くため。

---

## 3. 今回の homura フレームワークのハマりどころ解説

### 3-1. Opal × async × Promise × backtick JS の絡み

#### 問題の核心: 「Rubyっぽく書ける」が「JSの挙動を知らないとデバッグできない」

homuraは「RubyコードをOpalでJSにコンパイルし、Cloudflare Workersで動かす」という3層構造。

| 層 | 役割 | ユーザーが書くコード |
|---|---|---|
| Ruby層 | Sinatraアプリ | `get '/' do ... end` |
| Opal層 | Ruby→JSコンパイル | `__await__` → JS `await` |
| JS層 | Cloudflare Workers上で実行 | `Promise`、V8 API |

この構造により、**見た目はRubyだが、実際の挙動はJSの非同期モデルに従う**。

#### ハマりポイント1: `__await__` の見え方

```ruby
result = db[:todos].all.__await__
```

これはOpalによって以下のようにコンパイルされる：
```javascript
result = (await (self.$db()['$[]']("todos").$order("id").$all()));
```

つまり、`__await__`を呼んだ行はJSの`await`になる。これが**async functionの中**でないとSyntaxErrorになる。homuraは`# await: true`ファイルのroute blockを自動的に`async function`にコンパイルしてくれるが、この仕組みが「見えない」ため、なぜ空レスポンスになるのか判断が難しい。

#### ハマりポイント2: backtick JS（x-string）の挙動差

OpalではRubyのbacktick（`` `...` ``）で直接JSコードを書ける。これは非常に強力だが、**multi-lineとsingle-lineでOpalのコンパイル結果が大きく変わる**。

| 形式 | Opalの扱い | 戻り値 |
|---|---|---|
| single-line `` `expr` `` | expression | exprの評価結果 |
| multi-line `` `stmt\nstmt` `` | statement | `undefined` |

`wrap_async_halt_result`では、multi-lineで書かれた`res.catch(...)`が`undefined`を返しており、Sinatraの`apply_invoke_result`にPromiseではなく`undefined`が渡されていた。これが**見かけ上は「catchしてPromiseを返す」コードに見えるのに、実際にはundefinedになる**という罠。

#### ハマりポイント3: Opalの`catch`/`throw`とJSの`try`/`catch`

Rubyの`catch(:halt)`/`throw(:halt, value)`はOpalでは以下のようにコンパイルされる：

```javascript
try {
  return Opal.yield1($yield, tag);
} catch ($err) {
  if (Opal.rescue($err, [$$$('UncaughtThrowError')])) {
    if ($eqeq(e.$tag(), tag)) {
      return e.$value();
    }
  }
}
```

つまり、Rubyの`throw`はJSの`throw`を使っているが、投げるのは`UncaughtThrowError`という特殊な例外。Rubyの`catch`はJSの`try/catch`でこれを捕捉する。

async route（`async function`）の中で`throw :halt`をすると、JSの`throw`が発生する。しかし、async function内のthrowは**Promiseのrejection**になる。これを外側の`catch(:halt)`が捕捉できない（同期的なtry/catchではasync内のthrowを捕捉できない）。

このため、sinatra-homuraでは`wrap_async_halt_result`でPromiseの`.catch()`を使ってrejectionを捕捉し、`HaltResponse`例外のpayload（Rack tuple）を返すようにしていた。この仕組み自体は正しかったが、multi-line backtickの問題で戻り値がundefinedになっていた。

### 3-2. standalone build の特殊性

homura-appは`--standalone`オプションでbuildしている。これは「Cloudflare Workersのruntimeファイル（worker_module.mjs等）を自動生成する」モード。

- `build/`ディレクトリに`hello.no-exit.mjs`（Opalコンパイル済みRubyコード）が出力される
- `cf-runtime/`に`worker_module.mjs`がコピーされる
- `wrangler dev`はこの`worker_module.mjs`をエントリポイントとして起動する

**ハマりポイント**: buildは成功しても、実行時に動かないことがある。build時のOpalコンパイルエラーは出ないが、JSの実行時エラー（`undefined`を返すメソッド等）はランタイムでしか検出できない。

### 3-3. wrangler dev のログ確認の難しさ

wrangler devはログを標準出力に出すが、tmux pane内で動かしているとログが流れていく。また、Cloudflare WorkersのruntimeエラーはJSON形式で返ってくるが、スタックトレースはOpalコンパイル後のJSコードを指しており、元のRubyコードとの対応が難しい。

例えば：
```
Error: D1 execute_dui failed: Exception: raw.$[](...).$is_a? is not a function
```

これは「`raw['meta']`がJSオブジェクトのままで、Rubyの`is_a?`メソッドを持っていない」というエラーだが、元のRubyコードのどの行で起きたのかを特定するのに時間がかかる。

---

## 4. 「デモサイトでも検証していたはずなのに、なぜここまで時間がかかったか」を厳密に説明

### 4-1. テストの盲点

#### 盲点1: async routeの戻り値の検証が不十分だった

%170では個別のasyncメソッド（D1クエリ等）の動作は検証していたが、**async route全体の戻り値がSinatraのresponse bodyに届くまでのフロー**は検証していなかった。

具体的には：
- D1 `all()` → Promise → await → Array までは動く
- しかし、そのArrayをSinatraがresponse bodyに設定する際に、async routeの戻り値Promiseが`undefined`に化けていた
- 結果として、DBは動いているのに、response bodyが空になる

#### 盲点2: multi-line backtickの挙動差

Opalのx-string（backtick JS）の挙動差は、**単体テストでは検出しにくい**。メソッドの戻り値が`undefined`になるのは、呼び出し側で`nil`や`false`と同様に扱われるため、目立ったエラーにならない。

例えば：`wrap_async_halt_result(res)`が`undefined`を返しても、呼び出し側の`apply_invoke_result(undefined)`は「resがnilなので何もしない」パスに入り、静かに失敗する。

### 4-2. smoke test と実アプリの差

#### 差1: smoke testではresponse bodyを詳細にアサートしていなかった

smoke testでは「200 OKが返る」ことや「特定の文字列が含まれる」ことは確認していたが、**空レスポンス（200 OKだがボディが空）**を検出するアサートがなかった。

```ruby
# あったかもしれないアサート
assert_equal 200, last_response.status
assert_includes last_response.body, "async-ok"

# なかったアサート（これが重要）
refute_empty last_response.body
```

#### 差2: smoke testでは`tap`などのRubyメソッドチェーンが含まれていなかった

実アプリでは以下のようなコードがあった：
```ruby
db[:todos].order(:id).all.__await__
```

これは`all()`がPromiseを返し、そのPromiseに対して`__await__`を呼ぶ。smoke testでは単純な`Promise.resolve("ok").__await__`だけをテストしていたため、**複数の非同期操作が絡む場合の戻り値伝播**が検証されていなかった。

#### 差3: DB操作後のレスポンスshape

smoke testではD1のクエリ結果をモックしていた可能性がある。実際のD1 bindingはJSのPromiseを返し、その結果をOpalのArray/Hashに変換する。この変換パイプライン（D1 JS → Opal Array → Sinatra body → Rack tuple → Cloudflare Response）全体が動くことを検証する必要があった。

### 4-3. build artifact / local path gem / stale build

#### 問題1: stale build

homuraのbuildは`build/hello.no-exit.mjs`を生成するが、**以前のbuild結果が残っていると、新しいコードが反映されない**ことがある。

特に`cloudflare-workers-build --standalone --with-db`は、一部のファイルをキャッシュしている可能性がある。build成功メッセージ（`homura build: ok`）が出ても、実際には古いbuild結果が使われているケースがあった。

#### 問題2: local path gemの反映遅延

Gemfileを`path:`指定に変更しても、**Bundlerのキャッシュが古いgemを参照し続ける**ことがある。

```ruby
gem 'homura-runtime', path: '/Users/kazuph/src/github.com/kazuph/homurabi/gems/homura-runtime'
```

`bundle install`は成功するが、実際にロードされるのは`vendor/bundle`以下のキャッシュされたバージョン。`bundle exec`でbuildしても、古いコードが使われていることに気づかない。

**解決策**: `vendor/bundle`を削除して`bundle install`し直す、または`bundle exec ruby -e "puts Gem.loaded_specs['homura-runtime'].full_gem_path"`で実際のパスを確認する。

#### 問題3: compiled outputの可読性

Opalコンパイル後の`build/hello.no-exit.mjs`は約80,000行。人間が読むのは現実的ではない。問題が起きた際に「どのRubyコードがどのJSコードにコンパイルされたか」を追跡するのが非常に困難。

特にmulti-line backtickの問題は、compiled outputを見ても`return`の有無だけの差（1単語）であり、目視で検出するのはほぼ不可能。

### 4-4. 検証の非対称性

#### 非対称1: 個別機能は動くが、統合すると動かない

- D1クエリ単体: 動く
- Sinatra route単体: 動く
- async/await単体: 動く
- **D1クエリ + Sinatra route + async/await**: 動かない（空レスポンス）

これは「各部分は正しいが、各部分のインターフェース（戻り値の型、Promiseの有無等）が微妙にずれている」ため。

#### 非対称2: sync routeでは動くが、async routeでは動かない

`# await: true`がない（sync）routeでは問題なく動くコードが、async routeでは動かない。`catch(:halt)`/`throw(:halt)`がsyncでは機能するが、asyncでは`UncaughtThrowError`がPromise rejectionとして伝播する。

---

## 5. Mermaid 図（174番視点の調査フロー）

```mermaid
flowchart LR
    subgraph START["開始"]
        A[continuous.md読み込み<br/>3 Blocker確認]
    end

    subgraph ENV["環境構築"]
        B1[Gemfile path指定切替]
        B2[bundle install]
        B3[npm run build]
    end

    subgraph ERR1["初回エラー"]
        C1[wrangler dev起動]
        C2[$respond_to?エラー]
        C3[git pullで最新修正取得]
        C4[解決]
    end

    subgraph INVEST1["空レスポンス調査"]
        D1[GET /api/todos → 空]
        D2[/api/async-test追加]
        D3[async-testも空]
        D4[compiled output確認]
        D5[wrap_async_halt_result<br/>にデバッグログ追加]
        D6[multi-line backtickが<br/>undefinedを返すことを発見]
        D7[single-line化で修正]
    end

    subgraph VERIFY1["DB検証"]
        E1[GET /api/todos → {"todos":[]}]
        E2[POST / でParserError]
        E3[JSONフォーマットに変更]
        E4[db.executeの<br/>argumentsオプション必須を発見]
        E5[INSERT成功]
    end

    subgraph VERIFY2["Blocker検証"]
        F1[params[id]検証<br/>→ /api/params-test/42 OK]
        F2[redirect検証<br/>→ 302 Found OK]
        F3[toggleで!0問題]
        F4[to_i反転に修正]
    end

    subgraph FIX1["nested object問題"]
        G1[D1 run()結果のmetaが<br/>JSオブジェクトのまま]
        G2[js_object_to_hashを<br/>再帰化]
        G3[toggle/delete正常化]
    end

    subgraph END["完了"]
        H1[全CRUDフロー検証]
        H2[HTMLレンダリング確認]
        H3[continuous.md更新]
        H4[%170へ報告]
    end

    A --> B1 --> B2 --> B3 --> C1
    C1 --> C2 --> C3 --> C4
    C4 --> D1 --> D2 --> D3 --> D4 --> D5 --> D6 --> D7
    D7 --> E1 --> E2 --> E3 --> E4 --> E5
    E5 --> F1 --> F2 --> F3 --> F4
    F4 --> G1 --> G2 --> G3
    G3 --> H1 --> H2 --> H3 --> H4
```

---

## 補足: 今後の予防策（提案）

1. **build後の smoke test で空レスポンスを検出**
   - `refute_empty last_response.body` を必須アサートにする

2. **multi-line backtick使用箇所の linter**
   - sinatra-homura/homura-runtimeのコードベースで、multi-line backtickがメソッドの最終式になっていないか静的に検出

3. **path gem のバージョン確認スクリプト**
   - `bundle exec ruby -e "puts Gem.loaded_specs['sinatra-homura'].version"` をbuild前に自動実行

4. **async route の戻り値型検証テスト**
   - `Promise.resolve("ok")` を返すrouteを必ず1つ含め、response bodyが空でないことを確認

---

*本レポートは174番（Sisyphus）が2026-04-23に作成。*
