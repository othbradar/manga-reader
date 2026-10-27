#!/usr/bin/env python3
"""Add local-readable copies for every original novel, including unmapped books.

The source list is frozen in matches.db. New folders are never rediscovered as
originals. Uses the same schema/relative paths as Flutter and sync_novels.py.
"""
import argparse
import concurrent.futures
import hashlib
import html
import re
import shutil
import sqlite3
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin,urlparse
import requests

from sync_novels import Client, SCHEMA, atomic_new, backup_index, image_ext, names, now, report_db, safe, write_report


class PlainNovel(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.pieces=[]
        self.images=[]

    def handle_starttag(self,tag,attrs):
        if tag in ('br','p','div','h1','h2','h3'):
            self.pieces.append('\n')
        elif tag=='img':
            url=dict(attrs).get('src','')
            if url:
                self.images.append(url)
                self.pieces.append(f'\n【原插图链接：{url}】\n')

    def handle_endtag(self,tag):
        if tag in ('p','div','h1','h2','h3'):
            self.pieces.append('\n')

    def handle_data(self,data):
        self.pieces.append(data)


def decode(data):
    if data.startswith((b'\xff\xfe',b'\xfe\xff')):
        return data.decode('utf-16')
    try:
        return data.decode('utf-8-sig')
    except UnicodeDecodeError:
        partial=data.decode('utf-8',errors='replace')
        # Historical exports sometimes lost bytes at a UTF-8 boundary. Keep
        # explicit replacement characters, never invent the missing text.
        stripped=data
        while stripped and 0x80 <= stripped[0] <= 0xbf:
            stripped=stripped[1:]
        boundary_only=False
        if 0 < len(data)-len(stripped) <= 3:
            try:
                stripped.decode('utf-8');boundary_only=True
            except UnicodeDecodeError:pass
        if boundary_only or partial.count('\ufffd') / max(1,len(partial)) < .03:
            return partial
        return data.decode('gb18030')


def plain_text(text):
    if re.search(r'<(?:br|p|img)\b',text,re.I):
        parser=PlainNovel(); parser.feed(text)
        return ''.join(parser.pieces).replace('\r\n','\n'),parser.images
    return text.replace('\r\n','\n'),[]


def local_header(text, fallback):
    first=next((x.strip() for x in text.splitlines() if x.strip()),'')
    if len(first) < 180 and ('\xa0\xa0' in first or
       re.match(r'^[\ufffd]*(?:第[一二三四五六七八九十百零〇\d]+[卷部]|全一卷|[上下]卷|短篇|外传|番外)', first)):
        return first
    return fallback


def chapter_sort(header):
    """Natural volume/chapter order; keep unknown titles stable, don't invent it."""
    digits={c:i for i,c in enumerate('零一二三四五六七八九')};digits['〇']=0
    def number(s):
        if s.isdigit():return int(s)
        if not any(c in s for c in '十百千'):
            return int(''.join(str(digits[c]) if c in digits else c for c in s))
        total=part=0
        for c in s:
            if c.isdigit():part=part*10+int(c)
            elif c in digits:part=digits[c]
            else:total+=(part or 1)*{'十':10,'百':100,'千':1000}[c];part=0
        return total+part
    def key(s):
        return tuple((0,number(x)) if re.fullmatch(r'[\d零〇一二三四五六七八九十百千]+',x)
                     else (1,x.casefold()) for x in re.split(r'([\d零〇一二三四五六七八九十百千]+)',s) if x)
    parts=re.split(r'\xa0{2,}',header,maxsplit=1)
    volume,chapter=(parts if len(parts)==2 else ('',header))
    if re.search(r'序章|序幕|前言|序言|prologue',chapter,re.I):rank=0
    elif re.search(r'后记|後記|あとがき',chapter):rank=9
    elif re.search(r'终章|終章|尾声|尾聲|epilogue',chapter,re.I):rank=8
    else:rank=1
    return key(volume),rank,key(chapter)


def inspect_candidates(report,client):
    report.execute('''CREATE TABLE IF NOT EXISTS details(path_word TEXT PRIMARY KEY,
      novel_uuid TEXT,title TEXT,authors TEXT,alias TEXT,brief TEXT,cover TEXT)''')
    rows=report.execute("SELECT * FROM matches WHERE status='review'").fetchall()
    for row in rows:
        if report.execute('SELECT 1 FROM details WHERE path_word=?',(row['path_word'],)).fetchone():continue
        b=client.api('/api/v3/book/'+row['path_word'])['book']
        report.execute('INSERT OR REPLACE INTO details VALUES (?,?,?,?,?,?,?)',
          (b['path_word'],b['uuid'],b['name'],names(b.get('author')),b.get('alias') or '',b.get('brief') or '',b.get('cover') or ''))
        report.commit()
        print(row['source_dir'],'=>',b['name'],'|',names(b.get('author')),'|',b.get('alias') or '',flush=True)


def convert_all(source,index,report,client):
    backup_index(index)
    report.execute('''CREATE TABLE IF NOT EXISTS local_files(source_dir TEXT,source_file TEXT,
      source_sha256 TEXT,destination TEXT,text_sha256 TEXT,images INTEGER,error TEXT,
      PRIMARY KEY(source_dir,source_file))''')
    report.execute('''CREATE TABLE IF NOT EXISTS missing_images(source_dir TEXT,source_file TEXT,
      url TEXT,status TEXT DEFAULT 'pending',relative_path TEXT DEFAULT '',error TEXT DEFAULT '',
      PRIMARY KEY(source_dir,source_file,url))''')
    report.execute('''CREATE TABLE IF NOT EXISTS encoding_repairs(source_dir TEXT,source_file TEXT,
      replacement_characters INTEGER,source_sha256 TEXT,reason TEXT,
      PRIMARY KEY(source_dir,source_file))''')
    db=sqlite3.connect(index,timeout=30);db.row_factory=sqlite3.Row
    db.executescript(SCHEMA.read_text())
    rows=report.execute('SELECT * FROM matches ORDER BY source_dir').fetchall()
    for number,row in enumerate(rows):
        folder=source/row['source_dir']
        if row['status'] in ('review','not_found'):
            uid='local-novel-'+hashlib.sha256(row['source_dir'].encode()).hexdigest()
            pathword=uid;title=row['title'];author=row['authors'];brief='';alias='';cover_url=''
            target=source/(safe(title)+' - '+safe(author)+' - 本地小说')
            kind='dmzj'
        else:
            existing=db.execute('SELECT * FROM novels WHERE path_word=?',(row['path_word'],)).fetchone()
            detail=report.execute('SELECT * FROM details WHERE path_word=?',(row['path_word'],)).fetchone()
            cached=existing or detail
            book=({'uuid':cached['novel_uuid'],'path_word':cached['path_word'],'name':cached['title'],
                   'author':[{'name':cached['authors']}],'brief':cached['brief'],'alias':cached['alias'],
                   'cover':cached['cover_url'] if existing else cached['cover']} if cached else
                  client.api('/api/v3/book/'+row['path_word'])['book'])
            uid=book['uuid'];pathword=book['path_word'];title=book['name'];author=names(book.get('author'))
            brief=book.get('brief') or '';alias=book.get('alias') or '';cover_url=book.get('cover') or ''
            target=source/(safe(title)+' - '+safe(author)+' - 拷贝小说');kind='both'
        target.mkdir(exist_ok=True)
        relative=lambda file:file.relative_to(source.parent).as_posix()
        images=sorted(f for f in folder.iterdir() if f.is_file() and f.suffix.lower() in ('.jpg','.jpeg','.png','.gif','.webp','.jxl'))
        covers=[f for f in images if '汇总' in f.stem or '封面' in f.stem]
        cover=''
        for image in images:
            dest=target/('原藏 - '+image.name)
            if not dest.exists():shutil.copy2(image,dest)
            elif hashlib.sha256(dest.read_bytes()).digest()!=hashlib.sha256(image.read_bytes()).digest():
                raise RuntimeError('本地图片与已有副本不一致，未覆盖：'+str(dest))
            if image in covers and not cover:cover=relative(dest)
        with db:
            db.execute('''INSERT INTO novels(novel_uuid,path_word,title,authors,alias,brief,cover_url,relative_dir,cover_relative_path,source_kind,library_order,updated_at)
              VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(novel_uuid) DO UPDATE SET
              relative_dir=excluded.relative_dir,source_kind=excluded.source_kind,
              cover_relative_path=CASE WHEN cover_relative_path='' THEN excluded.cover_relative_path ELSE cover_relative_path END''',
              (uid,pathword,title,author,alias,brief,cover_url,relative(target),cover,kind,number,now()))
            db.execute('INSERT OR REPLACE INTO novel_import_sources VALUES(?,?,?,?)',(row['source_dir'],uid,row['method'],now()))
        files=sorted(f for f in folder.iterdir() if f.is_file() and f.suffix.lower()=='.txt')
        for i,file in enumerate(files):
            if report.execute('SELECT 1 FROM local_files WHERE source_dir=? AND source_file=? AND error=""',(row['source_dir'],file.name)).fetchone():continue
            try:
                raw=file.read_bytes();decoded=decode(raw);text,urls=plain_text(decoded)
                if '\ufffd' in decoded:
                    report.execute('INSERT OR REPLACE INTO encoding_repairs VALUES(?,?,?,?,?)',
                      (row['source_dir'],file.name,decoded.count('\ufffd'),hashlib.sha256(raw).hexdigest(),
                       '原始 UTF-8 存在残缺字节，保留可解码正文，以替代字符标记缺字；原文件未修改'))
                # DMZJ HTML first line preserves the volume that old filenames often lost.
                header=local_header(text,file.stem.removeprefix(row['source_dir']+' - '))
                vid='local-'+hashlib.sha256(file.name.encode()).hexdigest()[:20]
                name=f'{safe(title)} - {safe(author)} - 原藏 {safe(header)} [{vid[6:14]}].txt'
                dest=target/name
                for url in urls:
                    # Reuse images already present in the original book directory.
                    basename=Path(url.split('?')[0]).name
                    local=next((f for f in images if f.name==basename or f.stem==Path(basename).stem),None)
                    if local:
                        text=text.replace(f'【原插图链接：{url}】',f'【插图：原藏 - {local.name}】')
                    else:
                        report.execute('INSERT OR IGNORE INTO missing_images(source_dir,source_file,url) VALUES(?,?,?)',(row['source_dir'],file.name,url))
                data=text.encode('utf-8');atomic_new(dest,data)
                with db:
                    db.execute('''INSERT OR IGNORE INTO novel_volumes(novel_uuid,volume_id,title,volume_order,txt_encoding,txt_relative_path,text_sha256,is_downloaded)
                      VALUES(?,?,?,?,?,?,?,1)''',(uid,vid,'[原藏] '+header,100000+i,'UTF-8',relative(dest),hashlib.sha256(data).hexdigest()))
                report.execute('INSERT OR REPLACE INTO local_files VALUES(?,?,?,?,?,?,?)',
                  (row['source_dir'],file.name,hashlib.sha256(raw).hexdigest(),relative(dest),hashlib.sha256(data).hexdigest(),len(urls),''))
            except Exception as e:
                report.execute('INSERT OR REPLACE INTO local_files VALUES(?,?,?,?,?,?,?)',(row['source_dir'],file.name,'','','',0,str(e)))
            report.commit()
        print(f'本地转换 {number+1}/{len(rows)}: {title} ({len(files)} 个 TXT)',flush=True)
    db.close()
    write_report(report,source)


def normalize_derived(source,index,report):
    """Rename/reorder only generated, hash-verified copies; never source TXT."""
    backup_index(index)
    db=sqlite3.connect(index,timeout=30);db.row_factory=sqlite3.Row
    changed=0
    all_rows=report.execute('SELECT * FROM local_files WHERE error="" ORDER BY source_dir,source_file').fetchall()
    for book in db.execute('SELECT * FROM novels').fetchall():
        # The source mapping is in the shared index, not in application state.
        origins={x[0] for x in db.execute('SELECT source_dir FROM novel_import_sources WHERE novel_uuid=?',(book['novel_uuid'],))}
        pending=[]
        for row in all_rows:
            if row['source_dir'] not in origins:continue
            old=source.parent/row['destination'];raw=old.read_bytes()
            if hashlib.sha256(raw).hexdigest()!=row['text_sha256']:raise RuntimeError('派生 TXT 已被修改，停止整理：'+str(old))
            fallback=Path(row['source_file']).stem.removeprefix(row['source_dir']+' - ')
            header=local_header(raw.decode('utf-8'),fallback)
            vid='local-'+hashlib.sha256(row['source_file'].encode()).hexdigest()[:20]
            new=old.with_name(f'{safe(book["title"])} - {safe(book["authors"])} - 原藏 {safe(header)} [{vid[6:14]}].txt')
            pending.append((chapter_sort(header),row,old,new,vid,header))
        for order,(_,row,old,new,vid,header) in enumerate(sorted(pending,key=lambda x:x[0])):
            if new!=old:
                if new.exists():raise RuntimeError('目标已存在，停止而不覆盖：'+str(new))
                old.rename(new);changed+=1
            relative=new.relative_to(source.parent).as_posix()
            with db:db.execute('UPDATE novel_volumes SET title=?,volume_order=?,txt_relative_path=? WHERE novel_uuid=? AND volume_id=?',
                ('[原藏] '+header,100000+order,relative,book['novel_uuid'],vid))
            report.execute('UPDATE local_files SET destination=? WHERE source_dir=? AND source_file=?',(relative,row['source_dir'],row['source_file']));report.commit()
    db.close();print(f'仅整理派生副本：改名 {changed} 个，全部按卷/章节自然排序',flush=True)


def recover_images(source,index,report,proxy=None):
    """Recover reachable legacy illustrations. Never fabricate/rewrite old URLs.

    A host with three connection failures is deferred, not falsely labelled as
    thousands of individual 404s. A future run can retry those links.
    """
    rows=report.execute("SELECT DISTINCT url FROM missing_images WHERE status<>'saved'").fetchall()
    hosts={}
    for row in rows:
        url=urljoin('https://xs.dmzj.com/',row['url'])
        hosts.setdefault(urlparse(url).netloc,[]).append((row['url'],url))
    def fetch(pair):
        original,url=pair
        try:
            r=requests.get(url,timeout=(6,12),proxies={'http':proxy,'https':proxy} if proxy else {})
            r.raise_for_status();image_ext(r.content)
            return original,r.content,'',False
        except requests.ConnectionError as e:return original,None,type(e).__name__+': '+str(e)[:240],True
        except requests.Timeout as e:return original,None,type(e).__name__+': '+str(e)[:240],True
        except Exception as e:return original,None,str(e)[:260],False
    recovered=0
    def save(result):
        nonlocal recovered
        url,data,error,_=result
        if data is None:
            report.execute("UPDATE missing_images SET status='failed',error=? WHERE url=?",(error,url))
        else:
            for r in report.execute('SELECT DISTINCT source_dir,source_file FROM missing_images WHERE url=?',(url,)).fetchall():
                output=report.execute('SELECT destination FROM local_files WHERE source_dir=? AND source_file=? AND error=""',(r['source_dir'],r['source_file'])).fetchone()
                if not output:continue
                folder=(source.parent/output['destination']).parent
                dest=folder/('原藏插图 - '+hashlib.sha256(url.encode()).hexdigest()[:20]+'.'+image_ext(data))
                atomic_new(dest,data)
                report.execute("UPDATE missing_images SET status='saved',relative_path=?,error='' WHERE source_dir=? AND source_file=? AND url=?",
                  (dest.relative_to(source.parent).as_posix(),r['source_dir'],r['source_file'],url))
                recovered+=1
        report.commit()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for host,pairs in hosts.items():
            sample=list(pool.map(fetch,pairs[:3]))
            if sample and all(x[3] for x in sample):
                report.executemany("UPDATE missing_images SET status='host_unreachable',error=? WHERE url=?",
                  [('主机连接失败，未逐条验证：'+sample[0][2],x[0]) for x in pairs])
                report.commit();print('旧插图主机不可达：',host,len(pairs),flush=True);continue
            for result in sample:save(result)
            for result in pool.map(fetch,pairs[3:]):save(result)
            print('旧插图主机处理完成：',host,'累计恢复',recovered,flush=True)
    db=sqlite3.connect(index,timeout=30)
    for row in report.execute("SELECT * FROM local_files WHERE error='' AND images>0").fetchall():
        file=source.parent/row['destination'];raw=file.read_bytes()
        if hashlib.sha256(raw).hexdigest()!=row['text_sha256']:
            raise RuntimeError('转换副本已被修改，未覆盖：'+str(file))
        text=raw.decode('utf-8')
        for r in report.execute("SELECT * FROM missing_images WHERE source_dir=? AND source_file=? AND status='saved'",(row['source_dir'],row['source_file'])):
            text=text.replace('【原插图链接：'+r['url']+'】','【插图：'+Path(r['relative_path']).name+'】')
        data=text.encode('utf-8')
        if data==raw:continue
        # Only our own hash-verified derived TXT is updated. Originals stay intact.
        part=file.with_name(file.name+'.image-recovery-part');part.write_bytes(data);part.replace(file)
        digest=hashlib.sha256(data).hexdigest()
        with db:db.execute('UPDATE novel_volumes SET text_sha256=? WHERE txt_relative_path=?',(digest,row['destination']))
        report.execute('UPDATE local_files SET text_sha256=? WHERE source_dir=? AND source_file=?',(digest,row['source_dir'],row['source_file']));report.commit()
    db.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--index',type=Path)
    p.add_argument('--report',type=Path,required=True);p.add_argument('--inspect',action='store_true')
    p.add_argument('--convert',action='store_true');p.add_argument('--proxy')
    p.add_argument('--recover-images',action='store_true')
    p.add_argument('--normalize-derived',action='store_true')
    args=p.parse_args();db=report_db(args.report);client=Client('api.copy202602.com',args.proxy)
    if args.inspect:inspect_candidates(db,client)
    if args.convert:
        if not args.index:p.error('--convert 需要 --index')
        convert_all(args.source,args.index,db,client)
    if args.recover_images:
        if not args.index:p.error('--recover-images 需要 --index')
        recover_images(args.source,args.index,db,args.proxy)
    if args.normalize_derived:
        if not args.index:p.error('--normalize-derived 需要 --index')
        normalize_derived(args.source,args.index,db)
    db.close()


if __name__=='__main__':main()
