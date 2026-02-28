#!/bin/bash

echo "开始恢复 macOS 自动更新设置..."

# 1. 开启后台自动检查更新
sudo softwareupdate --schedule on

# 2. 恢复系统偏好设置：启用自动检查、下载和安装更新
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -int 1
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -int 1
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -int 1

# 3. 恢复 App Store 的自动更新
sudo defaults write /Library/Preferences/com.apple.Commerce AutoUpdate -bool true

# 4. 从 hosts 文件中安全移除苹果更新服务器的屏蔽记录
# 注意：macOS 使用的是 BSD sed，因此 -i 后面需要加一对空引号 '' 来直接修改文件而不备份
echo "正在清理 hosts 文件中的屏蔽规则..."
sudo sed -i '' '/mesu.apple.com/d' /etc/hosts
sudo sed -i '' '/appldnld.apple.com/d' /etc/hosts
sudo sed -i '' '/swscan.apple.com/d' /etc/hosts
sudo sed -i '' '/gdmf.apple.com/d' /etc/hosts

# 5. 刷新 DNS 缓存以立即生效
echo "正在刷新 DNS 缓存..."
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

echo "========================================"
echo "恢复完成！你的 Mac 现在可以正常接收和下载系统更新了。"
echo "========================================"
