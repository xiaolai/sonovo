# Vendored test corpora

Every corpus below is vendored at a fixed revision. Tests never use the
network. `SHA256SUMS` records the exact bytes committed here;
`CorpusIntegrityTests` fails when a vendored file changes without a deliberate
manifest update.

| Directory | Corpus | Revision | License |
| --- | --- | --- | --- |
| `cm/` | CommonMark `spec.json` | 0.31.2 (`spec.commonmark.org`) | CC-BY-SA 4.0 (`cm/LICENSE`) |
| `gfm/` | GFM spec sections from `cmark-gfm/test/spec.txt` | cmark-gfm `0.29.0.gfm.13` @ `587a12bb54d95ac37241377e6ddc93ea0e45439b` | CC-BY-SA 4.0 spec text; repository `COPYING` is BSD-2-Clause |
| `cmreg/` | cmark regression suite and `spec.txt` | cmark `0.31.1` @ `bb3678d7a73cb02d35c8876ecd097072636200a8` | BSD-2-Clause |
| `gfmreg/` | cmark-gfm regression suite and `smart_punct.txt` | cmark-gfm `0.29.0.gfm.13` @ `587a12bb54d95ac37241377e6ddc93ea0e45439b` | BSD-2-Clause |
| `gfmext/` | cmark-gfm extension suite | cmark-gfm `0.29.0.gfm.13` @ `587a12bb54d95ac37241377e6ddc93ea0e45439b` | BSD-2-Clause |
| `xss/` | markdown-it XSS corpus (`test/fixtures/markdown-it/xss.txt`) | markdown-it `14.1.0` @ `0fe7ccb4b7f30236fb05f623be6924961d296d3d` | MIT |
| `remark-gfm/` | remark-gfm fixtures | `109972e8a773bf5dac1d6d2da0776557f36971aa` | MIT |
| `remark-frontmatter/` | remark-frontmatter fixtures | `1125009e530386bc8c2ba497087f7f2a3ae99ddf` | MIT |
| `vmark-ext/` | VMark wiki-link, details, and TOC tests | `44253dd5bd0d5a098762a54869de0710c02960c1` | ISC |
| `math/` | pulldown-cmark math corpus (`specs/math.txt`) | `v0.13.0` @ `f17d98ae9e7ef9c3be601fcb1c9fbd536d3cb873` | MIT |
| `cjk-emph/` | pulldown-cmark regression suite | `v0.13.0` @ `f17d98ae9e7ef9c3be601fcb1c9fbd536d3cb873` | MIT |
| `sonovo/` | Local product and custom-syntax fixtures | this repository | project |

## Notes

- **CJK emphasis:** pulldown-cmark `v0.13.0` has no dedicated CJK emphasis
  corpus. The vendored `pulldown-regression.rs` is that revision's Unicode and
  emphasis regression suite; the ledger's `cjk-emph` row is therefore narrower
  than stated. Sonovo's own `sonovo/cjk.md` covers CJK text directly.
- **Secondary oracles:** remark and VMark fixtures document expected behavior;
  they are not normative. CommonMark and GFM are.
- **Reference labels:** cmark-gfm's C API resolves reference links to
  destination/title and does not expose the source label on the node. The
  reference projection therefore carries destination and title; link-label
  identity is covered by Sonovo's own source-preservation fixtures instead.
- **Regenerating:** to update a corpus, replace the files, update the revision
  in this table, and regenerate `SHA256SUMS` with
  `find . -type f ! -name SHA256SUMS ! -name PROVENANCE.md -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS`.
  The integrity test then verifies the new bytes.
