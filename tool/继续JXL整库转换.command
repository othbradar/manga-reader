#!/bin/zsh
set -euo pipefail

label="com.othbradar.copymanga.jxlconvert.once"
domain="gui/$(id -u)"
service="${domain}/${label}"
script_dir="${0:A:h}"
plist="${script_dir}/com.othbradar.copymanga.jxlconvert.once.plist"

if [[ ! -f "${plist}" ]]; then
  echo "没有找到本机 launchd 配置：${plist}"
  echo "请复制同目录的 .plist.example，替换其中占位路径后再运行。"
  read -r "?按回车关闭窗口："
  exit 1
fi

if launchctl print "${service}" >/dev/null 2>&1; then
  current="$(launchctl print "${service}" 2>/dev/null)"
  if [[ "${current}" == *"state = running"* ]]; then
    echo "转换任务本来就在运行。"
  else
    launchctl kickstart "${service}"
    echo "已从断点继续转换。"
  fi
else
  launchctl bootstrap "${domain}" "${plist}"
  echo "已载入任务并从断点继续转换。"
fi

read -r "?按回车关闭窗口："
