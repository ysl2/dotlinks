FUTURE="2099-12-31 23:59:59 +0000"

dscl . list /Users | grep -v '^_' | while read -r u; do
  # 跳过系统账号/异常账号（可按需增减）
  [ "$u" = "root" ] && continue
  home="$(dscl . -read /Users/"$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -d "$home" ] || continue

  sudo -u "$u" HOME="$home" defaults write com.apple.SoftwareUpdate MajorOSUserNotificationDate -date "$FUTURE"
  sudo -u "$u" HOME="$home" defaults write com.apple.SoftwareUpdate UserNotificationDate -date "$FUTURE"
done
