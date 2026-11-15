# NeoMillie ユーザーマニュアル

[English](manual.md) | [Español](manual.es.md) | [Français](manual.fr.md) | [Deutsch](manual.de.md) | [Italiano](manual.it.md) | [日本語](manual.ja.md)

Analogue Pocket 用の NeoMillie と NeoMillieCD 0.6.0 のマニュアルです。

NeoMillie は Analogue Pocket 用の FPGA コアで、MiSTer プロジェクトのネオジオの RTL を移植したものです。ネオジオのゲームを遊べます。カートリッジのゲームは NeoMillie で家庭用 (AES) または業務用基板 (MVS) として動かし、ネオジオCDのディスクは NeoMillieCD で動かします。どちらも openFPGA のコアです。BIOS、ゲーム、ディスクは付属していないので、ご自身で用意してください。

設定項目の名前は、Pocket の画面に表示されるとおり、英語のまま記載しています。

## 目次

1. [必要なもの](#必要なもの)
2. [ゲームの起動](#ゲームの起動)
3. [操作](#操作)
4. [カートリッジ版コアのメニュー](#カートリッジ版コアのメニュー)
5. [CD版コアのメニュー](#cd版コアのメニュー)
6. [ディスクイメージ](#ディスクイメージ)
7. [読み込み時間と速度](#読み込み時間と速度)
8. [セーブデータ](#セーブデータ)
9. [故障に見えるゲームの動作](#故障に見えるゲームの動作)
10. [困ったとき](#困ったとき)

## 必要なもの

[Releases](https://github.com/uniplexed/neomillie/releases) から2つの zip をダウンロードし、それぞれを SD カードのルートに展開して、フォルダーを統合してください。そのあと、ご自身のファイルを追加します。

カートリッジのゲームには、`Assets/ng/common/` に次のファイルを置きます。

| ファイル | 内容 |
|---|---|
| `uni-bios_4_0.rom` | UniBIOS 4.0 |
| `000-lo.lo` | LO ROM |
| `sfix.sfix` | BIOS のテキストレイヤー |
| ゲームごとに1つのフォルダー | Darksoft 形式のゲームの ROM。`srom`、`prom`、`crom0`、`m1rom`、`vroma0`、そしてゲームに `prom1` がある場合は `prom1` |

ゲームのフォルダー名は、コアのゲーム一覧の項目が想定している名前に合わせてください。Neo Geo Overdrive コアをすでにお使いの場合は、BIOS とゲームのフォルダーをそのまま使えます。

ディスクには、`Assets/ngcd/common/` に次のファイルを置きます。

| ファイル | 内容 |
|---|---|
| `uni-bioscd.rom` | UniBIOS CD。ちょうど 524,288 バイトです。コアはこの名前で読み込みます |
| `000-lo.lo` | LO ROM |
| ディスクごとに1つのフォルダー | ディスクの `.cue` と、その隣に置いた `.bin`。例: `Metal Slug/Metal Slug.cue` と `Metal Slug.bin` |

ディスクは、1つの CUE と1つの BIN にする必要があります。ほかの形式の変換方法は[ディスクイメージ](#ディスクイメージ)を参照してください。

## ゲームの起動

カートリッジ版コア: Pocket で openFPGA を開き、Neo Geo を選び、一覧からゲームを選びます。コアが BIOS とゲームの ROM を読み込み、ゲームが始まります。

CD版コア: openFPGA を開き、Neo Geo CD、NeoMillieCD の順に選びます。BIOS が読み込まれ、BIOS の画面が表示されます。Pocket のメニューを開いて Core Settings に入り、Disc の項目でディスクの `.cue` を選ぶと、BIOS がディスクを見つけて起動します。ディスクを交換するときは、同じ方法で別の `.cue` を選びます。

どちらのコアも、終了するときは Pocket のメニューを開いて Quit を選びます。セーブデータが SD カードに書き込まれるのもこのタイミングなので、ゲームの途中で電源を切らずに Quit で終了してください。

## 操作

| Pocket | ネオジオ |
|---|---|
| 十字キー | レバー |
| A、B、X、Y | A、B、C、D |
| Start | Start |
| Select | 家庭用ではセレクト、業務用ではコイン |
| L | AとBの同時押し、またはAとBとCの同時押し |
| R | CとDの同時押し、またはAとBとCの同時押し |

L と R の動作は [L/R Buttons](#lr-buttons) で設定します。Dock 経由でつないだ2つ目のコントローラーは 2P になります。

## カートリッジ版コアのメニュー

ゲームの実行中に Pocket のメニューを開き、Core Settings に入ります。コアの項目は次の順に並んでおり、この節の番号もこの順番に対応しています。Pocket では1つの一覧として表示され、グループ名はこの図にしかありません。

![カートリッジ版コアのメニュー。各項目の初期値つき](img/menu-cart.svg)

ほとんどの項目は、変更するとすぐに反映されます。ただし Reset Core、AES/MVS、68K Clock の3つは、変更するとゲームが再起動するので、先にセーブしてください。

Pocket は、すべての項目の設定を次回のために記憶します。ただし MVS DIP、Memory Card Unplugged、Mute、ADPCM-A Channel は、コアを開くたびに初期値に戻ります。

### システム

1. Reset Core。本体を再起動します。再起動の前に、コアがメモリーカードを SD カードに書き込みます。MVS モードではバックアップRAMも書き込むので、リセットでセーブデータが失われることはありません。

2. AES/MVS。オンは業務用基板 (MVS)、オフは家庭用 (AES) です。初期値はオンです。UniBIOS はこの項目の設定に自動で合わせるので、UniBIOS のメニューにある SYSTEM の項目はここでは効きません。MVS モードでは Select でコインが入り、ゲームは設定とハイスコアをバックアップRAMに保存します。変更するとゲームが再起動します。

3. Region (Reset to apply)。Japan、USA、Europe のいずれか、または From the BIOS です。From the BIOS を選ぶと、UniBIOS 自身の設定に任せます。初期値は From the BIOS です。ゲームはリージョンによって言語を選び、一部のゲームは流血表現の表示と非表示も切り替えます。新しいリージョンは本体の起動時に読み込まれるので、変更したあとは Reset Core を使ってください。UniBIOS 使用時のみ有効です。

4. MVS DIP。業務用基板の DIP スイッチです。Settings は基板のテストと設定のメニューを開き、Freeplay はコインなしで遊べるようにし、Freeze はオンの間ゲームを止めます。一覧には、2つずつの組み合わせと3つすべての組み合わせもあります。Settings で何も起きないときは、Settings をオンにしたまま Reset Core を使ってください。

5. Memory Card Unplugged。本体からメモリーカードが見えない状態にします。起動のたびにメモリーカードのことを尋ねてくるゲームで、それが煩わしいときに使います。

6. 68K Clock。本体のメインプロセッサーの速度です。オリジナルと同じ 12 MHz、16 MHz、24 MHz から選びます。プロセッサーが速いと1フレームでこなせる処理が増えるので、実機で処理落ちする場面でも処理落ちが減ります。ゲームの進行は画面の毎秒60フレームに合わせているため、ゲーム自体が速くなることはありません。音と映像のタイミングも変わりません。変更するとゲームが再起動します。

### ビデオ

7. PAL Output。本体の映像を、ヨーロッパの本体と同じく PAL 規格の毎秒50フレームで動かします。オフ (初期値) では60フレームです。オンにすると、ゲームの進みが少し遅くなります。映像の 224 ラインは変わりません。

8. 320/304 H Video Output。オンにすると、本体が描く320列すべてを表示します。オフ (初期値) では中央の304列を表示します。多くのゲームは両端の列に表示の乱れを残しており、オフではそれが隠れます。

9. Video Scaler output。Pocket の画面での映像の形です。19:15、160:144、4:3、16:9 から選びます。初期値は 19:15 です。16:9 は、Dock 経由でテレビにつなぐときのための選択肢です。

10. Screen X Position。映像を左右に動かします。範囲は -32 から 32 ピクセルで、正の数で右に動きます。

11. Screen Y Position。映像を上下に動かします。範囲は -16 から 16 ラインで、正の数で下に動きます。

### オーディオ

12. Stereo Mix。左右のチャンネルを混ぜます。None、25%、50%、100% から選び、100% はモノラルです。ゲームによっては音を片側だけから鳴らすものがあり、ヘッドホンでは耳が疲れます。少し混ぜると聴きやすくなります。

13. Mute。サウンドチップの4つの音源のうち、1つ以上を消音します。4つの音源は、FM 音源の音楽、短いサンプル音声 (A)、長いサンプル音声 (B)、矩形波チャンネル (PSG) です。一覧にはすべての組み合わせがあります。

14. ADPCM-A Channel。短いサンプル音声は6つのチャンネルで鳴ります。この項目では、そのうちの1つを消音するか、1つだけを鳴らします (Solo)。

Mute と ADPCM-A Channel は、ゲームが音をどう組み立てているかを聴くための項目です。遊ぶときは、どちらも None のままにしてください。

### 操作の設定

<a id="lr-buttons"></a>

15. L/R Buttons。ショルダーボタンを押したときに、どのボタンが押されるかを決めます。

| 設定 | L | R |
|---|---|---|
| A+B / C+D (初期値) | AとB | CとD |
| ABC / C+D | A、B、C | CとD |
| A+B / ABC | AとB | A、B、C |

## CD版コアのメニュー

CD版コアには、AES/MVS、Region (Reset to apply)、MVS DIP、Memory Card Unplugged がありません。代わりに、独自の項目が先頭に3つあります。残りはカートリッジ版コアと同じ項目で、動作も同じです。

![CD版コアのメニュー。各項目の初期値つき](img/menu-cd.svg)

Reset Core、CD/CDZ、CD Turbo 4x、68K Clock を変更すると、ゲームが再起動します。再起動後は BIOS がもう一度起動し、ディスクは入ったままです。Pocket は、Mute と ADPCM-A Channel 以外のすべてを記憶します。

1. Reset Core。メモリーカードを SD カードに書き込んでから、本体を再起動します。

2. CD/CDZ。コアがどちらの本体になるかを決めます。オフ (初期値) は初代のネオジオCDで、ディスクを等倍速で読みます。オンは CDZ で、2倍速で読むため、読み込みにかかる時間がおよそ半分になります。UniBIOS はこの項目の設定に自動で合わせます。変更するとゲームが再起動します。

3. Region。US、EU、JP、AS (アジア) から選びます。初期値は US です。本体が報告するリージョンで、ゲームはカートリッジ版コアの Region と同じように扱います。変更したあとは Reset Core を使ってください。

4. CD Turbo 4x (beta)。ディスクのデータを等倍速の4倍で読みます。CD/CDZ がオンでもオフでも使えます。ディスクの音楽は通常の速さのまま再生されます。動作確認は UniBIOS でのみ、それも少数のディスクでしか行っていません。オンにしてゲームの動作がおかしくなったら、まずオフにしてください。変更するとゲームが再起動します。

5. 68K Clock。カートリッジ版コアと同じです。ディスクでは、読み込みの一部をプロセッサー自身が処理するので、読み込みも少し短くなります。

6 から 14 の項目は、PAL Output、320/304 H Video Output、Video Scaler output、Screen X Position、Screen Y Position、Stereo Mix、Mute、ADPCM-A Channel、L/R Buttons です。内容は前述のとおりですが、ディスクでは2点が異なります。Stereo Mix はディスクの音楽も混ぜます。一方、Mute ではディスクの音楽は消音されません。また、ネオジオCDには長いサンプル音声がないので、Mute の B は何も消音しません。

## ディスクイメージ

コアが読めるのは、1つの `.bin` を指定した1つの `.cue` で、トラックの種類は `MODE1/2352` と `AUDIO` です。データトラック1つだけの生の `.bin` も使えます。

それ以外の形式は、各[リリース](https://github.com/uniplexed/neomillie/releases)に添付されている NeoMillieCD Converter で先に変換してください。読める形式は次のとおりです。

- BIN、ISO、WAV ファイルを使う `.cue`。ファイルはトラックごとでも、複数のトラックで共有していてもかまいません。ビッグエンディアンの音声 (`MOTOROLA`) や、MP3、OGG、FLAC、APE、Opus の音声も読めます。
- CloneCD (`.ccd` とその `.img`)、Alcohol 120% (`.mds` とその `.mdf`、バージョン 1)、Nero (`.nrg`)、DiscJuggler (`.cdi`、バージョン 2、3、3.5)
- CHD (`.chd`)

変換ツールは元のファイルを変更せずに読み取り、ディスクごとに、1つの CUE と1つの BIN を入れたフォルダーを書き出します。各ディスクはいったん一時的な名前で書き込み、完成してから正式な名前に変えます。そのため、失敗したディスクや中止したディスクのファイルは残りません。書き出し先にすでにあるディスクは、上書きを指定しない限りスキップします。`MODE2` のトラックと、複数のセッションを持つディスクは受け付けませんが、ネオジオCDのゲームはどちらも使っていません。

### ウィンドウ

お使いのシステム用の zip をダウンロードして、展開してください。

| システム | ファイル |
|---|---|
| Windows x64 | `NeoMillieCD-Converter-windows-x64.zip` |
| macOS (Apple Silicon) | `NeoMillieCD-Converter-macos-arm64.zip` |
| Linux x64 | `NeoMillieCD-Converter-linux-x64.zip` |

どのプログラムも単体で動きます。PyInstaller で作られており、Python のインタープリター、ウィンドウを描く Tcl/Tk、そして Python が使う OpenSSL、zlib、bzip2、xz などのライブラリを中に含んでいます。Linux 版には、ウィンドウに必要な X11、fontconfig、FreeType のライブラリも入っています。何もインストールせずに使えるため、zip の大きさは 10 から 25 MB になります (スクリプトだけなら 56 KB です)。ffmpeg と chdman は含まれていません。[ffmpeg と chdman](#ffmpeg-と-chdman) を参照してください。中に含まれるものすべてのライセンスは、各 zip の `THIRD-PARTY-LICENSES.txt` にあります。

プログラムには署名がありません。初回は Windows SmartScreen が確認を求めるので、*More info* を選び、次に *Run anyway* を選んでください。macOS では、アプリを一度開き、確認できないというメッセージを閉じてから、システム設定のプライバシーとセキュリティで *Open Anyway* を選んでください。Intel 搭載の Mac 用のビルドはないので、下のスクリプトを Python で使ってください。

#### 手順

1. プログラムを開きます。最初、ウィンドウは空です。

   ![空のコンバーターのウィンドウ](img/converter-step1-empty.png)

2. ディスクを追加します。*Add discs…* ではイメージファイル (`.cue`、`.chd`、`.ccd`、`.mds`、`.nrg`、`.cdi`) を選びます。*Add folder…* ではフォルダーを選ぶと、その中とサブフォルダーにあるディスクがすべて見つかります。ディスクごとに、名前、形式、状態を示す行ができます。名前は、SD カード上でディスクのフォルダーとファイルに付く名前で、ダブルクリックすると変更できます。*Remove* を押すと、選んだ行が一覧から外れます。
3. *Browse…* でディスクの書き出し先を選びます。*SD card layout* をオンにした場合は SD カードのルートを選びます。各ディスクは、コアが探す場所である `Assets/ngcd/common/` に入ります。オフの場合は、選んだフォルダーにディスクが入ります。書き出し先にすでにあるディスクは、*Overwrite* がオンでない限りスキップします。

   ![4枚のディスクを追加し、書き出し先を SD カードにした状態。CHD の1枚は chdman が必要](img/converter-step2-added.png)

4. 状態の列を確認します。*needs chdman* や *needs ffmpeg* と表示されたディスクは、そのプログラムを待っています。プログラムをインストールするか ([ffmpeg と chdman](#ffmpeg-と-chdman) を参照)、*Tools* 欄でそのプログラム名の横にある *Locate…* を押して、プログラムを選んでください。ディスクは *pending* になります。

   ![chdman の場所を指定した後。すべてのディスクが変換待ち](img/converter-step3-tools.png)

5. *Convert* を押します。*Disc* のバーは変換中のディスクの進み具合を、*Total* のバーは一覧全体の進み具合を示します。*Cancel* を押すと止まります。変換中だったディスクはまるごと取り除かれて書きかけのものは残らず、変換済みのディスクはそのまま残ります。

   ![2枚の変換が終わり、3枚目を変換中](img/converter-step4-converting.png)

6. すべての行が *done* になれば、ディスクの準備は完了です。ディスクごとに1つのフォルダーがあり、それぞれに `.cue` と `.bin` が1つずつ入っています。SD カードを Pocket に入れ、CD版コアの Core Settings を開き、Disc の項目でディスクの `.cue` を選びます。失敗したディスクは、その行に理由が表示されます。ほかのディスクの変換はそのまま続きます。

   ![すべてのディスクの変換が完了](img/converter-step5-done.png)

ウィンドウは、書き出し先、*SD card layout* のオンとオフ、ffmpeg と `chdman` の場所を記憶します。

### スクリプト

`NeoMillieCD-Converter-python.zip` には、同じ変換ツールが Python スクリプトとして入っています。Python 3.8 以降があれば、どのシステムでも使えます。

    python cd_convert.py SOURCE... DEST [--name NAME] [--overwrite]
    python cd_convert_gui.py

SOURCE は、ディスクイメージかフォルダーです。コアの配置に合わせるには、DEST を `<SD card>/Assets/ngcd/common` にします。各ディスクの名前は、イメージの名前の最初の括弧より前の部分です。たとえば `Metal Slug (1996)(SNK)(Jp-US)[!]` は `Metal Slug` になります。`--name` を使うと、1つのディスクの名前を指定できます。Linux では、ウィンドウを使うためにディストリビューションの `python3-tk` が必要な場合があります。

### ffmpeg と chdman

どちらも変換ツールには付属していません。変換ツールは、それぞれをまず変換ツールと同じ場所で、次に PATH の通った場所で探します。ウィンドウでは *Locate…* で場所を指定できます。

| 用途 | Windows | macOS | Debian と Ubuntu |
|---|---|---|---|
| 圧縮音声: ffmpeg | `winget install Gyan.FFmpeg` | `brew install ffmpeg` | `sudo apt install ffmpeg` |
| CHD: chdman | [MAME](https://www.mamedev.org/) の `chdman.exe` | `brew install rom-tools` | `sudo apt install mame-tools` |

## 読み込み時間と速度

ディスクの読み込み時間は、3つの設定で変わります。次の表は、The King of Fighters '99 の7回の読み込みの合計で、1台の Pocket でコア自身が計測した値です。

| CD/CDZ | CD Turbo 4x | 68K Clock | 7回の読み込み |
|---|---|---|---|
| Off | Off | 12 MHz | 66.3 秒 |
| On | Off | 12 MHz | 38.4 秒 |
| Off | On | 12 MHz | 27.8 秒 |
| On | On | 12 MHz | 27.8 秒 |
| On | On | 16 MHz | 24.5 秒 |
| On | On | 24 MHz | 23.6 秒 |

普段使いの設定として動作を確認しているのは、CD/CDZ をオンにした状態です。CD Turbo 4x は最も効果が大きいものの、まだベータ版の機能です。68K Clock は読み込みにはわずかしか効かず、主な用途は負荷の高い場面での処理落ちの軽減です。

## セーブデータ

| コア | セーブ | SD カード上のファイル |
|---|---|---|
| カートリッジ | メモリーカード。ゲームごとに1つ | `Saves/ng/uniplexed.NeoMillie/`。ゲームの名前に `.sav` をつけたファイル |
| カートリッジ (MVS モード) | バックアップRAM。基板の設定、ハイスコア、集計 | `Saves/ng/common/backup.bak` |
| CD | メモリーカード。すべてのディスクで1つ | `Saves/ngcd/common/uni-bioscd.sav` |

Pocket がこれらのファイルを書き込むのは、Quit を選んだとき、スリープに入るとき、Pocket のメニューから電源を切るときです。コアは Reset Core のときにも書き込みます。それまでは、ゲーム内でセーブしても、データは本体のメモリーにあるだけです。

Neo Geo Overdrive コアのセーブデータは、このコアでは読み込めません。変換ツールもありません。

## 故障に見えるゲームの動作

CD版の Fatal Fury 3 では、対戦の最初の "Fight" の直後に1秒近く画面が暗転し、ラウンドが終わるときにも少し短く暗転します。これはゲーム自身の動作です。実況の音声をキャラクターの音声に入れ替えるためにプロセッサーが4分の1メガバイトをコピーしており、その間ゲームが映像を消しています。実機でも同じ時間がかかります。68K Clock を 24 MHz にすると、このコピーも暗転も短くなります。

UniBIOS の SYSTEM の項目は、本体の種類を表示し、変更もできます。ただしこれらのコアでは効果がなく、カートリッジでは AES/MVS が、ディスクでは CD/CDZ が本体の種類を決めます。

AES/MVS、CD/CDZ、CD Turbo 4x、68K Clock を変更するとゲームが再起動しますが、これは設定を反映するための動作です。

## 困ったとき

| 見られる症状 | 確認すること |
|---|---|
| CD の BIOS が、ディスクがないと表示する | `.cue` が、同じフォルダーにある、綴りも同じ `.bin` をちょうど1つだけ指定している。トラックが `MODE1/2352` または `AUDIO` である。`WAVE` ファイル、複数の `FILE` 行、`MODE1/2048` を含む CUE には、[変換ツール](#ディスクイメージ)が必要です |
| CD Turbo 4x をオンにすると、ディスクの読み込みが止まる、または動作がおかしくなる | CD Turbo 4x をオフにして、もう一度試す |
| カートリッジのゲームが一覧にない、または起動しない | `Assets/ng/common/` にあるそのフォルダーが、一覧の求める名前で、[必要なもの](#必要なもの)にあるすべてのファイルを含んでいる |
| セーブデータが消えた | Quit を使わずにコアを終了した。[セーブデータ](#セーブデータ)を参照 |
| カートリッジで Region が効かない | UniBIOS が必要で、変更後に Reset Core も必要 |
| 画面の左または右が欠ける | 320/304 H Video Output をオンにするか、Screen X Position で動かす |

そのほかの場合は、[github.com/uniplexed/neomillie](https://github.com/uniplexed/neomillie/issues) で issue を作成し、コア、バージョン、BIOS、ゲーム、設定を書いてください。

コアの作りについては、[architecture.md](architecture.md) (英語) を参照してください。
