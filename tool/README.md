# 漫画库维护工具

这些工具用于一次性整理或转换漫画库，不参与 App 启动。

运行任何带 `--apply` 的工具前：

1. 暂停桌面下载器和手机端下载。
2. 备份 `拷贝漫画总索引.db`。
3. 先运行 dry-run。
4. 核对预计数量、文件路径和报告。
5. 只对备份或明确目标执行。

## append_missing_local_comics.py

把只有文件夹、封面或章节 ZIP 的动漫之家独有漫画追加到共享 SQLite 底部。默认只
分析，指定 `--apply` 才写入。

```bash
python3 tool/append_missing_local_comics.py \
  --database "/path/漫画/拷贝漫画总索引.db" \
  --library "/path/漫画" \
  --expect 75 \
  --report "/tmp/missing-comics.csv"
```

确认报告后追加 `--apply`。

## migrate_library_metadata.py

为特定历史快照补充来源、原始顺序和标题排序字段。脚本包含数量与顺序锚点，若实际库
不符合就会拒绝执行，不应为了绕过校验随意改常量。

## convert_library_to_jxl.py

创建独立目标库，把章节 ZIP 内 JPEG 以 JPEG XL `lossless_jpeg=1` 可逆压缩。
源库只读，目标库包含断点状态数据库。

```bash
python3 tool/convert_library_to_jxl.py \
  --source "/path/source/漫画" \
  --destination "/path/destination/漫画" \
  --effort 7 \
  --workers 18 \
  --codec-threads 1
```

转换默认逐页还原并比较原 JPEG 字节。不要使用
`--no-roundtrip-verify` 制作正式备份。

### launchd 后台运行

1. 复制：

   ```bash
   cp tool/com.othbradar.copymanga.jxlconvert.once.plist.example \
     tool/com.othbradar.copymanga.jxlconvert.once.plist
   ```

2. 替换模板中的：

   - `__PYTHON__`
   - `__PROJECT_DIR__`
   - `__SOURCE_LIBRARY__`
   - `__DESTINATION_LIBRARY__`

3. 双击“继续JXL整库转换.command”载入或继续任务。
4. 拔外置盘前双击“暂停JXL整库转换.command”，等待安全落盘提示。

实际 `.plist` 含本机路径，已被 Git 忽略；仓库只提交 `.example`。
