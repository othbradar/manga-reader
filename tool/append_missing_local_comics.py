#!/usr/bin/env python3
"""Append folder-only comics to the shared CopyManga SQLite index.

The generated local IDs intentionally match LibraryDatabase.rebuildFromFolders
so the mobile reader will not create a second record for the same folder.
"""

from __future__ import annotations

import argparse
import base64
import copy
import csv
import json
import re
import sqlite3
import unicodedata
import zipfile
from pathlib import Path


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
BOTTOM_TIMESTAMP = "1970-01-01T00:00:00.000Z"


def normalized(value: str) -> str:
    return unicodedata.normalize("NFKC", value).casefold().replace(" ", "")


def stable_id(value: str) -> str:
    encoded = base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii")
    return encoded.rstrip("=")


def natural_key(value: str) -> list[object]:
    parts = re.split(r"(\d+(?:\.\d+)?)", unicodedata.normalize("NFKC", value))
    return [float(part) if re.fullmatch(r"\d+(?:\.\d+)?", part) else part.casefold() for part in parts]


def split_folder_name(folder: str) -> tuple[str, str]:
    split = folder.rfind(" - ")
    if split <= 0:
        return folder, "未知作者"
    return folder[:split], folder[split + 3 :]


def choose_cover(directory: Path, folder: str) -> Path | None:
    images = [
        item
        for item in directory.iterdir()
        if item.is_file() and item.suffix.casefold() in IMAGE_SUFFIXES
    ]
    if not images:
        return None
    expected = normalized(f"{folder} - 汇总")

    def score(path: Path) -> tuple[int, int, int, str]:
        stem = normalized(path.stem)
        return (
            int(stem == expected),
            int("汇总" in path.stem),
            path.stat().st_size,
            path.name,
        )

    return max(images, key=score)


def page_count(archive: Path) -> int:
    try:
        with zipfile.ZipFile(archive) as opened:
            return sum(
                1
                for item in opened.infolist()
                if not item.is_dir()
                and Path(item.filename).suffix.casefold() in IMAGE_SUFFIXES
            )
    except (OSError, zipfile.BadZipFile):
        return 0


def chapter_title(folder: str, archive: Path) -> str:
    stem = archive.stem
    prefix = f"{folder} - "
    return stem[len(prefix) :] if stem.startswith(prefix) else stem


def chapter_metadata(
    *,
    chapter_uuid: str,
    title: str,
    pages: int,
    comic_uuid: str,
    comic_title: str,
    comic_path_word: str,
    group_size: int,
    order: float,
) -> dict[str, object]:
    return {
        "chapterUuid": chapter_uuid,
        "chapterTitle": title,
        "chapterSize": pages,
        "comicUuid": comic_uuid,
        "comicTitle": comic_title,
        "comicPathWord": comic_path_word,
        "groupPathWord": "local",
        "groupName": "本地章节",
        "groupSize": group_size,
        "order": order,
        "comicStatus": "ongoing",
        "isPdfExported": False,
        "isCbzExported": False,
        "isDownloaded": True,
    }


def comic_metadata(
    template: dict[str, object],
    *,
    comic_uuid: str,
    path_word: str,
    title: str,
    authors: str,
    cover_relative_path: str,
    chapters: list[dict[str, object]],
) -> dict[str, object]:
    metadata = copy.deepcopy(template)
    detail = metadata["comic"]
    assert isinstance(detail, dict)
    detail.update(
        {
            "uuid": comic_uuid,
            "b_404": False,
            "b_hidden": False,
            "ban": 0,
            "ban_ip": None,
            "name": title,
            "alias": title,
            "path_word": path_word,
            "close_comment": False,
            "close_roast": False,
            "free_type": {"value": 0, "display": "本地"},
            "restrict": {"value": 0, "display": "本地"},
            "reclass": {"value": 0, "display": "本地漫画"},
            "seo_baidu": title,
            "region": {"value": 0, "display": "本地"},
            "status": {"value": 0, "display": "本地"},
            "author": [{"name": authors, "alias": None, "path_word": ""}],
            "theme": [],
            "brief": "动漫之家本地整理库",
            "datetime_updated": BOTTOM_TIMESTAMP,
            "cover": cover_relative_path,
            "last_chapter": (
                {
                    "uuid": chapters[-1]["chapterUuid"],
                    "name": chapters[-1]["chapterTitle"],
                }
                if chapters
                else {"uuid": "", "name": ""}
            ),
            "popular": 0,
            "groups": {"local": chapters},
        }
    )
    metadata.update(
        {
            "popular": 0,
            "groups": {
                "local": {
                    "path_word": "local",
                    "count": len(chapters),
                    "name": "本地章节",
                }
            },
            "isDownloaded": True,
        }
    )
    metadata.pop("comicDownloadDir", None)
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--expect", type=int, default=75)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    connection = sqlite3.connect(args.database)
    connection.row_factory = sqlite3.Row
    template_row = connection.execute(
        "SELECT metadata_blob FROM comics WHERE metadata_blob <> '' ORDER BY rowid LIMIT 1"
    ).fetchone()
    if template_row is None:
        raise RuntimeError("数据库中没有可复用的漫画元数据模板")
    template = json.loads(template_row["metadata_blob"])

    existing_rows = connection.execute(
        "SELECT title, comic_relative_dir FROM comics ORDER BY rowid"
    ).fetchall()
    existing_directories = {
        normalized(row["comic_relative_dir"]) for row in existing_rows
    }
    existing_titles = {normalized(row["title"]) for row in existing_rows}

    missing: list[dict[str, object]] = []
    for directory in sorted(args.library.iterdir(), key=lambda item: natural_key(item.name)):
        if (
            not directory.is_dir()
            or directory.name.startswith(".")
            or directory.name.startswith("_导入前索引备份_")
            or normalized(directory.name) in existing_directories
        ):
            continue
        title, authors = split_folder_name(directory.name)
        if normalized(title) in existing_titles:
            raise RuntimeError(f"发现同名数据库记录，拒绝自动追加：{directory.name}")
        archives = sorted(
            [
                item
                for item in directory.iterdir()
                if item.is_file() and item.suffix.casefold() == ".zip"
            ],
            key=lambda item: natural_key(item.name),
        )
        cover = choose_cover(directory, directory.name)
        if not archives and cover is None:
            continue

        comic_stable = stable_id(directory.name)
        comic_uuid = f"local-{comic_stable}"
        path_word = comic_uuid
        chapter_rows: list[dict[str, object]] = []
        for index, archive in enumerate(archives):
            relative_archive = archive.relative_to(args.library).as_posix()
            chapter_uuid = f"local-{stable_id(f'{directory.name}/{archive.name}')}"
            title_value = chapter_title(directory.name, archive)
            pages = page_count(archive)
            metadata = chapter_metadata(
                chapter_uuid=chapter_uuid,
                title=title_value,
                pages=pages,
                comic_uuid=comic_uuid,
                comic_title=title,
                comic_path_word=path_word,
                group_size=len(archives),
                order=float(index),
            )
            chapter_rows.append(
                {
                    "chapter_uuid": chapter_uuid,
                    "chapter_title": title_value,
                    "chapter_order": float(index),
                    "page_count": pages,
                    "archive_relative_path": relative_archive,
                    "metadata_blob": json.dumps(
                        metadata, ensure_ascii=False, separators=(",", ":")
                    ),
                }
            )

        cover_relative_path = (
            cover.relative_to(args.library).as_posix() if cover is not None else ""
        )
        metadata = comic_metadata(
            template,
            comic_uuid=comic_uuid,
            path_word=path_word,
            title=title,
            authors=authors,
            cover_relative_path=cover_relative_path,
            chapters=[
                json.loads(row["metadata_blob"]) for row in chapter_rows
            ],
        )
        missing.append(
            {
                "comic_uuid": comic_uuid,
                "path_word": path_word,
                "title": title,
                "authors": authors,
                "comic_relative_dir": directory.name,
                "cover_relative_path": cover_relative_path,
                "metadata_blob": json.dumps(
                    metadata, ensure_ascii=False, separators=(",", ":")
                ),
                "chapters": chapter_rows,
            }
        )

    if len(missing) != args.expect:
        raise RuntimeError(f"预计追加 {args.expect} 部，实际识别 {len(missing)} 部")

    if args.apply:
        connection.execute("BEGIN IMMEDIATE")
        try:
            next_library_order = connection.execute(
                "SELECT COALESCE(MAX(library_order), 0) + 1 FROM comics"
            ).fetchone()[0]
            for comic in missing:
                connection.execute(
                    """
                    INSERT INTO comics(
                      comic_uuid, path_word, title, authors, comic_relative_dir,
                      cover_url, cover_relative_path, metadata_blob, source_kind,
                      library_order, title_sort_key, updated_at
                    ) VALUES(?, ?, ?, ?, ?, '', ?, ?, 'dmzj', ?, ?, ?)
                    """,
                    (
                        comic["comic_uuid"],
                        comic["path_word"],
                        comic["title"],
                        comic["authors"],
                        comic["comic_relative_dir"],
                        comic["cover_relative_path"],
                        comic["metadata_blob"],
                        next_library_order,
                        normalized(comic["title"]),
                        BOTTOM_TIMESTAMP,
                    ),
                )
                next_library_order += 1
                connection.execute(
                    """
                    INSERT INTO chapter_groups(comic_uuid, group_path_word, group_name)
                    VALUES(?, 'local', '本地章节')
                    """,
                    (comic["comic_uuid"],),
                )
                for chapter in comic["chapters"]:
                    connection.execute(
                        """
                        INSERT INTO chapters(
                          chapter_uuid, comic_uuid, group_path_word, group_name,
                          chapter_title, chapter_order, page_count,
                          archive_relative_path, is_pdf_exported, is_cbz_exported,
                          metadata_blob, updated_at
                        ) VALUES(?, ?, 'local', '本地章节', ?, ?, ?, ?, 0, 0, ?, ?)
                        """,
                        (
                            chapter["chapter_uuid"],
                            comic["comic_uuid"],
                            chapter["chapter_title"],
                            chapter["chapter_order"],
                            chapter["page_count"],
                            chapter["archive_relative_path"],
                            chapter["metadata_blob"],
                            BOTTOM_TIMESTAMP,
                        ),
                    )
            connection.commit()
        except Exception:
            connection.rollback()
            raise

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("w", encoding="utf-8-sig", newline="") as report:
            writer = csv.writer(report)
            writer.writerow(
                ["title", "authors", "comic_relative_dir", "cover_relative_path", "chapters"]
            )
            for comic in missing:
                writer.writerow(
                    [
                        comic["title"],
                        comic["authors"],
                        comic["comic_relative_dir"],
                        comic["cover_relative_path"],
                        len(comic["chapters"]),
                    ]
                )

    print(
        json.dumps(
            {
                "mode": "apply" if args.apply else "dry-run",
                "added_comics": len(missing),
                "added_chapters": sum(len(comic["chapters"]) for comic in missing),
                "covers": sum(bool(comic["cover_relative_path"]) for comic in missing),
                "first": missing[0]["comic_relative_dir"] if missing else None,
                "last": missing[-1]["comic_relative_dir"] if missing else None,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
