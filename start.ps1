# Paytm Vyaapar Saathi - serves the app on http://localhost:8000 with no Python needed.
# Uses a raw TCP listener so it works without administrator rights.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$file = Join-Path $root "Paytm_Vyaapar_Saathi.html"
$port = 8000

if (-not (Test-Path $file)) {
  Write-Host "Cannot find Paytm_Vyaapar_Saathi.html next to this script."
  exit 1
}

$bytes = [System.IO.File]::ReadAllBytes($file)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
$listener.Start()

$url = "http://localhost:$port/Paytm_Vyaapar_Saathi.html"
Write-Host ""
Write-Host "  Paytm Vyaapar Saathi"
Write-Host "  --------------------"
Write-Host "  Opening: $url"
Write-Host "  The microphone works only on this address."
Write-Host "  Press Ctrl+C in this window to stop."
Write-Host ""
Start-Process $url

while ($true) {
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $requestLine = $reader.ReadLine()
    while ($reader.ReadLine()) { }   # drain headers

    if ($requestLine -match "GET\s+/(Paytm_Vyaapar_Saathi\.html)?\s") {
      $head = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
      $stream.Write($hb, 0, $hb.Length)
      $stream.Write($bytes, 0, $bytes.Length)
    } else {
      $body = [System.Text.Encoding]::UTF8.GetBytes("not found")
      $head = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
      $stream.Write($hb, 0, $hb.Length)
      $stream.Write($body, 0, $body.Length)
    }
    $stream.Flush()
  } catch { }
  finally { $client.Close() }
}
