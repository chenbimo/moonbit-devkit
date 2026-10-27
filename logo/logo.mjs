// MoonBit 模块 logo 生成器:长方形底 + 双色名称,字形转成 path 内嵌。
//
// 为什么是 path 而不是 <text>:SVG 里的文字按渲染器选字体排版,同一份文件在
// 浏览器、resvg、rsvg 里字宽和基线都不一样(实测留白最大差 8px)。转成 path 之后
// 几何由这里算,谁渲染都一样。
//
// 排版规则(可以在命令行覆盖):
//   左右内边距 22、上下内边距 24 —— 上下略大于左右,读起来更透气;
//   宽度 = 墨迹宽 + 两侧内边距,高度 = 大写高 + 上下内边距,不靠猜。
//
// 用法:
//   bun logo.mjs --name BM2 --out ../bm2/docs/public/logo.svg
//   bun logo.mjs --name clicolor --split 9 --raster 32,180 --out ../clicolor/docs/public/logo.svg
//
// 参数:
//   --name   显示名(必填)
//   --split  前几个字符用第一色,其余用第二色(默认 2)
//   --bg     底色(默认 #0284c7)
//   --one    第一色(默认 #ffffff)
//   --two    第二色(默认 #ffd60a)
//   --pad-x  左右内边距(默认 22)
//   --pad-y  上下内边距(默认 24)
//   --radius 圆角(默认 16)
//   --size   字号(默认 45)
//   --out    输出 SVG 路径(必填);同名 PNG 会写在同目录
//   --raster 额外导出的 PNG 高度,逗号分隔(如 32,180);需要 @resvg/resvg-js

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import opentype from 'opentype.js'

const HERE = dirname(fileURLToPath(import.meta.url))
const FONT_PATH = join(HERE, 'fonts', 'Inter_800ExtraBold.ttf')

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, '')
    out[key] = argv[i + 1]
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
if (!args.name || !args.out) {
  console.error('用法: bun logo.mjs --name <名称> --out <输出.svg> [--split 2] [--raster 32,180]')
  process.exit(2)
}

const NAME = args.name
const SPLIT = Number(args.split ?? 2)
const BG = args.bg ?? '#0284c7'
const ONE = args.one ?? '#ffffff'
const TWO = args.two ?? '#ffd60a'
const PAD_X = Number(args['pad-x'] ?? 22)
const PAD_Y = Number(args['pad-y'] ?? 24)
const RADIUS = Number(args.radius ?? 16)
const SIZE = Number(args.size ?? 45)

const font = opentype.loadSync(FONT_PATH)

// 量墨迹盒:逐字累加字宽,同时记录每个字形轮廓的真实边界。
// 只用字宽会把两侧的侧边距也算进块宽,留白就会比设定值大几像素——这里按墨迹算。
const measure = (text) => {
  const glyphs = font.stringToGlyphs(text)
  const scale = SIZE / font.unitsPerEm
  let pen = 0
  let minX = Infinity
  let maxX = -Infinity
  let minY = Infinity
  let maxY = -Infinity
  for (const g of glyphs) {
    const box = g.getPath(pen, 0, SIZE).getBoundingBox()
    if (box.x1 < minX) minX = box.x1
    if (box.x2 > maxX) maxX = box.x2
    if (box.y1 < minY) minY = box.y1
    if (box.y2 > maxY) maxY = box.y2
    pen += (g.advanceWidth ?? 0) * scale
  }
  return { advance: pen, minX, maxX, minY, maxY, width: maxX - minX, height: maxY - minY }
}

const full = measure(NAME)
const W = Math.round(full.width + PAD_X * 2)
const H = Math.round(full.height + PAD_Y * 2)

// 基线:让墨迹盒的顶边落在 PAD_Y 处;水平:让最左侧墨迹落在 PAD_X 处。
// 四边留白因此由墨迹决定,与字体的侧边距无关,换字体也不会偏心。
const baseline = PAD_Y - full.minY
const originX = PAD_X - full.minX

const first = NAME.slice(0, SPLIT)
const second = NAME.slice(SPLIT)
const firstAdvance = measure(first).advance

const pathOf = (text, dx) =>
  font.getPath(text, originX + dx, baseline, SIZE).toPathData(2)

const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${NAME}">` +
  `<rect width="${W}" height="${H}" rx="${RADIUS}" fill="${BG}"/>` +
  (first ? `<path d="${pathOf(first, 0)}" fill="${ONE}"/>` : '') +
  (second ? `<path d="${pathOf(second, firstAdvance)}" fill="${TWO}"/>` : '') +
  `</svg>\n`

writeFileSync(args.out, svg)
console.log(`logo: ${args.name} -> ${args.out} (${W}×${H})`)

// 需要位图时用 resvg 直接出,不依赖系统图像工具。
if (args.raster) {
  const { Resvg } = await import('@resvg/resvg-js')
  const heights = args.raster.split(',').map((v) => Number(v.trim()))
  const dir = dirname(args.out)
  const base = args.out.replace(/\.svg$/, '')
  for (const h of heights) {
    const resvg = new Resvg(svg, { fitTo: { mode: 'height', value: h } })
    const png = resvg.render().asPng()
    const out = `${base}-${h}.png`
    writeFileSync(out, png)
    console.log(`  raster: ${out} (${png.length} 字节)`)
  }
  if (!dir) process.exit(1)
}
