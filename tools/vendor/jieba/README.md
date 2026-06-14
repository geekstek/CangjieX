# Jieba Traditional Dictionary Source

This dictionary is vendored from Jieba and is used as a broad Traditional
Chinese phrase source for rebuilding CangjieX associated phrases.

- Upstream: https://github.com/fxsjy/jieba
- Source file: `extra_dict/dict.txt.big`
- Upstream commit: `67fa2e36e72f69d9134b8a1037b83fbb070b9775`
- License: MIT, copied in `LICENSE`
- SHA256: `b16011275c42955ccd81fc1adecc93a59dbb7926af69d93fc95d4943d40f6aad`

`tools/cook-associated-phrases.rb` reads the first column as a phrase and the
second column as its frequency. Phrases are merged by frequency after
CangjieX's hand-curated high-priority seeds, then filtered to Traditional
Chinese Han-only phrases before being written into `associated_phrases`.
