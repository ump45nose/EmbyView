# EmbyView 开发约定

EmbyView 是基于 Moonfin 3.1.1（GPL-3.0）的 Mac 优先 Emby 客户端。上游代码保留，EmbyView 的界面和服务写在独立目录，便于每 2–3 个月合并上游。构建、签名与双机安装见 [docs/embyview-macos-install.md](docs/embyview-macos-install.md)。

## 架构约束

- 新界面全部在 `lib/embyview/ui/`，新服务在 `lib/embyview/{data,playback,subtitles,prefs,contracts}/`。Moonfin 原界面不改；上游只在路由入口（`app_router.dart`、`lib/embyview/entry.dart`）、Mac 播放宿主和少数接入点有改动。
- 界面只经「界面数据门面」`lib/embyview/data/` 取数据，不直接调 Moonfin 仓库或 Emby 接口。封面取图规则、自定义分区查询只在门面里实现一次。
- 门面、本机索引和预解析缓存按「服务器 + 用户」隔离；切换用户先结束播放会话再重建门面。服务器保存有序地址列表，连接失败按顺序换下一条，会话身份按 serverId / userId / token 校验，请求动态读当前地址，不因换地址重建界面。
- 播放用 fork 的 AetherEngine（跟上游正式版，加证书补丁和 Anime4K 对比）。一次播放一个播放会话对象，界面只发操作、订阅状态。切字幕轨不重开媒体；确需重开时先重新取 115 直连地址再回原位置。
- 字幕由客户端直接读写 NAS 上片子的同目录，Emby 识别只尽力。AI 字幕：本机 whisper.cpp 听写（模型首次使用时下载到 Application Support，不打进安装包），翻译走单一 OpenAI 兼容接口（地址、模型、密钥在设置里填）。
- 版本号是 EmbyView 自己的（从 1.0.0 起），构建号只增不减，保证升级安装不倒退；「基于 Moonfin 3.1.1」写在关于页。
- 仓库公开：个人服务器地址、网关地址、密钥都不进仓库，密钥存钥匙串，开发验证经运行时注入。

## 待办

- Emby 4.10.2 实测本地文件与 strm 的同目录字幕均无法通过条目通知、元数据刷新建立索引；继续由客户端直接读取 NAS，网页及电视端仍需单独解决。
