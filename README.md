# Desklog

Desklogは、macOS上の作業をローカルで収集・分析するメニューバーアプリです。

- すべてのディスプレイを定期キャプチャし、指定したウィンドウだけを除外
- Apple Visionによる日本語・英語OCR
- Whisper.cpp `large-v3-turbo-q5_0`によるローカル文字起こし
- SpeakerKit / Pyannoteによるローカル話者分離・話者同定
- 日別JSONLと任意のJPEGをローカル保存
- localhostのOllamaで直近のワークログをMarkdown要約（既定モデル`gpt-oss:latest`）
- 毎日指定時刻の定期要約と、必要なスクリーンショットのMarkdown挿入

通常実行時にクラウドAPIやモデル配布サーバーへ接続しません。SpeakerKitはアプリ本体へリンクせず、全ネットワークをOS sandboxで拒否した常駐helperだけで実行します。音声はprivateな一時ファイルへ変換して処理直後に削除し、話者特徴量は非公開の話者ストアにだけ保存します。Ollama URLも`localhost`、`127.0.0.1`、`::1`のHTTPルートだけを受け付けます。

## 必要環境

- macOS 14以降
- Swift 6.2以降のtoolchain（XcodeまたはCommand Line Tools。検証環境はSwift 6.3.2）
- [Ollama](https://ollama.com/) と任意のローカルモデル
- Homebrew（Whisper.cppの導入に使用）

## 初期セットアップ

Whisper.cpp、Whisperモデル、SpeakerKitモデルを明示的に準備します。

```bash
make models-setup
```

`make whisper-setup`はWhisper.cppと約547MiBのモデルを、`make speaker-setup`はSpeakerKitモデルを取得します。これらはインストール専用コマンドであり、Desklog本体はモデルのダウンロードを無効にしてローカルファイルだけを読み込みます。

Ollamaのモデルも事前に用意します。

```bash
ollama pull gpt-oss:latest
ollama serve
```

## ビルドと起動

```bash
make test
make run
```

`build/Desklog.app`が生成されます。初回はメインウィンドウが自動で開き、必要な準備を案内します。
`make run`はマイク権限を開発ビルド間で維持しやすいDebug署名を選び、`make app`は配布向けReleaseビルドを作ります。

## 準備と権限の流れ

Desklogは、使う収集元に必要な権限を1つの操作でまとめて案内します。macOSが画面収録の反映に再起動を求める場合に備え、マイクを先に、画面収録を最後に確認するため、権限設定の途中で再起動する必要はありません。「記録を開始」を押しても、説明なしにシステムダイアログを表示しません。拒否後もシステム設定を勝手に開かず、回復操作はユーザーが明示的に選びます。

画面OCRをオンにすると、すべてのディスプレイを取得するためmacOSの画面収録権限が必要です。Desklogはシステム音声を取得しません。

「取得しないウィンドウ」では、現在開いているウィンドウを複数選べます。指定したウィンドウはScreenCaptureKitの除外フィルターで画素から取り除かれ、同じアプリの別ウィンドウは引き続き取得されます。Desklog自身のウィンドウも常に除外します。

除外ウィンドウは記録中でも追加・削除でき、進行中のOCRを安全にキャンセルして次回取得から反映します。閉じたウィンドウの指定も設定一覧からいつでも削除できます。ウィンドウを閉じて新しく作り直した場合は別のウィンドウ個体になるため、必要ならもう一度選んでください。

音声認識はWhisperを使うため、Appleの音声認識権限は不要です。

## 使い方

1. メニューバーの録画アイコンから「Desklogを開く…」を選択
2. 「設定」で画面OCR・マイク文字起こしのうち必要な収集元だけをオンにする
3. 「必要な権限をまとめて許可」からマイクと画面収録を続けて許可し、macOSに求められた場合は最後に一度だけ再起動する
4. 必要なら取得しないウィンドウ、取得間隔、保存の有無、Ollama URL・モデル、要約プロンプト、毎日の要約時刻を変更する
5. 「ワークログ」で記録を開始し、ライブ文字起こし・画面OCR・要約を確認する
6. 「話者」で検出された話者に名前を付け、自分の発話には「自分」を付ける

「話者」で登録・改名・自分タグの変更を保存すると、音声を認識し直さず、ライブ画面に残っている発話も直ちに新しい表示へ変わります。統合済みの過去クラスタIDも現在の名前へ解決されます。

「設定」→「要約」では、出力形式・言語・着目点などの要約プロンプトを編集できます。ログ本文と固定の安全指示はDesklogが自動で追加するため、プレースホルダーは不要です。変更は手動・定期のどちらも次回の要約から反映され、「既定に戻す」で初期状態へ戻せます。

モデル確認中は「準備を中止」から安全に取り消せます。画面収録またはマイク権限が記録中に取り消された場合は、誤解を招く継続表示をせず記録を停止します。エラーはどの画面にいても上部に表示されます。

終了時は最後の文字起こしに最大15秒、その後の保存処理に共有5秒の猶予を与えます。ScreenCaptureKitなどのOS処理が応答しない場合にも、アプリ全体の25秒上限でCmd-Qやログアウトが無期限に止まらないようにしています。

## 保存先とプライバシー

保存先は`~/Library/Application Support/Desklog/`です。

```text
Desklog/
├── 2026-07-13.jsonl       # OCR、文字起こし、要約、システムイベント
├── captures/2026-07-13/   # JPEG（設定で無効化可能）
├── summaries/             # OllamaのMarkdown要約
├── speakers/              # 話者プロファイル・発話観測（権限0700）
└── speaker-models/        # SpeakerKitのローカルモデル
```

マイク音声は12秒ごとに確定し、各境界の前後2秒を重ねた推論窓として、権限0700の一時ディレクトリに16kHz WAVを書き出します。重複部分は文字起こし後に除去し、SpeakerKitには境界前後の文脈を渡すことで、窓の途中にある話者交代点でも発話を分割します。話者分離用の音声・IPC応答・stderrも専用の権限0700セッション内でファイル権限0600にします。これらは処理直後に削除され、成功だけでなくエラー・キャンセル・タイムアウト時にも残しません。起動時にはライフタイムロックを持たない中断セッションを経過時間に関係なく消すため、直前のクラッシュで残った生音声も次回起動時に削除されます。ワークログには文字起こしと話者プロファイルIDだけを保存し、生音声や声の特徴量は含めません。

文字起こしはSpeakerKitで話者ごとに分割され、未登録の話者には`Speaker-001`のようなIDが付きます。同じ人物名を別の検出クラスタへ指定すると1人のプロフィールに統合され、各クラスタの声の特徴量を同定用アンカーとして利用します。特徴量は`speakers/`にだけ保存し、JSONLやOllamaには渡しません。要約には確定した話者名・自分タグ・文字起こしだけを渡します。

画面と周囲の会話には機密情報が含まれ得ます。保存先は同期フォルダではありませんが、端末のバックアップ設定は別途確認してください。不要ならスクリーンショット保存または収集元そのものをオフにできます。

## ローカル完結性の検証

```bash
make verify-local-only
```

このコマンドは次を検証します。

- 外部ホスト・HTTPS・資格情報付き・パス付きOllama URLを通信前に拒否する
- 編集した要約プロンプトが長文の分割・統合段階すべてに渡り、通信先がループバックから変わらないことを確認する
- システムプロキシを使わず、ローカルOllamaから外部ホストへのHTTPリダイレクトも追跡しない
- 許可したOllamaリクエストがループバックホストから出ないことをURL transport spyで確認する
- 通常実行ソースにOllama以外のネットワークtransportやリモートURLが増えていないことを検査する
- アプリ本体にSpeakerKitをリンクせず、常駐する専用helperだけが`download: false`でローカルモデルを一度ロードすることを検査する
- 話者分離helperを独自のmacOS sandbox内で実行し、親の制限に頼らずネットワーク接続が`EPERM/EACCES`で拒否されることを確認する
- helperへ渡す音声・応答・stderrが権限0700のセッション内かつファイル権限0600で、成功・キャンセル・タイムアウト後に残らないことを検査する
- 本番と同じWhisper subprocess経路で、WAVが権限0600で作られ、子プロセスのネットワークがmacOS sandboxに拒否され、成功時・失敗時ともWAV/JSONが残らないことを検査する
- 音声パス・WAVパス・話者特徴量をワークログへ保存するメタデータがないことを検査する
- ログ・要約・話者データ・一時音声のディレクトリとファイル権限を検証する
- 実SpeakerKitモデルをネットワーク拒否helperで推論した後、別途macOS sandboxで全ネットワークを拒否した状態で実Whisper.cpp文字起こしが完走することを確認する

依存パッケージ内の標準音声の代わりに任意の16kHzモノラル音声を使う場合は、モデル準備後に次を実行できます。

```bash
DESKLOG_WHISPER_TEST_AUDIO=/absolute/path/to/test.wav \
DESKLOG_SPEAKER_TEST_AUDIO=/absolute/path/to/test.wav \
make verify-local-only
```

この検証はDesklog本体の通常実行境界を対象にします。`make models-setup`と`ollama pull`は、ユーザーが明示的に実行する初期ダウンロードなので対象外です。

## コード署名

すべてのアプリビルドでHardened Runtimeと音声入力entitlementを付けます。`CODESIGN_IDENTITY`を指定した場合はその署名IDを使用します。未指定のDebugビルドでは利用可能なApple Development署名を自動選択し、見つからない場合や未指定のReleaseビルドでは警告してアドホック署名へフォールバックします。

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh debug
```

安定した署名を使うと、開発ビルドごとにmacOSのマイク権限を再登録する事態を避けやすくなります。配布時はDeveloper ID Application署名を明示し、別途notarizationしてください。

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
```

## 開発

```bash
swift build -Xswiftc -warnings-as-errors
swift test
swift run DesklogSelfTest
./scripts/build-app.sh debug
```
