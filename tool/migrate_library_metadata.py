#!/usr/bin/env python3
"""Add portable source, original-order, and title-sort metadata to the library."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path


EXPECTED_COMICS = 1191
EXPECTED_SOURCES = {"both": 1035, "copy_manga": 81, "dmzj": 75}
EXPECTED_ANCHORS = {
    877: "龍與虎",
    878: "16bit的感動",
    957: "沒有黃段子的無聊世界",
    958: "Dimension W-維度戰記-",
    1115: "女裝男友和男裝女友",
    1116: "搖曳百合資料集",
    1117: "2×2 Two By Two",
    1191: "魔王与勇者与圣剑神殿",
}


def load_sort_keys(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        comic_uuid, separator, key = line.partition("\t")
        if separator and comic_uuid and key:
            result[comic_uuid] = key
    return result


def ensure_column(
    connection: sqlite3.Connection,
    name: str,
    declaration: str,
) -> None:
    columns = {
        row[1] for row in connection.execute("PRAGMA table_info(comics)").fetchall()
    }
    if name not in columns:
        connection.execute(f"ALTER TABLE comics ADD COLUMN {name} {declaration}")


def validate_snapshot(connection: sqlite3.Connection) -> None:
    count = connection.execute("SELECT COUNT(*) FROM comics").fetchone()[0]
    if count != EXPECTED_COMICS:
        raise RuntimeError(f"预计 {EXPECTED_COMICS} 部漫画，实际 {count} 部")
    for rowid, title in EXPECTED_ANCHORS.items():
        row = connection.execute(
            "SELECT title FROM comics WHERE rowid = ?", (rowid,)
        ).fetchone()
        if row is None or row[0] != title:
            raise RuntimeError(
                f"数据库顺序锚点不匹配：rowid={rowid}，"
                f"预计={title!r}，实际={None if row is None else row[0]!r}"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--sort-keys", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    sort_keys = load_sort_keys(args.sort_keys)
    connection = sqlite3.connect(args.database)
    validate_snapshot(connection)
    rows = connection.execute("SELECT comic_uuid FROM comics").fetchall()
    missing_sort_keys = [row[0] for row in rows if row[0] not in sort_keys]
    if missing_sort_keys:
        raise RuntimeError(f"{len(missing_sort_keys)} 部漫画缺少首字母排序键")

    if args.apply:
        connection.execute("BEGIN IMMEDIATE")
        try:
            ensure_column(
                connection,
                "source_kind",
                "TEXT NOT NULL DEFAULT 'copy_manga'",
            )
            ensure_column(
                connection,
                "library_order",
                "INTEGER NOT NULL DEFAULT 0",
            )
            ensure_column(
                connection,
                "title_sort_key",
                "TEXT NOT NULL DEFAULT ''",
            )
            connection.execute(
                """
                UPDATE comics
                SET source_kind = CASE
                  WHEN path_word LIKE 'local-%' THEN 'dmzj'
                  WHEN rowid BETWEEN 1 AND 877
                    OR rowid BETWEEN 958 AND 1115 THEN 'both'
                  ELSE 'copy_manga'
                END,
                library_order = rowid
                """
            )
            connection.executemany(
                "UPDATE comics SET title_sort_key = ? WHERE comic_uuid = ?",
                [(key, comic_uuid) for comic_uuid, key in sort_keys.items()],
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise

    columns = {
        row[1] for row in connection.execute("PRAGMA table_info(comics)").fetchall()
    }
    stats = {}
    if "source_kind" in columns:
        stats = dict(
            connection.execute(
                "SELECT source_kind, COUNT(*) FROM comics GROUP BY source_kind"
            ).fetchall()
        )
        if args.apply and stats != EXPECTED_SOURCES:
            raise RuntimeError(f"来源数量校验失败：{stats}")
    print(
        json.dumps(
            {
                "mode": "apply" if args.apply else "dry-run",
                "comics": len(rows),
                "sort_keys": len(sort_keys),
                "sources": stats,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
