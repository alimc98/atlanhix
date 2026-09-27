Add-Type -AssemblyName System.Drawing
# Build a multi-resolution .ico from the intro wordmark on an app-tinted
# rounded tile: 16/32/48/256 px.
$src = 'F:\atlan\atlanhix\assets\brand\intro.png'
$out = 'F:\atlan\atlanhix\windows\runner\resources\app_icon.ico'
$logo = [System.Drawing.Image]::FromFile($src)

$sizes = @(16, 32, 48, 256)
$frames = @()
foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap($s, $s)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  # rounded dark tile (app background #0A0B0E)
  $r = [Math]::Max(2, [int]($s * 0.22))
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, 2*$r, 2*$r, 180, 90)
  $path.AddArc($s-2*$r, 0, 2*$r, 2*$r, 270, 90)
  $path.AddArc($s-2*$r, $s-2*$r, 2*$r, 2*$r, 0, 90)
  $path.AddArc(0, $s-2*$r, 2*$r, 2*$r, 90, 90)
  $path.CloseFigure()
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 10, 11, 14))
  $g.FillPath($brush, $path)
  # wordmark fitted inside with padding
  $pad = [Math]::Max(1, [int]($s * 0.14))
  $availW = $s - 2*$pad; $availH = $s - 2*$pad
  $scale = [Math]::Min($availW / $logo.Width, $availH / $logo.Height)
  $lw = [int]($logo.Width * $scale); $lh = [int]($logo.Height * $scale)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.DrawImage($logo, [int](($s-$lw)/2), [int](($s-$lh)/2), $lw, $lh)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $frames += ,@($s, $ms.ToArray())
  $ms.Dispose(); $bmp.Dispose()
}
$logo.Dispose()

# assemble the ICO container (PNG-compressed frames are valid for Vista+)
$msOut = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($msOut)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
  $s = $f[0]; $data = $f[1]
  $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
  $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
  $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32)
  $bw.Write([uint32]$data.Length); $bw.Write([uint32]$offset)
  $offset += $data.Length
}
foreach ($f in $frames) { $bw.Write($f[1]) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($out, $msOut.ToArray())
$bw.Dispose(); $msOut.Dispose()
Write-Output ("ico written: $out (" + (Get-Item $out).Length + " bytes)")
