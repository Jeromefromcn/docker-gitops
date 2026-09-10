# Chinese output: Traditional, Hong Kong written standard

No `paths:` frontmatter — this governs how every reply is written, including
replies that read no files, so it has to load unconditionally.

**Always Traditional Chinese in the Hong Kong written standard. Never
Simplified.**

Hong Kong vocabulary, not Taiwan:

| Use | Not |
|---|---|
| 軟件 | 軟體 |
| 網絡 | 網路 |
| 打印 | 列印 |
| 質量 | 品質 |
| 優先級 | 優先順序 |

## Converting a file

Use OpenCC with the **`s2hk`** config. Not `s2t`, which writes 因爲 / 喫力 /
覈實 / 剛纔 — archaic forms nobody uses. Not `s2tw`, which swaps in Taiwan
vocabulary.

```bash
python3 -m venv /tmp/occ && /tmp/occ/bin/pip -q install opencc-python-reimplemented
/tmp/occ/bin/python -c "
from opencc import OpenCC; import io,sys
p=sys.argv[1]; s=io.open(p,encoding='utf-8').read()
io.open(p,'w',encoding='utf-8').write(OpenCC('s2hk').convert(s))" FILE.md
```

**Check the output by hand afterwards — `s2hk` over-converts in two places:**

- **`了` → `瞭`.** Correct in 瞭解, wrong everywhere it is a particle:
  寫明**了**理由, 聲明**了**一個. Running the converter again re-breaks these,
  so re-check after every run.
- **`并` → `併`.** Correct in 高併發 / 併發, wrong as the conjunction:
  提交**並**公開, **並**為每一個.

Also watch 槓桿 (not 槓杆) and 發佈 (not 發布).

## The exception

**Text already sent to someone keeps the exact characters it was sent in.**
Converting a sent message falsifies the record. In the job-search repo this is
enforced by `.claude/rules/outreach.md`; the principle holds anywhere.
