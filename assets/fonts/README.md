# 字体

更纱黑体(Sarasa Gothic SC)子集,来源 https://github.com/be5invis/Sarasa-Gothic,
许可 SIL Open Font License 1.1(全文 https://scripts.sil.org/OFL)。
- ZemoteS-UI-Regular.ttf / -Bold.ttf → family "Sarasa UI SC"(界面)
- ZemoteS-Term-Regular.ttf → family "Sarasa Term SC"(代码/diff/终端)
子集范围:GB2312 + ASCII + 中英标点;未覆盖字符回退系统字体。
再生成:`pip install fonttools && python tool/subset_fonts.py`
