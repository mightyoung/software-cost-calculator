# Offline Chinese and Latin font

`NotoSansSC.ttf` is the unmodified Google Fonts Noto Sans SC variable font,
downloaded from commit `a85815a42757630ce188fdad368c2dfc444d4773`:
https://github.com/google/fonts/tree/a85815a42757630ce188fdad368c2dfc444d4773/ofl/notosanssc

It covers Simplified Chinese and Latin text. The adjacent `OFL.txt` permits
bundling and redistribution under SIL Open Font License 1.1; preserve it in
deployments. Font size: 17,772,300 bytes. SHA-256:
`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`.

The packaging tool registers it as the Web engine's default `Roboto` family
alias so existing Flutter text uses the bundled glyphs. The font binary and its
internal family name are unchanged. Packaging verifies the font and license
hashes, and the offline manifest pins both in the same application generation.
