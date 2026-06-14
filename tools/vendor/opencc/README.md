# OpenCC Phrase Sources

These phrase dictionaries are vendored from OpenCC and are used only as source
data for rebuilding CangjieX associated phrases.

- Upstream: https://github.com/BYVoid/OpenCC
- Version: `ver.1.1.9`
- License: Apache License 2.0, copied in `LICENSE`

Vendored files:

- `STPhrases.txt`
- `STCharacters.txt`
- `TSPhrases.txt`
- `TWPhrasesIT.txt`
- `TWPhrasesName.txt`
- `TWPhrasesOther.txt`
- `TWVariantsRevPhrases.txt`
- `HKVariantsRevPhrases.txt`

`tools/cook-associated-phrases.rb` reads the Traditional Chinese side of these
tab-separated dictionaries and merges the result with CangjieX's own
high-priority associated phrase seeds. `tools/associated-phrase-quality.rb` also
uses `STCharacters.txt` to reject simplified-only characters from every phrase
source.
