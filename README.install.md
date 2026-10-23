# Mac OBS Beauty · 安装 / Installation / インストール

## 中文

1. 使用 Apple Silicon（M 系列）Mac、macOS 13+。下载 mac-obs-beauty-0.8.0-macos-arm64.pkg。
2. 退出 OBS，双击 PKG 按 macOS 提示安装。标准 obs-live-beauty.plugin 会直接装到当前用户的 OBS 插件目录，不需要独立 App、依赖向导或第二次安装。
3. 重开 OBS → 停靠窗口 / 工具 → 直播美颜。选择视频来源，点击「添加到来源」。识别点在「工具 → 识别点诊断…」打开。
4. 如果美颜运行资源缺失，OBS 内会提示，可从「工具 → 美颜运行资源…」另行准备；已准备好则直接使用。运行库来自本机官方 Mac 直播伴侣10.0.0 / 10.0.4，首次效果资源准备需联网。不足时保留原画。
5. ZIP 用户可手动复制 .plugin 到自己的 OBS 插件目录，或双击 install.command。安装工具只安装插件，不强制下载运行组件。
6. 当前 PKG 未签名，二进制为临时签名，未获 Apple 公证。若 macOS 阻止打开，核对 GitHub TIMEKB/mac-obs-beauty 与 SHA256SUMS，然后在「系统设置 → 隐私与安全性 → 仍要打开」批准这个安装包。不要关闭整个系统的安全检查。

## English

1. Requires an Apple Silicon (M-series) Mac and macOS 13+. Download mac-obs-beauty-0.8.0-macos-arm64.pkg.
2. Quit OBS, double-click the PKG and follow macOS prompts. It directly installs the standard obs-live-beauty.plugin for your user account. No standalone app, dependency wizard or second installation is needed.
3. Restart OBS → Docks / Tools → 直播美颜 (Live Beauty), select a source and click 添加到来源 (Add to source). Tools → 识别点诊断… opens landmark diagnostics.
4. Missing beauty runtime resources are handled inside OBS under Tools → 美颜运行资源…; existing prepared resources work directly. The runtime comes from the official Mac Douyin Live Companion app (10.0.0 / 10.0.4). Initial resource preparation needs internet. Until ready, video remains unchanged.
5. ZIP users can manually copy the .plugin into their user OBS plugin directory or double-click install.command. Plugin installation does not require downloading runtime components. UI labels are currently Chinese.
6. The PKG is unsigned, binaries are ad-hoc signed, and this build is not Apple notarized. If macOS blocks it, verify the GitHub repository and SHA256SUMS, then approve this package in System Settings → Privacy & Security → Open Anyway.

## 日本語

1. Apple Silicon（M シリーズ）Mac、macOS 13 以降が必要です。mac-obs-beauty-0.8.0-macos-arm64.pkg をダウンロードします。
2. OBS を終了し、PKG をダブルクリックして macOS の手順に従います。標準の obs-live-beauty.plugin をユーザーの OBS フォルダーに直接導入します。独立 App、依存ウィザード、二回目の導入操作は不要です。
3. OBS を再起動し、「ドック / ツール → 直播美颜」を開き、ソースを選んで 添加到来源 をクリックします。「ツール → 识别点诊断…」で特徴点を確認できます。
4. 美顔の実行素材が不足する場合だけ、OBS 内で案内します。「ツール → 美颜运行资源…」から別途準備できます。公式 Mac 版直播伴侣10.0.0 / 10.0.4のライブラリを利用し、初回の素材取得にはネット接続が必要です。準備できるまでは元映像を維持します。
5. ZIP 版は .plugin をユーザーの OBS フォルダーにコピーするか、install.command をダブルクリックします。プラグイン導入時に実行素材を強制ダウンロードしません。操作表示は現在中国語です。
6. PKG は未署名、バイナリはアドホック署名で、Apple 公証は受けていません。ブロックされたら GitHub と SHA256SUMS を確認し、「システム設定 → プライバシーとセキュリティ → このまま開く」でこのパッケージを許可してください。

插件 / Plugin / プラグイン：
~/Library/Application Support/obs-studio/plugins/obs-live-beauty.plugin

运行资源 / Runtime resources / 実行素材：
~/Library/Application Support/obs-live-beauty/engine-resources

卸载 / Remove / 削除：退出 OBS 后只删除该 .plugin。资源可按需另行删除，不删除整个插件目录或场景设置。/ Quit OBS and remove only this .plugin. / OBS を終了し、この .plugin だけを削除します。

本次仅美颜核心与106点诊断；不含采集卡、Wink、FaceBetter。
Beauty core and 106-point diagnostics only; no capture-card, Wink or FaceBetter module.
美顔コアと106点診断のみです。キャプチャーカード、Wink、FaceBetter は含みません。

如果这个插件对你有帮助，请给我一个星星 ⭐。
If this plugin helps you, please give it a star ⭐.
このプラグインが役に立ったら、スターをお願いします ⭐。
https://github.com/TIMEKB/mac-obs-beauty

开发 / Development / 開発: TIMEKB; OpenAI Codex; ChatGPT / GPT; 逆向一切 / Reverse Engineer Anything (REA); OBS Studio; Qt; Apple frameworks; CMake / Clang.
