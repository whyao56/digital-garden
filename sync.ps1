#requires -Version 5.1
<#
  把私有 Obsidian 库里「可公开」的目录同步到本仓库（digital-garden）。
  用法：
    .\sync.ps1              # 只生成内容，不提交
    .\sync.ps1 -Commit      # 生成 + git add/commit
    .\sync.ps1 -Push        # 生成 + 提交 + 推送
#>
param(
  [string]$Vault = 'D:\Obsidian\Documents\MyDigitalBrain',
  [switch]$Commit,
  [switch]$Push,
  [string]$Message = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# ---- 公开范围：只列这些目录 ----
$selection = @(
  @{ Src = '仓库区/手艺';              Dest = '手艺' },
  @{ Src = '仓库区/知识/科技与工程';    Dest = '知识/科技与工程' },
  @{ Src = '仓库区/知识/数理与科学';    Dest = '知识/数理与科学' },
  @{ Src = '仓库区/知识/自然与地理';    Dest = '知识/自然与地理' },
  @{ Src = '仓库区/知识/学习与心智';    Dest = '知识/学习与心智' },
  @{ Src = '仓库区/知识/娱乐与文化';    Dest = '知识/娱乐与文化' },
  @{ Src = '仓库区/知识/生活与技能';    Dest = '知识/生活与技能' }
)

# ---- 清掉上一次生成的目录（只在本仓库目录内操作）----
foreach ($d in @('手艺', '知识', 'assets')) {
  $p = Join-Path $root $d
  if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}

# ---- 复制笔记 ----
$notes = @()
foreach ($s in $selection) {
  $src = Join-Path $Vault $s.Src
  if (-not (Test-Path $src)) { throw "源目录不存在: $src" }
  $dst = Join-Path $root $s.Dest
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
  $notes += Get-ChildItem $dst -Recurse -File -Filter '*.md'
}

# ---- 附件索引（按文件名）----
$attachMap = @{}
$dupNames = @()
Get-ChildItem $Vault -Recurse -File | Where-Object {
  $_.Extension -ne '.md' -and $_.FullName -notmatch '\\\.git\\'
} | ForEach-Object {
  if (-not $attachMap.ContainsKey($_.Name)) { $attachMap[$_.Name] = $_.FullName }
  else { $dupNames += $_.Name }
}

$noteNames = @{}
foreach ($n in $notes) { $noteNames[$n.BaseName] = $true }

# ---- 处理链接 + 复制被引用的附件 ----
$assetsDir = Join-Path $root 'assets'
New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
$copiedAssets = @{}
$missingAssets = @()
$strippedLinks = New-Object System.Collections.Generic.List[string]

$linkRe = [regex]'(!?)\[\[([^\]\|#]*)(#[^\]]*)?(\|[^\]]*)?\]\]'
$utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($n in $notes) {
  $text = [IO.File]::ReadAllText($n.FullName, [Text.Encoding]::UTF8)
  $orig = $text
  $text = $linkRe.Replace($text, {
    param($m)
    $bang = $m.Groups[1].Value
    $target = $m.Groups[2].Value.Trim()
    $heading = $m.Groups[3].Value
    $alias = $m.Groups[4].Value
    if ($bang -eq '!') {
      # 附件：保留原样，稍后复制文件
      return $m.Value
    }
    if ($noteNames.ContainsKey($target)) { return $m.Value }
    # 指向私有笔记：剥掉链接，只留显示文字
    $shown = if ($alias) { $alias.TrimStart('|').Trim() } else { $target }
    if ($shown -match '^\d+$') { $shown = $target }
    $strippedLinks.Add("$($n.Name) -> [[$target]]")
    return $shown
  })
  if ($text -ne $orig) { [IO.File]::WriteAllText($n.FullName, $text, $utf8) }
}

# 扫描附件引用并复制
foreach ($n in $notes) {
  $text = [IO.File]::ReadAllText($n.FullName, [Text.Encoding]::UTF8)
  foreach ($m in [regex]::Matches($text, '!\[\[([^\]\|#]+)')) {
    $name = $m.Groups[1].Value.Trim()
    $fileName = [IO.Path]::GetFileName($name)
    if ($copiedAssets.ContainsKey($fileName)) { continue }
    if ($attachMap.ContainsKey($fileName)) {
      Copy-Item -LiteralPath $attachMap[$fileName] -Destination (Join-Path $assetsDir $fileName) -Force
      $copiedAssets[$fileName] = $true
    } else {
      $missingAssets += "$($n.Name) -> $fileName"
    }
  }
}

# ---- README ----
$today = Get-Date -Format 'yyyy-MM-dd'
$readme = @"
# digital-garden

公开笔记仓库：只放愿意公开的手艺与知识类内容，私人日志、健康、情感、政治与工作区笔记不在其中。

## 结构

- ``手艺/`` — 工具与技能教程（AI、Office、Windows、开发、浏览器、计算机理论等）
- ``知识/`` — 科技与工程、数理与科学、自然与地理、学习与心智、娱乐与文化、生活与技能
- ``assets/`` — 笔记里引用的图片与附件

## 说明

- 笔记在 Obsidian 中编写，图片引用使用 ``![[文件名]]`` 语法，在 GitHub 上不会内嵌显示。
- 内容由 ``sync.ps1`` 从私有库按目录白名单同步，同步时会剥掉指向私有笔记的链接。
- 本仓库不含任何个人身份、联系方式、健康或私人生活内容。

最后同步：$today，共 $($notes.Count) 篇。
"@
[IO.File]::WriteAllText((Join-Path $root 'README.md'), $readme, $utf8)

# ---- 隐私自检：输出目录里不允许出现的东西 ----
$patterns = @(
  @{ Label = '手机号'; Re = '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)' },
  @{ Label = '邮箱';   Re = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' },
  @{ Label = '身份证'; Re = '[1-9][0-9]{5}(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx]' },
  @{ Label = '实名';   Re = '15396887023|2160444959|武豪' },
  @{ Label = '密钥';   Re = 'sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}' }
)
$problems = @()
foreach ($n in $notes) {
  $text = [IO.File]::ReadAllText($n.FullName, [Text.Encoding]::UTF8)
  foreach ($p in $patterns) {
    foreach ($m in [regex]::Matches($text, $p.Re)) {
      if ($p.Label -eq '邮箱' -and $m.Value -match 'users\.noreply\.github\.com|@example\.(com|org)') { continue }
      $problems += "$($p.Label) in $($n.Name): $($m.Value)"
    }
  }
}

Write-Host ("笔记 {0} 篇；附件 {1} 个；剥离私有链接 {2} 处；缺失附件 {3} 个" -f $notes.Count, $copiedAssets.Count, $strippedLinks.Count, $missingAssets.Count)
if ($missingAssets.Count -gt 0) {
  Write-Host "缺失附件：" -ForegroundColor Yellow
  $missingAssets | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
}
if ($problems.Count -gt 0) {
  Write-Host "隐私自检未通过：" -ForegroundColor Red
  $problems | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
  throw "输出目录里发现敏感内容，已停止，未提交。"
}
Write-Host "隐私自检通过。" -ForegroundColor Green

if ($Commit -or $Push) {
  git add -A
  $status = git status --porcelain
  if ($status) {
    if (-not $Message) { $Message = "sync: $today" }
    git commit -m $Message | Out-Null
    Write-Host "已提交：$Message"
  } else {
    Write-Host "没有变化，跳过提交。"
  }
}
if ($Push) {
  git push origin main
  Write-Host "已推送。"
}
