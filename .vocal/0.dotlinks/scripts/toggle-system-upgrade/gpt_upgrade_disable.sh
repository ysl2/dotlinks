# ===== 0) 可选：查看系统版本 =====
sw_vers

# ===== 1) 屏蔽“升级/更新”通知（当前登录用户）=====
# 说明：日期只要是“未来时间”即可，写远一点更省心
FUTURE="2099-12-31 23:59:59 +0000"

# 屏蔽“升级到新主版本 macOS（如 Sonoma/Sequoia/Tahoe …）”类通知
defaults write com.apple.SoftwareUpdate MajorOSUserNotificationDate -date "$FUTURE"

# 屏蔽“Updates Available / 有更新可安装”类通知（含常见的强提示横幅）
defaults write com.apple.SoftwareUpdate UserNotificationDate -date "$FUTURE"

# ===== 2) 关闭后台自动检查/下载/安装（需要管理员权限）=====
# 关闭自动计划检查（老牌开关，配合下面的 defaults 更稳）
sudo softwareupdate --schedule off

# 彻底关闭“自动检查更新 / 自动下载 / 自动安装”
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false

# 可选：连“安全响应/系统文件”“关键更新”的自动安装也关掉（更安静，但安全性更差）
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool false

# ===== 3) 可选：去掉 Dock 上“系统设置/系统偏好设置”的红点角标 =====
defaults write com.apple.systempreferences AttentionPrefBundleIDs 0

# ===== 4) 可选：重启相关进程让它立刻刷新（不重启电脑也行）=====
killall NotificationCenter 2>/dev/null
killall Dock 2>/dev/null
sudo killall softwareupdated 2>/dev/null
