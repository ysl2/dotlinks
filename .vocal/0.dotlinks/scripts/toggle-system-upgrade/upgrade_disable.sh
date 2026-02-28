sw_vers

grep -q "configuration.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 configuration.apple.com" >> /etc/hosts'
grep -q "gdmf.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 gdmf.apple.com" >> /etc/hosts'
grep -q "gsp64-ssl.ls.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 gsp64-ssl.ls.apple.com" >> /etc/hosts'
grep -q "mesu.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 mesu.apple.com" >> /etc/hosts'
grep -q "swcdn.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 swcdn.apple.com" >> /etc/hosts'
grep -q "swdist.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 swdist.apple.com" >> /etc/hosts'
grep -q "swdownload.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 swdownload.apple.com" >> /etc/hosts'
grep -q "swquery.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 swquery.apple.com" >> /etc/hosts'
grep -q "swscan.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 swscan.apple.com" >> /etc/hosts'
grep -q "updates-http.cdn-apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 updates-http.cdn-apple.com" >> /etc/hosts'
grep -q "xp.apple.com" /etc/hosts || sudo sh -c 'echo "127.0.0.1 xp.apple.com" >> /etc/hosts'
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

FUTURE="2099-12-31 23:59:59 +0000"
defaults write com.apple.SoftwareUpdate MajorOSUserNotificationDate -date "$FUTURE"
defaults write com.apple.SoftwareUpdate UserNotificationDate -date "$FUTURE"

sudo softwareupdate --schedule off

sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false

sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool false

sudo defaults write /Library/Preferences/com.apple.Commerce AutoUpdate -bool false

defaults delete com.apple.systempreferences AttentionPrefBundleIDs
defaults delete com.apple.systempreferences DidShowPrefBundleIDs
defaults delete com.apple.systemsettings AttentionPrefBundleIDs
defaults delete com.apple.systemsettings DidShowPrefBundleIDs

killall NotificationCenter 2>/dev/null
killall Dock 2>/dev/null
sudo killall softwareupdated 2>/dev/null
