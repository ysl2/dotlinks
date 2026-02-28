# 撤销“未来日期”屏蔽（当前用户）
defaults delete com.apple.SoftwareUpdate MajorOSUserNotificationDate 2>/dev/null
defaults delete com.apple.SoftwareUpdate UserNotificationDate 2>/dev/null

# 重新打开自动检查计划
sudo softwareupdate --schedule on 2>/dev/null

# 重新打开系统级自动更新（按你需要改 true/false）
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true

# 刷新
killall NotificationCenter 2>/dev/null
killall Dock 2>/dev/null
sudo killall softwareupdated 2>/dev/null
