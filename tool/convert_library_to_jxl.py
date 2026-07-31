#!/usr/bin/env python3
"""Create a resumable, byte-reversible JPEG XL copy of a manga ZIP library."""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import os
import posixpath
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import zipfile
from pathlib import Path


LIBRARY_DATABASE_NAME = "拷贝漫画总索引.db"
STATE_DATABASE_NAME = ".jxl_conversion_state.db"
ARCHIVE_MARKER = b"CopyMangaReader-JXL-e7-exact-jpeg-v1"
SUPPORTED_ARCHIVE_MARKERS = {
    ARCHIVE_MARKER,
    b"CopyMangaReader-JXL-e9-exact-jpeg-v1",
}
JPEG_SUFFIXES = {".jpg", ".jpeg"}
JXL_SUFFIX = ".jxl"
IMAGE_SUFFIXES = JPEG_SUFFIXES | {
    ".png",
    ".webp",
    ".gif",
    ".bmp",
    JXL_SUFFIX,
}


class ConversionInterrupted(RuntimeError):
    """Raised inside a worker when the operator requests a safe pause."""


@dataclasses.dataclass(frozen=True)
class ArchiveTask:
    relative_path: str
    source_path: Path
    destination_path: Path
    source_size: int
    source_mtime_ns: int


@dataclasses.dataclass(frozen=True)
class ArchiveResult:
    relative_path: str
    source_size: int
    source_mtime_ns: int
    output_size: int
    entry_count: int
    page_count: int
    jxl_pages: int
    fallback_jpeg_pages: int
    original_jpeg_bytes: int
    jxl_bytes: int
    recovered_existing: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "把章节 ZIP 内的 JPEG 可逆转码为 JPEG XL，原库只读，"
            "输出库支持断点恢复。"
        )
    )
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--effort", type=int, default=9)
    parser.add_argument(
        "--workers",
        type=int,
        default=max(1, min(14, (os.cpu_count() or 4) - 2)),
    )
    parser.add_argument("--codec-threads", type=int, default=1)
    parser.add_argument(
        "--no-roundtrip-verify",
        action="store_true",
        help="跳过每页还原原 JPEG 的 SHA/字节比较（不建议）",
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="仅转换前 N 个章节，用于小规模测试；不会发布正式索引",
    )
    return parser.parse_args()


def connect_state(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=NORMAL")
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS conversion_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS archives (
            relative_path TEXT PRIMARY KEY,
            source_size INTEGER NOT NULL,
            source_mtime_ns INTEGER NOT NULL,
            status TEXT NOT NULL,
            output_size INTEGER NOT NULL DEFAULT 0,
            entry_count INTEGER NOT NULL DEFAULT 0,
            page_count INTEGER NOT NULL DEFAULT 0,
            jxl_pages INTEGER NOT NULL DEFAULT 0,
            fallback_jpeg_pages INTEGER NOT NULL DEFAULT 0,
            original_jpeg_bytes INTEGER NOT NULL DEFAULT 0,
            jxl_bytes INTEGER NOT NULL DEFAULT 0,
            recovered_existing INTEGER NOT NULL DEFAULT 0,
            error TEXT NOT NULL DEFAULT '',
            started_at TEXT NOT NULL DEFAULT '',
            completed_at TEXT NOT NULL DEFAULT ''
        );
        """
    )
    connection.commit()
    return connection


def set_meta(connection: sqlite3.Connection, key: str, value: object) -> None:
    connection.execute(
        """
        INSERT INTO conversion_meta(key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (key, str(value)),
    )


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def collect_archives(source: Path, destination: Path) -> list[ArchiveTask]:
    tasks: list[ArchiveTask] = []
    for current, _, filenames in os.walk(source):
        current_path = Path(current)
        for filename in filenames:
            if not filename.lower().endswith(".zip"):
                continue
            source_path = current_path / filename
            relative = source_path.relative_to(source).as_posix()
            stat = source_path.stat()
            tasks.append(
                ArchiveTask(
                    relative_path=relative,
                    source_path=source_path,
                    destination_path=destination / Path(relative),
                    source_size=stat.st_size,
                    source_mtime_ns=stat.st_mtime_ns,
                )
            )
    tasks.sort(key=lambda task: task.relative_path)
    return tasks


def copy_non_archives(source: Path, destination: Path) -> tuple[int, int]:
    copied = 0
    skipped = 0
    for current, dirnames, filenames in os.walk(source):
        current_path = Path(current)
        relative_directory = current_path.relative_to(source)
        destination_directory = destination / relative_directory
        destination_directory.mkdir(parents=True, exist_ok=True)
        for dirname in dirnames:
            (destination_directory / dirname).mkdir(parents=True, exist_ok=True)
        for filename in filenames:
            source_path = current_path / filename
            if filename == ".DS_Store":
                continue
            if filename.startswith(LIBRARY_DATABASE_NAME):
                continue
            if filename.lower().endswith(".zip"):
                continue
            destination_path = destination_directory / filename
            source_stat = source_path.stat()
            if (
                destination_path.is_file()
                and destination_path.stat().st_size == source_stat.st_size
            ):
                skipped += 1
                continue
            partial = destination_path.with_name(
                f"{destination_path.name}.copying"
            )
            if partial.exists():
                partial.unlink()
            shutil.copy2(source_path, partial)
            if partial.stat().st_size != source_stat.st_size:
                raise OSError(f"复制后大小不一致：{source_path}")
            os.replace(partial, destination_path)
            copied += 1
    return copied, skipped


def completed_archives(
    connection: sqlite3.Connection,
) -> dict[str, tuple[int, int, int]]:
    rows = connection.execute(
        """
        SELECT relative_path, source_size, source_mtime_ns, output_size
        FROM archives
        WHERE status = 'completed'
        """
    )
    return {
        row[0]: (int(row[1]), int(row[2]), int(row[3]))
        for row in rows
    }


def clone_info(
    source: zipfile.ZipInfo,
    filename: str,
    compress_type: int,
) -> zipfile.ZipInfo:
    target = zipfile.ZipInfo(filename=filename, date_time=source.date_time)
    target.compress_type = compress_type
    target.comment = source.comment
    target.internal_attr = source.internal_attr
    target.external_attr = source.external_attr
    target.create_system = source.create_system
    target.create_version = source.create_version
    target.extract_version = source.extract_version
    return target


def has_conversion_marker(path: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as archive:
            return any(
                archive.comment.endswith(marker)
                for marker in SUPPORTED_ARCHIVE_MARKERS
            )
    except (OSError, zipfile.BadZipFile):
        return False


def recover_existing(task: ArchiveTask) -> ArchiveResult | None:
    destination = task.destination_path
    if not destination.is_file() or not has_conversion_marker(destination):
        return None
    try:
        with zipfile.ZipFile(destination) as archive:
            infos = [info for info in archive.infolist() if not info.is_dir()]
            bad_member = archive.testzip()
            if bad_member is not None:
                return None
            page_infos = [
                info
                for info in infos
                if Path(info.filename).suffix.lower() in IMAGE_SUFFIXES
            ]
            return ArchiveResult(
                relative_path=task.relative_path,
                source_size=task.source_size,
                source_mtime_ns=task.source_mtime_ns,
                output_size=destination.stat().st_size,
                entry_count=len(infos),
                page_count=len(page_infos),
                jxl_pages=sum(
                    Path(info.filename).suffix.lower() == JXL_SUFFIX
                    for info in page_infos
                ),
                fallback_jpeg_pages=sum(
                    Path(info.filename).suffix.lower() in JPEG_SUFFIXES
                    for info in page_infos
                ),
                original_jpeg_bytes=0,
                jxl_bytes=sum(
                    info.file_size
                    for info in page_infos
                    if Path(info.filename).suffix.lower() == JXL_SUFFIX
                ),
                recovered_existing=True,
            )
    except (OSError, zipfile.BadZipFile, RuntimeError):
        return None


def run_codec_process(
    command: list[str],
    stop_requested: threading.Event,
) -> int:
    if stop_requested.is_set():
        raise ConversionInterrupted("operator requested pause")
    process = subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        while process.poll() is None:
            if stop_requested.wait(0.1):
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise ConversionInterrupted("operator requested pause")
        return int(process.returncode)
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise


def run_codec(
    source_bytes: bytes,
    work_directory: Path,
    effort: int,
    codec_threads: int,
    verify_roundtrip: bool,
    stop_requested: threading.Event,
) -> bytes | None:
    source_path = work_directory / "page.jpg"
    encoded_path = work_directory / "page.jxl"
    restored_path = work_directory / "restored.jpg"
    source_path.write_bytes(source_bytes)
    if encoded_path.exists():
        encoded_path.unlink()
    if restored_path.exists():
        restored_path.unlink()

    encoded_returncode = run_codec_process(
        [
            "cjxl",
            str(source_path),
            str(encoded_path),
            f"--effort={effort}",
            "--lossless_jpeg=1",
            f"--num_threads={codec_threads}",
            "--quiet",
        ],
        stop_requested,
    )
    if encoded_returncode != 0 or not encoded_path.is_file():
        return None
    jxl_bytes = encoded_path.read_bytes()

    if verify_roundtrip:
        decoded_returncode = run_codec_process(
            ["djxl", str(encoded_path), str(restored_path), "--quiet"],
            stop_requested,
        )
        if (
            decoded_returncode != 0
            or not restored_path.is_file()
            or restored_path.read_bytes() != source_bytes
        ):
            return None
    return jxl_bytes


def convert_archive(
    task: ArchiveTask,
    *,
    effort: int,
    codec_threads: int,
    verify_roundtrip: bool,
    stop_requested: threading.Event,
) -> ArchiveResult:
    if stop_requested.is_set():
        raise ConversionInterrupted("operator requested pause")
    recovered = recover_existing(task)
    if recovered is not None:
        return recovered
    if task.destination_path.exists():
        raise FileExistsError(
            f"目标文件已存在但不是本转换器生成：{task.destination_path}"
        )

    task.destination_path.parent.mkdir(parents=True, exist_ok=True)
    partial = task.destination_path.with_name(
        f"{task.destination_path.name}.partial"
    )
    if partial.exists():
        partial.unlink()

    entry_count = 0
    page_count = 0
    jxl_pages = 0
    fallback_jpeg_pages = 0
    original_jpeg_bytes = 0
    jxl_bytes_total = 0

    with tempfile.TemporaryDirectory(prefix="copymanga_jxl_") as work:
        work_directory = Path(work)
        try:
            with zipfile.ZipFile(task.source_path, "r") as source_archive:
                with zipfile.ZipFile(
                    partial,
                    "w",
                    allowZip64=True,
                ) as destination_archive:
                    original_comment = source_archive.comment
                    if original_comment:
                        available = 65535 - len(ARCHIVE_MARKER) - 1
                        destination_archive.comment = (
                            original_comment[:available]
                            + b"\n"
                            + ARCHIVE_MARKER
                        )
                    else:
                        destination_archive.comment = ARCHIVE_MARKER

                    for source_info in source_archive.infolist():
                        if stop_requested.is_set():
                            raise ConversionInterrupted(
                                "operator requested pause"
                            )
                        if source_info.is_dir():
                            destination_archive.writestr(
                                clone_info(
                                    source_info,
                                    source_info.filename,
                                    zipfile.ZIP_STORED,
                                ),
                                b"",
                            )
                            continue

                        entry_count += 1
                        suffix = Path(source_info.filename).suffix.lower()
                        source_bytes = source_archive.read(source_info)
                        if suffix in IMAGE_SUFFIXES:
                            page_count += 1

                        if suffix not in JPEG_SUFFIXES:
                            destination_archive.writestr(
                                clone_info(
                                    source_info,
                                    source_info.filename,
                                    source_info.compress_type,
                                ),
                                source_bytes,
                            )
                            continue

                        original_jpeg_bytes += len(source_bytes)
                        jxl_bytes = run_codec(
                            source_bytes,
                            work_directory,
                            effort,
                            codec_threads,
                            verify_roundtrip,
                            stop_requested,
                        )
                        if jxl_bytes is None:
                            fallback_jpeg_pages += 1
                            destination_archive.writestr(
                                clone_info(
                                    source_info,
                                    source_info.filename,
                                    source_info.compress_type,
                                ),
                                source_bytes,
                            )
                            continue

                        stem, _ = posixpath.splitext(source_info.filename)
                        jxl_name = f"{stem}{JXL_SUFFIX}"
                        destination_archive.writestr(
                            clone_info(
                                source_info,
                                jxl_name,
                                zipfile.ZIP_STORED,
                            ),
                            jxl_bytes,
                        )
                        jxl_pages += 1
                        jxl_bytes_total += len(jxl_bytes)

            if stop_requested.is_set():
                raise ConversionInterrupted("operator requested pause")
            with zipfile.ZipFile(partial) as verification_archive:
                if not verification_archive.comment.endswith(ARCHIVE_MARKER):
                    raise zipfile.BadZipFile("转换标记缺失")
                bad_member = verification_archive.testzip()
                if bad_member is not None:
                    raise zipfile.BadZipFile(
                        f"输出 ZIP CRC 校验失败：{bad_member}"
                    )

            with partial.open("rb") as handle:
                os.fsync(handle.fileno())
            os.replace(partial, task.destination_path)
        except BaseException:
            if partial.exists():
                partial.unlink()
            raise

    return ArchiveResult(
        relative_path=task.relative_path,
        source_size=task.source_size,
        source_mtime_ns=task.source_mtime_ns,
        output_size=task.destination_path.stat().st_size,
        entry_count=entry_count,
        page_count=page_count,
        jxl_pages=jxl_pages,
        fallback_jpeg_pages=fallback_jpeg_pages,
        original_jpeg_bytes=original_jpeg_bytes,
        jxl_bytes=jxl_bytes_total,
    )


def mark_started(connection: sqlite3.Connection, task: ArchiveTask) -> None:
    connection.execute(
        """
        INSERT INTO archives(
            relative_path, source_size, source_mtime_ns, status, started_at
        )
        VALUES (?, ?, ?, 'running', ?)
        ON CONFLICT(relative_path) DO UPDATE SET
            source_size = excluded.source_size,
            source_mtime_ns = excluded.source_mtime_ns,
            status = 'running',
            error = '',
            started_at = excluded.started_at
        """,
        (
            task.relative_path,
            task.source_size,
            task.source_mtime_ns,
            timestamp(),
        ),
    )
    connection.commit()


def mark_completed(
    connection: sqlite3.Connection, result: ArchiveResult
) -> None:
    connection.execute(
        """
        INSERT INTO archives(
            relative_path, source_size, source_mtime_ns, status,
            output_size, entry_count, page_count, jxl_pages,
            fallback_jpeg_pages, original_jpeg_bytes, jxl_bytes,
            recovered_existing, completed_at
        )
        VALUES (?, ?, ?, 'completed', ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(relative_path) DO UPDATE SET
            source_size = excluded.source_size,
            source_mtime_ns = excluded.source_mtime_ns,
            status = 'completed',
            output_size = excluded.output_size,
            entry_count = excluded.entry_count,
            page_count = excluded.page_count,
            jxl_pages = excluded.jxl_pages,
            fallback_jpeg_pages = excluded.fallback_jpeg_pages,
            original_jpeg_bytes = excluded.original_jpeg_bytes,
            jxl_bytes = excluded.jxl_bytes,
            recovered_existing = excluded.recovered_existing,
            error = '',
            completed_at = excluded.completed_at
        """,
        (
            result.relative_path,
            result.source_size,
            result.source_mtime_ns,
            result.output_size,
            result.entry_count,
            result.page_count,
            result.jxl_pages,
            result.fallback_jpeg_pages,
            result.original_jpeg_bytes,
            result.jxl_bytes,
            int(result.recovered_existing),
            timestamp(),
        ),
    )
    connection.commit()


def mark_failed(
    connection: sqlite3.Connection, task: ArchiveTask, error: BaseException
) -> None:
    connection.execute(
        """
        INSERT INTO archives(
            relative_path, source_size, source_mtime_ns, status,
            error, completed_at
        )
        VALUES (?, ?, ?, 'failed', ?, ?)
        ON CONFLICT(relative_path) DO UPDATE SET
            source_size = excluded.source_size,
            source_mtime_ns = excluded.source_mtime_ns,
            status = 'failed',
            error = excluded.error,
            completed_at = excluded.completed_at
        """,
        (
            task.relative_path,
            task.source_size,
            task.source_mtime_ns,
            str(error),
            timestamp(),
        ),
    )
    connection.commit()


def mark_interrupted(
    connection: sqlite3.Connection, task: ArchiveTask
) -> None:
    connection.execute(
        """
        UPDATE archives
        SET status = 'interrupted',
            error = 'operator requested pause',
            completed_at = ?
        WHERE relative_path = ?
        """,
        (timestamp(), task.relative_path),
    )
    connection.commit()


def publish_library_database(source: Path, destination: Path) -> None:
    source_database = source / LIBRARY_DATABASE_NAME
    if not source_database.is_file():
        raise FileNotFoundError(f"源索引不存在：{source_database}")
    destination_database = destination / LIBRARY_DATABASE_NAME
    partial = destination / f"{LIBRARY_DATABASE_NAME}.publishing"
    if partial.exists():
        partial.unlink()
    shutil.copy2(source_database, partial)
    connection = sqlite3.connect(
        f"file:{partial}?mode=ro&immutable=1",
        uri=True,
    )
    try:
        result = connection.execute("PRAGMA quick_check").fetchone()
        if result is None or result[0] != "ok":
            raise sqlite3.DatabaseError(f"新索引校验失败：{result}")
    finally:
        connection.close()
    os.replace(partial, destination_database)


def main() -> int:
    args = parse_args()
    source = args.source.resolve()
    destination = args.destination.resolve()
    if source == destination:
        raise ValueError("源目录和目标目录不能相同")
    if destination.is_relative_to(source) or source.is_relative_to(destination):
        raise ValueError("源目录和目标目录不能互相包含")
    if not (source / LIBRARY_DATABASE_NAME).is_file():
        raise FileNotFoundError(f"源漫画库索引不存在：{source}")
    if not shutil.which("cjxl") or not shutil.which("djxl"):
        raise RuntimeError("找不到 cjxl/djxl，请先安装 jpeg-xl")

    destination.mkdir(parents=True, exist_ok=True)
    state_path = destination / STATE_DATABASE_NAME
    connection = connect_state(state_path)
    set_meta(connection, "source", source)
    set_meta(connection, "destination", destination)
    set_meta(connection, "effort", args.effort)
    set_meta(connection, "workers", args.workers)
    set_meta(connection, "codec_threads", args.codec_threads)
    set_meta(connection, "roundtrip_verify", not args.no_roundtrip_verify)
    set_meta(connection, "last_started_at", timestamp())
    connection.commit()

    copied, skipped = copy_non_archives(source, destination)
    print(
        f"NON_ARCHIVES copied={copied} already_present={skipped}",
        flush=True,
    )

    all_tasks = collect_archives(source, destination)
    tasks = all_tasks[: args.limit] if args.limit is not None else all_tasks
    completed = completed_archives(connection)
    remaining = []
    for task in tasks:
        previous = completed.get(task.relative_path)
        if (
            previous is not None
            and previous[0] == task.source_size
            and previous[1] == task.source_mtime_ns
            and task.destination_path.is_file()
            and task.destination_path.stat().st_size == previous[2]
        ):
            continue
        remaining.append(task)

    print(
        f"ARCHIVES total={len(tasks)} completed={len(tasks) - len(remaining)} "
        f"remaining={len(remaining)} workers={args.workers}",
        flush=True,
    )
    if not remaining:
        if args.limit is None:
            publish_library_database(source, destination)
            print("COMPLETE no remaining archives; index published", flush=True)
        connection.close()
        return 0

    stop_requested = threading.Event()

    def request_stop(signum: int, _frame: object) -> None:
        print(f"STOP_REQUESTED signal={signum}", flush=True)
        stop_requested.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    started = time.time()
    finished_count = 0
    failed_count = 0
    total_source_bytes = 0
    total_output_bytes = 0
    fallback_pages = 0
    task_iterator = iter(remaining)
    pending: dict[concurrent.futures.Future[ArchiveResult], ArchiveTask] = {}

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.workers
    ) as executor:

        def fill_pending() -> None:
            while (
                not stop_requested.is_set()
                and len(pending) < args.workers
            ):
                try:
                    task = next(task_iterator)
                except StopIteration:
                    break
                mark_started(connection, task)
                future = executor.submit(
                    convert_archive,
                    task,
                    effort=args.effort,
                    codec_threads=args.codec_threads,
                    verify_roundtrip=not args.no_roundtrip_verify,
                    stop_requested=stop_requested,
                )
                pending[future] = task

        fill_pending()
        while pending:
            done, _ = concurrent.futures.wait(
                pending,
                return_when=concurrent.futures.FIRST_COMPLETED,
            )
            for future in done:
                task = pending.pop(future)
                try:
                    result = future.result()
                except ConversionInterrupted:
                    mark_interrupted(connection, task)
                except BaseException as error:
                    failed_count += 1
                    mark_failed(connection, task, error)
                    print(
                        f"FAILED {task.relative_path}: {error}",
                        flush=True,
                    )
                else:
                    finished_count += 1
                    total_source_bytes += result.source_size
                    total_output_bytes += result.output_size
                    fallback_pages += result.fallback_jpeg_pages
                    mark_completed(connection, result)
                    if (
                        finished_count <= 10
                        or finished_count % 25 == 0
                    ):
                        elapsed = max(time.time() - started, 0.001)
                        rate = finished_count / elapsed * 3600
                        ratio = (
                            total_output_bytes / total_source_bytes
                            if total_source_bytes
                            else 0
                        )
                        print(
                            f"PROGRESS finished={finished_count}/"
                            f"{len(remaining)} failed={failed_count} "
                            f"rate={rate:.1f}_archives_per_hour "
                            f"output_ratio={ratio:.4f} "
                            f"fallback_pages={fallback_pages}",
                            flush=True,
                        )
            fill_pending()

    interrupted = stop_requested.is_set()
    state_counts = dict(
        connection.execute(
            "SELECT status, COUNT(*) FROM archives GROUP BY status"
        ).fetchall()
    )
    print(
        f"STATE {state_counts} interrupted={interrupted}",
        flush=True,
    )

    if (
        not interrupted
        and args.limit is None
        and state_counts.get("completed", 0) == len(all_tasks)
        and state_counts.get("failed", 0) == 0
    ):
        publish_library_database(source, destination)
        set_meta(connection, "completed_at", timestamp())
        connection.commit()
        print("COMPLETE all archives verified; index published", flush=True)
        connection.close()
        return 0

    if (
        not interrupted
        and args.limit is not None
        and failed_count == 0
    ):
        print(
            f"PILOT_COMPLETE converted={len(tasks)}; index not published",
            flush=True,
        )
        connection.close()
        return 0

    connection.close()
    return 130 if interrupted else 1


if __name__ == "__main__":
    raise SystemExit(main())
