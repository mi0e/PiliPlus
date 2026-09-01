# PiliPlus `tv.danmaku.bili` 自动构建 Fork

这是 PiliPlus 的非官方自定义构建层。应用本体继续来自
[`bggRGjQaUbCoE/PiliPlus`](https://github.com/bggRGjQaUbCoE/PiliPlus)，Fork 只维护包名兼容、更新源、签名、验证和发布自动化。

本仓库保留 PiliPlus 的 GPL 许可证和原作者 attribution。本构建不是哔哩哔哩官方客户端，也不代表 PiliPlus 上游项目。

## 与上游构建的差异

- Android `applicationId` 固定为 `tv.danmaku.bili`，用于兼容通过
  `intent.setPackage("tv.danmaku.bili")` 打开的 Bilibili Deep Link。
- Java/Kotlin namespace 和类路径仍是 `com.example.piliplus`，没有进行全局包名替换。
- DocumentsProvider authority 随 applicationId 变为
  `tv.danmaku.bili.MTDataFilesProvider`；静态快捷方式使用标准 `VIEW` action。
- 应用内 updater 只查询当前 Fork 的 GitHub Releases。仓库 owner/name 由 CI 注入，未注入时 updater 关闭，不会回退到上游 Release。
- 首版不伪造官方 Bilibili Activity 类名。若某个调用使用
  `setClassName(package, activity)` 而不只是 `setPackage`，必须先取得准确的 Activity 名，再在独立 patch 中增加 `activity-alias`。

## 自动同步与发布

`Fork - Sync upstream` 每天 04:17（Asia/Shanghai）运行，也可以手动执行：

1. 查询上游默认分支并 fetch 完整历史和 tags。
2. 用 merge 将上游提交合入 Fork `main`，不 rebase、不 force-push。
3. 检查 `patches/bilibili-package.patch` 是否仍能严格应用。
4. 上游 main 有变化时构建 smoke APK；有新的正式上游 Release 时，从该 Release tag 的精确提交构建正式 APK。
5. 正式 APK 验证通过后，发布到本仓库 Releases，供应用内 updater 使用。

merge 冲突或 patch 漂移会在 Actions Summary 和 `upstream-sync-conflict` artifact 中列出具体文件；workflow 不会覆盖冲突、push 半成品或创建 Release。构建失败但同步已经 push 时，下一次定时执行仍会发现该上游 Release 尚未发布并重试。

发布命名约定：

- tag：`v<上游Release>-bili.<修订号>`
- versionName：`<上游Release>-bili.<修订号>`
- APK：`PiliPlus-tv.danmaku.bili_<versionName>+<versionCode>_<abi>.apk`
- ABI：`arm64-v8a`、`armeabi-v7a`、`x86_64`

versionCode 取“上游提交计数”和“上一个 Fork Release versionCode + 1”的较大值，因此上游版本号调整或同一上游 Release 的 Fork 修订不会造成 Android 降级。

## 首次配置固定签名

第一版安装后，所有后续版本必须使用完全相同的 keystore。丢失 keystore 或密码意味着已经安装的应用无法再覆盖升级。不要把 keystore、密码、`key.properties` 或解码后的临时文件提交到 Git。

如果还没有发布密钥，只在可信的离线环境中生成一次，例如：

```shell
keytool -genkeypair -v -keystore piliplus-fork.jks -alias piliplus \
  -keyalg RSA -keysize 4096 -validity 10000
```

在仓库 `Settings → Secrets and variables → Actions` 中配置：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `ANDROID_KEYSTORE_BASE64` | keystore 文件的单行 Base64 |
| Secret | `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| Secret | `ANDROID_KEY_ALIAS` | key alias |
| Secret | `ANDROID_KEY_PASSWORD` | key 密码 |
| Variable | `ANDROID_SIGNING_CERT_SHA256` | 证书 SHA-256，去掉冒号并使用 64 位十六进制 |

证书摘要可通过以下命令读取：

```shell
keytool -list -v -keystore piliplus-fork.jks -alias piliplus
```

Windows PowerShell 可生成 Base64：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('piliplus-fork.jks'))
```

同时确认仓库 `Settings → Actions → General → Workflow permissions` 允许读写内容。默认使用受限的 `GITHUB_TOKEN` push 同步结果；只有分支保护明确阻止它时，才配置可写当前仓库内容的 `FORK_SYNC_TOKEN` Secret。不要给这个 token 超出当前 Fork 所需的权限。

## 第一次与后续 Release

完成签名配置后，手动运行 `Fork - Sync upstream`。它会同步 main，并在当前上游正式 Release 尚未被本 Fork 构建时自动创建首个 `v…-bili.1` Release。

也可以手动运行 `Fork - Build Android`：

- `verify-main`：构建和验证当前上游 main，不发布，使用 CI 临时 debug 签名。
- `release-latest-upstream`：使用固定生产签名发布最新上游正式 Release。
- `force_release`：上游 tag 相同时显式创建下一个 `bili.N` 修订；日常自动任务不会重复发布。

每个正式 Release 同时包含 `release-metadata.json` 与 `SHA256SUMS`。CI 会比较固定证书变量和上一版 APK 的实际证书；任一不一致都会停止发布。

## 安装、共存与恢复

- 本 Fork 与官方 Bilibili 都使用 `tv.danmaku.bili`，但签名不同。首次安装前必须卸载官方客户端，二者不能共存，也不能相互覆盖升级。
- 原版 PiliPlus 使用 `com.example.piliplus`，因此可以与本 Fork 共存；两者不能原地覆盖，也不会自动共享应用数据。
- 如要从本 Fork 切回官方 Bilibili，必须卸载本 Fork 后再安装官方客户端。卸载通常会删除私有应用数据，请先使用 PiliPlus 自身支持的导出方式备份需要的数据。
- 包名兼容只能解决按 package 解析 Intent 的情况，无法绕过调用方对官方签名证书、特定 Activity、权限或私有接口的校验。

## CI 安全门禁与故障处理

正式发布前会验证三个 APK 的：

- applicationId、versionName、versionCode 和 ABI 文件名；
- `com.example.piliplus.MainActivity`、Deep Link filters 和 Provider authority；
- APK v1/v2 签名、三个 ABI 的相同证书、固定证书变量和上一 Release 证书；
- Fork updater repository marker，以及 APK 中不存在官方 PiliPlus Release API/下载 URL；
- updater Release 过滤、版本比较、ABI 选择和非 Fork 下载 URL 拒绝逻辑。

常见失败含义：

- `Fork patch no longer applies`：上游修改了 Gradle、Manifest 或 updater，需审阅上游差异并更新 patch，不能跳过检查。
- `Signing certificate does not match`：Secrets、alias 或证书变量与首版不一致，禁止发布。
- `fork updater repository marker is missing`：dart-define 未进入 APK 或 updater 被上游重构。
- merge conflict：Fork 的少量永久文件与上游同时修改；依据 conflict artifact 手动合并后重新运行。

仍无法完全自动消除的风险包括 GitHub 未认证 API 限流、上游构建工具链失效、Bilibili 或第三方新增官方签名校验，以及只能在真实设备发现的运行时兼容变化。CI 会让能静态检测的变化失败，而不会发布一个包名、更新源或签名不确定的 APK。
