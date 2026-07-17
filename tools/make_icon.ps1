# ============================================================
# make_icon.ps1 - Genera assets\icon.ico (multi-tamano, entradas PNG)
# Diseno placeholder de marca: cuadrado redondeado con degradado
# llama (naranja->rojo) y una "F" blanca. Reemplazable por un .ico
# profesional cuando exista arte definitivo.
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_icon.ps1
# ============================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$assetsDir = Join-Path $root "assets"
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
$outIco = Join-Path $assetsDir "icon.ico"

function New-IconPng([int]$Size) {
    $bmp = New-Object Drawing.Bitmap($Size, $Size)
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gfx.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAlias
    $gfx.Clear([Drawing.Color]::Transparent)

    $margin = [Math]::Max(1, [int]($Size * 0.04))
    $radius = [Math]::Max(2, [int]($Size * 0.22))
    $rect = New-Object Drawing.Rectangle($margin, $margin, ($Size - 2 * $margin), ($Size - 2 * $margin))

    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [Drawing.Color]::FromArgb(255, 255, 122, 0),
        [Drawing.Color]::FromArgb(255, 200, 16, 46),
        [Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
    )
    $gfx.FillPath($brush, $path)

    $fontSize = [float]($Size * 0.62)
    $font = New-Object Drawing.Font("Segoe UI", $fontSize, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    $textRect = New-Object Drawing.RectangleF(0, ($Size * 0.02), $Size, $Size)
    $gfx.DrawString("F", $font, [Drawing.Brushes]::White, $textRect, $format)

    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $gfx.Dispose(); $bmp.Dispose(); $font.Dispose(); $brush.Dispose(); $path.Dispose()
    return $ms.ToArray()
}

# Convierte el PNG de un tamano a entrada DIB clasica (BGRA bottom-up + mascara AND).
# Los compiladores de recursos (csc /win32icon) y GDI+ prefieren DIB para tamanos
# chicos; PNG solo se usa para la entrada de 256px (estandar desde Vista).
function ConvertTo-IconDib([byte[]]$PngBytes, [int]$Size) {
    $ms = New-Object IO.MemoryStream(, $PngBytes)
    $bmp = New-Object Drawing.Bitmap($ms)

    $out = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($out)
    # BITMAPINFOHEADER (alto doble: imagen + mascara)
    $bw.Write([uint32]40)
    $bw.Write([int32]$Size)
    $bw.Write([int32]($Size * 2))
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]0)   # BI_RGB
    $bw.Write([uint32]0); $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)

    # Pixeles BGRA bottom-up
    for ($y = $Size - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $Size; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }

    # Mascara AND (todo 0: la transparencia la da el canal alfa), filas alineadas a 32 bits
    $maskRowBytes = [int][Math]::Ceiling($Size / 32.0) * 4
    $maskRow = New-Object byte[] $maskRowBytes
    for ($y = 0; $y -lt $Size; $y++) { $bw.Write($maskRow) }

    $bw.Flush()
    $result = $out.ToArray()
    $bw.Dispose(); $out.Dispose(); $bmp.Dispose(); $ms.Dispose()
    return , $result
}

# Todas las entradas en DIB clasico: el csc.exe de .NET Framework (con el
# que se compila el stub) rechaza iconos con entradas PNG comprimidas.
$sizes = @(16, 24, 32, 48, 64)
$images = @()
foreach ($size in $sizes) {
    $png = New-IconPng $size
    $images += , (ConvertTo-IconDib $png $size)
}

$stream = New-Object IO.MemoryStream
$writer = New-Object IO.BinaryWriter($stream)
$writer.Write([uint16]0)              # reservado
$writer.Write([uint16]1)              # tipo: icono
$writer.Write([uint16]$sizes.Count)   # cantidad

$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $size = $sizes[$i]
    $bytes = $images[$i]
    $dim = if ($size -ge 256) { 0 } else { $size }
    $writer.Write([byte]$dim)          # ancho (0 = 256)
    $writer.Write([byte]$dim)          # alto
    $writer.Write([byte]0)             # paleta
    $writer.Write([byte]0)             # reservado
    $writer.Write([uint16]1)           # planos
    $writer.Write([uint16]32)          # bpp
    $writer.Write([uint32]$bytes.Length)
    $writer.Write([uint32]$offset)
    $offset += $bytes.Length
}
foreach ($bytes in $images) { $writer.Write($bytes) }
$writer.Flush()
[IO.File]::WriteAllBytes($outIco, $stream.ToArray())
$writer.Dispose(); $stream.Dispose()

# Verificacion: .NET debe poder cargarlo
$icon = New-Object Drawing.Icon($outIco)
Write-Host ("OK: {0} ({1} bytes, {2} tamanos)" -f $outIco, (Get-Item $outIco).Length, $sizes.Count)
$icon.Dispose()
