# 关闭后台自动检查更新
sudo softwareupdate --schedule off

# 禁用自动检查更新功能
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false

# 禁用自动下载 macOS 更新
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -int 0

# 禁用自动安装 macOS 更新
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false

# 禁用自动安装系统数据文件和安全更新（可选，但推荐保留安全更新以防漏洞，若要极致屏蔽则执行此条）
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -int 0
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -int 0

# 禁用 App Store 的自动更新
sudo defaults write /Library/Preferences/com.apple.Commerce AutoUpdate -bool false

# ---

# 清除系统偏好设置/系统设置的角标通知
defaults write com.apple.systempreferences AttentionPrefBundleIDs 0

# 重启 Dock 以使更改生效
killall Dock

# ---

# 将苹果的更新服务器重定向到无效地址 (0.0.0.0)
sudo sh -c 'echo "0.0.0.0 mesu.apple.com" >> /etc/hosts'
sudo sh -c 'echo "0.0.0.0 appldnld.apple.com" >> /etc/hosts'
sudo sh -c 'echo "0.0.0.0 swscan.apple.com" >> /etc/hosts'
sudo sh -c 'echo "0.0.0.0 gdmf.apple.com" >> /etc/hosts'

# 刷新 DNS 缓存以立即生效
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
