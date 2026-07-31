#!/bin/zsh
set -euo pipefail

label="com.othbradar.copymanga.jxlconvert.once"
domain="gui/$(id -u)"
service="${domain}/${label}"

if ! launchctl print "${service}" >/dev/null 2>&1; then
  echo "转换任务没有载入，目前已是停止状态。"
else
  current="$(launchctl print "${service}" 2>/dev/null)"
  if [[ "${current}" == *"state = running"* ]]; then
    echo "正在安全暂停，请稍候……"
    launchctl kill SIGTERM "${service}"
    while true; do
      current="$(launchctl print "${service}" 2>/dev/null || true)"
      if [[ "${current}" != *"state = running"* ]]; then
        break
      fi
      sleep 0.5
    done
  fi
  sync
  echo "已暂停并落盘，现在可以在 Finder 中弹出相关外置盘。"
fi

read -r "?按回车关闭窗口："
