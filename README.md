# multica-notify 🐕

Multica 菜单栏通知宠物：有人 @你 或 agent 任务完成时，推送 macOS 系统通知。
不接其他 IM，只进通知中心。

## 功能
- 轮询 Multica Inbox（`mentioned` + `status_changed`），30秒/1分/5分/15分 快捷切换
- 未读静默播种：启动时不轰炸历史，只播报近 3 分钟
- 超过 5 条聚合为一条汇总通知
- 🎉 趣味模式：语音播报"有消息，快查看"(zh-CN TTS) + 🐕💬 气泡冒泡，菜单可关
- App 图标 🐕(tools/gen_icon.swift 程序化生成 icns)
- 通知点击跳转 issue 页面；菜单里保留最近 5 条
- 暂停/恢复、打开 Multica、开机自启（LaunchAgent）
- 状态图标：🐕 正常 / 🐕💤 离线 / 🐕❗ 凭证失效

## 使用
```bash
./build.sh              # 编译并组装 .app
open MulticaNotify.app  # 启动
```
- 凭证读 `~/.multica/config.json`（无需单独登录）
- 配置落 `~/.multica-notify.json`；日志 `~/.multica-notify.log`
- API 直连走 https 且绕过系统代理（公司网关会丢 Authorization）

## 技术备忘
- 服务端把 `/api/inbox/` 308 到无斜杠版，URLSession/curl 跟随时丢 Authorization → 必须请求 `https://host/api/inbox?workspace_id=…`
- UN 通知授权被拒时自动降级 osascript `display notification`
- 单文件 AppKit（NSStatusItem），LSUIElement 无 Dock 图标
