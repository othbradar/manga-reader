#!/usr/bin/env python3
"""Read-only catalogue matching; explicit opt-in downloads use additive SQLite tables.

Never edits/removes the old DMZJ files. Run --help for the staged workflow.
Credentials are not accepted on the command line or written to reports.
"""
import argparse
import concurrent.futures
import hashlib
import json
import re
import sqlite3
import threading
import time
import unicodedata
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

import requests

PROJECT = Path(__file__).resolve().parents[1]
SCHEMA = PROJECT / 'assets/sql/novel_library.sql'


def now():
    return datetime.now(timezone.utc).isoformat()


def safe(value):
    return re.sub(r'\s+', ' ', re.sub(r'[\x00-\x1f/:*?"<>|\\]', ' ', value)).strip().rstrip('. ') or '未命名'


def names(value):
    return '、'.join(x.get('name', '') for x in value or [] if isinstance(x, dict))


class Client:
    def __init__(self, domain, proxy=None):
        self.domain = domain
        self.proxies = {'http': proxy, 'https': proxy} if proxy else {}
        self.lock = threading.Lock()
        self.last = 0
        self.sessions = threading.local()

    def session(self):
        if not hasattr(self.sessions, 'http'):
            self.sessions.http = requests.Session()
        return self.sessions.http

    def api(self, path, **query):
        # Historical one-off importer: retain conversion/report code, but do not
        # silently keep a second, stale API implementation outside the reader.
        # Offline tests inject FakeClient; this path never contacts an account.
        raise RuntimeError('旧导入脚本的 API 入口已停用，请使用阅读器 0.5.0+32 及以后版本；'
                           '本地转换与既有报告不受影响')

    def asset(self, url):
        if not url.startswith(('https://', 'http://')):
            raise ValueError('无效资源 URL')
        for attempt in range(5):
            try:
                # Separate CDN request: never send the API signature or a member token.
                response = self.session().get(url, proxies=self.proxies, timeout=(15, 60))
                response.raise_for_status()
                if not response.content:
                    raise ValueError('空资源')
                return response.content
            except (requests.RequestException, ValueError):
                if attempt == 4:
                    raise
                time.sleep(2 ** attempt)


class Normalizer:
    def __init__(self):
        self.mapping = {}
        for line in (PROJECT / 'assets/opencc/TSCharacters.txt').read_text().splitlines():
            if line and not line.startswith('#'):
                columns = line.split()
                if len(columns) > 1:
                    self.mapping[ord(columns[0])] = columns[1]

    def key(self, text):
        text = unicodedata.normalize('NFKC', text).translate(self.mapping).lower()
        return ''.join(x for x in text if x.isalnum())

    def variants(self, text):
        values = [text, *re.split(r'[()（）\[\]【】／/]', text)]
        return {self.key(x) for x in values if len(self.key(x)) > 1}


def report_db(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.executescript('''
      CREATE TABLE IF NOT EXISTS catalog(path_word TEXT PRIMARY KEY, title TEXT, authors TEXT, cover TEXT);
      CREATE TABLE IF NOT EXISTS matches(source_dir TEXT PRIMARY KEY, title TEXT, authors TEXT,
        path_word TEXT, remote_title TEXT, remote_authors TEXT, status TEXT, method TEXT,
        score REAL DEFAULT 0, downloaded_volumes INTEGER DEFAULT 0, error TEXT DEFAULT '');
      CREATE TABLE IF NOT EXISTS candidates(source_dir TEXT, path_word TEXT, title TEXT,
        authors TEXT, score REAL, PRIMARY KEY(source_dir,path_word));
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
    ''')
    return db


def catalog(client, db):
    rows = db.execute('SELECT * FROM catalog').fetchall()
    if db.execute("SELECT 1 FROM metadata WHERE key='catalog_complete'").fetchone():
        return rows
    offset = 0
    while True:
        result = client.api('/api/v3/books', limit=100, offset=offset, ordering='name')
        entries = result['list']
        if not entries:
            if offset < result['total']:
                raise RuntimeError('目录分页提前为空，未标记完成')
            break
        for book in entries:
            db.execute('INSERT OR REPLACE INTO catalog VALUES (?,?,?,?)',
                       (book['path_word'], book['name'], names(book.get('author')), book.get('cover', '')))
        db.commit()
        offset += len(entries)
        print(f'目录 {offset}/{result["total"]}', flush=True)
        if offset >= result['total']:
            break
    db.execute("INSERT OR REPLACE INTO metadata VALUES ('catalog_complete',?)", (now(),))
    db.commit()
    return db.execute('SELECT * FROM catalog').fetchall()


def match_all(source, client, db):
    normal = Normalizer()
    online = catalog(client, db)
    books = [(r, normal.variants(r['title']), normal.key(r['authors'])) for r in online]
    folders = sorted(p for p in source.iterdir() if p.is_dir() and not p.name.startswith('.'))
    for i, folder in enumerate(folders):
        if db.execute('SELECT 1 FROM matches WHERE source_dir=?', (folder.name,)).fetchone():
            continue
        title, _, author = folder.name.rpartition(' - ')
        if not title:
            title, author = folder.name, ''
        variants, author_key = normal.variants(title), normal.key(author)
        ranked = []
        exact = []
        for row, titles, authors in books:
            score = max((SequenceMatcher(None, a, b).ratio() for a in variants for b in titles), default=0)
            same_author = bool(author_key and author_key == authors)
            same_title = bool(variants.intersection(titles))
            if same_title and same_author:
                exact.append(row)
            ranked.append((score * .8 + (0.2 if same_author else 0), row))
        ranked.sort(key=lambda x: x[0], reverse=True)
        winner = exact[0] if len(exact) == 1 else ranked[0][1]
        status = 'matched' if len(exact) == 1 else 'review'
        method = '简繁/Unicode归一化后标题及作者一致且唯一' if status == 'matched' else '需核对别名或作者'
        db.execute('INSERT INTO matches(source_dir,title,authors,path_word,remote_title,remote_authors,status,method,score) VALUES (?,?,?,?,?,?,?,?,?)',
                   (folder.name, title, author, winner['path_word'], winner['title'], winner['authors'], status, method, ranked[0][0]))
        for score, row in ranked[:5]:
            db.execute('INSERT OR REPLACE INTO candidates VALUES (?,?,?,?,?)',
                       (folder.name, row['path_word'], row['title'], row['authors'], score))
        db.commit()
        print(f'匹配 {i+1}/{len(folders)} {status}: {folder.name} => {winner["title"]}', flush=True)
    write_report(db, source)


def write_report(db, source):
    report = Path(db.execute('PRAGMA database_list').fetchone()[2]).with_suffix('.md')
    rows = db.execute('SELECT * FROM matches ORDER BY status,source_dir').fetchall()
    counts = dict(db.execute('SELECT status,count(*) FROM matches GROUP BY status').fetchall())
    lines = ['# 小说匹配与下载清单', '', f'源目录：{source}', '', f'更新：{now()}', '', str(counts), '',
             '|原文件夹|拷贝小说|作者|状态|依据 / 错误|', '|---|---|---|---|---|']
    for r in rows:
        values = [r['source_dir'], r['remote_title'], r['remote_authors'], r['status'], r['error'] or r['method']]
        lines.append('|' + '|'.join(str(v).replace('|', '／').replace('\n', ' ') for v in values) + '|')
    report.write_text('\n'.join(lines) + '\n')


def atomic_new(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() == data:
            return
        raise FileExistsError(f'拒绝覆盖内容不同的已有文件：{path}')
    temporary = path.with_name(path.name + '.novel-part')
    temporary.write_bytes(data)
    temporary.replace(path)


def image_ext(data):
    if data.startswith(b'\xff\xd8\xff'):
        return 'jpg'
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'png'
    if data.startswith(b'GIF8'):
        return 'gif'
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        return 'webp'
    raise ValueError('资源不是受支持的图片，未保存')


def backup_index(index):
    backup = index.parent.parent / '索引备份' / ('小说接入前_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.db')
    backup.parent.mkdir(exist_ok=True)
    with sqlite3.connect(f'file:{index}?mode=ro', uri=True) as source, sqlite3.connect(backup) as target:
        source.backup(target)
    print(f'索引备份：{backup}', flush=True)


def download_all(source, index, client, report, limit, source_names=None, make_backup=True, write_summary=True):
    rows = report.execute("SELECT * FROM matches WHERE status IN ('matched','failed') ORDER BY source_dir").fetchall()
    if source_names is not None:
        rows = [r for r in rows if r['source_dir'] in source_names]
    if limit:
        rows = rows[:limit]
    if not rows:
        return
    if make_backup: backup_index(index)
    db = sqlite3.connect(index, timeout=30)
    db.executescript(SCHEMA.read_text())
    for row in rows:
        try:
            book = client.api('/api/v3/book/' + row['path_word'])['book']
            if book['path_word'] != row['path_word']:
                raise ValueError('详情标识不匹配')
            uid, title, authors = book['uuid'], book['name'], names(book.get('author'))
            # Fresh sibling folder in 小说; originals never renamed or overwritten.
            folder = source / (safe(title) + ' - ' + safe(authors) + ' - 拷贝小说')
            relative = lambda path: path.relative_to(source.parent).as_posix()
            cover_bytes = client.asset(book['cover'])
            cover = folder / f'{safe(title)} - {safe(authors)} - 汇总.{image_ext(cover_bytes)}'
            atomic_new(cover, cover_bytes)
            db.execute('''INSERT INTO novels(novel_uuid,path_word,title,authors,alias,brief,cover_url,relative_dir,cover_relative_path,source_kind,library_order,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,'both',?,?) ON CONFLICT(novel_uuid) DO UPDATE SET
                title=excluded.title,authors=excluded.authors,alias=excluded.alias,brief=excluded.brief,
                cover_url=excluded.cover_url,relative_dir=excluded.relative_dir,
                cover_relative_path=excluded.cover_relative_path,source_kind='both',updated_at=excluded.updated_at''',
                (uid, book['path_word'], title, authors, book.get('alias') or '', book.get('brief') or '', book['cover'],
                 relative(folder), relative(cover), len(db.execute('SELECT novel_uuid FROM novels').fetchall()), now()))
            db.execute('INSERT OR REPLACE INTO novel_import_sources VALUES (?,?,?,?)',
                       (row['source_dir'], uid, row['method'], now()))
            db.commit()
            volumes = client.api('/api/v3/book/' + row['path_word'] + '/volumes', limit=100, offset=0)['list']
            done = 0
            for volume in volumes:
                vid = str(volume['id'])
                old = db.execute('SELECT txt_relative_path,is_downloaded FROM novel_volumes WHERE novel_uuid=? AND volume_id=?', (uid, vid)).fetchone()
                if old and old[1] and (source.parent / old[0]).is_file():
                    done += 1
                    continue
                detail = client.api(f'/api/v3/book/{row["path_word"]}/volume/{vid}')['volume']
                raw = client.asset(detail['txt_addr'])
                text = raw.decode(detail.get('txt_encoding') or 'utf-8').lstrip('\ufeff')
                if not text.strip() or text.lstrip().lower().startswith(('<!doctype', '<html')):
                    raise ValueError('TXT 内容为空或为错误页面')
                stem = f'{safe(title)} - {safe(authors)} - {safe(volume["name"])}'
                # Stable upstream ID prevents two identically named specials from colliding.
                if sum(v['name'] == volume['name'] for v in volumes) > 1:
                    stem += f' [{vid}]'
                txt = folder / f'{stem}.txt'
                encoded = text.encode('utf-8')
                atomic_new(txt, encoded)
                sections = detail.get('contents') or []
                image_rows = {}
                def download_image(item):
                    section_index, section = item
                    data = client.asset(section['content'])
                    path = folder / f'{stem} - {section_index + 1:03d} {safe(section["name"])}.{image_ext(data)}'
                    atomic_new(path, data)
                    return section_index, relative(path)
                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                    for si, path in pool.map(download_image, [(i, s) for i, s in enumerate(sections) if s.get('content_type') == 2]):
                        image_rows[si] = path
                with db:
                    db.execute('INSERT OR REPLACE INTO novel_volumes VALUES (?,?,?,?,?,?,?,?,1)',
                               (uid, vid, volume['name'], volume.get('sort', 0), detail['txt_addr'], 'UTF-8', relative(txt), hashlib.sha256(encoded).hexdigest()))
                    for si, section in enumerate(sections):
                        db.execute('INSERT OR REPLACE INTO novel_sections VALUES (?,?,?,?,?,?,?,?,?)',
                                   (uid, vid, si, section.get('name', ''), section.get('content_type', 1),
                                    section.get('start_lines', 0), section.get('end_lines', 0),
                                    section.get('content') if section.get('content_type') == 2 else '', image_rows.get(si, '')))
                done += 1
                report.execute('UPDATE matches SET downloaded_volumes=? WHERE source_dir=?', (done, row['source_dir']))
                report.commit()
                print(f'已下载 {title} {volume["name"]} ({done}/{len(volumes)})', flush=True)
            report.execute("UPDATE matches SET status='downloaded',error='' WHERE source_dir=?", (row['source_dir'],))
        except Exception as error:
            report.execute("UPDATE matches SET status='failed',error=? WHERE source_dir=?", (str(error), row['source_dir']))
            print(f'失败 {row["source_dir"]}: {error}', flush=True)
        report.commit()
        if write_summary: write_report(report, source)
    db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--domain', default='api.copy202602.com')
    parser.add_argument('--proxy')
    parser.add_argument('--match', action='store_true')
    parser.add_argument('--download', action='store_true')
    parser.add_argument('--index', type=Path)
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--workers', type=int, default=1, choices=range(1,5))
    args = parser.parse_args()
    client = Client(args.domain, args.proxy)
    db = report_db(args.report)
    if args.match:
        match_all(args.source, client, db)
    if args.download:
        if not args.index or not args.index.is_file():
            parser.error('--download 需要既有 --index 文件')
        if args.workers == 1:
            download_all(args.source, args.index, client, db, args.limit)
        else:
            backup_index(args.index)
            pending=[r[0] for r in db.execute("SELECT source_dir FROM matches WHERE status IN ('matched','failed') ORDER BY source_dir")]
            if args.limit:pending=pending[:args.limit]
            def worker(names):
                report=report_db(args.report)
                try:download_all(args.source,args.index,client,report,0,set(names),False,False)
                finally:report.close()
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
                for _ in pool.map(worker,[pending[i::args.workers] for i in range(args.workers)]):
                    write_report(db,args.source)
    print(dict(db.execute('SELECT status,count(*) FROM matches GROUP BY status').fetchall()), flush=True)
    db.close()


if __name__ == '__main__':
    main()
