# 当前用户：看通知日期是否被写到未来
defaults read com.apple.SoftwareUpdate MajorOSUserNotificationDate
defaults read com.apple.SoftwareUpdate UserNotificationDate

# 系统级：看自动更新相关开关
sudo defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled
sudo defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload
sudo defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates
sudo defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall
sudo defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall
