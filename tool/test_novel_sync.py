import sqlite3
import tempfile
import unittest
from pathlib import Path

from sync_novels import SCHEMA, atomic_new, download_all, report_db, safe
from prepare_novel_library import convert_all, decode, plain_text, normalize_derived, local_header, chapter_sort


class FakeClient:
    def api(self, path, **query):
        if path.endswith('/volumes'):
            return {'list': [{'id':'1','name':'第01卷','sort':10}]}
        if '/volume/' in path:
            return {'volume': {'id':'1','name':'第01卷','txt_addr':'https://example.test/text',
                    'txt_encoding':'UTF-8','contents':[{'name':'第一章','content_type':1,'start_lines':0,'end_lines':2},
                    {'name':'插图','content_type':2,'content':'https://example.test/image','start_lines':0,'end_lines':0}]}}
        return {'book': {'uuid':'n1','path_word':'one','name':'小说一','author':[{'name':'作者'}],
                         'cover':'https://example.test/image'}}

    def asset(self, url):
        return '第一章\n正文\n'.encode() if url.endswith('text') else b'\xff\xd8\xfftest-image'


class NovelSyncTest(unittest.TestCase):
    def test_additive_schema_and_download_no_original_mutation(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); source=root/'小说'; source.mkdir()
            original=source/'小说一 - 作者'; original.mkdir()
            old=original/'旧章节.txt'; old.write_text('保留原文件')
            manga=root/'漫画'; manga.mkdir(); index=manga/'拷贝漫画总索引.db'
            with sqlite3.connect(index) as db:
                db.execute('CREATE TABLE comics(id TEXT PRIMARY KEY,title TEXT)')
                db.execute("INSERT INTO comics VALUES('c1','漫画')")
            report=report_db(root/'report.db')
            report.execute("INSERT INTO matches(source_dir,title,authors,path_word,status,method) VALUES('小说一 - 作者','小说一','作者','one','matched','test')")
            report.commit()
            download_all(source,index,FakeClient(),report,0)
            self.assertEqual(report.execute('SELECT status FROM matches').fetchone()[0],'downloaded')
            with sqlite3.connect(index) as db:
                self.assertEqual(db.execute('SELECT * FROM comics').fetchall(),[('c1','漫画')])
                self.assertEqual(db.execute('SELECT is_downloaded FROM novel_volumes').fetchone()[0],1)
                self.assertEqual(db.execute('SELECT count(*) FROM novel_sections').fetchone()[0],2)
                db.executescript(SCHEMA.read_text())
                self.assertEqual(db.execute('SELECT count(*) FROM novels').fetchone()[0],1)
            self.assertEqual(old.read_text(),'保留原文件')
            self.assertEqual(len(list(root.glob('索引备份/*.db'))),1)
            report.close()

    def test_no_overwrite_and_safe_names(self):
        self.assertEqual(safe('a/b: c?'),'a b c')
        with tempfile.TemporaryDirectory() as temp:
            file=Path(temp)/'one.txt'; atomic_new(file,b'one'); atomic_new(file,b'one')
            with self.assertRaises(FileExistsError): atomic_new(file,b'two')
            self.assertEqual(file.read_bytes(),b'one')

    def test_unmatched_html_is_readable_preserves_every_original_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'小说';source.mkdir()
            original=source/'未匹配 - 作者';original.mkdir()
            old=original/'章节.txt'
            raw='第一卷&nbsp;&nbsp;第一章<br/>正文<img src="https://example.test/1.jpg">'.encode('gb18030')
            old.write_bytes(raw)
            (original/'1.jpg').write_bytes(b'\xff\xd8\xffold')
            manga=root/'漫画';manga.mkdir();index=manga/'拷贝漫画总索引.db'
            with sqlite3.connect(index) as db:db.execute('CREATE TABLE comics(id)')
            report=report_db(root/'report.db')
            report.execute("INSERT INTO matches(source_dir,title,authors,status,method) VALUES('未匹配 - 作者','未匹配','作者','not_found','test')")
            report.commit()
            convert_all(source,index,report,FakeClient())
            convert_all(source,index,report,FakeClient())
            normalize_derived(source,index,report)
            normalize_derived(source,index,report)
            self.assertEqual(old.read_bytes(),raw)
            with sqlite3.connect(index) as db:
                self.assertEqual(db.execute('SELECT count(*) FROM novels').fetchone()[0],1)
                path=db.execute('SELECT txt_relative_path FROM novel_volumes').fetchone()[0]
                text=(root/path).read_text()
                self.assertIn('第一卷',text);self.assertNotIn('<br',text)
                self.assertIn('【插图：原藏 - 1.jpg】',text)
                self.assertTrue((root/Path(path).parent/'原藏 - 1.jpg').is_file())
            report.close()

    def test_volume_headers_and_natural_order(self):
        header='web版\xa0\xa011-15'
        self.assertEqual(local_header(header+'\n正文','11-15'),header)
        self.assertLess(chapter_sort('第一卷\xa0\xa0第2章'),chapter_sort('第一卷\xa0\xa0第10章'))
        self.assertLess(chapter_sort('第二卷\xa0\xa0第一章'),chapter_sort('第十卷\xa0\xa0第一章'))
        self.assertLess(chapter_sort('第一卷\xa0\xa0序章'),chapter_sort('第一卷\xa0\xa0第一章'))
        self.assertGreater(chapter_sort('第一卷\xa0\xa0后记'),chapter_sort('第一卷\xa0\xa0第10章'))
        self.assertIsInstance(chapter_sort('第二卷\xa0\xa0第二2话'),tuple)

    def test_text_encodings_and_missing_link_preserved(self):
        for encoding in ('utf-8-sig','utf-16','gb18030'):
            self.assertEqual(decode('小说正文'.encode(encoding)),'小说正文')
        text,urls=plain_text('第一卷<br/>正文<img src="https://example.test/missing.jpg">')
        self.assertEqual(urls,['https://example.test/missing.jpg'])
        self.assertIn('【原插图链接：',text)
        truncated='短篇 正文'.encode('utf-8')[1:]
        self.assertTrue(decode(truncated).endswith('篇 正文'))
        self.assertIn('\ufffd',decode(truncated))


if __name__=='__main__': unittest.main()
