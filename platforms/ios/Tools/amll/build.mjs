import { build } from "esbuild";
import { readFileSync, writeFileSync } from "node:fs";

const result = await build({
  entryPoints: ["entry.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari15"],
  write: false,
  outdir: "out",
  loader: { ".css": "css" },
  legalComments: "none",
  logLevel: "info",
});

let js = "";
let css = "";
for (const file of result.outputFiles) {
  if (file.path.endsWith(".js")) js = file.text;
  if (file.path.endsWith(".css")) css = file.text;
}
js = js.replace(/<\/script/gi, "<\\/script");

const html = `<!doctype html>
<!--
  Moumusic lyric page. Renders lyrics with the original Apple Music-like Lyrics core
  (https://github.com/amll-dev/applemusic-like-lyrics), Copyright (c) the AMLL contributors,
  licensed under the GNU Affero General Public License v3.0 only. The bundled script below is built from
  @applemusic-like-lyrics/core 0.6.0 plus platforms/ios/Tools/amll/entry.js; both are in this repository's source.
-->
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>
/* The system font stack (-apple-system) does not fall back to a CJK font reliably (the simulator shows boxes), so CJK
   characters are mapped to PingFang explicitly, one face per weight; Latin text keeps the system font. */
@font-face{font-family:"AMLL CJK";font-weight:100 450;src:local("PingFangSC-Regular"),local("PingFang SC"),local("Heiti SC"),local("Hiragino Sans GB");unicode-range:U+2E80-2FDF,U+3000-30FF,U+31C0-33FF,U+3400-4DBF,U+4E00-9FFF,U+AC00-D7AF,U+F900-FAFF,U+FE30-FE4F,U+FF00-FFEF}
@font-face{font-family:"AMLL CJK";font-weight:451 599;src:local("PingFangSC-Medium"),local("PingFang SC Medium"),local("PingFangSC-Regular"),local("Heiti SC");unicode-range:U+2E80-2FDF,U+3000-30FF,U+31C0-33FF,U+3400-4DBF,U+4E00-9FFF,U+AC00-D7AF,U+F900-FAFF,U+FE30-FE4F,U+FF00-FFEF}
@font-face{font-family:"AMLL CJK";font-weight:600 900;src:local("PingFangSC-Semibold"),local("PingFang SC Semibold"),local("PingFangSC-Medium"),local("Heiti SC");unicode-range:U+2E80-2FDF,U+3000-30FF,U+31C0-33FF,U+3400-4DBF,U+4E00-9FFF,U+AC00-D7AF,U+F900-FAFF,U+FE30-FE4F,U+FF00-FFEF}
html,body,#root{margin:0;padding:0;width:100%;height:100%;background:transparent;overflow:hidden;
  -webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent;
  font-family:"AMLL CJK",-apple-system,"SF Pro Text","PingFang SC","Helvetica Neue",sans-serif}
.amll-lyric-player{--amll-lp-color:#fff;--amll-lp-font-size:30px;mix-blend-mode:normal !important}
/* The translation (and romaji) of the line being sung is highlighted with it; AMLL keeps it at 30% opacity. */
.amll-lyric-player [class*="lyricLine"][class*="FmKaba_active"] [class*="lyricSubLine"]{opacity:.85 !important}
/* AMLL puts a background box behind the line under the pointer. On a touch screen the "hover" of the last tap never ends,
   so the box stayed on the line after seeking to it. No box at all. */
.amll-lyric-player{--amll-lp-hover-bg-color:transparent}
.amll-lyric-player [class*="lyricLineWrapper"]:hover,.amll-lyric-player [class*="lyricLineWrapper"]:active{background-color:transparent !important}
/* Weights as in the standard lyric column: bold lines, medium translation. */
.amll-lyric-player [class*="lyricMainLine"]{font-weight:700}
.amll-lyric-player [class*="lyricSubLine"]{font-weight:500}
</style>
<style>${css}</style>
</head>
<body>
<div id="root"></div>
<script>${js}</script>
</body>
</html>
`;
writeFileSync("AMLLLyricsPage.html", html);
console.log("html bytes:", html.length, "js:", js.length, "css:", css.length);
