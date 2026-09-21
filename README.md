# CacaoTrans / CacaoClaudeTrans

日本語の音声ファイル（mp3 / wav / m4a など）を、この Mac の中で文字起こしし、
話者を分離し、Claude で誤変換や句読点を整えて、Word / テキスト / 字幕に書き出す Mac アプリ群。

| アプリ | 役割 | 必要なもの |
|---|---|---|
| **CacaoClaudeTrans** | 音声 → 文字起こし → 話者分離 → Claude 校正 → 編集 → 書き出し | Claude API キー、macOS 26 以降 |
| **CacaoTrans** | 保存したプロジェクト（`.ccot`）を開いて編集・再生・書き出し。Claude API も音声認識も使わない | macOS 26 以降 |
| `cacaoclaudetrans` | CacaoClaudeTrans のコマンドライン版（検証・バッチ用） | 同上 |

2つのアプリは同じソースからビルドしている（`CLAUDE_TRANS` フラグの有無で機能を切り替え）。
`.ccot` のダブルクリックは編集用の CacaoTrans で開く。

## しくみ

| 工程 | 担当 | 場所 |
|---|---|---|
| 音声 → 文字 | Apple SpeechAnalyzer（macOS 26 以降の純正オンデバイス認識） | Mac 内 |
| 話者分離（話者1・2・3…） | FluidAudio（CoreML 版 pyannote） | Mac 内 |
| 誤変換・句読点・話者の補正 | Claude API（既定 `claude-opus-5`） | Anthropic |
| 検索・置換 / 書き出し | 自前実装（依存なし） | Mac 内 |

Claude API は音声を受け取れないため、音声そのものは Mac の外に出ない。Claude に送るのはテキストだけ。

## 構成

```
CacaoTrans/
├── project.yml                    # XcodeGen の定義（ここから .xcodeproj を生成）
├── CacaoTrans.xcodeproj           # 生成物（xcodegen generate で再生成できる）
├── make-dmg.sh                    # 配布用 dmg を作る（背景は dmg/make-background.swift で生成）
├── manual/                        # 作業員マニュアル（Marp）。build.sh で PDF 化して dist/ にも置く
├── icon/make-icon.swift           # アプリアイコンを描くスクリプト（trans / claude の2種）
├── dist/                          # ビルド済み: *.app / cacaoclaudetrans / *.dmg
├── CacaoTrans/                    # Mac アプリ（SwiftUI、両アプリ共通ソース）
│   ├── CacaoTransApp.swift        # エントリ・メニュー
│   ├── AppModel.swift             # 状態・ファイル操作・置換・書き出し
│   ├── PlaybackController.swift   # 発話単位の音声再生
│   └── Views/                     # 画面
├── CacaoTransCLI/                 # cacaoclaudetrans（検証用コマンドライン）
└── Packages/
    ├── CacaoTransCore/            # OS 非依存の共通コア（Win/Linux でもそのままビルド可）
    │   ├── Transcript.swift       # データ構造・プロジェクトファイル
    │   ├── SpeakerAssigner.swift  # 認識結果 × 話者分離 → 発話
    │   ├── ClaudeClient.swift     # Claude Messages API（素の HTTP）
    │   ├── TranscriptRefiner.swift# チャンク分割・校正プロンプト・構造化出力
    │   ├── FindReplace.swift      # 一括検索・置換（正規表現対応）
    │   └── Exporters.swift        # txt / md / srt / csv / docx（ZIP 自前）
    └── CacaoTransEngine/          # macOS 専用エンジン
        ├── AudioLoader.swift          # AVFoundation で読み込み・16kHz 変換
        ├── SpeechTranscriptionService.swift  # SpeechAnalyzer
        ├── DiarizationService.swift   # FluidAudio
        ├── KeychainStore.swift        # API キーの保存
        └── TranscriptionPipeline.swift # 一気通貫の実行と進捗
```

## ビルド

必要: macOS 26 以降、Xcode 27、XcodeGen（`brew install xcodegen`）。

```bash
cd ~/CacaoApps/CacaoTrans
xcodegen generate                         # project.yml を変えたときだけ
for s in CacaoClaudeTrans CacaoTrans cacaoclaudetrans; do
  xcodebuild -project CacaoTrans.xcodeproj -scheme $s -configuration Release \
    -derivedDataPath build/DerivedData build
done
cp -R build/DerivedData/Build/Products/Release/CacaoClaudeTrans.app dist/
cp -R build/DerivedData/Build/Products/Release/CacaoTrans.app dist/
cp build/DerivedData/Build/Products/Release/cacaoclaudetrans dist/
```

Xcode で開くなら `CacaoTrans.xcodeproj` をダブルクリックし、スキーム `CacaoClaudeTrans` または `CacaoTrans` を実行。

配布用 dmg（Applications へドラッグするだけのインストーラ）:

```bash
./make-dmg.sh              # dist/CacaoTrans-<ver>.dmg と dist/CacaoClaudeTrans-<ver>.dmg
./make-dmg.sh CacaoTrans   # 片方だけ
```

dmg を開くと矢印付きの背景に「アプリ → Applications」が並ぶ。アドホック署名なので、別の Mac では
初回に右クリック →「開く」が必要（背景に記載）。

マニュアルは `manual/CacaoTrans-マニュアル.md`（Marp、白背景）。`manual/build.sh` で
PDF を作り `dist/` にもコピーする（要 `brew install marp-cli` と Google Chrome）。画面写真は `manual/img/`。

アプリアイコンを変えるときは `icon/make-icon.swift` を編集し、
`swift icon/make-icon.swift trans icon/CacaoTrans-1024.png` と `... claude icon/CacaoClaudeTrans-1024.png` で描き直してから
`CacaoTrans/Resources/Assets.xcassets/AppIcon*.appiconset/` の各サイズを `sips -z` で作り直す。

共通コアのテスト:

```bash
cd Packages/CacaoTransCore && swift test
```

## 使い方（CacaoClaudeTrans）

1. 設定（⌘,）→ Claude タブに Anthropic Console の API キーを入れて「保存」（macOS キーチェーンに保存される）。
2. ⌘O で音声ファイルを開くと「この音声について」シートが出る。背景（目的・話し手の立場・時代や場所）と用語集
   （人名・地名・専門用語、1行1つ）を書いて「文字起こしを開始」。初期値は設定画面の内容で、入力した内容はプロジェクト
   （`.ccot`）に保存され、「Claude で校正だけやり直す」でも使われる。あとから直すときはサイドバーの「この音声について」→「編集…」。
   初回は認識モデル・話者分離モデルのダウンロードで数分かかる。
3. 結果は発話ごとに編集できる。Tab / ⇧Tab で次／前の発話の本文へ移れる。本文に入っている発話は F8 で頭から再生される。話者は各行のメニューで付け替え、左のサイドバーで表示名（例: 話者1 → 田中）を付ける。
4. 発話の分割と統合。本文をクリックして分けたい位置にカーソルを置き ⌘↩ で分割、⌥⌘↩ で句点（。？！）ごとに分割、
   ⌥⌘↑ / ⌥⌘↓ で前後の発話と統合。認識されなかった発言（被った相づちなど）は ⇧⌘↩ で「この発話の後に空の発話を挿入」して
   本文を入力する。複数の発話をまとめてつなげるには、行の左端の丸をクリックして選び ⌘J（上部のバーから
   話者の一括変更・削除もできる）。右クリックメニューからも実行でき、⌘Z で元に戻せる（本文入力中は文字の取り消し、⇧⌘Z でやり直し）。空欄のままの発話は
   書き出し時に無視される。
5. ⌘F で検索・置換パネル。「機械 → 機会」のような誤変換を全発話にまとめて置換。正規表現も使える。⌘Z で元に戻す。
6. 各行の ▶ でその発話の音声を再生できる。画面下の再生バーで再生／一時停止（F8。キーボードのメディアキーでも可）、前後の発話（⌘↑ / ⌘↓）、速度、連続再生、
   「この話者だけ再生」の絞り込みができる。プロジェクトには音声ファイルへの参照が保存され、後日開いても再生できる
   （見つからない場合は「再生」メニューの「音声ファイルを指定…」で再リンク）。
7. ⌘E で書き出し（Word / テキスト / Markdown / 字幕 SRT / CSV）。⌘S でプロジェクト（`.ccot`）として保存すれば後で開いて編集を続けられる。Finder でダブルクリックしても開ける
   （以前の `.cacaotrans` も開ける）。

## 使い方（CacaoTrans = 編集専用）

⌘O（または `.ccot` のダブルクリック）でプロジェクトを開く。以降の編集・再生・分割・統合・置換・書き出しは
CacaoClaudeTrans と同じ操作。Claude API キーは不要で、ネットワークにもつながない。

音声ファイルの探し方（順に試す）:
1. プロジェクト保存時の音声ファイル（同じ Mac ならそのまま見つかる）。
2. **音声フォルダ**（既定 `書類/CacaoTrans`）の中の同名ファイル（1階層下のサブフォルダも見る）。
   サンドボックスの制約で、最初に一度だけ「音声フォルダを設定…」でフォルダを選んでもらう（以降は記憶する）。
3. それでも見つからなければ再生バーの「音声ファイルを指定…」で手動選択。

運用の推奨: 作業員の Mac では `/Applications/CacaoTrans.app`、音声は `書類/CacaoTrans/` に置く。
管理者は `.ccot` と音声ファイルをセットで渡す。

## 使い方（CLI）

```bash
./dist/cacaoclaudetrans 会議.m4a --format docx --out 会議.docx
./dist/cacaoclaudetrans 会議.m4a --no-claude      # 認識と話者分離だけ
ANTHROPIC_API_KEY=sk-ant-... ./dist/cacaoclaudetrans 会議.mp3 --glossary 用語.txt --context "元兵士への聞き取り。聞き手は山田"
```

API キーは環境変数 `ANTHROPIC_API_KEY`、なければアプリで保存したキーチェーンを読む。

## 費用の目安

Apple の音声認識と話者分離は無料。Claude 校正は 60 分の会議で 1〜2 ドル程度（`claude-opus-5`、effort=medium）。
設定で `claude-sonnet-5` にすると半分以下、`claude-haiku-4-5` なら 5 分の 1 程度（思考機能なし、精度はやや落ちる）。
`claude-fable-5-1` は最上位だが Opus の 2 倍の費用。

## Windows / Linux について

`Packages/CacaoTransCore` は Foundation だけに依存しており、Swift for Windows / Linux でもそのままビルドできる
（データ構造・Claude クライアント・置換・書き出し）。他 OS へ出す場合は、画面（SwiftUI は Apple 専用）と
音声認識（SpeechAnalyzer は Apple 専用 → whisper.cpp などに差し替え）を別途用意する。

## 既知の制約

- macOS 26 以降専用（SpeechAnalyzer が必要）。
- 話者分離は声質で判定するため、似た声・電話音声・同時発話では取り違えが起きる。Claude の補正とアプリ上の付け替えで直す。
- Claude の校正は「意味を変えない」前提のプロンプトだが、AI の出力なので最終確認は人が行う。校正前の原文は各行の ✨ アイコンと右クリック「校正前の文に戻す」で確認できる。

## 免責事項

- 本ソフトウェアは MIT ライセンスのもと「現状のまま」提供され、動作や結果について
  いかなる保証もしません。利用によって生じた損害について、作者（ICTCacao）は責任を負いません。
- 音声認識と AI（Claude）による校正は誤りを含むことがあります。文字起こしの内容は
  必ず人が確認してください。
- CacaoClaudeTrans は Anthropic の Claude API を利用します。API の利用料は利用者の負担です。
  校正のために文字起こしテキストが Anthropic に送信されます（音声そのものは送信されません）。
  取り扱いに注意が必要な内容は、送信前に各自で判断してください。
- 本ソフトウェアはベータ版です。予告なく仕様が変わることがあります。

## ライセンス

- このリポジトリのコードは **MIT License**（[LICENSE](LICENSE)）。
- CacaoClaudeTrans が組み込んでいる FluidAudio は **Apache License 2.0**。ライセンス全文は
  [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) にあり、アプリ本体（Contents/Resources）にも同梱している。
